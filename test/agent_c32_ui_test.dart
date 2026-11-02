import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/features/assistant/assistant_providers.dart';
import 'package:habit_checkin/features/assistant/data/assistant_service.dart';
import 'package:habit_checkin/features/assistant/data/local_conversation_store.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'assistant_conversation_ui_test.dart' show openPlanning, sendText;
import 'support/scripted_agent_service.dart';
import 'support/test_assistant_service.dart';
import 'support/ui_harness.dart';

class _UiStore extends LocalConversationStore {
  _UiStore(super.goals, this.boundary);
  final String boundary;
  final release = Completer<void>();
  bool failed = false;
  bool cleanupThrows = false;
  bool began = false;

  @override
  Future<PendingAssistantTurn> begin(
    String sessionId,
    String text, {
    String? retryMessageId,
  }) async {
    final turn = await super.begin(
      sessionId,
      text,
      retryMessageId: retryMessageId,
    );
    began = true;
    if (boundary == 'begin') await release.future;
    return turn;
  }

  @override
  Future<void> fail(PendingAssistantTurn turn, {bool discarded = false}) async {
    failed = true;
    if (cleanupThrows) throw StateError('TEST failed persistence');
    if (boundary == 'cleanup') await release.future;
    await super.fail(turn, discarded: discarded);
  }

  @override
  Future<List<StoredAssistantSession>> sessions() async {
    if ((boundary == 'refresh' && failed) ||
        (boundary == 'preflight' && began)) {
      await release.future;
    }
    return super.sessions();
  }
}

void main() {
  setUpAll(tzdata.initializeTimeZones);
  for (final boundary in ['model', 'cleanup', 'cleanup_error', 'refresh']) {
    testUiWidgets(
      'C32 $boundary timeout exposes existing error and explicit retry',
      (tester) async {
        final app = UiHarness();
        final store = _UiStore(app.repository, boundary);
        store.cleanupThrows = boundary == 'cleanup_error';
        await store.memories.consent();
        final service = ScriptedAgentService();
        final releaseModel = Completer<void>();
        service.script.add((request) async {
          if (boundary == 'model') {
            await releaseModel.future;
            return agentResponse(request, text: 'TEST late response');
          }
          throw const AssistantFailure(AssistantFailureKind.timeout);
        });
        await app.mount(
          tester,
          assistantStore: store,
          assistantService: service,
          assistantCredentials: ConversationTestCredentials(),
        );
        await openPlanning(tester);
        await sendText(tester, 'TEST timeout', waiting: true);
        final controller = await app.container.read(
          assistantConversationProvider.future,
        );
        try {
          expect(service.agentRequests, hasLength(1));
          if (boundary == 'model' || boundary == 'cleanup') {
            expect(controller.busy, isTrue);
          }
          await tester.pump(const Duration(seconds: 60));
          await tester.pump(const Duration(seconds: 6));
          await tester.pump();
          expect(controller.busy, isFalse);
          expect(controller.stage, isNull);
          expect(
            find.text(
              const AssistantFailure(AssistantFailureKind.timeout).message,
            ),
            findsWidgets,
          );
          final original = controller.messages.single;
          final retry = find.byKey(ValueKey('retry-${original.id}'));
          expect(retry, findsOneWidget);
          expect(tester.widget<ButtonStyleButton>(retry).onPressed, isNotNull);
          expect(service.agentRequests, hasLength(1));
          store.cleanupThrows = false;
          store.release.complete();
          releaseModel.complete();
          await pumpWaiting(tester);
          await controller.refresh();
          await tester.pump();
          expect(find.text('TEST late response'), findsNothing);
          expect(
            await app.database.select(app.database.planProposals).get(),
            isEmpty,
          );
          expect(await app.repository.loadGoals(), isEmpty);
          service.script.add(
            (request) async => agentResponse(request, text: 'TEST retried'),
          );
          await tapVisible(tester, retry);
          expect(service.agentRequests, hasLength(1));
          await tapVisible(
            tester,
            find.byKey(const ValueKey('assistant-confirm-retry')),
          );
          expect(service.agentRequests, hasLength(2));
          expect(
            service.agentRequests[1].requestId,
            isNot(service.agentRequests[0].requestId),
          );
          expect(find.text('TEST retried'), findsOneWidget);
          expect(await app.repository.loadGoals(), isEmpty);
        } finally {
          if (!store.release.isCompleted) store.release.complete();
          if (!releaseModel.isCompleted) releaseModel.complete();
          await tester.pumpAndSettle();
        }
      },
    );
  }

  for (final boundary in ['begin', 'preflight']) {
    testUiWidgets(
      'C32 $boundary is bounded by the default 90-second UI limit',
      (tester) async {
        final app = UiHarness();
        final store = _UiStore(app.repository, boundary);
        final service = ScriptedAgentService();
        await store.memories.consent();
        await app.mount(
          tester,
          assistantStore: store,
          assistantService: service,
          assistantCredentials: ConversationTestCredentials(),
        );
        await openPlanning(tester);
        final controller = await app.container.read(
          assistantConversationProvider.future,
        );
        var settled = false;
        final sending = controller
            .send('TEST preflight')
            .then((_) => settled = true);
        try {
          for (var i = 0; i < 30 && !store.began; i++) {
            await tester.pump(const Duration(milliseconds: 10));
          }
          expect(store.began, isTrue);
          await tester.pump(const Duration(seconds: 90));
          expect(controller.busy, isFalse);
          expect(
            controller.error,
            const AssistantFailure(AssistantFailureKind.timeout).message,
          );
          await tester.pump(const Duration(seconds: 6));
          expect(settled, isTrue);
          expect(service.agentRequests, isEmpty);
        } finally {
          store.release.complete();
          await tester.pump();
          await sending;
          await pumpWaiting(tester);
        }
        expect(service.agentRequests, isEmpty);
      },
    );
  }
}
