import 'dart:convert';
import 'dart:math' as math;

import 'package:drift/drift.dart';

import '../../data/local/app_database.dart';
import '../../data/local/local_goal_repository.dart';
import '../../shared/app_clock.dart';
import '../goals/domain/goal.dart';
import 'domain/reminder_plan.dart';
import 'notification_permissions.dart';
import 'reminder_notifications.dart';
import 'reminder_payload.dart';

class SerialWork {
  Future<void> _tail = Future<void>.value();

  Future<void> get drained => _tail;

  Future<T> run<T>(Future<T> Function() action) {
    final next = _tail.then((_) => action());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }
}

class GoalReminderCoverage {
  const GoalReminderCoverage({
    required this.status,
    this.times = const [],
    this.firstUncovered,
  });

  final String status;
  final List<DateTime> times;
  final DateTime? firstUncovered;
}

class ReminderReport {
  const ReminderReport(this.goals, {this.checkedAt, this.zone});

  final Map<int, GoalReminderCoverage> goals;
  final DateTime? checkedAt;
  final String? zone;
}

class _Replan implements Exception {}

class ReminderCoordinator {
  ReminderCoordinator({
    required this.repository,
    required this.clock,
    required this.permissions,
    required this.notifications,
  });

  final LocalGoalRepository repository;
  final AppClock clock;
  final NotificationPermissions permissions;
  final ReminderNotifications notifications;
  bool disposed = false;
  AppDatabase get db => repository.db;

  String payload(StoredReminderOccurrence row) => reminderPayload(row);

  // Deleting a goal removes its ledger in the business transaction. These
  // durable intents bridge that commit and the subsequent platform calls.
  Future<void> _cancelDeletedGoals() async {
    final intents = await (db.select(
      db.reminderCancellations,
    )..where((row) => row.owner.equals(repository.owner))).get();
    if (intents.isEmpty) return;
    var pending = await notifications.pending();
    for (final intent in intents) {
      _checkAlive();
      final matches = pending.where((item) => item.id == intent.notificationId);
      if (matches.any(
        (item) => !sameReminderOccurrence(
          item.payload,
          intent.payload,
          intent.notificationId,
        ),
      )) {
        throw StateError('Deleted-goal notification identifier collision');
      }
      if (matches.isNotEmpty) {
        await notifications.cancel(intent.notificationId);
      }
      pending = await notifications.pending();
      _checkAlive();
      if (pending.any((item) => item.id == intent.notificationId)) {
        throw StateError('Deleted-goal notification cancellation unconfirmed');
      }
      await (db.delete(db.reminderCancellations)..where(
            (row) =>
                row.notificationId.equals(intent.notificationId) &
                row.owner.equals(intent.owner) &
                row.payload.equals(intent.payload),
          ))
          .go();
    }
  }

  bool _owns(PendingReminder item, StoredReminderOccurrence? row) {
    if (row == null || item.payload == null) return false;
    try {
      final decoded = jsonDecode(item.payload!);
      return decoded is Map<String, dynamic> &&
          decoded['source'] == 'habit-reminder-v1' &&
          decoded['owner'] == row.owner &&
          decoded['id'] == row.id &&
          decoded['goal'] == row.goalId &&
          decoded['day'] == row.day;
    } on FormatException {
      return false;
    }
  }

  void _checkAlive() {
    if (disposed) throw StateError('Reminder coordinator was disposed');
  }

  /// Runs on the shared serial queue before committing an identity switch.
  Future<void> suspendIdentity() async {
    _checkAlive();
    await _cancelDeletedGoals();
    final rows = await (db.select(
      db.reminderOccurrences,
    )..where((row) => row.owner.equals(repository.owner))).get();
    final byId = {for (final row in rows) row.id: row};
    var pending = await notifications.pending();
    final delivered = await notifications.delivered();
    bool isOwn(PendingReminder item) => _owns(item, byId[item.id]);
    bool claimsOwner(PendingReminder item) {
      try {
        final decoded = jsonDecode(item.payload ?? '');
        return decoded is Map<String, dynamic> &&
            decoded['source'] == 'habit-reminder-v1' &&
            decoded['owner'] == repository.owner;
      } on FormatException {
        return false;
      }
    }

    if (pending.any((item) => claimsOwner(item) && !isOwn(item))) {
      throw StateError('Untracked reminder prevents identity switch');
    }
    for (final row in rows) {
      if (pending.any((item) => item.id == row.id && !isOwn(item))) {
        throw StateError('Notification identifier collision');
      }
      if (pending.any((item) => item.id == row.id && isOwn(item)) ||
          (row.armed &&
              row.fireAt > clock.read().instant.microsecondsSinceEpoch)) {
        await notifications.cancel(row.id);
      }
    }
    pending = await notifications.pending();
    if (pending.any(claimsOwner)) {
      throw StateError('Identity reminder cancellation was not confirmed');
    }
    _checkAlive();
    await db.transaction(() async {
      for (final row in rows) {
        final ended =
            row.ended ||
            (row.armed &&
                row.fireAt <= clock.read().instant.microsecondsSinceEpoch) ||
            delivered.any((item) => item.id == row.id && isOwn(item));
        await (db.update(
          db.reminderOccurrences,
        )..where((r) => r.id.equals(row.id))).write(
          ReminderOccurrencesCompanion(
            armed: const Value(false),
            ended: Value(ended),
          ),
        );
      }
    });
  }

