import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/app/providers.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'support/ui_harness.dart';

Future<void> editWeekdays(
  WidgetTester tester,
  Set<int> weekdays, {
  String? title,
}) async {
  await tapVisible(tester, find.byKey(const ValueKey('edit-goal')));
  if (title != null) {
    await tester.enterText(find.byKey(const ValueKey('goal-title')), title);
  }
  await tapVisible(tester, find.byKey(const ValueKey('goal-frequency')));
  await tapVisible(tester, find.text('指定星期').last);
  for (var day = 1; day <= 7; day++) {
    final chip = find.byKey(ValueKey('weekday-$day'));
    if (tester.widget<FilterChip>(chip).selected != weekdays.contains(day)) {
      await tapVisible(tester, chip);
    }
  }
  expect(find.text('频率从 2026年10月10日 起生效，今天不变。'), findsOneWidget);
  await tapVisible(tester, find.byKey(const ValueKey('save-goal')));
}

Future<void> selectHistoryDay(WidgetTester tester, String key) =>
    tapVisible(tester, find.byKey(ValueKey('review-day-$key')));

void main() {
  setUpAll(tzdata.initializeTimeZones);

  testUiWidgets(
    'same-day frequency edits keep today and history and replace tomorrow rule',
    (tester) async {
      final app = UiHarness();
      app.clock.setDay(2026, 10, 8);
      final id = await app.repository.create(
        const GoalDraft(title: '原来的阅读目标', kind: GoalKind.habit),
      );
      await app.repository.setCompleted(id, true, expectedDay: app.clock.day);
      app.clock.setDay(2026, 10, 9);
      await app.mount(tester);
      await tapVisible(tester, find.byKey(ValueKey('complete-$id')));
      await tapVisible(tester, find.byKey(ValueKey('detail-$id')));
      await editWeekdays(tester, {1, 3, 5}, title: '修改后的阅读目标');
      expect(find.text('每天'), findsOneWidget);
      expect(find.text('2026年10月10日 起：周一、周三、周五'), findsOneWidget);
      await editWeekdays(tester, {6});
      expect(find.text('2026年10月10日 起：周六'), findsOneWidget);
      final goal = (await app.repository.loadGoals()).single;
      expect(goal.scheduleOn(app.clock.day).weekdays, 127);
      expect(goal.scheduleOn(app.clock.day.addDays(1)).weekdays, 32);
      expect(goal.schedules, hasLength(2));
      expect(goal.completions, hasLength(2));

      await tapVisible(tester, find.byKey(const ValueKey('goal-history')));
      await selectHistoryDay(tester, '2026-10-08');
      expect(find.text('原来的阅读目标'), findsOneWidget);
      expect(find.text('每天'), findsOneWidget);
      expect(find.text('已完成 1 项'), findsOneWidget);
      expect(find.byKey(ValueKey('undo-$id')), findsNothing);
      await selectHistoryDay(tester, '2026-10-09');
      expect(find.text('修改后的阅读目标'), findsOneWidget);
      expect(find.text('每天'), findsOneWidget);
      expect(find.text('已完成 1 项'), findsOneWidget);

      // No queries or writes occur on the skipped dates.
      app.clock.setDay(2026, 10, 12);
      await app.container.read(environmentProvider.notifier).refresh();
      await tester.pumpAndSettle();
      await selectHistoryDay(tester, '2026-10-10');
      expect(find.text('修改后的阅读目标'), findsOneWidget);
      expect(find.text('周六'), findsOneWidget);
      expect(find.text('未记录'), findsOneWidget);
      await selectHistoryDay(tester, '2026-10-11');
      expect(find.text('不在计划内'), findsOneWidget);
      await selectHistoryDay(tester, '2026-10-07');
      expect(find.text('尚未创建'), findsOneWidget);
      await selectHistoryDay(tester, '2026-10-17');
      expect(find.text('尚未到期'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testUiWidgets(
    'overdue single keeps plan when renamed and completes only on the actual day',
    (tester) async {
      final app = UiHarness();
      app.clock.setDay(2026, 10, 7);
      final plan = app.clock.day;
      final id = await app.repository.create(
        GoalDraft(title: '待整理的资料', kind: GoalKind.single, plannedDay: plan),
      );
      app.clock.setDay(2026, 10, 9);
      await app.mount(tester);
      expect(find.text('已逾期，仍可完成'), findsOneWidget);
      expect(find.text('计划 2026年10月7日'), findsOneWidget);
      await tapVisible(tester, find.byKey(ValueKey('detail-$id')));
      await tapVisible(tester, find.byKey(const ValueKey('edit-goal')));
      await tester.enterText(
        find.byKey(const ValueKey('goal-title')),
        '重命名的资料任务',
      );
      await tapVisible(tester, find.byKey(const ValueKey('save-goal')));
      expect(
        (await app.repository.loadGoals()).single
            .scheduleOn(app.clock.day)
            .plannedDay,
        plan,
      );
      await goBack(tester);
      await tapVisible(tester, find.byKey(ValueKey('complete-$id')));
      expect(find.text('今日已完成 1 项'), findsOneWidget);
      final completion =
          (await app.repository.loadGoals()).single.singleCompletion!;
      expect(completion.day, app.clock.day);
      expect(completion.plannedDay, plan);

      await tapVisible(tester, find.byKey(ValueKey('detail-$id')));
      expect(find.text('已完成于 2026年10月9日'), findsOneWidget);
      await tapVisible(tester, find.byKey(const ValueKey('edit-goal')));
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const ValueKey('planned-day')))
            .onPressed,
        isNull,
      );
      expect(find.text('已完成任务不可直接改期'), findsOneWidget);
      await goBack(tester);
      await tapVisible(tester, find.byKey(const ValueKey('goal-history')));
      await selectHistoryDay(tester, '2026-10-07');
      expect(find.text('待整理的资料'), findsOneWidget);
      expect(find.text('未记录'), findsOneWidget);
      expect(find.text('已完成 0 项'), findsOneWidget);
      await selectHistoryDay(tester, '2026-10-09');
      expect(find.text('重命名的资料任务'), findsOneWidget);
      expect(find.text('已完成 1 项'), findsOneWidget);
      expect(find.text('计划 2026年10月7日'), findsOneWidget);
      await goBack(tester);
      await goBack(tester);
      await tapVisible(tester, find.byKey(ValueKey('undo-$id')));
      expect(find.text('已逾期，仍可完成'), findsOneWidget);
      expect(find.text('今日已完成 0 项'), findsOneWidget);

      await tapVisible(tester, find.byKey(ValueKey('detail-$id')));
      await tapVisible(tester, find.byKey(const ValueKey('edit-goal')));
      await tapVisible(tester, find.byKey(const ValueKey('planned-day')));
      if (find.byType(InputDatePickerFormField).evaluate().isNotEmpty) {
        await tester.enterText(
          find.descendant(
            of: find.byType(InputDatePickerFormField),
            matching: find.byType(TextFormField),
          ),
          '2026/10/10',
        );
        await tapVisible(
          tester,
          find.byKey(const ValueKey('goal-date-confirm')),
        );
      } else {
        await tapVisible(tester, find.text('10').last);
        await tapVisible(tester, find.widgetWithText(TextButton, '确定'));
      }
      await tapVisible(tester, find.byKey(const ValueKey('save-goal')));
      await goBack(tester);
      expect(find.text('今天没有待办'), findsOneWidget);
      await openMenu(tester, '目标管理');
      expect(find.text('重命名的资料任务'), findsOneWidget);
      await tapVisible(tester, find.byKey(ValueKey('detail-$id')));
      await tapVisible(tester, find.byKey(const ValueKey('goal-history')));
      await selectHistoryDay(tester, '2026-10-07');
      expect(find.text('计划 2026年10月7日'), findsOneWidget);
      expect(find.text('未记录'), findsOneWidget);
      final goal = (await app.repository.loadGoals()).single;
      expect(goal.singleCompletion, isNull);
      expect(
        goal.scheduleOn(app.clock.day).plannedDay,
        app.clock.day.addDays(1),
      );
      expect(goal.scheduleOn(plan).plannedDay, plan);
      expect(tester.takeException(), isNull);
    },
  );

  testUiWidgets(
    'archiving pending goal keeps its original day and future read only',
    (tester) async {
      final app = UiHarness();
      final id = await app.repository.create(
        const GoalDraft(title: '归档保留未记录', kind: GoalKind.habit),
      );
      await app.mount(tester);
      await tapVisible(tester, find.byKey(ValueKey('detail-$id')));
      await tapVisible(tester, find.byKey(const ValueKey('archive-goal')));
      await tapVisible(tester, find.byKey(const ValueKey('confirm-archive')));
      expect(find.byKey(const ValueKey('edit-goal')), findsNothing);
      await tapVisible(tester, find.byKey(const ValueKey('goal-history')));
      expect(find.text('未记录'), findsOneWidget);
      await selectHistoryDay(tester, '2026-10-10');
      expect(find.text('已归档'), findsOneWidget);
      expect(find.byKey(ValueKey('complete-$id')), findsNothing);
      await goBack(tester);
      await goBack(tester);
      expect(find.text('今天没有待办'), findsOneWidget);
      expect(find.text('归档保留未记录'), findsNothing);
      expect((await app.repository.loadGoals()).single.isArchived, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}
