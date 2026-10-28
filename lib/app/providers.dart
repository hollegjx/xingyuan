import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/timezone.dart' as tz;

import '../data/local/app_database.dart';
import '../data/local/local_goal_repository.dart';
import '../data/local/open_database.dart';
import '../features/goals/domain/goal.dart';
import '../features/reminders/notification_permissions.dart';
import '../features/reminders/reminder_coordinator.dart';
import '../features/reminders/reminder_notifications.dart';
import '../shared/app_clock.dart';
import '../shared/local_date.dart';

class DeviceClock implements AppClock {
  tz.Location? _location;

  Future<void> refreshZone() async {
    final zone = await FlutterTimezone.getLocalTimezone();
    _location = tz.getLocation(zone.identifier);
  }

  @override
  ClockReading read() => ClockReading(
    instant: DateTime.now(),
    location: _location ?? (throw StateError('Device time zone is not ready')),
  );
}

final _deviceClockProvider = Provider((ref) => DeviceClock());
final clockProvider = Provider<AppClock>(
  (ref) => ref.watch(_deviceClockProvider),
);
final refreshClockProvider = Provider<Future<void> Function()>(
  (ref) => ref.watch(_deviceClockProvider).refreshZone,
);

final environmentProvider =
    AsyncNotifierProvider<EnvironmentController, ClockReading>(
      EnvironmentController.new,
      retry: (retryCount, error) => null,
    );

class EnvironmentController extends AsyncNotifier<ClockReading> {
  Future<ClockReading>? _refreshing;
  Timer? _midnight;

  @override
  Future<ClockReading> build() async {
    final periodic = Timer.periodic(
      const Duration(seconds: 30),
      (_) => refresh().ignore(),
    );
    ref.onDispose(() {
      periodic.cancel();
      _midnight?.cancel();
    });
    return _read();
  }

  Future<ClockReading> _read() async {
    await ref.read(refreshClockProvider)().timeout(const Duration(seconds: 10));
    if (!ref.mounted) throw StateError('Clock refresh was disposed');
    final reading = ref.read(clockProvider).read();
    final local = reading.localTime;
    final midnight = tz.TZDateTime(
      local.location,
      local.year,
      local.month,
      local.day + 1,
    );
    _midnight?.cancel();
    _midnight = Timer(
      midnight.difference(local) + const Duration(milliseconds: 20),
      () => refresh().ignore(),
    );
    return reading;
  }

  Future<ClockReading> refresh() {
    return _refreshing ??= _update().whenComplete(() => _refreshing = null);
  }

  Future<ClockReading> _update() async {
    try {
      final reading = await _read();
      if (ref.mounted) state = AsyncData(reading);
      return reading;
    } catch (error, stack) {
      if (ref.mounted) state = AsyncError(error, stack);
      rethrow;
    }
  }
}

final databaseFactoryProvider = Provider<AppDatabase Function()>(
  (ref) => openAppDatabase,
);

class _DatabaseClosures {
  AppDatabase? _database;
  Future<void>? _opening;
  Future<void>? _closing;

  void release(AppDatabase database, Future<void> opening) {
    assert(_database == null);
    _database = database;
    _opening = opening;
    finish().ignore();
  }

  Future<void> finish() {
    if (_closing case final pending?) return pending;
    final database = _database;
    if (database == null) return Future<void>.value();
    return _closing = _close(database, _opening!)
        .then((_) {
          _database = null;
          _opening = null;
        })
        .whenComplete(() => _closing = null);
  }

  Future<void> _close(AppDatabase database, Future<void> opening) async {
    try {
      await opening;
    } catch (_) {
      // Opening errors are exposed by databaseProvider; disposal still runs.
    }
    await database.close();
  }
}

final _databaseClosuresProvider = Provider((ref) => _DatabaseClosures());
final reminderWorkProvider = Provider((ref) => SerialWork());

final databaseProvider = FutureProvider<AppDatabase>((ref) async {
  final factory = ref.watch(databaseFactoryProvider);
  final closures = ref.watch(_databaseClosuresProvider);
  await closures.finish();
  if (!ref.mounted) throw StateError('Database opening was disposed');
  final database = factory();
  final work = ref.read(reminderWorkProvider);
  final opening = database.customSelect('SELECT 1').get().then<void>((_) {});
  ref.onDispose(() {
    final drained = work.drained;
    closures.release(database, opening.then((_) => drained));
  });
  await opening;
  return database;
}, retry: (retryCount, error) => null);

final goalRepositoryProvider = FutureProvider<LocalGoalRepository>((ref) async {
  final clock = ref.watch(clockProvider);
  return LocalGoalRepository(await ref.watch(databaseProvider.future), clock);
}, retry: (retryCount, error) => null);

final goalsProvider = StreamProvider<List<Goal>>((ref) async* {
  final repository = await ref
      .watch(goalRepositoryProvider.future)
      .timeout(const Duration(seconds: 15));
  if (!ref.mounted) return;
  yield await repository.loadGoals().timeout(const Duration(seconds: 15));
  if (!ref.mounted) return;
  yield* repository.watchGoals();
}, retry: (retryCount, error) => null);

void retryLocalRecords(WidgetRef ref) {
  ref.invalidate(databaseProvider);
  ref.invalidate(goalsProvider);
}

final notificationOpenProvider = NotifierProvider<NotificationOpen, int>(
  NotificationOpen.new,
);

class NotificationOpen extends Notifier<int> {
  @override
  int build() => 0;
  void opened() => state++;
}

final _iosNotificationsProvider = Provider(
  (ref) => IosNotificationPermissions(
    onNotification: () {
      if (ref.mounted) ref.read(notificationOpenProvider.notifier).opened();
    },
  ),
);
final notificationPermissionsProvider = Provider<NotificationPermissions>(
  (ref) => ref.watch(_iosNotificationsProvider),
);
final reminderNotificationsProvider = Provider<ReminderNotifications>(
  (ref) => ref.watch(_iosNotificationsProvider),
);

