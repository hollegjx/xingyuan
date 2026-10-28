import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/app/app.dart';
import 'package:habit_checkin/app/providers.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/local/open_database.dart';
import 'package:habit_checkin/features/assistant/assistant_providers.dart';
import 'package:habit_checkin/features/assistant/data/local_conversation_store.dart';
import 'package:integration_test/integration_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import '../test/support/test_assistant_service.dart';
import '../test/support/test_clock.dart';
import '../test/support/test_reminder_notifications.dart';
import '../test/support/ui_harness.dart' show TestNotificationPermissions;

// Isolated simulator only. Synthetic transport/notifications; real SQLite/UI.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  const phase = String.fromEnvironment('ASSISTANT_CHAT_PHASE');
  const run = String.fromEnvironment('ASSISTANT_CHAT_RUN');
  testWidgets(
    'conversation, summary, plan and memory survive independent processes',
    (tester) async {
      expect(['write', 'undo', 'reopen'], contains(phase));
      expect(RegExp(r'^[A-Za-z0-9-]{8,60}$').hasMatch(run), isTrue);
      final db = openAppDatabase(name: 'habit_checkin_assistant_chat_$run');
      final clock = TestClock()..setDay(2026, 10, 20, hour: 21);
      final goals = LocalGoalRepository(db, clock);
      final store = LocalConversationStore(goals);
      final service = ConversationTestService()
        ..onTurn = (request) async => syntheticReply(
          request,
          plan: request.messages.last.text == 'TEST 规划并记忆',
          memory: request.messages.last.text == 'TEST 规划并记忆',
        );
      late ProviderContainer container;
      Future<void> tap(Finder finder) async {
        await tester.ensureVisible(finder);
        await tester.pumpAndSettle();
        await tester.tap(finder);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }

      Future<void> send(String text) async {
        final controller = await container.read(
          assistantConversationProvider.future,
        );
        final before = service.requests.length;
        final input = find.byKey(const ValueKey('assistant-input'));
        await tester.ensureVisible(input);
        await tester.pumpAndSettle();
        await tester.tap(input);
        await tester.pumpAndSettle();
        await tester.enterText(input, text);
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(input).controller!.text, text);
        expect(
          tester
              .widget<IconButton>(find.byKey(const ValueKey('assistant-send')))
              .onPressed,
          isNotNull,
          reason: 'Composer must be enabled before tapping',
        );
        await tap(find.byKey(const ValueKey('assistant-send')));
        final wait = Stopwatch()..start();
        while ((controller.busy || service.requests.length == before) &&
            controller.error == null &&
            wait.elapsed < const Duration(seconds: 20)) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(controller.error, isNull);
        expect(controller.busy, isFalse);
        expect(service.requests.length, before + 1);
        await tester.pumpAndSettle();
      }

      try {
        if (phase == 'write') {
          expect(await store.sessions(), isEmpty);
          expect(await goals.loadGoals(), isEmpty);
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
        container = ProviderScope.containerOf(
          tester.element(find.byType(HabitCheckinApp)),
        );
        await tap(find.byTooltip('规划'));
        if (phase == 'write') {
          expect(service.requests, isEmpty);
          await tap(find.byKey(const ValueKey('assistant-consent-confirm')));
          await send('TEST 规划并记忆');
          final proposal = (await store.sessionProposals(
            (await store.sessions()).single.id,
          )).single;
          await tap(find.byKey(ValueKey('open-proposal-${proposal.id}')));
          await tap(find.byKey(const ValueKey('assistant-apply-plan')));
          expect(
            (await goals.loadGoals()).single
                .scheduleOn(clock.day)
                .timing
                .startMinute,
            20 * 60,
          );
          await tap(find.byType(BackButton));
          for (var i = 0; i < 10; i++) {
            await send('TEST 后续聊天 $i');
          }
          expect(service.requests, hasLength(11));
          expect(service.summaries, hasLength(1));
          expect(await store.memories.list(), hasLength(1));
          expect((await store.sessions()).single.summary, 'TEST 历史约束摘要');
        } else {
          final session = (await store.sessions()).single;
          expect(await store.messages(session.id), hasLength(22));
          expect(session.summary, 'TEST 历史约束摘要');
          final proposal = (await store.sessionProposals(session.id)).single;
          if (phase == 'undo') {
            expect(proposal.status, 'applied');
            expect(await goals.loadGoals(), hasLength(1));
            final message = (await store.messages(session.id))
                .firstWhere((row) => row.role == 'assistant');
            final event = (await store.memories.events(message.id)).single;
            await tap(find.byKey(ValueKey('undo-memory-${event.id}')));
            await tap(find.byKey(ValueKey('undo-proposal-${proposal.id}')));
            await tap(find.byKey(const ValueKey('assistant-undo-confirm')));
            await tap(find.byType(BackButton));
          } else {
            expect(proposal.status, 'undone');
            expect(find.text('已撤销 · 查看结果'), findsOneWidget);
            expect(find.textContaining('已撤销记忆操作'), findsOneWidget);
          }
          expect(await goals.loadGoals(), isEmpty);
          expect(await store.memories.list(), isEmpty);
          expect(service.requests, isEmpty);
          expect(service.summaries, isEmpty);
        }
        expect(await db.select(db.syncOutbox).get(), isEmpty);
        expect(await db.select(db.reminderCancellations).get(), isEmpty);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(Duration.zero);
        await db.close();
      }
    },
  );
}
