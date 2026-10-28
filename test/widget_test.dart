import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'support/ui_harness.dart';

const titleKey = ValueKey('goal-title');
const saveKey = ValueKey('save-goal');

void main() {
  setUpAll(tzdata.initializeTimeZones);

  testUiWidgets(
    'empty install neither seeds examples nor requests permission',
    (tester) async {
      final app = UiHarness();
      await app.mount(tester);
      expect(find.text('还没有目标'), findsOneWidget);
      expect(find.text('今日已完成 0 项'), findsOneWidget);
      expect(await app.repository.loadGoals(), isEmpty);
      expect(app.permissions.requests, 0);
      expect(app.permissions.reads, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testUiWidgets('creates, checks in once, undoes and checks in again', (
    tester,
  ) async {
    final app = UiHarness();
    await app.mount(tester);
    await tapVisible(tester, find.byKey(const ValueKey('entry-new-goal')));
    await tester.enterText(find.byKey(titleKey), '阅读 10 分钟 📖');
    await tester.ensureVisible(find.byKey(saveKey));
    await tester.tap(find.byKey(saveKey));
    await tester.tap(find.byKey(saveKey));
    await tester.pumpAndSettle();
    final goals = await app.repository.loadGoals();
    expect(goals, hasLength(1));
    final id = goals.single.id;
    expect(find.text('阅读 10 分钟 📖'), findsOneWidget);
    final complete = find.byKey(ValueKey('complete-$id'));
    await tester.ensureVisible(complete);
    await tester.tap(complete);
    await tester.tap(complete);
    await tester.pumpAndSettle();
    expect(find.text('今日已完成 1 项'), findsOneWidget);
    expect((await app.repository.loadGoals()).single.completions, hasLength(1));
    await tapVisible(tester, find.byKey(ValueKey('undo-$id')));
    expect(find.text('今日已完成 0 项'), findsOneWidget);
    await tapVisible(tester, complete);
    expect(find.text('今日已完成 1 项'), findsOneWidget);
    expect(app.permissions.requests, 0);
  });

  testUiWidgets(
    'dirty cancellation confirms and leaves no goal or permission',
    (tester) async {
      final app = UiHarness();
      await app.mount(tester);
      await tapVisible(tester, find.byKey(const ValueKey('entry-new-goal')));
      await tester.enterText(find.byKey(titleKey), '不保存的目标');
      await tapVisible(tester, find.byKey(const ValueKey('reminder-toggle')));
      await tapVisible(tester, find.text('取消'));
      await tapVisible(tester, find.text('继续编辑'));
      expect(find.byKey(titleKey), findsOneWidget);
      await tapVisible(tester, find.text('取消'));
      await tapVisible(tester, find.widgetWithText(FilledButton, '放弃更改'));
      expect(find.text('还没有目标'), findsOneWidget);
      expect(await app.repository.loadGoals(), isEmpty);
      expect(app.permissions.requests, 0);
    },
  );

  testUiWidgets('invalid names and empty weekday selection cannot be saved', (
    tester,
  ) async {
    final app = UiHarness();
    await app.mount(tester);
    await tapVisible(tester, find.byKey(const ValueKey('entry-new-goal')));
    await tapVisible(tester, find.byKey(saveKey));
    expect(find.text('名称需要 1 至 60 个字符'), findsOneWidget);
    await tester.enterText(find.byKey(titleKey), List.filled(61, '读').join());
    await tapVisible(tester, find.byKey(saveKey));
    expect(find.text('名称需要 1 至 60 个字符'), findsOneWidget);
    await tester.enterText(find.byKey(titleKey), '每周阅读');
    await tapVisible(tester, find.byKey(const ValueKey('goal-frequency')));
    await tapVisible(tester, find.text('指定星期').last);
    for (var weekday = 1; weekday <= 7; weekday++) {
      await tapVisible(tester, find.byKey(ValueKey('weekday-$weekday')));
    }
    await tapVisible(tester, find.byKey(saveKey));
    expect(find.text('至少选择一周中的一天'), findsOneWidget);
    expect(await app.repository.loadGoals(), isEmpty);
    for (final weekday in [1, 3, 5]) {
      await tapVisible(tester, find.byKey(ValueKey('weekday-$weekday')));
    }
    await tapVisible(tester, find.byKey(saveKey));
    expect(
      (await app.repository.loadGoals()).single
          .scheduleOn(app.clock.day)
          .weekdays,
      21,
    );
  });

  testUiWidgets('permission failure after save does not duplicate a goal', (
    tester,
  ) async {
    final app = UiHarness();
    app.permissions.failure = StateError('injected platform failure');
    await app.mount(tester);
    await tapVisible(tester, find.byKey(const ValueKey('entry-new-goal')));
    await tester.enterText(find.byKey(titleKey), '保存后权限失败');
    await tapVisible(tester, find.byKey(const ValueKey('reminder-toggle')));
    await tapVisible(tester, find.byKey(saveKey));
    expect(find.byKey(saveKey), findsNothing);
    final goal = (await app.repository.loadGoals()).single;
    expect(goal.reminder.enabled, isTrue);
    expect(goal.reminder.status, 'error');
    await tapVisible(tester, find.byKey(ValueKey('detail-${goal.id}')));
    expect(find.text('提醒安排或取消未确认，记录已保存。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final size in [
    const Size(320, 568),
    const Size(414, 896),
    const Size(896, 414),
  ]) {
    for (final scale in [1.0, 3.0]) {
      testUiWidgets(
        'new single date and time pickers work at $size with ${scale}x text',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          final app = UiHarness();
          await app.mount(tester);
          await tapVisible(
            tester,
            find.byKey(const ValueKey('entry-new-goal')),
          );
          await tester.enterText(find.byKey(titleKey), '明天整理资料 📁');
          await tapVisible(tester, find.byKey(const ValueKey('goal-kind')));
          await tapVisible(tester, find.text('单次任务').last);
          expect(
            tester.takeException(),
            isNull,
            reason: 'single type selection',
          );
          await tapVisible(tester, find.byKey(const ValueKey('planned-day')));
          expect(tester.takeException(), isNull, reason: 'date picker');
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
          expect(find.text('2026年10月10日'), findsOneWidget);
          await tapVisible(
            tester,
            find.byKey(const ValueKey('reminder-toggle')),
          );
          await tapVisible(tester, find.byKey(const ValueKey('reminder-time')));
          expect(tester.takeException(), isNull, reason: 'time picker');
          await tapVisible(tester, find.widgetWithText(TextButton, '确定'));
          await tapVisible(tester, find.byKey(saveKey));
          final stored = (await app.repository.loadGoals()).single;
          expect(stored.kind, GoalKind.single);
          expect(
            stored.scheduleOn(app.clock.day).plannedDay,
            app.clock.day.addDays(1),
          );
          expect(stored.reminder.enabled, isTrue);
          expect(app.permissions.requests, 1);
          expect(find.text('今天没有待办'), findsOneWidget);
          await openMenu(tester, '目标管理');
          await tapVisible(tester, find.byKey(ValueKey('detail-${stored.id}')));
          expect(find.text('通知未授权，提醒未生效'), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testUiWidgets('stale today button cannot complete a different date', (
    tester,
  ) async {
    final app = UiHarness();
    final id = await app.repository.create(
      const GoalDraft(title: '换日保护', kind: GoalKind.habit),
    );
    await app.mount(tester);
    app.clock.setDay(2026, 10, 10);
    await tapVisible(tester, find.byKey(ValueKey('complete-$id')));
    expect(find.text('日期已经变化，请刷新今天后重试'), findsOneWidget);
    expect((await app.repository.loadGoals()).single.completions, isEmpty);
    expect(find.text('10月10日 周六'), findsOneWidget);
    await tapVisible(tester, find.byKey(ValueKey('complete-$id')));
    expect(
      (await app.repository.loadGoals()).single.completionOn(app.clock.day),
      isNotNull,
    );
  });

  testUiWidgets(
    'write failure preserves form and retries without partial data',
    (tester) async {
      final app = UiHarness();
      await app.database.customStatement('''
      CREATE TRIGGER fail_ui_save BEFORE INSERT ON goals
      BEGIN SELECT RAISE(ABORT, 'injected write failure'); END
    ''');
      await app.mount(tester);
      await tapVisible(tester, find.byKey(const ValueKey('entry-new-goal')));
      await tester.enterText(find.byKey(titleKey), '失败后重试');
      await tapVisible(tester, find.byKey(saveKey));
      expect(find.text('未能保存，请重试。原有记录未被清空。'), findsOneWidget);
      expect(await app.repository.loadGoals(), isEmpty);
      await app.database.customStatement('DROP TRIGGER fail_ui_save');
      await tapVisible(tester, find.byKey(saveKey));
      expect(
        (await app.repository.loadGoals()).single.titleOn(app.clock.day),
        '失败后重试',
      );
    },
  );

  testUiWidgets(
    'future single is managed and archived completion stays read only',
    (tester) async {
      final app = UiHarness();
      final future = await app.repository.create(
        GoalDraft(
          title: '未来整理资料',
          kind: GoalKind.single,
          plannedDay: app.clock.day.addDays(2),
        ),
      );
      final id = await app.repository.create(
        const GoalDraft(title: '每日阅读', kind: GoalKind.habit),
      );
      await app.mount(tester);
      expect(find.text('未来整理资料'), findsNothing);
      await tapVisible(tester, find.byKey(ValueKey('complete-$id')));
      await tapVisible(tester, find.byKey(ValueKey('detail-$id')));
      await tapVisible(tester, find.byKey(const ValueKey('archive-goal')));
      await tapVisible(tester, find.byKey(const ValueKey('confirm-archive')));
      expect(find.byKey(const ValueKey('edit-goal')), findsNothing);
      expect(find.text('已归档，只读'), findsOneWidget);
      await goBack(tester);
      await tester.pumpAndSettle();
      expect(find.text('今日已完成 1 项'), findsOneWidget);
      expect(find.byKey(ValueKey('undo-$id')), findsNothing);
      await openMenu(tester, '目标管理');
      expect(find.text('未来整理资料'), findsOneWidget);
      await tapVisible(tester, find.byKey(ValueKey('detail-$future')));
      await tapVisible(tester, find.byKey(const ValueKey('edit-goal')));
      expect(find.byKey(const ValueKey('planned-day')), findsOneWidget);
      await goBack(tester);
      await tester.pumpAndSettle();
      await goBack(tester);
      await tester.pumpAndSettle();
      await tapVisible(tester, find.byKey(const ValueKey('goal-filter')));
      await tapVisible(tester, find.text('已归档').last);
      expect(find.text('每日阅读'), findsOneWidget);
      expect(find.text('未来整理资料'), findsNothing);
    },
  );

  testUiWidgets(
    'calendar supports semantic activation and past days are read only',
    (tester) async {
      final app = UiHarness();
      final id = await app.repository.create(
        const GoalDraft(title: '历史阅读', kind: GoalKind.habit),
      );
      await app.repository.setCompleted(id, true, expectedDay: app.clock.day);
      app.clock.setDay(2026, 10, 10);
      await app.mount(tester);
      await tapVisible(tester, find.byTooltip('回顾'));
      final node = tester.getSemantics(
        find.byKey(const ValueKey('review-day-2026-10-09')),
      );
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      tester.binding.rootPipelineOwner.visitChildren((owner) {
        owner.semanticsOwner?.performAction(node.id, SemanticsAction.tap);
      });
      await tester.pumpAndSettle();
      expect(find.text('已完成 1 项'), findsOneWidget);
      expect(find.byKey(ValueKey('undo-$id')), findsNothing);
      await tapVisible(tester, find.byKey(const ValueKey('previous-month')));
      expect(find.text('2026年9月'), findsOneWidget);
      await tapVisible(tester, find.byKey(const ValueKey('review-today')));
      expect(find.text('2026年10月10日'), findsOneWidget);
    },
  );

  testUiWidgets('timer and resume refresh today without losing history', (
    tester,
  ) async {
    final app = UiHarness();
    app.clock.setDay(2026, 10, 9, hour: 23, minute: 59);
    final id = await app.repository.create(
      const GoalDraft(title: '跨日阅读', kind: GoalKind.habit),
    );
    await app.repository.setCompleted(id, true, expectedDay: app.clock.day);
    await app.mount(tester);
    expect(find.text('今日已完成 1 项'), findsOneWidget);
    app.clock.setDay(2026, 10, 10, hour: 0);
    await tester.pump(const Duration(minutes: 1, milliseconds: 30));
    await tester.pumpAndSettle();
    expect(find.text('今日已完成 0 项'), findsOneWidget);
    expect(find.byKey(ValueKey('complete-$id')), findsOneWidget);
    app.clock.setDay(2026, 10, 11);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('10月11日 周日'), findsOneWidget);
    expect((await app.repository.loadGoals()).single.completions, hasLength(1));
  });

  testUiWidgets(
    'clock failure shows retry and cannot silently change the day',
    (tester) async {
      final app = UiHarness();
      app.clockFailure = StateError('injected zone failure');
      await app.mount(tester);
      expect(find.text('无法读取设备日期与时区，记录未被清空。'), findsOneWidget);
      app.clockFailure = null;
      await tapVisible(tester, find.text('重试'));
      expect(find.text('还没有目标'), findsOneWidget);
    },
  );

  for (final size in [
    const Size(320, 568),
    const Size(414, 896),
    const Size(896, 414),
  ]) {
    for (final scale in [1.0, 3.0]) {
      testUiWidgets(
        'real screens fit $size at ${scale}x and remain interactive',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          addTearDown(tester.view.resetViewInsets);
          final app = UiHarness();
          final id = await app.repository.create(
            GoalDraft(
              title: '${List.filled(20, '阅读').join()} 📖',
              kind: GoalKind.habit,
            ),
          );
          await app.mount(tester);
          expect(tester.takeException(), isNull);
          await tapVisible(tester, find.byKey(ValueKey('complete-$id')));
          expect(find.text('今日已完成 1 项'), findsOneWidget);
          await tapVisible(tester, find.byKey(ValueKey('undo-$id')));
          expect(find.text('今日已完成 0 项'), findsOneWidget);
          await tapVisible(tester, find.byKey(ValueKey('detail-$id')));
          await tapVisible(tester, find.byKey(const ValueKey('edit-goal')));
          await tester.enterText(find.byKey(titleKey), '小屏幕长名称与中文输入 📖');
          tester.view.viewInsets = FakeViewPadding(bottom: size.height / 3);
          await tester.pumpAndSettle();
          await tapVisible(tester, find.byKey(saveKey));
          tester.view.resetViewInsets();
          await tester.pumpAndSettle();
          expect(find.text('小屏幕长名称与中文输入 📖'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tapVisible(tester, find.byKey(const ValueKey('goal-history')));
          expect(find.byKey(const ValueKey('review-month')), findsOneWidget);
          final calendar = find.byWidgetPredicate(
            (widget) =>
                widget is SingleChildScrollView &&
                widget.scrollDirection == Axis.horizontal,
          );
          await tester.ensureVisible(calendar);
          final scroll = tester
              .widget<SingleChildScrollView>(calendar)
              .controller!;
          if (scroll.position.maxScrollExtent > 0) {
            await tester.dragFrom(
              tester.getTopLeft(calendar) + const Offset(100, 24),
              const Offset(-160, 0),
            );
            await tester.pumpAndSettle();
            expect(scroll.offset, greaterThan(0));
          }
          expect(tester.takeException(), isNull);
          await goBack(tester);
          await tester.pumpAndSettle();
          await goBack(tester);
          await tester.pumpAndSettle();
          await openMenu(tester, '目标管理');
          expect(tester.takeException(), isNull);
          await goBack(tester);
          await tester.pumpAndSettle();
          await openMenu(tester, '设置');
          expect(tester.takeException(), isNull);
          expect(find.text('系统通知'), findsOneWidget);
        },
      );
    }
  }
}
