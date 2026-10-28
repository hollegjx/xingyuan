import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/app/app.dart';
import 'package:habit_checkin/app/providers.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/local/open_database.dart';
import 'package:habit_checkin/features/assistant/assistant_providers.dart';
import 'package:habit_checkin/features/assistant/data/assistant_service.dart';
import 'package:habit_checkin/features/assistant/data/device_credential_store.dart';
import 'package:habit_checkin/features/assistant/data/local_conversation_store.dart';
import 'package:habit_checkin/features/assistant/domain/plan_preview.dart';
import 'package:integration_test/integration_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:xingyuan_core/xingyuan_core.dart';

import '../test/support/test_clock.dart';
import '../test/support/test_reminder_notifications.dart';
import '../test/support/ui_harness.dart' show TestNotificationPermissions;
import 'support/live_assistant_scenarios.dart';

class _ObservedTransport implements AssistantService {
  _ObservedTransport(this.live, this.offline);
  final HttpAssistantService live;
  final HttpAssistantService offline;
  final turns = <TurnRequest>[];
  final summaries = <SummaryRequest>[];
  final responses = <TurnResponse>[];
  bool interruptSummary = false;
  bool interruptTurn = false;

  @override
  bool get configured => live.configured;
  @override
  Future<void> health({required AssistantAccess access}) =>
      live.health(access: access);
  @override
  Future<TurnResponse> turn(
    TurnRequest request, {
    required AssistantAccess access,
    AssistantCancellation? cancellation,
  }) async {
    turns.add(request);
    final response = await (interruptTurn ? offline : live).turn(
      request,
      access: access,
      cancellation: cancellation,
    );
    responses.add(response);
    return response;
  }

  @override
  Future<SummaryResponse> summarize(
    SummaryRequest request, {
    required AssistantAccess access,
    AssistantCancellation? cancellation,
  }) {
    summaries.add(request);
    return (interruptSummary ? offline : live).summarize(
      request,
      access: access,
      cancellation: cancellation,
    );
  }
}

