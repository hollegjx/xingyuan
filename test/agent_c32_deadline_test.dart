import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/features/assistant/data/agent_conversation_runner.dart';
import 'package:habit_checkin/features/assistant/data/assistant_conversation_runner.dart';
import 'package:habit_checkin/features/assistant/data/assistant_service.dart';
import 'package:habit_checkin/features/assistant/data/local_conversation_store.dart';
import 'package:habit_checkin/features/assistant/presentation/assistant_conversation_controller.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:xingyuan_core/xingyuan_core.dart';

import 'support/scripted_agent_service.dart';
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

class _StalledStore extends LocalConversationStore {
  _StalledStore(super.goals);
  final gate = _Gate();
  String? stall;
  bool responseReturned = false;
  bool failed = false;
  bool failThrows = false;
  final failFinished = Completer<void>();

  @override
  Future<bool> isCurrent(PendingAssistantTurn turn) async {
    if (stall == 'initial' || (stall == 'post_send' && responseReturned)) {
      await gate.wait();
    }
    return super.isCurrent(turn);
  }

  @override
  Future<String> agentInput(
    PendingAssistantTurn turn, {
    bool recordsSupported = false,
  }) async {
    if (stall == 'input') await gate.wait();
    return super.agentInput(turn, recordsSupported: recordsSupported);
  }

  @override
  Future<void> recordAgentRequest(
    PendingAssistantTurn turn,
    AgentRequest request,
  ) async {
    if (stall == 'record') await gate.wait();
    return super.recordAgentRequest(turn, request);
  }

  @override
  Future<void> fail(PendingAssistantTurn turn, {bool discarded = false}) async {
    failed = true;
    try {
      if (stall == 'fail') await gate.wait();
      if (failThrows) throw StateError('TEST cleanup failure');
      await super.fail(turn, discarded: discarded);
    } finally {
      if (!failFinished.isCompleted) failFinished.complete();
    }
  }

  @override
  Future<List<StoredAssistantSession>> sessions() async {
    if (stall == 'refresh' && failed) await gate.wait();
    return super.sessions();
  }
}

void main() {
  setUpAll(tzdata.initializeTimeZones);
  late AppDatabase db;
  late _StalledStore store;
  late ScriptedAgentService service;
  late String session;
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    store = _StalledStore(
      LocalGoalRepository(db, TestClock()..setDay(2026, 10, 29)),
    );
    service = ScriptedAgentService();
    session = await store.createSession();
    await store.memories.consent();
  });
  tearDown(() async {
    store.gate.close();
    await db.close();
  });

  for (final boundary in ['initial', 'input', 'record', 'post_send']) {
    test('C32 $boundary read cannot outlive the Agent deadline', () async {
      final turn = await store.begin(session, 'TEST bounded request');
      store.stall = boundary;
      service.script.add((request) async {
        store.responseReturned = true;
        return agentResponse(request);
      });
      final stages = <AssistantRunStage>[];
      final result =
          AgentConversationRunner(
                store: store,
                service: service,
                limit: const Duration(milliseconds: 200),
              )
              .run(turn, onStage: stages.add)
              .then<Object>((value) => value, onError: (Object error) => error);
      try {
        await store.gate.entered.future.timeout(const Duration(seconds: 2));
        final outcome = await result.timeout(
          const Duration(seconds: 1),
          onTimeout: () => 'TEST still waiting',
        );
        expect(
          outcome,
          isA<AssistantFailure>().having(
            (error) => error.kind,
            'kind',
            AssistantFailureKind.timeout,
          ),
        );
        expect(turn.cancellation.isCancelled, isTrue);
        if (boundary == 'post_send') {
          expect(stages.last, AssistantRunStage.sending);
        }
      } finally {
        store.gate.close();
        await result;
      }
      expect(service.agentRequests, hasLength(boundary == 'post_send' ? 1 : 0));
      expect(await db.select(db.planProposals).get(), isEmpty);
      expect(await db.select(db.goals).get(), isEmpty);
      expect(await store.messages(session), hasLength(1));
    });
  }

  for (final boundary in ['fail', 'fail_error']) {
    test('C32 $boundary preserves original failure and settles', () async {
      final turn = await store.begin(session, 'TEST failure cleanup');
      store.stall = boundary;
      store.failThrows = boundary == 'fail_error';
      service.script.add(
        (_) async => throw const AssistantFailure(AssistantFailureKind.network),
      );
      Object? outcome;
      final result = AssistantConversationRunner(store: store, service: service)
          .run(turn)
          .then<void>(
            (_) => outcome = 'unexpected success',
            onError: (Object error) => outcome = error,
          );
      for (var i = 0; i < 30 && !store.failed; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(store.failed, isTrue);
      try {
        await result.timeout(const Duration(seconds: 6), onTimeout: () {});
        expect(
          outcome,
          isA<AssistantFailure>().having(
            (error) => error.kind,
            'kind',
            AssistantFailureKind.network,
          ),
        );
      } finally {
        store.gate.close();
        await result;
      }
      expect(service.agentRequests, hasLength(1));
      expect(await db.select(db.planProposals).get(), isEmpty);
    });
  }

  for (final boundary in ['fail', 'refresh']) {
    test('C32 controller publishes failure before stalled $boundary', () async {
      final controller = AssistantConversationController(
        store: store,
        service: service,
      );
      await controller.initialize();
      store.stall = boundary;
      service.script.add(
        (_) async => throw const AssistantFailure(AssistantFailureKind.timeout),
      );
      bool? notifiedBusy;
      String? notifiedError;
      controller.addListener(() {
        notifiedBusy = controller.busy;
        notifiedError = controller.error;
      });
      var settled = false;
      final result = controller
          .send('TEST waiting')
          .then((_) => settled = true);
      for (var i = 0; i < 30 && !store.failed; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      try {
        expect(store.failed, isTrue);
        await result.timeout(
          const Duration(seconds: 12),
          onTimeout: () => false,
        );
        expect(notifiedBusy, isFalse);
        expect(
          notifiedError,
          const AssistantFailure(AssistantFailureKind.timeout).message,
        );
        expect(controller.stage, isNull);
        expect(settled, isTrue);
      } finally {
        store.gate.close();
        await result;
        controller.dispose();
      }
      expect(service.agentRequests, hasLength(1));
      expect(await db.select(db.goals).get(), isEmpty);
      expect(await db.select(db.planProposals).get(), isEmpty);
    });
  }
}
