import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/app/app.dart';
import 'package:habit_checkin/app/providers.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/local/open_database.dart';
import 'package:habit_checkin/features/assistant/assistant_providers.dart';
import 'package:habit_checkin/features/assistant/data/assistant_service.dart';
import 'package:habit_checkin/features/assistant/data/local_conversation_store.dart';
import 'package:integration_test/integration_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:xingyuan_core/xingyuan_core.dart';

import '../test/support/test_assistant_service.dart';
import '../test/support/test_clock.dart';
import '../test/support/test_reminder_notifications.dart';
import '../test/support/ui_harness.dart' show TestNotificationPermissions;

// Test simulator only. All data, credentials, transport and notifications are synthetic.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  const phase = String.fromEnvironment('ASSISTANT_JOURNEY_PHASE');
  const run = String.fromEnvironment('ASSISTANT_JOURNEY_RUN');

  testWidgets(
    'consecutive user workflows and restart preserve the right data',
    (tester) async {
      expect(['write', 'reopen'], contains(phase));
      expect(RegExp(r'^[A-Za-z0-9-]{8,60}$').hasMatch(run), isTrue);
      final db = openAppDatabase(name: 'habit_checkin_journey_$run');
      final clock = TestClock()..setDay(2026, 10, 20, hour: 12);
      final goals = LocalGoalRepository(db, clock);
      final store = LocalConversationStore(goals);
      final service = ConversationTestService();
      service.onTurn = (request) async {
        if (request.messages.last.text == 'TEST 网络故障') {
          throw const AssistantFailure(AssistantFailureKind.network);
        }
        return TurnResponse.fromJson({
          'protocol': assistantProtocol,
          'request_id': request.requestId,
          'reply': 'TEST 先预览再确认',
          'plan': {
            'tasks': [
              for (final title in ['TEST 保留打卡', 'TEST 未打卡'])
                {
                  'title': title,
                  'date': request.now.date.key,
                  'time': null,
                  'minutes': 30,
                },
            ],
            'habits': [],
          },
          'memory_ops': [],
        }, request: request);
      };
      final input = find.byKey(const ValueKey('assistant-input'));

      Future<void> waitFor(Future<bool> Function() predicate) async {
        final elapsed = Stopwatch()..start();
        while (!await predicate()) {
          if (elapsed.elapsed > const Duration(seconds: 20)) {
            fail('Native operation did not finish within 20 seconds');
          }
          await tester.pump(const Duration(milliseconds: 50));
        }
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }

      Future<void> tap(Finder finder) async {
        await tester.ensureVisible(finder);
        await tester.pumpAndSettle();
        await tester.tap(finder);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }

      Future<void> enter(Finder finder, String text) async {
        await tap(finder);
        await tester.enterText(finder, text);
        await tester.pumpAndSettle();
      }

      Future<void> back() => tap(find.byType(BackButton));
      void draft(String text) =>
          expect(tester.widget<TextField>(input).controller!.text, text);

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
              notificationPermissionsProvider.overrideWithValue(
                TestNotificationPermissions(),
              ),
              reminderNotificationsProvider.overrideWithValue(
                TestReminderNotifications(),
              ),
            ],
            child: const HabitCheckinApp(),
          ),
        );
        await tester.pumpAndSettle();
        final container = ProviderScope.containerOf(
          tester.element(find.byType(HabitCheckinApp)),
        );
        await tap(find.byTooltip('规划'));
        if (phase == 'write') {
          await tap(find.byKey(const ValueKey('assistant-consent-confirm')));
        }
        await waitFor(() async => input.evaluate().isNotEmpty);
        final controller = await container.read(
          assistantConversationProvider.future,
        );

        Future<void> send(String text) async {
          final before = service.requests.length;
          await enter(input, text);
          await tap(find.byKey(const ValueKey('assistant-send')));
          await waitFor(
            () async => !controller.busy && service.requests.length > before,
          );
        }

        if (phase == 'write') {
          await enter(input, 'TEST 返回不能清空');
          await tap(find.byTooltip('会话列表'));
          await back();
          draft('TEST 返回不能清空');
          await tap(find.byTooltip('今天'));
          await tap(find.byTooltip('规划'));
          draft('TEST 返回不能清空');
          await send('TEST 网络故障');
          expect(controller.messages.single.status, 'failed');
          expect(controller.proposals, isEmpty);
          final first = controller.session!.id;
          await enter(input, 'TEST 会话一草稿');
          await tap(find.byTooltip('会话列表'));
          await tap(find.widgetWithText(ListTile, 'TEST 网络故障'));
          draft('TEST 会话一草稿');
          await tap(find.byTooltip('会话列表'));
          final create = find.byKey(const ValueKey('assistant-new-session'));
          await tester.tap(create);
          await tester.tap(create);
          await waitFor(() async => input.evaluate().isNotEmpty);
          expect(controller.sessions, hasLength(2));
          draft('');
          await enter(input, 'TEST 会话二草稿');
          await tap(find.byTooltip('会话列表'));
          await tap(find.widgetWithText(ListTile, 'TEST 网络故障'));
          expect(controller.session!.id, first);
          draft('TEST 会话一草稿');
          await tap(find.byTooltip('会话列表'));
          await tap(find.widgetWithText(ListTile, '新会话'));
          draft('TEST 会话二草稿');
          await tap(find.byTooltip('会话列表'));
          await tap(find.widgetWithText(ListTile, 'TEST 网络故障'));
          await send('TEST 恢复后安排');
          expect(controller.error, isNull);
          expect(controller.messages, hasLength(3));
          expect(await goals.loadGoals(), isEmpty);
          final proposal = controller.proposals.single;
          final open = find.byKey(ValueKey('open-proposal-${proposal.id}'));
          await tap(open);
          await waitFor(
            () async => find.byTooltip('编辑条目').evaluate().isNotEmpty,
          );
          await tap(find.byTooltip('编辑条目').first);
          await enter(
            find.byKey(const ValueKey('assistant-plan-title')),
            'TEST 修改后保留',
          );
          await enter(find.byKey(const ValueKey('duration-minutes')), '45');
          await tap(find.byKey(const ValueKey('assistant-save-plan-item')));
          await waitFor(
            () async => find.text('TEST 修改后保留').evaluate().isNotEmpty,
          );
          await back();
          await tap(open);
          await waitFor(
            () async => find.text('TEST 修改后保留').evaluate().isNotEmpty,
          );
          expect(find.textContaining('45 分钟'), findsOneWidget);
          await tap(find.byKey(const ValueKey('assistant-apply-plan')));
          await waitFor(
            () async =>
                (await store.proposals.read(proposal.id)).status == 'applied',
          );
          expect(await goals.loadGoals(), hasLength(2));
          await back();
          await tap(find.byTooltip('今天'));
          final retained = (await goals.loadGoals()).singleWhere(
            (goal) => goal.titleOn(clock.day) == 'TEST 修改后保留',
          );
          await tap(find.byKey(ValueKey('complete-${retained.id}')));
          await waitFor(
            () async => find
                .byKey(ValueKey('undo-${retained.id}'))
                .evaluate()
                .isNotEmpty,
          );
          await tap(find.byTooltip('规划'));
          await tap(find.byKey(ValueKey('undo-proposal-${proposal.id}')));
          await waitFor(
            () async => find
                .byKey(const ValueKey('assistant-undo-confirm'))
                .evaluate()
                .isNotEmpty,
          );
          expect(find.textContaining('保留，已有打卡记录'), findsOneWidget);
          expect(find.textContaining('删除并取消提醒'), findsOneWidget);
          await tap(find.byKey(const ValueKey('assistant-undo-confirm')));
          await waitFor(
            () async =>
                (await store.proposals.read(proposal.id)).status == 'undone',
          );
          await back();
          expect(service.requests, hasLength(2));
        } else {
          expect(controller.sessions, hasLength(2));
          if (controller.session!.title != 'TEST 网络故障') {
            await tap(find.byTooltip('会话列表'));
            await tap(find.widgetWithText(ListTile, 'TEST 网络故障'));
          }
          expect(controller.messages, hasLength(3));
          expect(controller.messages.first.status, 'failed');
          expect(controller.proposals.single.status, 'undone');
          expect(find.text('已撤销 · 查看结果'), findsOneWidget);
          draft('');
          expect(service.requests, isEmpty);
        }
        final retained = (await goals.loadGoals()).single;
        expect(retained.titleOn(clock.day), 'TEST 修改后保留');
        expect(retained.scheduleOn(clock.day).durationMinutes, 45);
        expect(await db.select(db.checkIns).get(), hasLength(1));
        await tap(find.byTooltip('今天'));
        expect(find.byKey(ValueKey('undo-${retained.id}')), findsOneWidget);
        expect(find.text('TEST 未打卡'), findsNothing);
        expect(await db.select(db.syncOutbox).get(), isEmpty);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(Duration.zero);
        await db.close();
      }
    },
  );
}
