import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/features/assistant/data/assistant_conversation_runner.dart';
import 'package:habit_checkin/features/assistant/data/local_conversation_store.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'support/scripted_agent_service.dart';
import 'support/test_clock.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);
  Future<void> exercise(
    WidgetTester tester, {
    required bool cancelled,
    void Function()? beforeBegin,
  }) async {
    final db = AppDatabase(NativeDatabase.memory());
    final store = LocalConversationStore(LocalGoalRepository(db, TestClock()));
    final service = ScriptedAgentService();
    final subscriptions = <StreamSubscription<Object?>>[];
    var settled = false;
    Object? failure;
    CommittedAssistantTurn? result;
    final response = Completer<Map<String, dynamic>>();
    final entered = Completer<void>();
    service.script.add((request) {
      entered.complete();
      if (cancelled) return response.future;
      return Future.value(agentResponse(request, text: 'TEST complete'));
    });
    try {
      final session = await store.createSession();
      await store.memories.consent();
      subscriptions.add(db.select(db.identityStates).watch().listen((_) {}));
      subscriptions.add(
        (db.select(db.assistantSettings)
              ..where((row) => row.owner.equals(store.owner)))
            .watch()
            .listen((_) {}),
      );
      beforeBegin?.call();
      final turn = await store.begin(session, 'TEST request');
      AssistantConversationRunner(store: store, service: service)
          .run(turn)
          .then(
            (value) {
              result = value;
              settled = true;
            },
            onError: (Object error) {
              failure = error;
              settled = true;
            },
          );
      await entered.future;
      if (cancelled) await store.cancel(turn);
      for (var i = 0; i < 20 && !settled; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(
        settled,
        isTrue,
        reason: 'Run must finish while database remains open',
      );
      expect(service.agentRequests, hasLength(1));
      if (cancelled) {
        expect(failure, isNotNull);
        expect(result, isNull);
      } else {
        expect(failure, isNull);
        expect(result!.message.content, 'TEST complete');
      }
      expect(await db.select(db.goals).get(), isEmpty);
      expect(await db.select(db.planProposals).get(), isEmpty);
    } finally {
      for (final subscription in subscriptions) {
        subscription.cancel().ignore();
      }
      final closing = db.close();
      await tester.pump(Duration.zero);
      await closing;
      if (!response.isCompleted && service.agentRequests.isNotEmpty) {
        response.complete(agentResponse(service.agentRequests.single));
      }
      await tester.pump(Duration.zero);
    }
  }

  for (final cancelled in [false, true]) {
    testWidgets(
      'Agent ends with shared live database listeners, cancel=$cancelled',
      (tester) => exercise(tester, cancelled: cancelled),
    );
  }
  testWidgets('cleanup must preserve the failure before a request exists', (
    tester,
  ) async {
    final original = StateError('synthetic pre-request failure');
    await expectLater(
      exercise(tester, cancelled: false, beforeBegin: () => throw original),
      throwsA(same(original)),
    );
  });
}
