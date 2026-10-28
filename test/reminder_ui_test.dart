import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/app/providers.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:habit_checkin/features/reminders/notification_permissions.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'support/ui_harness.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);

  for (final scale in [1.0, 3.0]) {
    testUiWidgets('real reminder controls and coverage at ${scale}x', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final app = UiHarness();
      app.permissions.access = NotificationAccess.allowed;
      await app.mount(tester);
      await tapVisible(tester, find.byKey(const ValueKey('entry-new-goal')));
      await tester.enterText(
        find.byKey(const ValueKey('goal-title')),
        'TEST reminder',
      );
      await tapVisible(tester, find.byKey(const ValueKey('reminder-toggle')));
      await tapVisible(tester, find.byKey(const ValueKey('save-goal')));
      final goal = (await app.repository.loadGoals()).single;
      expect(app.permissions.requests, 1);
      expect(app.notifications.requests, hasLength(64));
      await tapVisible(tester, find.byKey(ValueKey('detail-${goal.id}')));
      expect(find.text('已预排 64 次'), findsOneWidget);
      expect(find.textContaining('已安排至：'), findsOneWidget);
      expect(find.textContaining('尚未覆盖：'), findsOneWidget);
      app.notifications.failure = StateError('injected failure');
      await app.container.read(reminderReportProvider.notifier).refresh();
      await tester.pumpAndSettle();
      expect(find.text('提醒安排或取消未确认，记录已保存。'), findsOneWidget);
      app.notifications.failure = null;
      await tapVisible(tester, find.text('重试'));
      expect(find.text('已预排 64 次'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testUiWidgets('notification opens today without mutating a goal', (
    tester,
  ) async {
    final app = UiHarness();
    final id = await app.repository.create(
      const GoalDraft(title: 'TEST tap', kind: GoalKind.habit),
    );
    await app.mount(tester);
    await tapVisible(tester, find.byTooltip('回顾'));
    await openMenu(tester, '设置');
    app.container.read(notificationOpenProvider.notifier).opened();
    await tester.pumpAndSettle();
    expect(find.text('设置'), findsNothing);
    expect(find.text('今日已完成 0 项'), findsOneWidget);
    expect((await app.repository.loadGoals()).single.id, id);
    expect((await app.repository.loadGoals()).single.completions, isEmpty);
  });
}
