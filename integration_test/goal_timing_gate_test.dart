import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/app/app.dart';
import 'package:habit_checkin/app/providers.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/local/open_database.dart';
import 'package:habit_checkin/features/assistant/assistant_providers.dart';
import 'package:habit_checkin/features/assistant/data/local_conversation_store.dart';
import 'package:habit_checkin/features/assistant/domain/plan_preview.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:habit_checkin/features/goals/presentation/goal_tile.dart';
import 'package:habit_checkin/shared/local_date.dart';
import 'package:integration_test/integration_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:xingyuan_core/xingyuan_core.dart' as core;

import '../test/support/test_assistant_service.dart';
import '../test/support/test_clock.dart';
import '../test/support/test_reminder_notifications.dart';
import '../test/support/ui_harness.dart' show TestNotificationPermissions;

// Isolated simulator: real SQLite/UI, synthetic assistant and notifications.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  const phase = String.fromEnvironment('GOAL_TIMING_PHASE');
  const run = String.fromEnvironment('GOAL_TIMING_RUN');

  testWidgets('timing edits and historical displays survive iOS processes', (
    tester,
  ) async {
    expect(['write', 'reopen'], contains(phase));
    expect(RegExp(r'^[A-Za-z0-9-]{8,60}$').hasMatch(run), isTrue);
    final db = openAppDatabase(name: 'habit_checkin_timing_$run');
    final clock = TestClock()..setDay(2026, 10, 20);
    final goals = LocalGoalRepository(db, clock);
    final store = LocalConversationStore(goals);
    final permissions = TestNotificationPermissions();
    final notifications = TestReminderNotifications();
    final service = ConversationTestService()
      ..onTurn = (request) async => core.TurnResponse.fromJson({
        'protocol': core.assistantProtocol,
        'request_id': request.requestId,
        'reply': 'TEST 时间验收提议，确认前不创建。',
        'plan': {
          'tasks': [
            {
              'title': 'TEST AI 单次',
              'date': request.now.date.key,
              'time': '21:00',
              'minutes': 20,
            },
            {
              'title': 'TEST AI 明天',
              'date': request.now.date.addDays(1).key,
              'time': null,
              'minutes': null,
            },
          ],
          'habits': [
            {
              'title': 'TEST AI 习惯',
              'start_date': request.now.date.key,
              'weekdays': [1, 3, 5],
              'time': '07:00',
              'minutes': 30,
            },
          ],
        },
        'memory_ops': [],
      }, request: request);
    late ProviderContainer container;

    Future<void> tap(Finder finder) async {
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
      await tester.tap(finder);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }

    Future<void> enter(Finder finder, String value) async {
      await tap(finder);
      await tester.enterText(finder, value);
      await tester.pumpAndSettle();
    }

    Future<void> back() => tap(find.byType(BackButton));

    Future<void> setTime(int minute) async {
      await tap(find.byKey(const ValueKey('start-time')));
      final picker = find.byType(CupertinoDatePicker);
      expect(picker, findsOneWidget);
      expect(tester.widget<CupertinoDatePicker>(picker).use24hFormat, isTrue);
      final wheels = find.byWidgetPredicate(
        (widget) =>
            widget is CupertinoPicker && widget.scrollController != null,
      );
      expect(wheels, findsNWidgets(2));
      tester
          .widget<CupertinoPicker>(wheels.at(0))
          .scrollController!
          .jumpToItem(minute ~/ 60);
      tester
          .widget<CupertinoPicker>(wheels.at(1))
          .scrollController!
          .jumpToItem(minute % 60);
      await tester.pumpAndSettle();
      await tap(find.byKey(const ValueKey('time-picker-confirm')));
      expect(picker, findsNothing);
    }

    Future<void> minutes(int value) =>
        enter(find.byKey(const ValueKey('duration-minutes')), '$value');

    Future<void> clearTiming() async {
      await tap(find.byKey(const ValueKey('clear-start-time')));
      await tap(find.byTooltip('清除预计分钟'));
    }

    Future<Goal> goal(String title) async => (await goals.loadGoals())
        .singleWhere((goal) => goal.titleOn(clock.day) == title);

    Future<int> create(String title, {bool single = false, int? time}) async {
      await tap(find.byKey(const ValueKey('entry-new-goal')));
      await enter(find.byKey(const ValueKey('goal-title')), title);
      if (single) {
        await tap(find.byKey(const ValueKey('goal-kind')));
        await tap(find.text('单次任务').last);
      }
      if (time != null) {
        await setTime(time);
        await minutes(30);
      }
      await tap(find.byKey(const ValueKey('save-goal')));
      expect(find.byKey(const ValueKey('save-goal')), findsNothing);
      return (await goal(title)).id;
    }

    Future<void> openGoal(int id) => tap(find.byKey(ValueKey('detail-$id')));

    Future<void> edit(int id) async {
      await openGoal(id);
      await tap(find.byKey(const ValueKey('edit-goal')));
    }

    Future<void> setDay(int day) async {
      clock.setDay(2026, 10, day);
      await container.read(environmentProvider.notifier).refresh();
      await tester.pumpAndSettle();
    }

    Future<void> tileLabel(int id, String label) async {
      final tile = find.ancestor(
        of: find.byKey(ValueKey('detail-$id')),
        matching: find.byType(GoalTile),
      );
      expect(tile, findsOneWidget);
      final text = find.descendant(of: tile, matching: find.text(label));
      await tester.ensureVisible(text);
      await tester.pumpAndSettle();
      expect(text, findsOneWidget);
    }

    void todayOrder(List<int> ids) {
      expect(
        tester
            .widgetList<GoalTile>(find.byType(GoalTile))
            .map((tile) => tile.view.goal.id),
        ids,
      );
    }

    Future<void> reviewDay(int day) =>
        tap(find.byKey(ValueKey('review-day-${LocalDate(2026, 10, day).key}')));

    try {
      if (phase == 'write') {
        expect(await goals.loadGoals(), isEmpty);
        expect(await store.sessions(), isEmpty);
      }
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            clockProvider.overrideWithValue(clock),
            refreshClockProvider.overrideWithValue(() async {}),
            goalRepositoryProvider.overrideWith((ref) => goals),
            assistantServiceProvider.overrideWithValue(service),
            assistantCredentialProvider.overrideWithValue(
              ConversationTestCredentials(),
            ),
            notificationPermissionsProvider.overrideWithValue(permissions),
            reminderNotificationsProvider.overrideWithValue(notifications),
          ],
          child: const HabitCheckinApp(),
        ),
      );
      await tester.pumpAndSettle();
      container = ProviderScope.containerOf(
        tester.element(find.byType(HabitCheckinApp)),
      );

      if (phase == 'write') {
        final single = await create('TEST 手动单次', single: true, time: 1170);
        await tileLabel(single, '计划 2026年10月20日 · 19:30 · 30 分钟');
        await edit(single);
        await setTime(1095);
        await minutes(45);
        await tap(find.byKey(const ValueKey('save-goal')));
        expect(find.text('计划 2026年10月20日 · 18:15 · 45 分钟'), findsOneWidget);
        await back();
        final habit = await create('TEST 手动习惯', time: 420);
        await edit(habit);
        await setTime(495);
        await minutes(45);
        expect(find.text('时间与分钟从 2026年10月21日 起生效，今天不变。'), findsOneWidget);
        await tap(find.byKey(const ValueKey('save-goal')));
        expect(find.text('每天 · 07:00 · 30 分钟'), findsOneWidget);
        expect(find.text('2026年10月21日 起：每天 · 08:15 · 45 分钟'), findsOneWidget);
        await back();
        final untimed = await create('TEST 手动清空', single: true, time: 1170);
        await edit(untimed);
        await clearTiming();
        await tap(find.byKey(const ValueKey('save-goal')));
        expect(find.text('计划 2026年10月20日'), findsOneWidget);
        await back();
        debugPrint('TIMING_CHECK manual-create-edit-clear PASS');

        await tap(find.byTooltip('规划'));
        await tap(find.byKey(const ValueKey('assistant-consent-confirm')));
        final controller = await container.read(
          assistantConversationProvider.future,
        );
        await enter(find.byKey(const ValueKey('assistant-input')), 'TEST 时间验收');
        await tap(find.byKey(const ValueKey('assistant-send')));
        final waiting = Stopwatch()..start();
        while ((controller.busy || service.requests.isEmpty) &&
            controller.error == null &&
            waiting.elapsed < const Duration(seconds: 20)) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(controller.error, isNull);
        expect(controller.busy, isFalse);
        expect(service.requests, hasLength(1));
        await tester.pumpAndSettle();
        final proposal = (await store.sessionProposals(
          (await store.sessions()).single.id,
        )).single;
        var preview = PlanPreview.decode(proposal.itemsJson);
        final first = preview.items.singleWhere(
          (i) => i.task.title == 'TEST AI 单次',
        );
        final future = preview.items.singleWhere(
          (i) => i.task.title == 'TEST AI 明天',
        );
        final repeating = preview.items.singleWhere((i) => i.task.isHabit);
        await tap(find.byKey(ValueKey('open-proposal-${proposal.id}')));
        expect(find.text('2026年10月20日 周二'), findsOneWidget);
        expect(find.text('2026年10月21日 周三'), findsOneWidget);
        expect(find.text('周一、周三、周五'), findsOneWidget);
        await tap(find.byKey(ValueKey('edit-plan-${first.id}')));
        await setTime(1215);
        await minutes(40);
        await tap(find.byKey(const ValueKey('assistant-save-plan-item')));
        await tap(find.byKey(ValueKey('edit-plan-${future.id}')));
        await setTime(1170);
        await minutes(35);
        await tap(find.byKey(const ValueKey('assistant-save-plan-item')));
        await tap(find.byTooltip('清除全部时间'));
        preview = PlanPreview.decode(
          (await store.proposals.read(proposal.id)).itemsJson,
        );
        expect(
          preview.items.every((i) => i.task.time == null && !i.reminder),
          isTrue,
        );
        expect(preview.items.map((i) => i.task.minutes), [40, 35, 30]);
        await tap(find.byKey(ValueKey('edit-plan-${first.id}')));
        await setTime(1215);
        await tap(find.byKey(const ValueKey('assistant-save-plan-item')));
        await tap(find.byKey(ValueKey('edit-plan-${future.id}')));
        await tap(find.byTooltip('清除预计分钟'));
        await tap(find.byKey(const ValueKey('assistant-save-plan-item')));
        await tap(find.byKey(ValueKey('edit-plan-${repeating.id}')));
        await setTime(420);
        await tap(find.byKey(const ValueKey('assistant-save-plan-item')));
        expect(await goals.loadGoals(), hasLength(3));
        await tap(find.byKey(const ValueKey('assistant-apply-plan')));
        expect(find.text('已创建 3 项'), findsOneWidget);
        expect(await goals.loadGoals(), hasLength(6));
        await back();
        await tap(find.byTooltip('今天'));
        final ai = await goal('TEST AI 单次');
        await tileLabel(ai.id, '计划 2026年10月20日 · 20:15 · 40 分钟');
        await edit(ai.id);
        await setTime(1080);
        await minutes(35);
        await tap(find.byKey(const ValueKey('save-goal')));
        expect(find.text('计划 2026年10月20日 · 18:00 · 35 分钟'), findsOneWidget);
        await back();
        todayOrder([habit, ai.id, single, untimed]);
        debugPrint('TIMING_CHECK proposal-edit-clear-apply-and-order PASS');

        await setDay(21);
        await edit(habit);
        await clearTiming();
        expect(find.text('时间与分钟从 2026年10月22日 起生效，今天不变。'), findsOneWidget);
        await tap(find.byKey(const ValueKey('save-goal')));
        expect(find.text('每天 · 08:15 · 45 分钟'), findsOneWidget);
        expect(find.text('2026年10月22日 起：每天'), findsOneWidget);
        await back();
      }

      final manual = await goal('TEST 手动单次');
      final habit = await goal('TEST 手动习惯');
      final cleared = await goal('TEST 手动清空');
      final ai = await goal('TEST AI 单次');
      final future = await goal('TEST AI 明天');
      final aiHabit = await goal('TEST AI 习惯');
      final day = LocalDate(2026, 10, 20);
      expect((await goals.loadGoals()).length, 6);
      expect(manual.scheduleOn(day).timing.label, '18:15 · 45 分钟');
      expect(cleared.scheduleOn(day).timing.label, isEmpty);
      expect(ai.scheduleOn(day).timing.label, '18:00 · 35 分钟');
      expect(future.scheduleOn(day).timing.label, isEmpty);
      expect(future.scheduleOn(day).plannedDay, day.addDays(1));
      expect(aiHabit.scheduleOn(day).weekdays, 21);
      expect(aiHabit.scheduleOn(day).timing.label, '07:00 · 30 分钟');
      expect(habit.schedules, hasLength(3));
      expect(habit.scheduleOn(day).timing.label, '07:00 · 30 分钟');
      expect(habit.scheduleOn(day.addDays(1)).timing.label, '08:15 · 45 分钟');
      expect(habit.scheduleOn(day.addDays(2)).timing.label, isEmpty);

      await setDay(20);
      todayOrder([habit.id, ai.id, manual.id, cleared.id]);
      await tileLabel(habit.id, '每天 · 07:00 · 30 分钟');
      await tileLabel(ai.id, '计划 2026年10月20日 · 18:00 · 35 分钟');
      await tileLabel(manual.id, '计划 2026年10月20日 · 18:15 · 45 分钟');
      await tileLabel(cleared.id, '计划 2026年10月20日');
      await tap(find.byTooltip('我的'));
      await tap(find.text('目标管理'));
      await tileLabel(aiHabit.id, '周一、周三、周五 · 07:00 · 30 分钟');
      await tileLabel(future.id, '计划 2026年10月21日');
      await tileLabel(manual.id, '计划 2026年10月20日 · 18:15 · 45 分钟');
      await tileLabel(ai.id, '计划 2026年10月20日 · 18:00 · 35 分钟');
      await openGoal(aiHabit.id);
      expect(find.text('周一、周三、周五 · 07:00 · 30 分钟'), findsOneWidget);
      await back();
      await back();
      await tap(find.byTooltip('今天'));
      await openGoal(habit.id);
      expect(find.text('2026年10月21日 起：每天 · 08:15 · 45 分钟'), findsOneWidget);
      await tap(find.byKey(const ValueKey('goal-history')));
      for (final entry in {
        20: '每天 · 07:00 · 30 分钟',
        21: '每天 · 08:15 · 45 分钟',
        22: '每天',
      }.entries) {
        await reviewDay(entry.key);
        await tileLabel(habit.id, entry.value);
      }
      await back();
      await back();
      await tap(find.byTooltip('回顾'));
      await reviewDay(21);
      await tileLabel(aiHabit.id, '周一、周三、周五 · 07:00 · 30 分钟');
      await tileLabel(future.id, '计划 2026年10月21日');
      await tileLabel(ai.id, '计划 2026年10月20日 · 18:00 · 35 分钟');
      await tileLabel(manual.id, '计划 2026年10月20日 · 18:15 · 45 分钟');
      debugPrint('TIMING_CHECK management-detail-and-history PASS');

      await tap(find.byTooltip('今天'));
      await setDay(21);
      todayOrder([
        aiHabit.id,
        habit.id,
        ai.id,
        manual.id,
        cleared.id,
        future.id,
      ]);
      await tileLabel(aiHabit.id, '周一、周三、周五 · 07:00 · 30 分钟');
      await tileLabel(habit.id, '每天 · 08:15 · 45 分钟');
      await setDay(22);
      todayOrder([ai.id, manual.id, habit.id, cleared.id, future.id]);
      await tileLabel(habit.id, '每天');
      expect(find.byKey(ValueKey('detail-${aiHabit.id}')), findsNothing);
      debugPrint('TIMING_CHECK next-day-version-and-order PASS');

      final proposal = (await store.sessionProposals(
        (await store.sessions()).single.id,
      )).single;
      expect(proposal.status, 'applied');
      final receipt = PlanPreview.decode(proposal.appliedItemsJson!);
      expect(receipt.items.first.timing.label, '20:15 · 40 分钟');
      expect(receipt.items[1].timing.label, isEmpty);
      expect(receipt.items.last.task.weekdays, [1, 3, 5]);
      expect(
        (await goals.loadGoals()).every((g) => !g.reminder.enabled),
        isTrue,
      );
      expect(permissions.requests, 0);
      expect(notifications.requests, isEmpty);
      expect(await db.select(db.syncOutbox).get(), isEmpty);
      expect(await db.customSelect('PRAGMA foreign_key_check').get(), isEmpty);
      expect(
        (await db.customSelect('PRAGMA integrity_check').get())
            .single
            .data
            .values,
        ['ok'],
      );
      expect(service.requests.length, phase == 'write' ? 1 : 0);
      expect(service.summaries, isEmpty);
      expect(tester.takeException(), isNull);
      debugPrint('TIMING_CHECK $phase-complete PASS');
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(Duration.zero);
      await db.close();
    }
  });
}
