import 'dart:convert';
import 'dart:io';

import 'package:characters/characters.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/sync/identity_store.dart';
import 'package:habit_checkin/data/sync/sync_identity.dart';
import 'package:habit_checkin/features/assistant/data/assistant_service.dart';
import 'package:habit_checkin/features/assistant/data/local_conversation_store.dart';
import 'package:habit_checkin/features/assistant/domain/plan_preview.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:xingyuan_core/xingyuan_core.dart';

import 'support/assistant_fixtures.dart';
import 'support/sync_fixtures.dart';
import 'support/test_clock.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);
  late AppDatabase db;
  late TestClock clock;
  late LocalGoalRepository goals;
  late LocalConversationStore store;
  late String sessionId;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    clock = TestClock();
    goals = LocalGoalRepository(db, clock);
    store = LocalConversationStore(goals);
    await store.memories.consent();
    sessionId = await store.createSession();
  });
  tearDown(() => db.close());

  Future<TurnRequest> request(PendingAssistantTurn turn) async {
    final input = await store.input(turn);
    final now = clock.read();
    final memories = await store.memories.forRequest();
    return TurnRequest.fromJson({
      'protocol': assistantProtocol,
      'request_id': turn.requestId,
      'now': {
        'date': now.day.key,
        'time': formatMinute(now.localTime.hour * 60 + now.localTime.minute),
        'weekday': now.day.weekday,
        'time_zone': now.zone,
      },
      'summary': input.summary,
      'messages': input.messages,
      if (memories != null)
        'memories': memories.map((row) => row.toJson()).toList(),
      'settings': {'auto_memory': turn.settings.autoMemory},
    });
  }

  TurnResponse response(
    TurnRequest request, {
    String text = 'TEST 好的',
    bool plan = false,
    bool memory = false,
  }) => TurnResponse.fromJson({
    'protocol': assistantProtocol,
    'request_id': request.requestId,
    'reply': text,
    'plan': plan
        ? syntheticPreview(day: request.now.date.key)
              .validateForConfirmation(request.now.date)
              .toJson()
        : null,
    'memory_ops': [
      if (memory)
        {
          'op': 'add',
          'id': null,
          'category': '偏好',
          'text': 'TEST 晚上阅读',
          'expires_on': null,
        },
    ],
  }, request: request);

  Future<(PendingAssistantTurn, TurnRequest)> prepare([
    String text = 'TEST 今天想读书',
  ]) async {
    final turn = await store.begin(sessionId, text);
    final payload = await request(turn);
    await store.recordRequest(turn, payload);
    return (turn, payload);
  }

  Future<void> exchange({
    String text = 'TEST user',
    String reply = 'TEST assistant',
  }) async {
    final (turn, payload) = await prepare(text);
    await store.commitResponse(turn, response(payload, text: reply));
  }

  SummaryResponse summary(PendingAssistantSummary work) =>
      SummaryResponse.fromJson({
        'protocol': assistantProtocol,
        'request_id': work.request.requestId,
        'summary': 'TEST 已汇总之前的规划约束',
      }, requestId: work.request.requestId);

  test('consent is required before saving a pending message', () async {
    await db.delete(db.assistantSettings).go();
    await expectLater(
      store.begin(sessionId, 'TEST'),
      throwsA(isA<AssistantFailure>()),
    );
    expect(await store.messages(sessionId), isEmpty);
  });

  test(
    'session title and message limits count graphemes, not code units',
    () async {
      const glyph = '👩🏽‍💻';
      await store.renameSession(sessionId, glyph * 60);
      expect((await store.session(sessionId)).title.characters.length, 60);
      await expectLater(
        store.renameSession(sessionId, glyph * 61),
        throwsA(isA<GoalRuleException>()),
      );
      await expectLater(
        store.begin(sessionId, glyph * 2001),
        throwsA(isA<GoalRuleException>()),
      );
      final turn = await store.begin(sessionId, glyph * 2000);
      expect(
        (await store.messages(sessionId)).single.content.characters.length,
        2000,
      );
      await store.cancel(turn);
      expect((await store.session(sessionId)).title, glyph * 60);
    },
  );

  test(
    'begin saves pending and a stable title, but no generated content',
    () async {
      final (turn, payload) = await prepare();
      final rows = await store.messages(sessionId);
      expect(rows.single.id, turn.messageId);
      expect(rows.single.status, 'pending');
      expect(jsonDecode(rows.single.sentPayload!), payload.toJson());
      expect((await store.session(sessionId)).title, 'TEST 今天想读书');
      expect(await db.select(db.goals).get(), isEmpty);
      expect(await db.select(db.assistantMemories).get(), isEmpty);
      expect(await db.select(db.planProposals).get(), isEmpty);
      expect(await db.select(db.syncOutbox).get(), isEmpty);
    },
  );

  test(
    'same-session concurrent begin allows one pending request only',
    () async {
      final outcomes = await Future.wait([
        for (var i = 0; i < 2; i++)
          store
              .begin(sessionId, 'TEST $i')
              .then<Object>((value) => value, onError: (Object error) => error),
      ]);
      expect(outcomes.whereType<PendingAssistantTurn>(), hasLength(1));
      expect(outcomes.whereType<GoalRuleException>(), hasLength(1));
      expect(await store.messages(sessionId), hasLength(1));
    },
  );

  test(
    'reply, memory events and proposal commit together without creating goals',
    () async {
      final (turn, payload) = await prepare();
      final result = await store.commitResponse(
        turn,
        response(payload, plan: true, memory: true),
      );
      expect((await store.messages(sessionId)).map((row) => row.status), [
        'sent',
        'sent',
      ]);
      expect(result.events, hasLength(1));
      expect(result.proposalId, isNotNull);
      expect(
        (await store.memories.list()).single.sourceMessageId,
        result.message.id,
      );
      expect(
        (await store.sessionProposals(sessionId)).single.messageId,
        result.message.id,
      );
      expect(await db.select(db.goals).get(), isEmpty);
      expect(await db.select(db.syncOutbox).get(), isEmpty);
      expect(await store.isCurrent(turn), isFalse);
    },
  );

  test(
    'last proposal write failure rolls back reply and memory writes',
    () async {
      final (turn, payload) = await prepare();
      await db.customStatement('''
      CREATE TRIGGER fail_proposal BEFORE INSERT ON plan_proposals
      BEGIN SELECT RAISE(ABORT, 'TEST proposal failure'); END
    ''');
      await expectLater(
        store.commitResponse(turn, response(payload, plan: true, memory: true)),
        throwsA(anything),
      );
      expect((await store.messages(sessionId)).single.status, 'pending');
      expect(await store.memories.list(), isEmpty);
      expect(await db.select(db.memoryEvents).get(), isEmpty);
      expect(await store.sessionProposals(sessionId), isEmpty);
      await db.customStatement('DROP TRIGGER fail_proposal');
      await store.commitResponse(
        turn,
        response(payload, plan: true, memory: true),
      );
      expect(await store.messages(sessionId), hasLength(2));
    },
  );

  for (final memory in [false, true]) {
    test(
      'response replay is rejected including zero-memory responses ($memory)',
      () async {
        final (turn, payload) = await prepare();
        final reply = response(payload, memory: memory, plan: true);
        await store.commitResponse(turn, reply);
        final before = await store.messages(sessionId);
        await expectLater(
          store.commitResponse(turn, reply),
          throwsA(isA<AssistantFailure>()),
        );
        await expectLater(
          store.commitResponse(turn, response(payload, memory: true)),
          throwsA(isA<AssistantFailure>()),
        );
        await store.fail(turn);
        expect(await store.messages(sessionId), before);
        expect(await store.memories.list(), hasLength(memory ? 1 : 0));
        expect(await store.sessionProposals(sessionId), hasLength(1));
      },
    );
  }

  test('concurrent reply callbacks commit exactly once', () async {
    final (turn, payload) = await prepare();
    final outcomes = await Future.wait([
      for (var i = 0; i < 2; i++)
        store
            .commitResponse(turn, response(payload, memory: true))
            .then<Object>((value) => value, onError: (Object error) => error),
    ]);
    expect(outcomes.whereType<CommittedAssistantTurn>(), hasLength(1));
    expect(outcomes.whereType<AssistantFailure>(), hasLength(1));
    expect(await store.messages(sessionId), hasLength(2));
    expect(await store.memories.list(), hasLength(1));
  });

  test('cancel rejects late response, retry preserves old actual payload with a new id', () async {
    final (turn, payload) = await prepare();
    await store.cancel(turn);
    final before = await store.messages(sessionId);
    await expectLater(
      store.commitResponse(turn, response(payload, plan: true, memory: true)),
      throwsA(isA<AssistantFailure>()),
    );
    expect(await store.messages(sessionId), before);
    final retry = await store.begin(
      sessionId,
      before.single.content,
      retryMessageId: turn.messageId,
    );
    expect(retry.requestId, isNot(turn.requestId));
    final newRequest = await request(retry);
    expect(newRequest.messages, hasLength(1));
    await store.recordRequest(retry, newRequest);
    await store.commitResponse(retry, response(newRequest));
    final after = await store.messages(sessionId);
    expect(after.map((row) => row.status), ['discarded', 'sent', 'sent']);
    expect(after.first.sentPayload, before.single.sentPayload);
  });

  test(
    'failed messages are retained locally but excluded from future context',
    () async {
      final (turn, _) = await prepare('TEST failed');
      await store.fail(turn);
      final next = await store.begin(sessionId, 'TEST new');
      expect((await store.input(next)).messages, [
        {'role': 'user', 'text': 'TEST new'},
      ]);
      await expectLater(
        store.begin(
          sessionId,
          'TEST different',
          retryMessageId: turn.messageId,
        ),
        throwsA(isA<GoalRuleException>()),
      );
      expect((await store.messages(sessionId)).first.status, 'failed');
    },
  );

  test('identity switches away and back invalidate the old generation with zero late writes', () async {
    final (turn, payload) = await prepare();
    final identities = IdentityStore(db);
    await identities.finish(await identities.begin(accountA));
    await identities.finish(await identities.begin(SyncIdentity.guest));
    final before = await store.messages(sessionId);
    expect(await store.isCurrent(turn), isFalse);
    await expectLater(
      store.commitResponse(turn, response(payload, memory: true, plan: true)),
      throwsA(isA<AssistantFailure>()),
    );
    await store.fail(turn);
    expect(await store.messages(sessionId), before);
    expect(await store.memories.list(), isEmpty);
    expect(await store.sessionProposals(sessionId), isEmpty);
  });

  test(
    'other owner cannot read, rename, delete or post into this session',
    () async {
      await exchange();
      final identities = IdentityStore(db);
      await identities.finish(await identities.begin(accountA));
      final other = LocalConversationStore(
        LocalGoalRepository(db, clock, owner: accountA.owner),
      );
      await other.memories.consent();
      expect(await other.sessions(), isEmpty);
      for (final operation in <Future<Object?>>[
        other.messages(sessionId),
        other.renameSession(sessionId, 'TEST'),
        other.deleteSession(sessionId),
        other.begin(sessionId, 'TEST'),
      ]) {
        await expectLater(operation, throwsA(isA<GoalRuleException>()));
      }
      expect(await db.select(db.assistantMessages).get(), hasLength(2));
    },
  );

  test(
    'changing sending settings during a request rejects all late writes',
    () async {
      final (turn, payload) = await prepare();
      await store.memories.updateSettings(autoMemory: false);
      final before = await store.messages(sessionId);
      expect(await store.isCurrent(turn), isFalse);
      await expectLater(
        store.commitResponse(turn, response(payload, memory: true)),
        throwsA(isA<AssistantFailure>()),
      );
      expect(await store.messages(sessionId), before);
      expect(await store.memories.list(), isEmpty);
    },
  );

  test(
    'request recording rejects extra disabled categories and rewritten history',
    () async {
      await store.memories.updateSettings(
        sendMemories: false,
        sendSchedule: false,
        sendStats: false,
      );
      final turn = await store.begin(sessionId, 'TEST');
      final base = await request(turn);
      for (final key in ['memories', 'schedule', 'stats']) {
        final bad = TurnRequest.fromJson({...base.toJson(), key: <Object>[]});
        await expectLater(
          store.recordRequest(turn, bad),
          throwsA(isA<GoalRuleException>()),
        );
      }
      final rewritten = TurnRequest.fromJson({
        ...base.toJson(),
        'messages': [
          {'role': 'user', 'text': 'TEST rewritten'},
        ],
      });
      await expectLater(
        store.recordRequest(turn, rewritten),
        throwsA(isA<GoalRuleException>()),
      );
      expect((await store.messages(sessionId)).single.sentPayload, isNull);
      await store.recordRequest(turn, base);
      await expectLater(
        store.recordRequest(turn, base),
        throwsA(isA<GoalRuleException>()),
      );
    },
  );

  test(
    'reply cannot be stored before request body or with another request id',
    () async {
      final turn = await store.begin(sessionId, 'TEST');
      final payload = await request(turn);
      await expectLater(
        store.commitResponse(turn, response(payload)),
        throwsA(isA<GoalRuleException>()),
      );
      await store.recordRequest(turn, payload);
      final wrong = TurnRequest.fromJson({
        ...payload.toJson(),
        'request_id': 'other-request',
      });
      await expectLater(
        store.commitResponse(turn, response(wrong)),
        throwsFormatException,
      );
      expect((await store.messages(sessionId)).single.status, 'pending');
    },
  );

  test('late midnight proposal keeps original dates and requires editing before apply', () async {
    clock.setDay(2026, 10, 20, hour: 23, minute: 59);
    final (turn, payload) = await prepare();
    final reply = response(payload, plan: true);
    clock.setDay(2026, 10, 21, hour: 0, minute: 1);
    final result = await store.commitResponse(turn, reply);
    final row = await store.proposals.read(result.proposalId!);
    final preview = PlanPreview.decode(row.itemsJson);
    expect(preview.items.first.task.date.key, '2026-10-20');
    expect(
      preview
          .inspect(today: CalendarDate.parse(clock.day.key), goals: [])
          .every((issue) => issue.kind == PreviewIssueKind.expired),
      isTrue,
    );
    await expectLater(
      store.proposals.apply(row.id, preview),
      throwsFormatException,
    );
    expect(await goals.loadGoals(), isEmpty);
  });

  test('deleting a chat removes drafts/events but preserves memory, goals and applied receipts', () async {
    final (first, firstPayload) = await prepare();
    final result = await store.commitResponse(
      first,
      response(firstPayload, plan: true, memory: true),
    );
    final applied = await store.proposals.read(result.proposalId!);
    await store.proposals.apply(
      applied.id,
      PlanPreview.decode(applied.itemsJson),
    );
    final (second, secondPayload) = await prepare('TEST another');
    await store.commitResponse(second, response(secondPayload, plan: true));
    final memory = (await store.memories.list()).single;
    await store.deleteSession(sessionId);
    expect(await store.sessions(), isEmpty);
    expect(await db.select(db.assistantMessages).get(), isEmpty);
    expect(await db.select(db.memoryEvents).get(), isEmpty);
    expect(await store.memories.list(), [memory]);
    final receipt = await store.proposals.read(applied.id);
    expect(receipt.sessionId, isNull);
    expect(receipt.messageId, isNull);
    expect(receipt.status, 'applied');
    expect(await db.select(db.planProposals).get(), hasLength(1));
    expect(await goals.loadGoals(), hasLength(2));
    await store.proposals.undo(receipt.id);
    expect(await goals.loadGoals(), isEmpty);
  });

  test(
    'deleting a pending chat does not let the response recreate it',
    () async {
      final (turn, payload) = await prepare();
      await store.deleteSession(sessionId);
      await expectLater(
        store.commitResponse(turn, response(payload, plan: true, memory: true)),
        throwsA(isA<AssistantFailure>()),
      );
      expect(await store.sessions(), isEmpty);
      expect(await db.select(db.assistantMessages).get(), isEmpty);
      expect(await store.memories.list(), isEmpty);
    },
  );

  test('20-message window summarizes only the older prefix and preserves all raw text', () async {
    for (var i = 0; i < 10; i++) {
      await exchange(text: 'TEST $i');
    }
    final turn = await store.begin(sessionId, 'TEST next');
    final before = await store.input(turn);
    expect(before.recent, hasLength(20));
    expect(before.older, hasLength(1));
    final work = (await store.nextSummary(turn))!;
    expect(work.request.messages.single.text, 'TEST 0');
    await store.saveSummary(work, summary(work));
    final after = await store.input(turn);
    expect(after.needsSummary, isFalse);
    expect(after.summaryThrough, before.older.single.id);
    expect(after.recent, before.recent);
    expect(await store.messages(sessionId), hasLength(21));
    final payload = await request(turn);
    expect(payload.summary, summary(work).summary);
    await store.recordRequest(turn, payload);
    await expectLater(
      store.saveSummary(work, summary(work)),
      throwsA(isA<AssistantFailure>()),
    );
  });

  test(
    '12000-character window summarizes even when under 20 messages',
    () async {
      await exchange(text: '甲' * 2000, reply: '乙' * 10000);
      final turn = await store.begin(sessionId, '丙');
      final context = await store.input(turn);
      expect(context.recent, hasLength(2));
      expect(context.older.single.content, '甲' * 2000);
      expect(
        context.messages.fold(
          0,
          (n, row) => n + row['text']!.characters.length,
        ),
        10001,
      );
      await expectLater(
        store.recordRequest(turn, await request(turn)),
        throwsA(isA<GoalRuleException>()),
      );
    },
  );

  test('oversize assistant message is split only for summary, never lost or truncated', () async {
    await exchange(reply: '测' * 13000);
    final turn = await store.begin(sessionId, 'TEST continue');
    final work = (await store.nextSummary(turn))!;
    expect(work.request.messages, hasLength(3));
    expect(
      work.request.messages.skip(1).map((row) => row.text).join(),
      '测' * 13000,
    );
    await store.saveSummary(work, summary(work));
    expect((await store.input(turn)).messages, [
      {'role': 'user', 'text': 'TEST continue'},
    ]);
    expect(
      (await store.messages(sessionId))[1].content.characters.length,
      13000,
    );
  });

  test(
    'summary failure keeps previous cursor and full history for retry',
    () async {
      for (var i = 0; i < 10; i++) {
        await exchange();
      }
      final turn = await store.begin(sessionId, 'TEST');
      final work = (await store.nextSummary(turn))!;
      final wrong = SummaryResponse.fromJson({
        'protocol': assistantProtocol,
        'request_id': 'different',
        'summary': 'TEST wrong',
      }, requestId: 'different');
      await expectLater(store.saveSummary(work, wrong), throwsFormatException);
      await store.fail(turn);
      expect((await store.session(sessionId)).summaryThrough, isNull);
      expect(await store.messages(sessionId), hasLength(21));
      final retry = await store.begin(
        sessionId,
        'TEST',
        retryMessageId: turn.messageId,
      );
      final repeated = (await store.nextSummary(retry))!;
      expect(repeated.through, work.through);
      expect(repeated.request.requestId, isNot(work.request.requestId));
    },
  );

  test('cancellation and identity generation reject late summaries without cursor writes', () async {
    for (var i = 0; i < 10; i++) {
      await exchange();
    }
    final turn = await store.begin(sessionId, 'TEST');
    final work = (await store.nextSummary(turn))!;
    await store.cancel(turn);
    await expectLater(
      store.saveSummary(work, summary(work)),
      throwsA(isA<AssistantFailure>()),
    );
    expect((await store.session(sessionId)).summaryThrough, isNull);
    final next = await store.begin(sessionId, 'TEST');
    final nextWork = (await store.nextSummary(next))!;
    final identities = IdentityStore(db);
    await identities.finish(await identities.begin(accountA));
    await identities.finish(await identities.begin(SyncIdentity.guest));
    await expectLater(
      store.saveSummary(nextWork, summary(nextWork)),
      throwsA(isA<AssistantFailure>()),
    );
    expect((await store.session(sessionId)).summaryThrough, isNull);
  });

  test('fixed or backwards clock cannot reorder messages', () async {
    await exchange();
    clock.setDay(2026, 10, 8);
    await exchange();
    final rows = await store.messages(sessionId);
    expect(rows.map((row) => row.role), [
      'user',
      'assistant',
      'user',
      'assistant',
    ]);
    for (var i = 1; i < rows.length; i++) {
      expect(rows[i].createdAt, greaterThan(rows[i - 1].createdAt));
    }
  });

  test('file reopen retains actual payload, summary and receipts; pending recovers as failed', () async {
    final dir = await Directory.systemTemp.createTemp('assistant-chat-');
    addTearDown(() => dir.delete(recursive: true));
    await db.close();
    final file = File('${dir.path}/chat.sqlite');
    db = AppDatabase(NativeDatabase(file));
    goals = LocalGoalRepository(db, clock);
    store = LocalConversationStore(goals);
    await store.memories.consent();
    sessionId = await store.createSession();
    for (var i = 0; i < 10; i++) {
      await exchange();
    }
    final turn = await store.begin(sessionId, 'TEST last');
    final work = (await store.nextSummary(turn))!;
    await store.saveSummary(work, summary(work));
    final payload = await request(turn);
    await store.recordRequest(turn, payload);
    await store.commitResponse(
      turn,
      response(payload, memory: true, plan: true),
    );
    final pending = await store.begin(sessionId, 'TEST interrupted');
    final saved = await store.messages(sessionId);
    await db.close();
    db = AppDatabase(NativeDatabase(file));
    store = LocalConversationStore(LocalGoalRepository(db, clock));
    expect(await store.messages(sessionId), saved);
    expect((await store.session(sessionId)).summary, summary(work).summary);
    expect((await store.memories.list()).single.content, 'TEST 晚上阅读');
    expect(await store.sessionProposals(sessionId), hasLength(1));
    await store.recoverInterrupted();
    final rows = await store.messages(sessionId);
    expect(rows.last.id, pending.messageId);
    expect(rows.last.status, 'failed');
    expect(rows.first.sentPayload, saved.first.sentPayload);
    expect(rows.where((row) => row.role == 'assistant'), hasLength(11));
  });
}