  Future<ReminderReport> reconcile() async {
    _checkAlive();
    try {
      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          return await _pass();
        } on _Replan {
          _checkAlive();
        }
      }
      throw StateError('Reminder plans changed while reconciling');
    } catch (_) {
      if (!disposed) {
        final goals = await repository.loadGoals();
        await _writeStatuses(
          {
            for (final goal in goals)
              goal.id: GoalReminderCoverage(
                status: goal.reminder.enabled || goal.reminder.needsReconcile
                    ? 'error'
                    : 'disabled',
              ),
          },
          goals,
          failed: true,
        );
      }
      rethrow;
    }
  }

  Future<ReminderReport> _pass() async {
    _checkAlive();
    await repository.requireActiveIdentity();
    await _cancelDeletedGoals();
    final goals = await repository.loadGoals();
    final goalIds = goals.map((goal) => goal.id).toSet();
    final rows = await (db.select(
      db.reminderOccurrences,
    )..where((row) => row.goalId.isIn(goalIds))).get();
    final now = clock.read();
    if (!goals.any((goal) => goal.reminder.enabled) &&
        !rows.any((row) => row.armed)) {
      final coverage = {
        for (final goal in goals)
          goal.id: const GoalReminderCoverage(status: 'disabled'),
      };
      await _writeStatuses(coverage, goals);
      return ReminderReport(coverage, checkedAt: now.instant, zone: now.zone);
    }

    final access = await permissions.read();
    var pending = await notifications.pending();
    final delivered = await notifications.delivered();
    _checkAlive();
    final byId = {for (final row in rows) row.id: row};
    bool owns(PendingReminder item) => _owns(item, byId[item.id]);
    final ended = <String>{};
    for (final row in rows) {
      final expired =
          row.armed && row.fireAt <= now.instant.microsecondsSinceEpoch;
      final arrived = delivered.any((item) => item.id == row.id && owns(item));
      if (row.ended || expired || arrived) {
        ended.add('${row.goalId}/${row.day}');
        if (!row.ended) {
          await (db.update(db.reminderOccurrences)
                ..where((entry) => entry.id.equals(row.id)))
              .write(const ReminderOccurrencesCompanion(ended: Value(true)));
        }
      }
    }
    final foreign = pending.where((item) => !owns(item)).length;
    final canSchedule = access != NotificationAccess.off;
    final plan = planReminders(
      goals: goals,
      now: now,
      ended: ended,
      capacity: canSchedule ? math.max(0, 64 - foreign) : 0,
    );
    final wanted = {for (final item in plan.selected) item.key: item};
    final cancelling = <StoredReminderOccurrence>[];
    for (final row in rows) {
      final desired = wanted['${row.goalId}/${row.day}'];
      final matches =
          desired != null &&
          row.owner == repository.owner &&
          desired.at.microsecondsSinceEpoch == row.fireAt &&
          row.zone == now.zone;
      if (!matches &&
          (pending.any((item) => item.id == row.id && owns(item)) ||
              row.armed)) {
        // Never remove a foreign request, even if its integer id collides.
        if (pending.any((item) => item.id == row.id && !owns(item))) {
          throw StateError('Notification identifier collision');
        }
        if (pending.any((item) => item.id == row.id && owns(item)) ||
            row.fireAt > now.instant.microsecondsSinceEpoch) {
          await notifications.cancel(row.id);
        }
        cancelling.add(row);
      }
    }
    if (cancelling.isNotEmpty) {
      pending = await notifications.pending();
      for (final row in cancelling) {
        if (pending.any((item) => item.id == row.id && owns(item))) {
          throw StateError('Notification cancellation was not confirmed');
        }
        final elapsed =
            row.armed &&
            row.fireAt <= clock.read().instant.microsecondsSinceEpoch;
        await (db.update(
          db.reminderOccurrences,
        )..where((entry) => entry.id.equals(row.id))).write(
          ReminderOccurrencesCompanion(
            armed: const Value(false),
            ended: Value(
              row.ended ||
                  elapsed ||
                  ended.contains('${row.goalId}/${row.day}'),
            ),
          ),
        );
        if (elapsed && wanted.containsKey('${row.goalId}/${row.day}')) {
          throw _Replan();
        }
      }
    }
    final allIds = await db
        .customSelect(
          'SELECT MAX(id) AS maximum FROM ('
          'SELECT id FROM reminder_occurrences UNION ALL '
          'SELECT notification_id AS id FROM reminder_cancellations)',
        )
        .getSingle();
    var nextId = allIds.readNullable<int>('maximum') ?? 0;
    for (final item in [...pending, ...delivered]) {
      nextId = math.max(nextId, item.id);
    }
    final expected = <int, String>{};
    for (final candidate in plan.selected) {
      _checkAlive();
      if (!candidate.at.isAfter(clock.read().instant)) throw _Replan();
      final old = rows
          .where(
            (row) =>
                row.goalId == candidate.goalId && row.day == candidate.day.key,
          )
          .firstOrNull;
      final id = old?.id ?? ++nextId;
      if (id < 1 || id > 0x7fffffff) {
        throw StateError('Notification identifiers exhausted');
      }
      if (pending.any((item) => item.id == id && !owns(item))) {
        throw StateError('Notification identifier collision');
      }
      final row = StoredReminderOccurrence(
        id: id,
        goalId: candidate.goalId,
        owner: repository.owner,
        day: candidate.day.key,
        fireAt: candidate.at.microsecondsSinceEpoch,
        zone: now.zone,
        armed: true,
        ended: false,
      );
      final encoded = payload(row);
      expected[id] = encoded;
      // Journal intent first so a crash or ambiguous platform failure is
      // recoverable, and an elapsed occurrence can never be reissued.
      await db.into(db.reminderOccurrences).insertOnConflictUpdate(row);
      if (!pending.any((item) => item.id == id && item.payload == encoded)) {
        await notifications.schedule(id, candidate.at, encoded);
      }
      byId[id] = row;
    }
    final actual = await notifications.pending();
    if (plan.selected.any((item) => !item.at.isAfter(clock.read().instant))) {
      throw _Replan();
    }
    for (final entry in expected.entries) {
      if (!actual.any(
        (item) => item.id == entry.key && item.payload == entry.value,
      )) {
        throw StateError('System did not retain the reminder plan');
      }
    }
    if (actual.any((item) => owns(item) && !expected.containsKey(item.id))) {
      throw StateError('Stale reminder is still pending');
    }
    final latest = await repository.loadGoals();
    if (latest.length != goals.length ||
        latest.any(
          (goal) => !goals.any(
            (before) =>
                before.id == goal.id &&
                before.reminder.revision == goal.reminder.revision,
          ),
        )) {
      throw _Replan();
    }
    final coverage = <int, GoalReminderCoverage>{};
    for (final goal in goals) {
      final times = plan.selected
          .where((item) => item.goalId == goal.id)
          .map((item) => item.at.toUtc())
          .toList();
      final uncovered = plan.firstUncovered[goal.id]?.at.toUtc();
      coverage[goal.id] = GoalReminderCoverage(
        status: !goal.reminder.enabled || goal.isArchived
            ? 'disabled'
            : !canSchedule
            ? 'denied'
            : uncovered != null
            ? 'limited'
            : times.isEmpty
            ? 'noFuture'
            : 'scheduled',
        times: List.unmodifiable(times),
        firstUncovered: uncovered,
      );
    }
    await _writeStatuses(coverage, goals);
    return ReminderReport(
      Map.unmodifiable(coverage),
      checkedAt: clock.read().instant,
      zone: now.zone,
    );
  }

  Future<void> _writeStatuses(
    Map<int, GoalReminderCoverage> coverage,
    List<Goal> goals, {
    bool failed = false,
  }) => db.transaction(() async {
    for (final goal in goals) {
      final status = coverage[goal.id]!.status;
      final dirty = failed && status == 'error';
      if (goal.reminder.status == status &&
          goal.reminder.needsReconcile == dirty) {
        continue;
      }
      await (db.update(db.goalReminders)..where(
            (row) =>
                row.goalId.equals(goal.id) &
                row.revision.equals(goal.reminder.revision),
          ))
          .write(
            GoalRemindersCompanion(
              status: Value(status),
              needsReconcile: Value(dirty),
            ),
          );
    }
  });
}
