import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:habit_checkin/features/reminders/notification_permissions.dart';
import 'package:habit_checkin/features/reminders/reminder_coordinator.dart';
import 'package:habit_checkin/features/reminders/reminder_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'support/sync_fixtures.dart';
import 'support/test_clock.dart';
import 'support/test_reminder_notifications.dart';
import 'support/ui_harness.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);
  for (final owner in ['guest', accountA.owner, accountB.owner]) {
    group('reminder rules under $owner', () {
      late AppDatabase db;
      late TestClock clock;
      late LocalGoalRepository repo;
      late TestReminderNotifications platform;
      late TestNotificationPermissions permissions;
      late ReminderCoordinator coordinator;
      setUp(() {
        db = AppDatabase(NativeDatabase.memory());
        clock = TestClock();
        repo = LocalGoalRepository(db, clock, owner: owner);
        platform = TestReminderNotifications();
        permissions = TestNotificationPermissions()
          ..access = NotificationAccess.allowed;
        coordinator = ReminderCoordinator(
          repository: repo,
          clock: clock,
          permissions: permissions,
          notifications: platform,
        );
      });
      tearDown(() => db.close());

      GoalDraft draft({
        bool enabled = true,
        int minute = 780,
        int weekdays = 127,
        bool single = false,
      }) => GoalDraft(
        title: 'TEST reminder isolation',
        kind: single ? GoalKind.single : GoalKind.habit,
        weekdays: weekdays,
        plannedDay: single ? clock.day : null,
        reminderEnabled: enabled,
        reminderMinute: minute,
      );
      Map<String, dynamic> payload(PendingReminder item) =>
          jsonDecode(item.payload!) as Map<String, dynamic>;
      List<PendingReminder> requests(int id, {bool todayOnly = false}) =>
          platform.requests.values
              .where(
                (r) =>
                    payload(r)['goal'] == id &&
                    (!todayOnly || payload(r)['day'] == clock.day.key),
              )
              .toList();

      test('daily weekday and single rules keep targeted cancellation and stable replacement', () async {
        final weekdays = 1 << (clock.day.weekday - 1);
        final daily = await repo.create(draft());
        final weekly = await repo.create(draft(weekdays: weekdays));
        final single = await repo.create(draft(single: true));
        await coordinator.reconcile();
        expect(
          platform.requests.values.every((r) => payload(r)['owner'] == owner),
          isTrue,
        );
        expect(requests(daily, todayOnly: true), hasLength(1));
        final weeklyId = requests(weekly, todayOnly: true).single.id;
        expect(requests(single), hasLength(1));
        await repo.setCompleted(weekly, true, expectedDay: clock.day);
        await coordinator.reconcile();
        expect(requests(weekly, todayOnly: true), isEmpty);
        expect(requests(weekly), isNotEmpty);
        expect(requests(single), hasLength(1));
        await repo.setCompleted(weekly, false, expectedDay: clock.day);
        await coordinator.reconcile();
        expect(requests(weekly, todayOnly: true).single.id, weeklyId);
        await repo.edit(weekly, draft(weekdays: weekdays, minute: 840));
        await coordinator.reconcile();
        expect(requests(weekly, todayOnly: true).single.id, weeklyId);
        expect(platform.times[weeklyId]!.hour, 14);
        await repo.setCompleted(single, true, expectedDay: clock.day);
        await coordinator.reconcile();
        expect(requests(single), isEmpty);
        await repo.archive(daily);
        await repo.edit(
          weekly,
          draft(enabled: false, weekdays: weekdays, minute: 840),
        );
        await coordinator.reconcile();
        expect(platform.requests, isEmpty);
        clock.setDay(2026, 10, 9, hour: 15);
        await repo.setCompleted(single, false, expectedDay: clock.day);
        await coordinator.reconcile();
        expect(requests(single), isEmpty);
        expect(permissions.requests, 0);
      });

      test(
        'delivered occurrence is not reissued after edit or completion undo',
        () async {
          final id = await repo.create(draft());
          await coordinator.reconcile();
          final arrived = requests(id, todayOnly: true).single;
          platform.arrivals.add(arrived);
          platform.requests.remove(arrived.id);
          await repo.edit(id, draft(minute: 840));
          await repo.setCompleted(id, true, expectedDay: clock.day);
          await repo.setCompleted(id, false, expectedDay: clock.day);
          await coordinator.reconcile();
          expect(requests(id, todayOnly: true), isEmpty);
          expect(requests(id), isNotEmpty);
        },
      );

      test(
        'permission denial leaves recording usable and cancels existing plans',
        () async {
          final id = await repo.create(draft());
          await coordinator.reconcile();
          permissions.access = NotificationAccess.off;
          expect((await coordinator.reconcile()).goals[id]!.status, 'denied');
          expect(platform.requests, isEmpty);
          await repo.setCompleted(id, true, expectedDay: clock.day);
          expect(
            (await repo.loadGoals()).single.completionOn(clock.day),
            isNotNull,
          );
          expect(permissions.requests, 0);
        },
      );
    });
  }
}
