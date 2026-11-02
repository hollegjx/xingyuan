import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/sync/identity_store.dart';
import 'package:habit_checkin/features/assistant/data/assistant_conversation_runner.dart';
import 'package:habit_checkin/features/assistant/data/local_conversation_store.dart';
import 'package:habit_checkin/features/assistant/presentation/assistant_conversation_controller.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'support/scripted_agent_service.dart';
import 'support/sync_fixtures.dart';
import 'support/test_clock.dart';

class _Gate {
  final entered = Completer<void>();
  final release = Completer<void>();

  Future<void> wait() async {
    if (!entered.isCompleted) entered.complete();
    await release.future;
  }

  void close() {
    if (!release.isCompleted) release.complete();
  }
}

class _CancelStore extends LocalConversationStore {
  _CancelStore(super.goals);

  final cleanup = _Gate();
  final refreshGate = _Gate();
  final beginGate = _Gate();
  bool holdFirstFailure = false;
  bool failCleanup = false;
  bool holdNextRefresh = false;
  bool failRefresh = false;
  bool holdNextBegin = false;
  int failures = 0;
  int sessionReads = 0;

  @override
  Future<void> fail(PendingAssistantTurn turn, {bool discarded = false}) async {
    if (++failures == 1 && holdFirstFailure) {
      await cleanup.wait();
      if (failCleanup) throw StateError('TEST old cancellation cleanup');
    }
    await super.fail(turn, discarded: discarded);
  }

  @override
  Future<List<StoredAssistantSession>> sessions() async {
    sessionReads++;
    final result = await super.sessions();
    if (holdNextRefresh) {
      holdNextRefresh = false;
      await refreshGate.wait();
      if (failRefresh) throw StateError('TEST cancellation refresh');
    }
    return result;
  }

  @override
  Future<PendingAssistantTurn> begin(
    String sessionId,
    String text, {
    String? retryMessageId,
  }) async {
    if (holdNextBegin) {
      holdNextBegin = false;
      await beginGate.wait();
    }
    return super.begin(sessionId, text, retryMessageId: retryMessageId);
  }
}

