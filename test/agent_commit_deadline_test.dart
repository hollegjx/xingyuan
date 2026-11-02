import 'dart:async';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/sync/identity_store.dart';
import 'package:habit_checkin/features/assistant/data/agent_conversation_runner.dart';
import 'package:habit_checkin/features/assistant/data/assistant_service.dart';
import 'package:habit_checkin/features/assistant/data/local_conversation_store.dart';
import 'package:habit_checkin/features/assistant/domain/agent_run_metadata.dart';
import 'package:habit_checkin/features/assistant/domain/plan_preview.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'support/scripted_agent_service.dart';
import 'support/test_clock.dart';

class _Gate {
  final entered = Completer<void>();
  final release = Completer<void>();
  Future<void> wait() async {
    if (entered.isCompleted) return;
    entered.complete();
    await release.future;
  }
}

class _CommitStore extends LocalConversationStore {
  _CommitStore(super.goals, this.gate);
  final _Gate? gate;
  _Gate? inputGate;
  bool commitEntered = false;
  final finished = Completer<void>();
  final inputFinished = Completer<void>();

  @override
  Future<String> agentInput(
    PendingAssistantTurn turn, {
    bool recordsSupported = false,
  }) async {
    try {
      await inputGate?.wait();
      return await super.agentInput(turn, recordsSupported: recordsSupported);
    } finally {
      if (!inputFinished.isCompleted) inputFinished.complete();
    }
  }

  @override
  Future<CommittedAssistantTurn> commitAgentResponse(
    PendingAssistantTurn turn, {
    required String text,
    required AgentRunMetadata metadata,
    PlanPreview? preview,
    Map<String, dynamic>? diaryDraft,
    String? memorySummary,
  }) async {
    commitEntered = true;
    try {
      await gate?.wait();
      return await super.commitAgentResponse(
        turn,
        text: text,
        metadata: metadata,
        preview: preview,
        diaryDraft: diaryDraft,
        memorySummary: memorySummary,
      );
    } finally {
      finished.complete();
    }
  }
}

class _FinalIdentityGoals extends LocalGoalRepository {
  _FinalIdentityGoals(super.db, super.clock, {required super.identityLease});
  _Gate? gate;

  @override
  Future<void> requireActiveIdentity() async {
    final currentGate = gate;
    if (currentGate != null && !currentGate.entered.isCompleted) {
      final sent =
          await (db.select(db.assistantMessages)..where(
                (row) => row.role.equals('user') & row.status.equals('sent'),
              ))
              .get();
      if (sent.isNotEmpty) await currentGate.wait();
    }
    await super.requireActiveIdentity();
  }
}

Future<void> _waitForCommitGate(_Gate gate, Future<Object> result) async {
  await Future.any<void>([
    gate.entered.future,
    result.then<void>((outcome) {
      final reason = outcome is AssistantFailure
          ? outcome.kind.name
          : outcome.runtimeType;
      throw TestFailure('Runner ended before commit gate: $reason');
    }),
  ]).timeout(
    const Duration(seconds: 3),
    onTimeout: () {
      throw TestFailure('Neither runner nor commit gate completed');
    },
  );
}

