import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/app/home_page.dart';
import 'package:habit_checkin/app/providers.dart';
import 'package:habit_checkin/features/assistant/data/local_proposal_store.dart';
import 'package:habit_checkin/features/assistant/domain/plan_preview.dart';
import 'package:habit_checkin/features/assistant/presentation/assistant_proposal_page.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:habit_checkin/features/reminders/notification_permissions.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:xingyuan_core/xingyuan_core.dart';

import 'support/assistant_fixtures.dart';
import 'support/ui_harness.dart';

Future<String> seed(UiHarness app, {PlanPreview? preview}) async {
  await seedAssistantReply(app.database);
  return LocalProposalStore(app.repository).saveDraft(
    sessionId: 'test-session',
    messageId: 'test-message',
    preview: preview ?? syntheticPreview(),
  );
}

Future<void> open(WidgetTester tester, String id) async {
  final context = tester.element(find.byType(HomePage));
  unawaited(
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AssistantProposalPage(proposalId: id),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(tzdata.initializeTimeZones);
  testUiWidgets(
    'last-goal cancellation failure stays visible and retry drains the durable intent',
    (tester) async {
      final app = UiHarness();
      app.permissions.access = NotificationAccess.allowed;
      final id = await seed(
        app,
        preview: syntheticPreview(count: 1, reminders: true),
      );
      await app.mount(tester);
      await open(tester, id);
      await tapVisible(
        tester,
        find.byKey(const ValueKey('assistant-apply-plan')),
      );
      expect(app.notifications.requests, hasLength(1));
      app.notifications.ignoreCancel = true;
      await tapVisible(
        tester,
        find.byKey(const ValueKey('assistant-undo-plan')),
      );
      await tapVisible(
        tester,
        find.byKey(const ValueKey('assistant-undo-confirm')),
      );
      expect(await app.repository.loadGoals(), isEmpty);
      expect(
        await app.database.select(app.database.reminderCancellations).get(),
        hasLength(1),
      );
      expect(find.text('提醒安排或取消未确认，记录已保存。'), findsOneWidget);
      app.notifications.ignoreCancel = false;
      await tapVisible(tester, find.widgetWithText(TextButton, '重试'));
      expect(
        await app.database.select(app.database.reminderCancellations).get(),
        isEmpty,
      );
      expect(app.notifications.requests, isEmpty);
      expect(find.text('提醒安排或取消未确认，记录已保存。'), findsNothing);
    },
  );
  for (final scale in [1.0, 2.0, 3.0]) {
    testUiWidgets(
      'preview edits, confirmation and undo work at 320px ${scale}x',
      (tester) async {
        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final app = UiHarness();
        final id = await seed(app);
        await app.mount(tester);
        await open(tester, id);
        expect(await app.repository.loadGoals(), isEmpty);
        await tapVisible(
          tester,
          find.byKey(const ValueKey('edit-plan-item-0')),
        );
        await tester.enterText(
          find.byKey(const ValueKey('assistant-plan-title')),
          'TEST edited',
        );
        await tester.ensureVisible(
          find.byKey(const ValueKey('duration-minutes')),
        );
        await tester.enterText(
          find.byKey(const ValueKey('duration-minutes')),
          '45',
        );
        await tapVisible(
          tester,
          find.byKey(const ValueKey('assistant-save-plan-item')),
        );
        await tapVisible(
          tester,
          find.byKey(const ValueKey('delete-plan-item-1')),
        );
        final store = LocalProposalStore(app.repository);
        final draft = PlanPreview.decode((await store.read(id)).itemsJson);
        expect(draft.items.single.task.title, 'TEST edited');
        expect(draft.items.single.task.minutes, 45);
        await goBack(tester);
        await open(tester, id);
        expect(find.text('TEST edited'), findsOneWidget);
        await tapVisible(tester, find.widgetWithText(SwitchListTile, '开启定时提醒'));
        expect(app.permissions.requests, 1);
        expect(find.textContaining('通知权限未开启'), findsOneWidget);
        await tapVisible(
          tester,
          find.byKey(const ValueKey('assistant-apply-plan')),
        );
        final created = (await app.repository.loadGoals()).single;
        expect(created.titleOn(app.clock.day), 'TEST edited');
        expect(created.scheduleOn(app.clock.day).durationMinutes, 45);
        expect(created.reminder.enabled, isTrue);
        expect(app.notifications.requests, isEmpty);
        expect(find.text('已创建 1 项'), findsOneWidget);
        await tapVisible(tester, find.byTooltip('查看对应日期'));
        expect(find.text('2026年10月'), findsOneWidget);
        await goBack(tester);
        await tapVisible(
          tester,
          find.byKey(const ValueKey('assistant-undo-plan')),
        );
        await tapVisible(
          tester,
          find.byKey(const ValueKey('assistant-undo-confirm')),
        );
        expect(find.text('已撤销'), findsOneWidget);
        expect(await app.repository.loadGoals(), isEmpty);
        expect(
          find.byKey(const ValueKey('assistant-apply-plan')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testUiWidgets(
    'expired proposal is blocked until explicit date selection, conflicts only warn',
    (tester) async {
      final app = UiHarness();
      final id = await seed(app, preview: syntheticPreview(count: 1));
      app.clock.setDay(2026, 10, 10);
      await app.repository.create(
        GoalDraft(
          title: 'TEST item 0',
          kind: GoalKind.single,
          plannedDay: app.clock.day,
          startMinute: 19 * 60,
          durationMinutes: 30,
        ),
      );
      await app.mount(tester);
      await open(tester, id);
      expect(find.text('已过期，请改期或删除'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('assistant-apply-plan')),
            )
            .onPressed,
        isNull,
      );
      await tapVisible(tester, find.byKey(const ValueKey('edit-plan-item-0')));
      await tapVisible(
        tester,
        find.byKey(const ValueKey('assistant-plan-date')),
      );
      await tapVisible(tester, find.widgetWithText(TextButton, '确定'));
      await tapVisible(
        tester,
        find.byKey(const ValueKey('assistant-save-plan-item')),
      );
      expect(find.text('与已有安排同名'), findsOneWidget);
      expect(find.text('与已有安排时间重叠'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('assistant-apply-plan')),
            )
            .onPressed,
        isNotNull,
      );
      await tapVisible(
        tester,
        find.byKey(const ValueKey('assistant-apply-plan')),
      );
      expect(await app.repository.loadGoals(), hasLength(2));
    },
  );

  testUiWidgets(
    'future preview only warns for singles actually planned on that date',
    (tester) async {
      final app = UiHarness();
      final tomorrow = app.clock.day.addDays(1);
      final existingId = await app.repository.create(
        GoalDraft(
          title: 'TEST item 0',
          kind: GoalKind.single,
          plannedDay: app.clock.day,
          startMinute: 19 * 60,
          durationMinutes: 30,
        ),
      );
      final id = await seed(
        app,
        preview: syntheticPreview(day: tomorrow.key, count: 1),
      );
      await app.mount(tester);
      await open(tester, id);
      expect(find.text('与已有安排同名'), findsNothing);
      expect(find.text('与已有安排时间重叠'), findsNothing);
      await goBack(tester);
      await app.repository.edit(
        existingId,
        GoalDraft(
          title: 'TEST item 0',
          kind: GoalKind.single,
          plannedDay: tomorrow,
          startMinute: 19 * 60,
          durationMinutes: 30,
        ),
      );
      await open(tester, id);
      expect(find.text('与已有安排同名'), findsOneWidget);
      expect(find.text('与已有安排时间重叠'), findsOneWidget);
      await tapVisible(
        tester,
        find.byKey(const ValueKey('assistant-apply-plan')),
      );
      expect(await app.repository.loadGoals(), hasLength(2));
      expect(tester.takeException(), isNull);
    },
  );

  testUiWidgets(
    'midnight refresh marks stale draft without rewriting its original date',
    (tester) async {
      final app = UiHarness();
      final id = await seed(app, preview: syntheticPreview(count: 1));
      await app.mount(tester);
      await open(tester, id);
      app.clock.setDay(2026, 10, 10);
      await app.container.read(environmentProvider.notifier).refresh();
      await tester.pumpAndSettle();
      expect(find.text('已过期，请改期或删除'), findsOneWidget);
      final row = await LocalProposalStore(app.repository).read(id);
      expect(
        PlanPreview.decode(row.itemsJson).items.single.task.date.key,
        '2026-10-09',
      );
      expect(await app.repository.loadGoals(), isEmpty);
    },
  );

  testUiWidgets(
    'undo preview preserves false check-in history and cancels only deleted reminders',
    (tester) async {
      final app = UiHarness();
      app.permissions.access = NotificationAccess.allowed;
      final id = await seed(app, preview: syntheticPreview(reminders: true));
      await app.mount(tester);
      await open(tester, id);
      await tapVisible(
        tester,
        find.byKey(const ValueKey('assistant-apply-plan')),
      );
      final goals = await app.repository.loadGoals();
      await app.repository.setCompleted(
        goals.first.id,
        true,
        expectedDay: app.clock.day,
      );
      await app.repository.setCompleted(
        goals.first.id,
        false,
        expectedDay: app.clock.day,
      );
      await tapVisible(
        tester,
        find.byKey(const ValueKey('assistant-undo-plan')),
      );
      expect(find.textContaining('保留，已有打卡记录'), findsOneWidget);
      await tapVisible(
        tester,
        find.byKey(const ValueKey('assistant-undo-confirm')),
      );
      expect((await app.repository.loadGoals()).single.id, goals.first.id);
      expect(
        await app.database.select(app.database.reminderCancellations).get(),
        isEmpty,
      );
      expect(app.notifications.requests, hasLength(1));
      expect(find.textContaining('保留，已有打卡记录'), findsOneWidget);
    },
  );

  testUiWidgets(
    'clear all times clears reminder choices; habit fields remain editable',
    (tester) async {
      final app = UiHarness();
      final habit = syntheticPreview(count: 1, habit: true).items.single;
      final single = PreviewItem(
        id: 'single',
        task: PlanTask.fromJson({
          'title': 'TEST later',
          'date': '2026-10-15',
          'time': '18:00',
          'minutes': 30,
        }, habit: false),
        reminder: true,
      );
      final id = await seed(app, preview: PlanPreview([habit, single]));
      await app.mount(tester);
      await open(tester, id);
      expect(find.text('重复习惯'), findsOneWidget);
      await tapVisible(tester, find.byTooltip('清除全部时间'));
      final preview = PlanPreview.decode(
        (await LocalProposalStore(app.repository).read(id)).itemsJson,
      );
      expect(
        preview.items.every((item) => item.task.time == null && !item.reminder),
        isTrue,
      );
      await tapVisible(tester, find.byKey(const ValueKey('edit-plan-item-0')));
      await tapVisible(tester, find.widgetWithText(CheckboxListTile, '周一'));
      await tapVisible(
        tester,
        find.byKey(const ValueKey('assistant-save-plan-item')),
      );
      final updated = PlanPreview.decode(
        (await LocalProposalStore(app.repository).read(id)).itemsJson,
      );
      expect(updated.items.first.task.weekdays, [3, 5]);
      expect(updated.items.first.task.minutes, 30);
      expect(await app.repository.loadGoals(), isEmpty);
    },
  );
}