// Launched only by the simulator-only host runner; no secrets in dart-defines.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  const run = String.fromEnvironment('ASSISTANT_LIVE_RUN');
  const phase = String.fromEnvironment('ASSISTANT_LIVE_PHASE');
  const address = String.fromEnvironment('ASSISTANT_BASE_URL');
  const suite = String.fromEnvironment(
    'ASSISTANT_LIVE_SUITE',
    defaultValue: 'long',
  );
  testWidgets('real assistant summary, memory and receipt survive restart', (
    tester,
  ) async {
    expect(RegExp(r'^[A-Za-z0-9-]{8,60}$').hasMatch(run), isTrue);
    expect(['write', 'reopen', 'cleanup'], contains(phase));
    expect(['long', 'scenarios'], contains(suite));
    final credentials = DeviceCredentialStore(key: 'assistant-live-$run');
    final db = openAppDatabase(name: 'habit_checkin_assistant_live_$run');
    final clock = TestClock()..setDay(2026, 10, 20, hour: 21);
    final goals = LocalGoalRepository(db, clock);
    final store = LocalConversationStore(goals);
    final service = _ObservedTransport(
      HttpAssistantService(
        endpoint: Uri.parse(address),
        readCredential: credentials.read,
        allowInsecureLoopback: true,
      ),
      HttpAssistantService(
        endpoint: Uri.parse('http://127.0.0.1:1'),
        readCredential: credentials.read,
        allowInsecureLoopback: true,
        timeout: const Duration(seconds: 2),
      ),
    );
    late ProviderContainer container;
    var completed = false;
    void progress(String stage) =>
        debugPrint('ASSISTANT_LIVE stage=$stage turn=${service.turns.length}');
    Future<void> settle() => tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 10),
    );
    Future<void> tap(Finder finder) async {
      await tester.ensureVisible(finder);
      await settle();
      await tester.tap(finder);
      await settle();
      expect(tester.takeException(), isNull);
    }

    Future<void> send(
      String text, {
      bool summaryFailure = false,
      bool networkFailure = false,
      String? retryId,
    }) async {
      progress('send-start');
      final controller = await container.read(
        assistantConversationProvider.future,
      );
      final before = (await store.messages(controller.session!.id)).length;
      final requestsBefore = service.turns.length;
      if (retryId == null) {
        final input = find.byKey(const ValueKey('assistant-input'));
        await tap(input);
        progress('focused');
        await tester.enterText(input, text);
        await settle();
        expect(
          tester.widget<TextField>(input).controller!.text == text,
          isTrue,
        );
        final sendButton = find.byKey(const ValueKey('assistant-send'));
        expect(tester.widget<IconButton>(sendButton).onPressed, isNotNull);
        await tap(sendButton);
      } else {
        await tap(find.byKey(ValueKey('retry-$retryId')));
        await tap(find.byKey(const ValueKey('assistant-confirm-retry')));
      }
      progress('tapped-send');
      final wait = Stopwatch()..start();
      do {
        await tester.pump(const Duration(milliseconds: 50));
      } while ((controller.busy || controller.messages.length == before) &&
          wait.elapsed < const Duration(seconds: 100));
      expect(controller.busy, isFalse);
      progress('request-finished');
      if (summaryFailure) {
        expect(controller.error, contains('无法生成会话摘要'));
        expect(service.turns.length, requestsBefore);
        expect(
          (await store.messages(controller.session!.id)).length,
          before + 1,
        );
      } else if (networkFailure) {
        expect(controller.error, contains('未创建任何内容'));
        expect(service.turns.length, requestsBefore + 1);
        expect(
          (await store.messages(controller.session!.id)).length,
          before + 1,
        );
      } else {
        expect(controller.error, isNull);
        expect(service.turns.length, requestsBefore + 1);
        expect(
          (await store.messages(controller.session!.id)).length,
          before + 2,
        );
      }
      await settle();
      progress('send-finished');
      expect(tester.takeException(), isNull);
    }

    try {
      final databaseFiles = await db.customSelect('PRAGMA database_list').get();
      final databasePath = databaseFiles
          .singleWhere((row) => row.read<String>('name') == 'main')
          .read<String>('file');
      expect(databasePath.contains('/CoreSimulator/Devices/'), isTrue);
      expect(databasePath.contains('/Containers/Data/Application/'), isTrue);
      if (phase == 'cleanup') {
        await credentials.clear();
        expect(await credentials.read(), isNull);
        completed = true;
        return;
      }
      if (phase == 'write') {
        expect(await store.sessions(), isEmpty);
        expect(await credentials.read(), isNull);
        // iOS changes the container UUID on reinstall even with data preserved.
        final bootstrap = File(
          '${File(databasePath).parent.path}/assistant-live-$run.credential',
        );
        expect(await bootstrap.exists(), isTrue);
        final token = (await bootstrap.readAsString()).trim();
        await bootstrap.delete();
        await credentials.save(token);
        expect(await credentials.read() == token, isTrue);
      } else {
        final token = await credentials.read();
        expect(
          token != null && RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(token),
          isTrue,
        );
      }
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            clockProvider.overrideWithValue(clock),
            refreshClockProvider.overrideWithValue(() async {}),
            goalRepositoryProvider.overrideWith((ref) => goals),
            assistantServiceProvider.overrideWithValue(service),
            assistantCredentialProvider.overrideWithValue(credentials),
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
      final controller = await container.read(
        assistantConversationProvider.future,
      );
      if (suite == 'scenarios') {
        final scenarios = LiveAssistantScenarios(
          tester: tester,
          container: container,
          store: store,
          goals: goals,
          clock: clock,
          tap: tap,
          send: (text, {networkFailure = false, retryId}) =>
              send(text, networkFailure: networkFailure, retryId: retryId),
          turns: service.turns,
          responses: service.responses,
          interruptTurn: (value) => service.interruptTurn = value,
        );
        if (phase == 'write') {
          expect(service.turns, isEmpty);
          await tap(find.byKey(const ValueKey('assistant-consent-confirm')));
          await scenarios.write();
        } else {
          await scenarios.reopen();
          expect(service.turns, isEmpty);
          expect(service.summaries, isEmpty);
          await credentials.clear();
          expect(await credentials.read(), isNull);
        }
      } else if (phase == 'write') {
        expect(service.turns, isEmpty);
        await tap(find.byKey(const ValueKey('assistant-consent-confirm')));
        await controller.create();
        await controller.rename(controller.session!.id, 'LIVE 长会话');
        await tester.pumpAndSettle();
        await send('记住我不喜欢早起。明天晚上21:00读书30分钟，只安排这一项，不开提醒。');
        final proposal = (await store.sessionProposals(controller.session!.id))
            .single;
        final item = PlanPreview.decode(proposal.itemsJson).items.single;
        expect(item.task.date.toString(), '2026-10-21');
        expect(item.task.time, '21:00');
        expect(item.task.minutes, 30);
        expect(item.reminder, isFalse);
        expect(await goals.loadGoals(), isEmpty);
        expect(
          (await store.memories.list()).any(
            (row) => row.content.contains('早起'),
          ),
          isTrue,
        );
        await tap(find.byKey(ValueKey('open-proposal-${proposal.id}')));
        await tap(find.byKey(const ValueKey('assistant-apply-plan')));
        expect(await goals.loadGoals(), hasLength(1));
        await tap(find.byType(BackButton));
        for (var i = 0; i < 10; i++) {
          await send('谢谢，这是第${i + 1}次闲聊，先不增加或修改任何计划，也不记录新记忆。');
        }
        final session = await store.session(controller.session!.id);
        expect(service.turns, hasLength(11));
        expect(service.summaries, hasLength(1));
        expect(session.summary, isNotEmpty);
        expect(session.summary!.characters.length, lessThanOrEqualTo(1500));
        expect(service.turns.last.summary == session.summary, isTrue);
        expect(await store.messages(session.id), hasLength(22));
        expect(await store.sessionProposals(session.id), hasLength(1));
        service.interruptSummary = true;
        await send('继续闲聊，不增加计划。', summaryFailure: true);
        expect(service.turns, hasLength(11));
        expect(service.summaries, hasLength(2));
        expect(
          (await store.session(session.id)).summary == session.summary,
          isTrue,
        );
        final messages = await store.messages(session.id);
        expect(messages, hasLength(23));
        expect(messages.last.status, 'failed');
        expect(messages.take(22).every((row) => row.status == 'sent'), isTrue);
      } else {
        final session = (await store.sessions()).single;
        expect(session.title, 'LIVE 长会话');
        expect(session.summary, isNotEmpty);
        expect(session.summaryThrough, isNotNull);
        expect(await store.messages(session.id), hasLength(23));
        expect((await store.messages(session.id)).last.status, 'failed');
        expect(
          (await store.sessionProposals(session.id)).single.status,
          'applied',
        );
        final goal = (await goals.loadGoals()).single;
        expect(goal.scheduleOn(clock.day).timing.startMinute, 21 * 60);
        expect(goal.scheduleOn(clock.day).timing.durationMinutes, 30);
        expect(
          (await store.memories.list()).any(
            (row) => row.content.contains('早起'),
          ),
          isTrue,
        );
        expect(service.turns, isEmpty);
        expect(service.summaries, isEmpty);
        await credentials.clear();
        expect(await credentials.read(), isNull);
      }
      expect(await db.select(db.syncOutbox).get(), isEmpty);
      expect(await db.select(db.reminderOccurrences).get(), isEmpty);
      completed = true;
    } finally {
      if (!completed) await credentials.clear();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(Duration.zero);
      await db.close();
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