void main() {
  setUpAll(tzdata.initializeTimeZones);
  test('pre-commit expiry cannot hang the commit gate fixture', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final clock = TestClock()..setDay(2026, 10, 28);
    final commitGate = _Gate();
    final inputGate = _Gate();
    final store = _CommitStore(
      LocalGoalRepository(
        db,
        clock,
        identityLease: await IdentityStore(db).active(),
      ),
      commitGate,
    )..inputGate = inputGate;
    final session = await store.createSession();
    await store.memories.consent();
    final turn = await store.begin(session, 'TEST pre-commit expiry');
    final service = ScriptedAgentService();
    final result = AgentConversationRunner(
      store: store,
      service: service,
      limit: const Duration(seconds: 1),
    ).run(turn).then<Object>((value) => value, onError: (Object e) => e);
    try {
      await expectLater(
        _waitForCommitGate(
          commitGate,
          result,
        ).timeout(const Duration(seconds: 3)),
        throwsA(
          isA<TestFailure>().having(
            (error) => error.message,
            'phase and outcome',
            contains('before commit gate: timeout'),
          ),
        ),
      );
      final outcome = await result;
      expect(outcome, isA<AssistantFailure>());
      expect((outcome as AssistantFailure).kind, AssistantFailureKind.timeout);
      expect(commitGate.entered.isCompleted, isFalse);
      expect(store.commitEntered, isFalse);
      expect(store.finished.isCompleted, isFalse);
      expect(await db.select(db.planProposals).get(), isEmpty);
      expect(await db.select(db.goals).get(), isEmpty);
      expect(
        (await db.select(db.assistantMessages).get()).single.status,
        'pending',
      );
      expect(service.agentRequests, isEmpty);
    } finally {
      inputGate.release.complete();
      if (!commitGate.release.isCompleted) commitGate.release.complete();
      await result;
      // Drain the previously blocked input before closing the synthetic DB.
      await store.inputFinished.future.timeout(const Duration(seconds: 2));
    }
  });
  for (final boundary in ['immediate', 'entry', 'final_identity', 'cancel']) {
    test('A1-138 $boundary commit obeys deadline and atomicity', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final clock = TestClock()..setDay(2026, 10, 28);
      final goals = _FinalIdentityGoals(
        db,
        clock,
        identityLease: await IdentityStore(db).active(),
      );
      final gate = _Gate();
      final store = _CommitStore(
        goals,
        boundary == 'entry' || boundary == 'cancel' ? gate : null,
      );
      final session = await store.createSession();
      await store.memories.consent();
      final service = ScriptedAgentService();
      service.script.add(
        (request) async => agentResponse(
          request,
          tool: 'submit_plan_draft',
          arguments: {
            'items': [
              {
                'title': 'TEST deadline draft',
                'date': clock.day.key,
                'start_minute': 600,
                'minutes': 30,
              },
            ],
            'note': '',
          },
        ),
      );
      final turn = await store.begin(session, 'TEST planning');
      if (boundary == 'final_identity') goals.gate = gate;
      final result = AgentConversationRunner(
        store: store,
        service: service,
        limit: const Duration(seconds: 1),
      ).run(turn).then<Object>((value) => value, onError: (Object e) => e);
      addTearDown(() async {
        if (!gate.release.isCompleted) gate.release.complete();
        await result.timeout(const Duration(seconds: 2));
        if (store.commitEntered) {
          await store.finished.future.timeout(const Duration(seconds: 2));
        }
      });
      if (boundary != 'immediate') {
        await _waitForCommitGate(gate, result);
        if (boundary == 'cancel') {
          turn.cancellation.cancel();
        } else {
          await Future<void>.delayed(const Duration(milliseconds: 1100));
        }
        gate.release.complete();
      }
      final outcome = await result;
      await store.finished.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () => throw TestFailure(
          'Commit did not finish after runner ended (entered=${store.commitEntered})',
        ),
      );
      final drafts = await db.select(db.planProposals).get();
      final messages = await db.select(db.assistantMessages).get();
      if (boundary == 'immediate') {
        expect(outcome, isA<CommittedAssistantTurn>());
        expect(drafts, hasLength(1));
        expect(messages, hasLength(2));
      } else {
        expect(drafts, isEmpty);
        expect(messages, hasLength(1));
        expect(messages.single.status, 'pending');
        expect(outcome, isA<AssistantFailure>());
        expect(
          (outcome as AssistantFailure).kind,
          boundary == 'cancel'
              ? AssistantFailureKind.cancelled
              : AssistantFailureKind.timeout,
        );
      }
      expect(await db.select(db.goals).get(), isEmpty);
      expect(service.agentRequests, hasLength(1));
      expect(service.summaries, isEmpty);
    });
  }
}