void main() {
  setUpAll(tzdata.initializeTimeZones);
  late AppDatabase db;
  late _CancelStore store;
  late ScriptedAgentService service;
  late AssistantConversationController controller;
  var disposed = false;
  final models = <_Gate>[];
  final pending = <Future<void>>[];

  Future<void> track(Future<void> operation) {
    pending.add(operation);
    return operation;
  }

  _Gate model(String text) {
    final gate = _Gate();
    models.add(gate);
    service.script.add((request) async {
      await gate.wait();
      return agentResponse(request, text: text);
    });
    return gate;
  }

  Future<void> entered(_Gate gate) =>
      gate.entered.future.timeout(const Duration(seconds: 2));

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    store = _CancelStore(
      LocalGoalRepository(db, TestClock()..setDay(2026, 10, 29)),
    );
    await store.createSession();
    await store.memories.consent();
    service = ScriptedAgentService();
    controller = AssistantConversationController(
      store: store,
      service: service,
    );
    await controller.initialize();
    disposed = false;
  });

  tearDown(() async {
    if (!disposed) controller.dispose();
    store.cleanup.close();
    store.refreshGate.close();
    store.beginGate.close();
    for (final gate in models) {
      gate.close();
    }
    await Future.wait(pending).timeout(const Duration(seconds: 3));
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(await db.select(db.goals).get(), isEmpty);
    expect(await db.select(db.planProposals).get(), isEmpty);
    models.clear();
    pending.clear();
    await db.close();
  });

  for (final cleanupFails in [true, false]) {
    test(
      'C32 old cancel cleanup failure=$cleanupFails cannot update a new send',
      () async {
        store.holdFirstFailure = true;
        store.failCleanup = cleanupFails;
        final old = model('TEST old response');
        final first = track(controller.send('TEST old'));
        await entered(old);
        final cancelling = track(controller.cancel());
        await entered(store.cleanup);
        await first;
        final fresh = model('TEST fresh response');
        final second = track(controller.send('TEST fresh'));
        await entered(fresh);
        final reads = store.sessionReads;
        var notifications = 0;
        controller.addListener(() => notifications++);
        store.cleanup.close();
        await cancelling;
        expect(controller.error, isNull);
        expect(controller.busy, isTrue);
        expect(controller.stage, AssistantRunStage.sending);
        expect(store.sessionReads, reads);
        expect(notifications, 0);
        expect(service.agentRequests, hasLength(2));
        expect(
          service.agentRequests.first.requestId,
          isNot(service.agentRequests.last.requestId),
        );
        fresh.close();
        await second;
        old.close();
        expect(controller.messages.last.content, 'TEST fresh response');
        expect(
          controller.messages.where((row) => row.role == 'assistant'),
          hasLength(1),
        );
      },
    );
  }

  for (final target in ['identity', 'disposed', 'current']) {
    test('C32 cancel cleanup error respects $target state', () async {
      store.holdFirstFailure = true;
      store.failCleanup = true;
      final old = model('TEST old response');
      final first = track(controller.send('TEST old'));
      await entered(old);
      final cancelling = track(controller.cancel());
      await entered(store.cleanup);
      await first;
      if (target == 'identity') {
        final changed = Completer<void>();
        controller.addListener(() {
          if (controller.identityChanged && !changed.isCompleted) {
            changed.complete();
          }
        });
        final identities = IdentityStore(db);
        await identities.finish(await identities.begin(accountA));
        await changed.future.timeout(const Duration(seconds: 2));
      } else if (target == 'disposed') {
        controller.dispose();
        disposed = true;
      }
      final before = controller.error;
      store.cleanup.close();
      await cancelling;
      expect(controller.busy, isFalse);
      expect(
        controller.error,
        target == 'current'
            ? assistantErrorMessage(StateError('TEST cleanup'))
            : before,
      );
      if (target == 'identity') {
        expect(controller.identityChanged, isTrue);
        expect(controller.messages, isEmpty);
        expect(controller.sessions, isEmpty);
      }
      expect(service.agentRequests, hasLength(1));
    });
  }

  for (final refreshFails in [false, true]) {
    test(
      'C32 old cancel refresh failure=$refreshFails cannot publish after new preflight',
      () async {
        final old = model('TEST old response');
        final first = track(controller.send('TEST old'));
        await entered(old);
        store.holdNextRefresh = true;
        store.failRefresh = refreshFails;
        final cancelling = track(controller.cancel());
        await entered(store.refreshGate);
        store.holdNextBegin = true;
        final fresh = model('TEST fresh response');
        final second = track(controller.send('TEST fresh'));
        await entered(store.beginGate);
        final messages = controller.messages;
        var notifications = 0;
        controller.addListener(() => notifications++);
        store.refreshGate.close();
        await cancelling;
        await first;
        expect(controller.error, isNull);
        expect(controller.busy, isTrue);
        expect(identical(controller.messages, messages), isTrue);
        expect(notifications, 0);
        expect(service.agentRequests, hasLength(1));
        store.beginGate.close();
        await entered(fresh);
        fresh.close();
        await second;
        expect(controller.messages.last.content, 'TEST fresh response');
      },
    );
  }

  test('C32 current cancel refresh failure remains visible', () async {
    final old = model('TEST old response');
    final first = track(controller.send('TEST old'));
    await entered(old);
    store.holdNextRefresh = true;
    store.failRefresh = true;
    final cancelling = track(controller.cancel());
    await entered(store.refreshGate);
    store.refreshGate.close();
    await cancelling;
    await first;
    expect(controller.busy, isFalse);
    expect(controller.error, assistantErrorMessage(StateError('TEST refresh')));
    expect(service.agentRequests, hasLength(1));
  });
}
