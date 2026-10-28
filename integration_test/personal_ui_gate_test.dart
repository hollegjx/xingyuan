import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/app/app.dart';
import 'package:habit_checkin/app/providers.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/local/open_database.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:habit_checkin/features/reminders/notification_permissions.dart';
import 'package:habit_checkin/shared/local_date.dart';
import 'package:integration_test/integration_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();

  testWidgets('personal screens persist across separate iOS app processes', (
    tester,
  ) async {
    const phase = String.fromEnvironment('UI_PROBE_PHASE');
    const run = String.fromEnvironment('UI_PROBE_RUN');
    expect(phase, anyOf('write', 'read'));
    expect(
      run,
      isNotEmpty,
      reason: 'Use a fresh token for each write/read pair',
    );
    final db = openAppDatabase(name: 'habit_checkin_ui_gate');
    final clock = DeviceClock();
    await clock.refreshZone();
    final repository = LocalGoalRepository(db, clock, owner: 'ui-$run');

    Future<void> tap(Finder finder) async {
      await tester.ensureVisible(finder);
      await tester.tap(finder);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }

    Future<void> menu(String label) async {
      await tap(find.byTooltip('我的'));
      if (label != '设置') await tap(find.text(label));
    }

    Future<void> create(
      String title, {
      bool single = false,
      bool weekly = false,
      LocalDate? plannedDay,
    }) async {
      await tap(find.byKey(const ValueKey('entry-new-goal')));
      await tester.enterText(find.byKey(const ValueKey('goal-title')), title);
      if (single) {
        await tap(find.byKey(const ValueKey('goal-kind')));
        await tap(find.text('单次任务').last);
      }
      if (plannedDay != null) {
        await tap(find.byKey(const ValueKey('planned-day')));
        final initial = tester
            .widget<DatePickerDialog>(find.byType(DatePickerDialog))
            .initialDate!;
        if (plannedDay.month != initial.month ||
            plannedDay.year != initial.year) {
          await tap(find.byTooltip('下个月'));
        }
        await tap(find.text('${plannedDay.day}').last);
        await tap(find.widgetWithText(TextButton, '确定'));
      }
      if (weekly) {
        await tap(find.byKey(const ValueKey('goal-frequency')));
        await tap(find.text('指定星期').last);
        for (var weekday = 1; weekday <= 7; weekday++) {
          await tap(find.byKey(ValueKey('weekday-$weekday')));
        }
        await tap(find.byKey(const ValueKey('save-goal')));
        expect(find.text('至少选择一周中的一天'), findsOneWidget);
        expect(
          (await repository.loadGoals()).any(
            (goal) => goal.titleOn(clock.read().day) == title,
          ),
          isFalse,
        );
        for (final weekday in [1, 3, 5]) {
          await tap(find.byKey(ValueKey('weekday-$weekday')));
        }
      }
      await tap(find.byKey(const ValueKey('save-goal')));
      expect(find.byKey(const ValueKey('save-goal')), findsNothing);
    }

    try {
      if (phase == 'write') {
        expect(
          await repository.loadGoals(),
          isEmpty,
          reason: 'Never erase probe data; choose a fresh run token',
        );
      }
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            clockProvider.overrideWithValue(clock),
            refreshClockProvider.overrideWithValue(clock.refreshZone),
            goalRepositoryProvider.overrideWith((ref) => repository),
          ],
          child: const HabitCheckinApp(),
        ),
      );
      await tester.pumpAndSettle();

      if (phase == 'write') {
        expect(find.text('还没有目标'), findsOneWidget);
        await tap(find.byKey(const ValueKey('entry-new-goal')));
        await tap(find.byKey(const ValueKey('save-goal')));
        expect(find.text('名称需要 1 至 60 个字符'), findsOneWidget);
        await tester.enterText(find.byKey(const ValueKey('goal-title')), '   ');
        await tap(find.byKey(const ValueKey('save-goal')));
        expect(find.text('名称需要 1 至 60 个字符'), findsOneWidget);
        await tester.enterText(
          find.byKey(const ValueKey('goal-title')),
          List.filled(61, '📖').join(),
        );
        await tap(find.byKey(const ValueKey('save-goal')));
        expect(find.text('名称需要 1 至 60 个字符'), findsOneWidget);
        expect(await repository.loadGoals(), isEmpty);
        await tester.enterText(
          find.byKey(const ValueKey('goal-title')),
          'TEST 不保存的目标',
        );
        await tap(find.byKey(const ValueKey('reminder-toggle')));
        await tap(find.widgetWithText(TextButton, '取消'));
        await tap(find.byKey(const ValueKey('continue-editing-goal')));
        expect(find.byKey(const ValueKey('goal-title')), findsOneWidget);
        await tap(find.widgetWithText(TextButton, '取消'));
        await tap(find.byKey(const ValueKey('discard-goal-changes')));
        expect(find.text('还没有目标'), findsOneWidget);
        expect(await repository.loadGoals(), isEmpty);
        await create('TEST 每日阅读');
        await create('TEST 单次资料', single: true);
        await create('TEST 周一三五', weekly: true);
        await create(
          'TEST 未来资料',
          single: true,
          plannedDay: clock.read().day.addDays(1),
        );
        expect(find.text('TEST 未来资料'), findsNothing);
        var goals = await repository.loadGoals();
        final daily = goals.singleWhere(
          (goal) => goal.titleOn(clock.read().day) == 'TEST 每日阅读',
        );
        final single = goals.singleWhere(
          (goal) => goal.titleOn(clock.read().day) == 'TEST 单次资料',
        );
        final weekly = goals.singleWhere(
          (goal) => goal.titleOn(clock.read().day) == 'TEST 周一三五',
        );
        await tap(find.byKey(ValueKey('complete-${daily.id}')));
        await tap(find.byKey(ValueKey('undo-${daily.id}')));
        await tap(find.byKey(ValueKey('complete-${daily.id}')));
        await tap(find.byKey(ValueKey('detail-${daily.id}')));
        await tap(find.byKey(const ValueKey('edit-goal')));
        await tester.enterText(
          find.byKey(const ValueKey('goal-title')),
          'TEST 每日阅读（已编辑）',
        );
        await tap(find.byKey(const ValueKey('save-goal')));
        await tap(find.byType(BackButton));
        await tap(find.byKey(ValueKey('complete-${single.id}')));
        await menu('目标管理');
        expect(find.text('TEST 未来资料'), findsOneWidget);
        await tap(find.byKey(ValueKey('detail-${weekly.id}')));
        await tap(find.byKey(const ValueKey('archive-goal')));
        await tap(find.byKey(const ValueKey('confirm-archive')));
        expect(find.text('已归档，只读'), findsOneWidget);
        expect(find.byKey(const ValueKey('edit-goal')), findsNothing);
        await tap(find.byType(BackButton));
        await tap(find.byType(BackButton));
        goals = await repository.loadGoals();
        expect(TodayOverview(goals, clock.read().day).completed, hasLength(2));
      }

      final goals = await repository.loadGoals();
      expect(goals, hasLength(4));
      final today = clock.read().day;
      final daily = goals.singleWhere(
        (goal) => goal.titleOn(today) == 'TEST 每日阅读（已编辑）',
      );
      final single = goals.singleWhere(
        (goal) => goal.titleOn(today) == 'TEST 单次资料',
      );
      final future = goals.singleWhere(
        (goal) => goal.titleOn(today) == 'TEST 未来资料',
      );
      final archived = goals.singleWhere((goal) => goal.isArchived);
      expect(daily.completionOn(daily.createdDay), isNotNull);
      expect(single.singleCompletion, isNotNull);
      expect(future.kind, GoalKind.single);
      expect(future.singleCompletion, isNull);
      expect(
        future.scheduleOn(future.createdDay).plannedDay,
        future.createdDay.addDays(1),
      );
      if (today == future.createdDay) {
        expect(find.byKey(ValueKey('complete-${future.id}')), findsNothing);
      }
      expect(archived.scheduleOn(archived.createdDay).weekdays, 21);
      expect(goals.every((goal) => !goal.reminder.enabled), isTrue);
      expect(goals.every((goal) => !goal.reminder.needsReconcile), isTrue);
      expect(await db.customSelect('PRAGMA foreign_key_check').get(), isEmpty);
      final completedToday = TodayOverview(goals, today).completed.length;
      await tap(find.byTooltip('今天'));
      expect(find.text('今日已完成 $completedToday 项'), findsOneWidget);
      await tap(find.byTooltip('回顾'));
      expect(find.text('已完成 $completedToday 项'), findsOneWidget);
      await menu('设置');
      final container = ProviderScope.containerOf(
        tester.element(find.byType(HabitCheckinApp)),
      );
      final access = await container.read(notificationAccessProvider.future);
      expect(access, isIn(NotificationAccess.values));
      await tester.pumpAndSettle();
      expect(find.text('无法读取通知权限'), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await db.close();
    }
  });
}