final reminderCoordinatorProvider = FutureProvider<ReminderCoordinator>((
  ref,
) async {
  final repository = await ref.watch(goalRepositoryProvider.future);
  if (!ref.mounted) throw StateError('Reminder coordinator was disposed');
  final coordinator = ReminderCoordinator(
    repository: repository,
    clock: ref.watch(clockProvider),
    permissions: ref.watch(notificationPermissionsProvider),
    notifications: ref.watch(reminderNotificationsProvider),
  );
  ref.onDispose(() => coordinator.disposed = true);
  return coordinator;
}, retry: (retryCount, error) => null);

final reminderReportProvider =
    AsyncNotifierProvider<ReminderController, ReminderReport>(
      ReminderController.new,
      retry: (retryCount, error) => null,
    );

class ReminderController extends AsyncNotifier<ReminderReport> {
  Future<ReminderReport>? _initial;
  Future<void>? _refreshing;
  bool _again = false;
  int _epoch = 0;

  @override
  Future<ReminderReport> build() {
    _epoch++;
    ref.listen(environmentProvider, (_, next) {
      if (next.hasValue && !next.isLoading) refresh().ignore();
    });
    ref.listen(notificationAccessProvider, (previous, next) {
      if (next.hasValue && previous?.value != next.value) refresh().ignore();
    });
    // Dependency invalidation replaces the coordinator after DB recovery.
    final coordinator = ref.watch(reminderCoordinatorProvider.future);
    return _initial = _run(coordinator);
  }

  Future<ReminderReport> _run(Future<ReminderCoordinator> coordinator) async {
    final service = await coordinator;
    if (!ref.mounted) throw StateError('Reminder controller was disposed');
    return ref.read(reminderWorkProvider).run(service.reconcile);
  }

  Future<void> refresh() {
    _again = true;
    return _refreshing ??= _refresh().whenComplete(() => _refreshing = null);
  }

  Future<void> _refresh() async {
    try {
      await _initial;
    } catch (_) {
      // A failed initial reconciliation is retryable without changing records.
    }
    while (_again && ref.mounted) {
      _again = false;
      final epoch = _epoch;
      final result = await AsyncValue.guard(
        () => _run(ref.read(reminderCoordinatorProvider.future)),
      );
      if (ref.mounted && epoch == _epoch) state = result;
    }
  }
}

final notificationAccessProvider =
    AsyncNotifierProvider<NotificationAccessController, NotificationAccess>(
      NotificationAccessController.new,
      retry: (retryCount, error) => null,
    );

class NotificationAccessController extends AsyncNotifier<NotificationAccess> {
  Future<NotificationAccess>? _initialRead;
  Future<void>? _refreshing;

  @override
  Future<NotificationAccess> build() => _initialRead = Future.sync(
    () => ref.watch(notificationPermissionsProvider).read(),
  ).timeout(const Duration(seconds: 10));

  Future<void> refresh({bool request = false}) {
    // Permission reads and prompts must finish in order, including initial load.
    final previous =
        _refreshing ??
        _initialRead?.then<void>(
          (_) {},
          onError: (Object _, StackTrace _) {},
        ) ??
        Future<void>.value();
    final operation = previous.then((_) async {
      if (!ref.mounted) return;
      state = const AsyncLoading();
      final result = await AsyncValue.guard(() async {
        final service = ref.read(notificationPermissionsProvider);
        return (request ? service.request() : service.read()).timeout(
          Duration(seconds: request ? 60 : 10),
        );
      });
      if (ref.mounted) state = result;
    });
    _refreshing = operation;
    return operation.whenComplete(() {
      if (identical(_refreshing, operation)) _refreshing = null;
    });
  }
}

final goalCommandsProvider = NotifierProvider<GoalCommands, Set<int>>(
  GoalCommands.new,
);

class GoalCommands extends Notifier<Set<int>> {
  @override
  Set<int> build() => const {};

  Future<T> _perform<T>(int key, Future<T> Function() operation) async {
    if (state.contains(key)) {
      throw const GoalRuleException('正在保存，请稍候');
    }
    state = {...state, key};
    try {
      await ref.read(environmentProvider.notifier).refresh();
      final result = await ref.read(reminderWorkProvider).run(operation);
      if (ref.mounted) {
        ref.read(reminderReportProvider.notifier).refresh().ignore();
      }
      return result;
    } finally {
      if (ref.mounted) state = {...state}..remove(key);
    }
  }

  Future<void> _requestIfEnabled(bool enabled) async {
    if (enabled) {
      await ref
          .read(notificationAccessProvider.notifier)
          .refresh(request: true);
    }
  }

  Future<int> create(GoalDraft draft) => _perform(0, () async {
    final repository = await ref.read(goalRepositoryProvider.future);
    final id = await repository.create(draft);
    await _requestIfEnabled(draft.reminderEnabled);
    return id;
  });

  Future<void> edit(Goal original, GoalDraft draft) =>
      _perform(original.id, () async {
        final repository = await ref.read(goalRepositoryProvider.future);
        await repository.edit(original.id, draft);
        await _requestIfEnabled(
          draft.reminderEnabled && !original.reminder.enabled,
        );
      });

  Future<void> setCompleted(int id, bool value, LocalDate day) =>
      _perform(id, () async {
        final repository = await ref.read(goalRepositoryProvider.future);
        await repository.setCompleted(id, value, expectedDay: day);
      });

  Future<void> archive(int id) => _perform(id, () async {
    final repository = await ref.read(goalRepositoryProvider.future);
    await repository.archive(id);
  });
}
