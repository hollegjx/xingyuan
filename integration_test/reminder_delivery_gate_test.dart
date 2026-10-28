import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/app/providers.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/local/open_database.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:habit_checkin/features/reminders/notification_permissions.dart';
import 'package:habit_checkin/features/reminders/reminder_coordinator.dart';
import 'package:habit_checkin/features/reminders/reminder_notifications.dart';
import 'package:integration_test/integration_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();

  testWidgets('production reminder scheduling and delivery across processes', (
    tester,
  ) async {
    const phase = String.fromEnvironment('REMINDER_PROBE_PHASE');
    const run = String.fromEnvironment('REMINDER_PROBE_RUN');
    expect(phase, anyOf('arm', 'checkpoint', 'verify', 'cleanup'));
    expect(RegExp(r'^[a-zA-Z0-9-]{1,80}$').stringMatch(run), run);
    final db = openAppDatabase(name: 'habit_checkin_reminder_gate');
    final clock = DeviceClock();
    await clock.refreshZone();
    final owner = 'reminder-$run';
    final repository = LocalGoalRepository(db, clock, owner: owner);
    final platform = IosNotificationPermissions();
    final coordinator = ReminderCoordinator(
      repository: repository,
      clock: clock,
      permissions: platform,
      notifications: platform,
    );
    Map<String, dynamic>? own(PendingReminder item) {
      try {
        final data = jsonDecode(item.payload ?? '');
        return data is Map<String, dynamic> && data['owner'] == owner
            ? data
            : null;
      } on FormatException {
        return null;
      }
    }

    Future<void> cleanup() async {
      for (final goal in await repository.loadGoals()) {
        await repository.archive(goal.id);
      }
      await coordinator.reconcile();
      for (final item in await platform.delivered()) {
        if (own(item) != null) await platform.cancel(item.id);
      }
      expect((await platform.pending()).where((p) => own(p) != null), isEmpty);
      expect(
        (await platform.delivered()).where((p) => own(p) != null),
        isEmpty,
      );
    }

    try {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Text('TEST reminder delivery gate')),
        ),
      );
      if (phase == 'cleanup') {
        await cleanup();
        return;
      }
      final access = await platform.read();
      expect(
        access,
        anyOf(NotificationAccess.allowed, NotificationAccess.quiet),
        reason: 'Existing authorization required; this probe never prompts.',
      );
      if (phase == 'arm') {
        expect(
          await repository.loadGoals(),
          isEmpty,
          reason: 'Choose a fresh token; never erase prior probe records.',
        );
        expect(
          await platform.pending(),
          isEmpty,
          reason: 'Preserve any existing notifications; do not clear them.',
        );
        expect(await platform.delivered(), isEmpty);
        final local = clock.read().localTime;
        final minute = local.hour * 60 + local.minute + 3;
        expect(minute, lessThan(1437), reason: 'Do not arm near midnight.');
        GoalDraft draft(String title, int time, {bool enabled = true}) =>
            GoalDraft(
              title: title,
              kind: GoalKind.habit,
              reminderEnabled: enabled,
              reminderMinute: time,
            );
        final control = await repository.create(draft('TEST control', minute));
        final cancelled = await repository.create(
          draft('TEST cancelled', minute),
        );
        final replacement = await repository.create(
          draft('TEST replacement', minute),
        );
        final restored = await repository.create(
          draft('TEST restored', minute),
        );
        final disabled = await repository.create(
          draft('TEST disabled', minute),
        );
        final archived = await repository.create(
          draft('TEST archived', minute),
        );
        final today = clock.read().day;
        await repository.create(
          GoalDraft(
            title: 'TEST single',
            kind: GoalKind.single,
            plannedDay: today,
            reminderEnabled: true,
            reminderMinute: minute,
          ),
        );
        await repository.create(
          GoalDraft(
            title: 'TEST weekdays',
            kind: GoalKind.habit,
            weekdays: 1 << (today.weekday - 1),
            reminderEnabled: true,
            reminderMinute: minute,
          ),
        );
        await coordinator.reconcile();
        final before = await platform.pending();
        expect(before, hasLength(64));
        int todayId(int goal) => before.singleWhere((item) {
          final data = own(item);
          return data?['goal'] == goal && data?['day'] == today.key;
        }).id;
        final cancelledId = todayId(cancelled);
        await repository.setCompleted(cancelled, true, expectedDay: today);
        await coordinator.reconcile();
        expect(
          (await platform.pending()).any((p) => p.id == cancelledId),
          isFalse,
        );
        await repository.setCompleted(cancelled, false, expectedDay: today);
        await coordinator.reconcile();
        expect(
          (await platform.pending()).any((p) => p.id == cancelledId),
          isTrue,
        );
        await repository.setCompleted(cancelled, true, expectedDay: today);
        final restoredId = todayId(restored);
        await repository.setCompleted(restored, true, expectedDay: today);
        await coordinator.reconcile();
        expect(
          (await platform.pending()).any((p) => p.id == restoredId),
          isFalse,
        );
        await repository.setCompleted(restored, false, expectedDay: today);
        await repository.edit(
          disabled,
          draft('TEST disabled', minute, enabled: false),
        );
        await repository.archive(archived);
        await repository.edit(
          replacement,
          draft('TEST replacement', minute + 2),
        );
        final report = await coordinator.reconcile();
        final pending = await platform.pending();
        expect(pending, hasLength(64));
        expect(pending.any((p) => p.id == cancelledId), isFalse);
        expect(pending.any((p) => p.id == restoredId), isTrue);
        expect(
          pending.any((p) => {disabled, archived}.contains(own(p)?['goal'])),
          isFalse,
        );
        expect(report.goals[cancelled]!.times.first, isNotNull);
        expect(
          report.goals[control]!.times.first.isBefore(
            report.goals[replacement]!.times.first,
          ),
          isTrue,
        );
        // Persisted ledger and repository are the verify phase's only plan.
        debugPrint(
          'REMINDER_GATE armed ${clock.read().instant.toIso8601String()} '
          'control=${report.goals[control]!.times.first.toIso8601String()} '
          'replacement=${report.goals[replacement]!.times.first.toIso8601String()}',
        );
      } else {
        final goals = await repository.loadGoals();
        expect(goals, hasLength(8));
        final control = goals.singleWhere(
          (g) => g.titles.first.title == 'TEST control',
        );
        final cancelled = goals.singleWhere(
          (g) => g.titles.first.title == 'TEST cancelled',
        );
        final replacement = goals.singleWhere(
          (g) => g.titles.first.title == 'TEST replacement',
        );
        final restored = goals.singleWhere(
          (g) => g.titles.first.title == 'TEST restored',
        );
        final disabled = goals.singleWhere(
          (g) => g.titles.first.title == 'TEST disabled',
        );
        final archived = goals.singleWhere(
          (g) => g.titles.first.title == 'TEST archived',
        );
        final single = goals.singleWhere(
          (g) => g.titles.first.title == 'TEST single',
        );
        final weekdays = goals.singleWhere(
          (g) => g.titles.first.title == 'TEST weekdays',
        );
        final ledger = await db.select(db.reminderOccurrences).get();
        final day = control.createdDay.key;
        final due = ledger.singleWhere(
          (r) => r.goalId == replacement.id && r.day == day,
        );
        final now = clock.read().instant.microsecondsSinceEpoch;
        if (phase == 'checkpoint') {
          final first = ledger.singleWhere(
            (r) => r.goalId == control.id && r.day == day,
          );
          expect(
            now,
            greaterThan(
              first.fireAt + const Duration(seconds: 10).inMicroseconds,
            ),
          );
          expect(
            now,
            lessThan(due.fireAt - const Duration(seconds: 10).inMicroseconds),
          );
        } else {
          expect(
            now,
            greaterThan(
              due.fireAt + const Duration(seconds: 20).inMicroseconds,
            ),
          );
          expect(
            now,
            lessThan(due.fireAt + const Duration(minutes: 15).inMicroseconds),
          );
        }
        final delivered = (await platform.delivered())
            .map(own)
            .whereType<Map<String, dynamic>>()
            .toList();
        final expected = {
          control.id,
          restored.id,
          single.id,
          weekdays.id,
          if (phase == 'verify') replacement.id,
        };
        expect(delivered, hasLength(expected.length));
        expect(delivered.map((p) => p['goal']).toSet(), expected);
        expect(delivered.every((p) => p['day'] == day), isTrue);
        final pending = (await platform.pending())
            .map(own)
            .whereType<Map<String, dynamic>>()
            .toList();
        expect(
          pending.where((p) => p['day'] == day).map((p) => p['goal']).toList(),
          phase == 'checkpoint' ? [replacement.id] : isEmpty,
        );
        expect(pending.any((p) => p['goal'] == cancelled.id), isTrue);
        expect(
          pending.any(
            (p) => {disabled.id, archived.id, single.id}.contains(p['goal']),
          ),
          isFalse,
        );
        debugPrint(
          'REMINDER_GATE $phase ${clock.read().instant.toIso8601String()} '
          'delivered=${delivered.map((p) => p['goal']).join(',')}',
        );
        if (phase == 'verify') {
          // Expired cancellation and a delivered occurrence must not rearm today.
          final today = clock.read().day;
          await repository.setCompleted(
            cancelled.id,
            false,
            expectedDay: today,
          );
          await repository.setCompleted(control.id, true, expectedDay: today);
          await repository.setCompleted(control.id, false, expectedDay: today);
          final local = clock.read().localTime;
          await repository.edit(
            control.id,
            GoalDraft(
              title: 'TEST control',
              kind: GoalKind.habit,
              reminderEnabled: true,
              reminderMinute: (local.hour * 60 + local.minute + 2) % 1440,
            ),
          );
          await coordinator.reconcile();
          expect(
            (await platform.pending()).any((p) => own(p)?['day'] == day),
            isFalse,
          );
          await cleanup();
        }
      }
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await db.close();
    }
  });
}
