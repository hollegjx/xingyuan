import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:habit_checkin/features/reminders/notification_permissions.dart';
import 'package:habit_checkin/features/reminders/reminder_coordinator.dart';
import 'package:habit_checkin/features/reminders/reminder_notifications.dart';
import 'package:habit_checkin/shared/local_date.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'support/test_clock.dart';
import 'support/test_reminder_notifications.dart';
import 'support/ui_harness.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);
  late AppDatabase db;
  late TestClock clock;
  late LocalGoalRepository repository;
  late TestNotificationPermissions permissions;
  late TestReminderNotifications platform;
  late ReminderCoordinator coordinator;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    clock = TestClock();
    repository = LocalGoalRepository(db, clock);
    permissions = TestNotificationPermissions()
      ..access = NotificationAccess.allowed;
    platform = TestReminderNotifications();
    coordinator = ReminderCoordinator(
      repository: repository,
      clock: clock,
      permissions: permissions,
      notifications: platform,
    );
  });
  tearDown(() => db.close());

  GoalDraft draft({
    String title = 'TEST private title',
    int minute = 1200,
    bool enabled = true,
    int weekdays = 127,
    LocalDate? single,
  }) => GoalDraft(
    title: title,
    kind: single == null ? GoalKind.habit : GoalKind.single,
    reminderEnabled: enabled,
    reminderMinute: minute,
    weekdays: weekdays,
    plannedDay: single,
  );

  Map<String, dynamic> decoded(PendingReminder item) =>
      jsonDecode(item.payload!) as Map<String, dynamic>;
  List<PendingReminder> forDay(LocalDate day) => platform.requests.values
      .where((item) => decoded(item)['day'] == day.key)
      .toList();

  test(
    '64 nearest dates, explicit boundary, stable IDs and private payload',
    () async {
      final id = await repository.create(draft());
      final first = await coordinator.reconcile();
      expect(platform.requests, hasLength(64));
      final coverage = first.goals[id]!;
      expect(coverage.status, 'limited');
      expect(coverage.times, hasLength(64));
      expect(
        LocalDate.fromDateTime(
          tz.TZDateTime.from(coverage.firstUncovered!, clock.location),
        ),
        clock.day.addDays(64),
      );
      expect(
        platform.requests.values.every(
          (item) => !item.payload!.contains('private title'),
        ),
        isTrue,
      );
      final ids = platform.requests.keys.toSet();
      await coordinator.reconcile();
      expect(platform.requests.keys.toSet(), ids);
      expect(platform.scheduled, hasLength(64));
      expect(permissions.requests, 0);
    },
  );

  test(
    'complete cancels only today; undo restores before trigger using same ID',
    () async {
      final id = await repository.create(draft());
      await coordinator.reconcile();
      final todayId = forDay(clock.day).single.id;
      final tomorrowId = forDay(clock.day.addDays(1)).single.id;
      await repository.setCompleted(id, true, expectedDay: clock.day);
      await coordinator.reconcile();
      expect(forDay(clock.day), isEmpty);
      expect(platform.requests.containsKey(tomorrowId), isTrue);
      await repository.setCompleted(id, false, expectedDay: clock.day);
      await coordinator.reconcile();
      expect(forDay(clock.day).single.id, todayId);
      expect(platform.requests, hasLength(64));
    },
  );

  test(
    'elapsed or ambiguously delivered occurrence is never issued again',
    () async {
      final id = await repository.create(draft(minute: 13 * 60));
      await coordinator.reconcile();
      clock.setDay(2026, 10, 9, hour: 14);
      await repository.edit(id, draft(minute: 16 * 60));
      await coordinator.reconcile();
      expect(forDay(clock.day), isEmpty);
      await repository.setCompleted(id, true, expectedDay: clock.day);
      await coordinator.reconcile();
      await repository.setCompleted(id, false, expectedDay: clock.day);
      await coordinator.reconcile();
      expect(forDay(clock.day), isEmpty);
      expect(forDay(clock.day.addDays(1)), hasLength(1));
    },
  );

  test('confirmed cancellation before due allows a new later time', () async {
    final id = await repository.create(draft(minute: 13 * 60));
    await coordinator.reconcile();
    await repository.edit(id, draft(enabled: false, minute: 13 * 60));
    await coordinator.reconcile();
    clock.setDay(2026, 10, 9, hour: 14);
    await repository.edit(id, draft(minute: 16 * 60));
    await coordinator.reconcile();
    expect(forDay(clock.day), hasLength(1));
  });

  test(
    'delivered receipt prevents duplicates after clock moves backward',
    () async {
      final id = await repository.create(draft(minute: 13 * 60));
      await coordinator.reconcile();
      final arrival = forDay(clock.day).single;
      platform.arrivals.add(arrival);
      platform.requests.remove(arrival.id);
      await repository.edit(id, draft(minute: 16 * 60));
      await coordinator.reconcile();
      expect(forDay(clock.day), isEmpty);
    },
  );

  test('denial cancels existing plans, allowing again replenishes', () async {
    final id = await repository.create(draft());
    await coordinator.reconcile();
    permissions.access = NotificationAccess.off;
    expect((await coordinator.reconcile()).goals[id]!.status, 'denied');
    expect(platform.requests, isEmpty);
    expect((await repository.loadGoals()).single.reminder.enabled, isTrue);
    permissions.access = NotificationAccess.allowed;
    await coordinator.reconcile();
    expect(platform.requests, hasLength(64));
    expect(permissions.requests, 0);
  });

  test('foreign and other-owner pending requests are preserved and consume capacity', () async {
    platform.requests[500] = const PendingReminder(500, 'foreign');
    final other = LocalGoalRepository(db, clock, owner: 'other');
    await other.create(draft());
    await ReminderCoordinator(
      repository: other,
      clock: clock,
      permissions: permissions,
      notifications: platform,
    ).reconcile();
    final foreignIds = platform.requests.keys.toSet();
    final id = await repository.create(draft());
    final report = await coordinator.reconcile();
    expect(report.goals[id]!.times, isEmpty);
    expect(report.goals[id]!.firstUncovered, isNotNull);
    expect(platform.requests.keys.toSet(), foreignIds);
    expect(platform.cancelled, isEmpty);
  });

  test(
    'ownership transfer cancels old payloads before replacing them',
    () async {
      const target = 'user:11111111-1111-4111-8111-111111111111';
      final id = await repository.create(draft());
      await coordinator.reconcile();
      final ids = platform.requests.keys.toSet();
      expect(
        platform.requests.values.every((r) => decoded(r)['owner'] == 'guest'),
        isTrue,
      );
      await (db.update(db.goals)..where((row) => row.id.equals(id))).write(
        const GoalsCompanion(owner: Value(target)),
      );
      final transferred = ReminderCoordinator(
        repository: LocalGoalRepository(db, clock, owner: target),
        clock: clock,
        permissions: permissions,
        notifications: platform,
      );
      platform.ignoreCancel = true;
      await expectLater(transferred.reconcile(), throwsStateError);
      expect(
        platform.requests.values.every((r) => decoded(r)['owner'] == 'guest'),
        isTrue,
      );
      expect(platform.scheduled, hasLength(64));
      platform.ignoreCancel = false;
      await transferred.reconcile();
      expect(platform.requests.keys.toSet(), ids);
      expect(
        platform.requests.values.every((r) => decoded(r)['owner'] == target),
        isTrue,
      );
      expect(
        (await db.select(db.reminderOccurrences).get()).every(
          (r) => r.owner == target,
        ),
        isTrue,
      );
      await coordinator.reconcile();
      expect(platform.requests, hasLength(64));
    },
  );

  test('more than 64 enabled goals report unserved goals without dropping silently', () async {
    for (var i = 0; i < 65; i++) {
      await repository.create(draft());
    }
    final report = await coordinator.reconcile();
    expect(platform.requests, hasLength(64));
    expect(report.goals.values.where((g) => g.times.isEmpty), hasLength(1));
    expect(report.goals.values.every((g) => g.firstUncovered != null), isTrue);
  });

  test(
    'edit replaces time, future frequency starts tomorrow, archive cancels',
    () async {
      final id = await repository.create(draft());
      await coordinator.reconcile();
      final todayId = forDay(clock.day).single.id;
      await repository.edit(id, draft(minute: 18 * 60, weekdays: 1));
      await coordinator.reconcile();
      expect(forDay(clock.day).single.id, todayId);
      expect(platform.times[todayId]!.hour, 18);
      expect(forDay(clock.day.addDays(1)), isEmpty);
      expect(forDay(clock.day.addDays(3)), hasLength(1)); // Monday.
      await repository.archive(id);
      expect((await coordinator.reconcile()).goals[id]!.status, 'disabled');
      expect(platform.requests, isEmpty);
    },
  );

  test('single tasks remind only on planned day, no late catch-up', () async {
    final id = await repository.create(
      draft(single: clock.day, minute: 11 * 60),
    );
    expect((await coordinator.reconcile()).goals[id]!.status, 'noFuture');
    expect(platform.requests, isEmpty);
    await repository.edit(id, draft(single: clock.day.addDays(1)));
    await coordinator.reconcile();
    expect(platform.requests, hasLength(1));
    clock.setDay(2026, 10, 11);
    expect((await coordinator.reconcile()).goals[id]!.status, 'noFuture');
    expect(platform.requests, isEmpty);
  });

  test(
    'silent system eviction is detected and retry restores the queue',
    () async {
      final id = await repository.create(draft());
      platform.dropSchedule = true;
      await expectLater(coordinator.reconcile(), throwsStateError);
      final goal = (await repository.loadGoals()).single;
      expect(goal.reminder.needsReconcile, isTrue);
      expect(goal.reminder.status, 'error');
      platform.dropSchedule = false;
      expect((await coordinator.reconcile()).goals[id]!.times, hasLength(64));
    },
  );

  test(
    'failed cancellation does not erase saved completion and retries safely',
    () async {
      final id = await repository.create(draft());
      await coordinator.reconcile();
      platform.ignoreCancel = true;
      await repository.setCompleted(id, true, expectedDay: clock.day);
      await expectLater(coordinator.reconcile(), throwsStateError);
      expect(
        (await repository.loadGoals()).single.completionOn(clock.day),
        isNotNull,
      );
      platform.ignoreCancel = false;
      await coordinator.reconcile();
      expect(forDay(clock.day), isEmpty);
      expect(
        (await repository.loadGoals()).single.reminder.needsReconcile,
        isFalse,
      );
    },
  );

  test(
    'revision change during scheduling cannot leave an old plan active',
    () async {
      final id = await repository.create(draft());
      var changed = false;
      platform.onSchedule = (_) async {
        if (!changed) {
          changed = true;
          await repository.edit(id, draft(minute: 18 * 60));
        }
      };
      final report = await coordinator.reconcile();
      expect(report.goals[id]!.times, hasLength(64));
      expect(platform.times.values.every((at) => at.hour == 18), isTrue);
      expect(
        (await repository.loadGoals()).single.reminder.needsReconcile,
        isFalse,
      );
    },
  );

  test('ambiguous schedule failure is journaled and repaired without duplicate IDs', () async {
    await repository.create(draft());
    platform.onSchedule = (_) async => throw StateError('after scheduling');
    await expectLater(coordinator.reconcile(), throwsStateError);
    expect(platform.requests, hasLength(1));
    final id = platform.requests.keys.single;
    platform.onSchedule = null;
    await coordinator.reconcile();
    expect(platform.requests, hasLength(64));
    expect(platform.scheduled.where((value) => value == id), hasLength(1));
  });

  test(
    'date passage replenishes and timezone changes replace future instants',
    () async {
      final id = await repository.create(draft());
      await coordinator.reconcile();
      final prior = (await coordinator.reconcile()).goals[id]!.times.first;
      clock.location = tz.getLocation('Europe/London');
      final changed = await coordinator.reconcile();
      expect(changed.goals[id]!.times.first, isNot(prior));
      clock.instant = clock.instant.add(const Duration(days: 80));
      final replenished = await coordinator.reconcile();
      expect(replenished.goals[id]!.times, hasLength(64));
      expect(
        replenished.goals[id]!.times.every(
          (time) => time.isAfter(clock.instant),
        ),
        isTrue,
      );
    },
  );

  test('file reopening preserves IDs and ended occurrences', () async {
    await db.close();
    final directory = await Directory.systemTemp.createTemp('reminder-ledger-');
    final file = File('${directory.path}/test.sqlite');
    final first = AppDatabase(NativeDatabase(file));
    final repo = LocalGoalRepository(first, clock);
    final service = ReminderCoordinator(
      repository: repo,
      clock: clock,
      permissions: permissions,
      notifications: platform,
    );
    final id = await repo.create(draft(minute: 13 * 60));
    await service.reconcile();
    final ids = platform.requests.keys.toSet();
    await first.close();
    final second = AppDatabase(NativeDatabase(file));
    try {
      final restored = LocalGoalRepository(second, clock);
      final reopened = ReminderCoordinator(
        repository: restored,
        clock: clock,
        permissions: permissions,
        notifications: platform,
      );
      await reopened.reconcile();
      expect(platform.requests.keys.toSet(), ids);
      clock.setDay(2026, 10, 9, hour: 14);
      await restored.edit(id, draft(minute: 16 * 60));
      await reopened.reconcile();
      expect(forDay(clock.day), isEmpty);
    } finally {
      await second.close();
      await directory.delete(recursive: true);
    }
  });

  test(
    'serial work never interleaves writes and continues after errors',
    () async {
      final work = SerialWork();
      final ready = Completer<void>();
      final events = <int>[];
      final first = work.run(() async {
        events.add(1);
        await ready.future;
        events.add(2);
        throw StateError('injected');
      });
      final failure = expectLater(first, throwsStateError);
      final second = work.run(() async => events.add(3));
      await Future<void>.delayed(Duration.zero);
      expect(events, [1]);
      ready.complete();
      await failure;
      await second;
      expect(events, [1, 2, 3]);
    },
  );
}
