import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/app/app.dart';
import 'package:habit_checkin/app/providers.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/local/open_database.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:habit_checkin/shared/local_date.dart';
import 'package:integration_test/integration_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import '../test/support/test_clock.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();

  testWidgets('history and overdue screens persist across iOS processes', (
    tester,
  ) async {
    const phase = String.fromEnvironment('HISTORY_PROBE_PHASE');
    const run = String.fromEnvironment('HISTORY_PROBE_RUN');
    expect(phase, anyOf('write', 'read'));
    expect(
      RegExp(r'^[a-zA-Z0-9-]+$').hasMatch(run),
      isTrue,
      reason: 'Use a fresh alphanumeric/hyphen token for each write/read pair',
    );
    final db = openAppDatabase(name: 'habit_checkin_history_gate');
    final clock = TestClock()..setDay(2026, 10, 7);
    final repository = LocalGoalRepository(db, clock, owner: 'history-$run');
    final planned = LocalDate(2026, 10, 7);
    final edited = LocalDate(2026, 10, 9);
    final tomorrow = edited.addDays(1);
    late ProviderContainer container;

    Future<void> tap(Finder finder) async {
      await tester.ensureVisible(finder);
      await tester.tap(finder);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }

    Future<void> back() => tap(find.byType(BackButton));

    Future<void> menu(String label) async {
      await tap(find.byTooltip('我的'));
      if (label != '设置') await tap(find.text(label));
    }

    Future<void> setDay(int day) async {
      clock.setDay(2026, 10, day);
      await container.read(environmentProvider.notifier).refresh();
      await tester.pumpAndSettle();
    }

    Future<int> create(String title, {bool single = false}) async {
      await tap(find.byKey(const ValueKey('entry-new-goal')));
      await tester.enterText(find.byKey(const ValueKey('goal-title')), title);
      if (single) {
        await tap(find.byKey(const ValueKey('goal-kind')));
        await tap(find.text('单次任务').last);
      }
      await tap(find.byKey(const ValueKey('save-goal')));
      expect(find.byKey(const ValueKey('save-goal')), findsNothing);
      return (await repository.loadGoals())
          .singleWhere((goal) => goal.titleOn(clock.day) == title)
          .id;
    }

    Future<void> editWeekdays(Set<int> weekdays, {String? title}) async {
      await tap(find.byKey(const ValueKey('edit-goal')));
      if (title != null) {
        await tester.enterText(find.byKey(const ValueKey('goal-title')), title);
      }
      await tap(find.byKey(const ValueKey('goal-frequency')));
      await tap(find.text('指定星期').last);
      for (var day = 1; day <= 7; day++) {
        final chip = find.byKey(ValueKey('weekday-$day'));
        if (tester.widget<FilterChip>(chip).selected !=
            weekdays.contains(day)) {
          await tap(chip);
        }
      }
      expect(find.text('频率从 2026年10月10日 起生效，今天不变。'), findsOneWidget);
      await tap(find.byKey(const ValueKey('save-goal')));
    }

    Future<void> historyDay(int day) =>
        tap(find.byKey(ValueKey('review-day-${LocalDate(2026, 10, day).key}')));

    Future<void> archive(int id) async {
      await tap(find.byKey(ValueKey('detail-$id')));
      await tap(find.byKey(const ValueKey('archive-goal')));
      await tap(find.byKey(const ValueKey('confirm-archive')));
      expect(find.text('已归档，只读'), findsOneWidget);
      expect(find.byKey(const ValueKey('edit-goal')), findsNothing);
      await back();
      expect(find.byKey(ValueKey('complete-$id')), findsNothing);
      expect(find.byKey(ValueKey('undo-$id')), findsNothing);
    }

    try {
      if (phase == 'write') {
        expect(
          await repository.loadGoals(),
          isEmpty,
          reason: 'Never erase probe data; choose a fresh run token',
        );
      } else {
        clock.setDay(2026, 10, 9);
      }
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            clockProvider.overrideWithValue(clock),
            refreshClockProvider.overrideWithValue(() async {}),
            goalRepositoryProvider.overrideWith((ref) => repository),
          ],
          child: const HabitCheckinApp(),
        ),
      );
      container = ProviderScope.containerOf(
        tester.element(find.byType(HabitCheckinApp)),
      );
      await tester.pumpAndSettle();

      if (phase == 'write') {
        expect(find.text('还没有目标'), findsOneWidget);
        final habit = await create('TEST 原阅读目标');
        final single = await create('TEST 逾期资料', single: true);
        final pendingArchive = await create('TEST 归档未完成');
        final doneArchive = await create('TEST 归档已完成');
        await tap(find.byKey(ValueKey('complete-$habit')));
        await setDay(9);
        expect(find.text('已逾期，仍可完成'), findsOneWidget);

        await tap(find.byKey(ValueKey('complete-$habit')));
        await tap(find.byKey(ValueKey('detail-$habit')));
        await editWeekdays({1, 3, 5}, title: 'TEST 周六阅读');
        expect(find.text('每天'), findsOneWidget);
        expect(find.text('2026年10月10日 起：周一、周三、周五'), findsOneWidget);
        await editWeekdays({6});
        expect(find.text('2026年10月10日 起：周六'), findsOneWidget);
        await back();

        await tap(find.byKey(ValueKey('detail-$single')));
        await tap(find.byKey(const ValueKey('edit-goal')));
        await tester.enterText(
          find.byKey(const ValueKey('goal-title')),
          'TEST 改期的资料',
        );
        await tap(find.byKey(const ValueKey('save-goal')));
        expect(find.text('计划 2026年10月7日'), findsOneWidget);
        await back();
        await tap(find.byKey(ValueKey('complete-$single')));
        expect(find.text('今日已完成 2 项'), findsOneWidget);
        final completion = (await repository.loadGoals())
            .singleWhere((goal) => goal.id == single)
            .singleCompletion!;
        expect(completion.day, edited);
        expect(completion.plannedDay, planned);
        await tap(find.byKey(ValueKey('detail-$single')));
        await tap(find.byKey(const ValueKey('edit-goal')));
        expect(
          tester
              .widget<OutlinedButton>(find.byKey(const ValueKey('planned-day')))
              .onPressed,
          isNull,
        );
        await back();
        await tap(find.byKey(const ValueKey('goal-history')));
        await historyDay(7);
        expect(find.text('TEST 逾期资料'), findsOneWidget);
        expect(find.text('已完成 0 项'), findsOneWidget);
        expect(find.text('未记录'), findsOneWidget);
        await historyDay(9);
        expect(find.text('TEST 改期的资料'), findsOneWidget);
        expect(find.text('已完成 1 项'), findsOneWidget);
        expect(find.text('计划 2026年10月7日'), findsOneWidget);
        expect(find.byKey(ValueKey('undo-$single')), findsNothing);
        await back();
        await back();
        await tap(find.byKey(ValueKey('undo-$single')));
        expect(find.text('已逾期，仍可完成'), findsOneWidget);
        expect(find.text('今日已完成 1 项'), findsOneWidget);

        await tap(find.byKey(ValueKey('detail-$single')));
        await tap(find.byKey(const ValueKey('edit-goal')));
        await tap(find.byKey(const ValueKey('planned-day')));
        await tap(find.text('10').last);
        await tap(find.widgetWithText(TextButton, '确定'));
        await tap(find.byKey(const ValueKey('save-goal')));
        await back();
        expect(find.text('TEST 改期的资料'), findsNothing);
        expect(find.byKey(ValueKey('complete-$single')), findsNothing);
        await archive(pendingArchive);
        expect(find.text('TEST 归档未完成'), findsNothing);
        await tap(find.byKey(ValueKey('complete-$doneArchive')));
        await archive(doneArchive);
        expect(find.text('TEST 归档已完成'), findsOneWidget);
        expect(find.text('今日已完成 2 项'), findsOneWidget);
      }

      final goals = await repository.loadGoals();
      expect(goals, hasLength(4));
      final habit = goals.singleWhere(
        (goal) => goal.titleOn(edited) == 'TEST 周六阅读',
      );
      final single = goals.singleWhere((goal) => goal.kind == GoalKind.single);
      final pendingArchive = goals.singleWhere(
        (goal) => goal.titleOn(edited) == 'TEST 归档未完成',
      );
      final doneArchive = goals.singleWhere(
        (goal) => goal.titleOn(edited) == 'TEST 归档已完成',
      );
      expect(habit.titleOn(planned), 'TEST 原阅读目标');
      expect(habit.scheduleOn(edited).weekdays, 127);
      expect(habit.scheduleOn(tomorrow).weekdays, 32);
      expect(habit.schedules, hasLength(2));
      expect(habit.completionOn(planned), isNotNull);
      expect(habit.completionOn(edited), isNotNull);
      expect(single.singleCompletion, isNull);
      expect(single.scheduleOn(planned).plannedDay, planned);
      expect(single.scheduleOn(edited).plannedDay, tomorrow);
      expect(pendingArchive.archivedDay, edited);
      expect(pendingArchive.completionOn(edited), isNull);
      expect(doneArchive.archivedDay, edited);
      expect(doneArchive.completionOn(edited), isNotNull);
      expect(goals.every((goal) => !goal.reminder.enabled), isTrue);
      expect(goals.every((goal) => !goal.reminder.needsReconcile), isTrue);
      expect(await db.customSelect('PRAGMA foreign_key_check').get(), isEmpty);
      expect(find.text('今日已完成 2 项'), findsOneWidget);
      expect(find.byKey(ValueKey('undo-${doneArchive.id}')), findsNothing);

      await menu('目标管理');
      expect(find.text('TEST 改期的资料'), findsOneWidget);
      await tap(find.byKey(ValueKey('detail-${single.id}')));
      expect(find.text('计划 2026年10月10日'), findsOneWidget);
      await tap(find.byKey(const ValueKey('goal-history')));
      await historyDay(7);
      expect(find.text('TEST 逾期资料'), findsOneWidget);
      expect(find.text('计划 2026年10月7日'), findsOneWidget);
      expect(find.text('未记录'), findsOneWidget);
      await back();
      await back();
      await tap(find.byKey(const ValueKey('goal-filter')));
      await tap(find.text('已归档').last);
      expect(find.text('TEST 归档未完成'), findsOneWidget);
      expect(find.text('TEST 归档已完成'), findsOneWidget);
      await tap(find.byKey(ValueKey('detail-${pendingArchive.id}')));
      await tap(find.byKey(const ValueKey('goal-history')));
      await historyDay(9);
      expect(find.text('未记录'), findsOneWidget);
      await historyDay(10);
      expect(find.text('已归档'), findsOneWidget);
      expect(
        find.byKey(ValueKey('complete-${pendingArchive.id}')),
        findsNothing,
      );
      await back();
      await back();
      await back();

      await tap(find.byTooltip('今天'));
      await tap(find.byKey(ValueKey('detail-${habit.id}')));
      await tap(find.byKey(const ValueKey('goal-history')));
      await historyDay(7);
      expect(find.text('TEST 原阅读目标'), findsOneWidget);
      expect(find.text('每天'), findsOneWidget);
      expect(find.text('已完成 1 项'), findsOneWidget);
      await historyDay(9);
      expect(find.text('TEST 周六阅读'), findsOneWidget);
      expect(find.text('每天'), findsOneWidget);
      expect(find.text('已完成 1 项'), findsOneWidget);
      expect(find.byKey(ValueKey('undo-${habit.id}')), findsNothing);

      // The injected clock skips days without writing or rebuilding their history.
      await setDay(12);
      await historyDay(10);
      expect(find.text('周六'), findsOneWidget);
      expect(find.text('未记录'), findsOneWidget);
      await historyDay(11);
      expect(find.text('不在计划内'), findsOneWidget);
      await historyDay(6);
      expect(find.text('尚未创建'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await db.close();
    }
  });
}
