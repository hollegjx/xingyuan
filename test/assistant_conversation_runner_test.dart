import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:characters/characters.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/sync/identity_store.dart';
import 'package:habit_checkin/features/assistant/data/assistant_conversation_runner.dart';
import 'package:habit_checkin/features/assistant/data/assistant_request_builder.dart';
import 'package:habit_checkin/features/assistant/data/assistant_service.dart';
import 'package:habit_checkin/features/assistant/data/local_conversation_store.dart';
import 'package:habit_checkin/features/assistant/data/local_memory_store.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:xingyuan_core/xingyuan_core.dart';

import 'support/sync_fixtures.dart';
import 'support/test_clock.dart';

TurnResponse reply(TurnRequest request, {String text = 'TEST 好的'}) =>
    TurnResponse.fromJson({
      'protocol': assistantProtocol,
      'request_id': request.requestId,
      'reply': text,
      'plan': null,
      'memory_ops': [],
    }, request: request);

class TestAssistantService implements AssistantService {
  @override
  bool configured = true;
  final requests = <TurnRequest>[];
  final summaries = <SummaryRequest>[];
  Future<TurnResponse> Function(TurnRequest)? onTurn;
  Future<SummaryResponse> Function(SummaryRequest)? onSummary;

  @override
  Future<TurnResponse> turn(
    TurnRequest request, {
    required AssistantAccess access,
    AssistantCancellation? cancellation,
  }) async {
    requests.add(request);
    return onTurn == null ? reply(request) : onTurn!(request);
  }

  @override
  Future<SummaryResponse> summarize(
    SummaryRequest request, {
    required AssistantAccess access,
    AssistantCancellation? cancellation,
  }) async {
    summaries.add(request);
    return onSummary == null
        ? SummaryResponse.fromJson({
            'protocol': assistantProtocol,
            'request_id': request.requestId,
            'summary': 'TEST 历史约束摘要',
          }, requestId: request.requestId)
        : onSummary!(request);
  }

  @override
  Future<void> health({required AssistantAccess access}) async {}
}

void main() {
  setUpAll(tzdata.initializeTimeZones);
  late AppDatabase db;
  late TestClock clock;
  late LocalGoalRepository goals;
  late LocalConversationStore store;
  late TestAssistantService service;
  late AssistantConversationRunner runner;
  late String sessionId;
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    clock = TestClock()..setDay(2026, 10, 20);
    goals = LocalGoalRepository(db, clock);
    store = LocalConversationStore(goals);
    service = TestAssistantService();
    runner = AssistantConversationRunner(store: store, service: service);
    sessionId = await store.createSession();
    await store.memories.consent();
  });
  tearDown(() => db.close());

  Future<PendingAssistantTurn> begin([String text = 'TEST 请帮我规划']) =>
      store.begin(sessionId, text);
  Future<TurnRequest> build() async =>
      AssistantRequestBuilder(store).build(await begin());
  Future<void> fillChat() async {
    for (var i = 0; i < 10; i++) {
      await runner.run(await begin('TEST $i'));
    }
  }

  test(
    'runner persists the exact payload before transport; chat creates no goals',
    () async {
      service.onTurn = (request) async {
        final pending = (await store.messages(sessionId)).single;
        expect(pending.status, 'pending');
        expect(jsonDecode(pending.sentPayload!), request.toJson());
        return reply(request);
      };
      final stages = <AssistantRunStage>[];
      await runner.run(await begin(), onStage: stages.add);
      expect(stages, [AssistantRunStage.sending, AssistantRunStage.saving]);
      expect(service.requests, hasLength(1));
      expect(await goals.loadGoals(), isEmpty);
      expect(await db.select(db.syncOutbox).get(), isEmpty);
      expect(await store.sessionProposals(sessionId), isEmpty);
    },
  );

  test('no consent or unconfigured service performs zero requests', () async {
    await db.delete(db.assistantSettings).go();
    await expectLater(begin(), throwsA(isA<AssistantFailure>()));
    expect(service.requests, isEmpty);
    await store.memories.consent();
    service.configured = false;
    await expectLater(
      runner.run(await begin()),
      throwsA(
        isA<AssistantFailure>().having(
          (e) => e.kind,
          'kind',
          AssistantFailureKind.unconfigured,
        ),
      ),
    );
    expect(service.requests, isEmpty);
    expect(service.summaries, isEmpty);
    expect((await store.messages(sessionId)).single.status, 'failed');
  });

  test(
    'category opt-outs omit keys and never transmit owner or identifiers',
    () async {
      await store.memories.add(
        const MemoryDraft(category: '偏好', text: 'TEST private'),
      );
      await goals.create(
        const GoalDraft(title: 'TEST goal', kind: GoalKind.habit),
      );
      await store.memories.updateSettings(
        sendMemories: false,
        sendSchedule: false,
        sendStats: false,
      );
      final payload = (await build()).toJson();
      expect(payload.keys.toSet(), {
        'protocol',
        'request_id',
        'now',
        'summary',
        'messages',
        'settings',
        'diary_proposals',
      });
      expect(payload['diary_proposals'], isTrue);
      final serialized = jsonEncode(payload);
      expect(serialized, isNot(contains('TEST private')));
      expect(serialized, isNot(contains('TEST goal')));
      expect(serialized, isNot(contains('guest')));
      expect(serialized, isNot(contains('session_id')));
    },
  );

  test('request context includes only active own goals, versioned timing and 14 dates', () async {
    final habit = await goals.create(
      const GoalDraft(
        title: 'TEST 阅读',
        kind: GoalKind.habit,
        startMinute: 19 * 60,
        durationMinutes: 30,
      ),
    );
    await goals.edit(
      habit,
      const GoalDraft(
        title: 'TEST 阅读',
        kind: GoalKind.habit,
        startMinute: 20 * 60,
        durationMinutes: 45,
      ),
    );
    await goals.setCompleted(habit, true, expectedDay: clock.day);
    await goals.create(
      GoalDraft(
        title: 'TEST 下周任务',
        kind: GoalKind.single,
        plannedDay: clock.day.addDays(7),
      ),
    );
    final archived = await goals.create(
      const GoalDraft(title: 'TEST ARCHIVED', kind: GoalKind.habit),
    );
    await goals.archive(archived);
    await LocalGoalRepository(
      db,
      clock,
      owner: accountA.owner,
    ).create(const GoalDraft(title: 'TEST OTHER OWNER', kind: GoalKind.habit));
    await store.memories.add(
      MemoryDraft(
        category: '近期约束',
        text: 'TEST expired',
        expiresOn: CalendarDate.parse(clock.day.addDays(-1).key),
      ),
    );
    await store.memories.add(
      MemoryDraft(
        category: '近期约束',
        text: 'TEST today',
        expiresOn: CalendarDate.parse(clock.day.key),
      ),
    );
    final request = await build();
    expect(request.schedule!.length, 14);
    expect(request.schedule!.last.date.key, clock.day.addDays(13).key);
    expect(request.schedule!.first.items.single, {
      'title': 'TEST 阅读',
      'kind': 'habit',
      'time': '19:00',
      'minutes': 30,
      'done': true,
    });
    expect(request.schedule![1].items.single['time'], '20:00');
    expect(request.schedule![1].items.single['minutes'], 45);
    expect(
      request.schedule!.where(
        (day) => day.items.any((item) => item['title'] == 'TEST 下周任务'),
      ),
      hasLength(1),
    );
    expect(request.memories!.single.text, 'TEST today');
    final json = jsonEncode(request.toJson());
    expect(json, isNot(contains('ARCHIVED')));
    expect(json, isNot(contains('OTHER OWNER')));
    expect(json, isNot(contains('TEST expired')));
  });

  test(
    'overdue single is sent today only, not duplicated across fourteen days',
    () async {
      clock.setDay(2026, 10, 18);
      await goals.create(
        GoalDraft(
          title: 'TEST overdue',
          kind: GoalKind.single,
          plannedDay: clock.day,
        ),
      );
      clock.setDay(2026, 10, 20);
      final request = await build();
      expect(request.schedule, hasLength(1));
      expect(request.schedule!.single.date.key, '2026-10-20');
      expect(request.schedule!.single.items.single['done'], isFalse);
      expect(request.stats!.single.scheduled, 1);
    },
  );

  test(
    '14-day counts use historical schedules and actual completion day',
    () async {
      clock.setDay(2026, 10, 1);
      final habit = await goals.create(
        const GoalDraft(title: 'TEST habit', kind: GoalKind.habit),
      );
      final single = await goals.create(
        GoalDraft(
          title: 'TEST single',
          kind: GoalKind.single,
          plannedDay: clock.day,
        ),
      );
      clock.setDay(2026, 10, 7);
      await goals.setCompleted(habit, true, expectedDay: clock.day);
      clock.setDay(2026, 10, 10);
      await goals.edit(
        habit,
        const GoalDraft(title: 'TEST habit', kind: GoalKind.habit, weekdays: 1),
      );
      clock.setDay(2026, 10, 20);
      await goals.setCompleted(single, true, expectedDay: clock.day);
      final request = await build();
      final stats = request.stats!;
      expect(stats.first.scheduled, 6); // Oct 7-10, then Mondays Oct 12 and 19.
      expect(stats.first.done, 1);
      expect(stats.last.scheduled, 0);
      expect(stats.last.done, 1);
    },
  );

  test(
    'schedule budget truncates full date groups and sends an explicit marker',
    () async {
      for (var day = 0; day < 14; day++) {
        for (var i = 0; i < 2; i++) {
          await goals.create(
            GoalDraft(
              title: 'TEST $day-$i ${'字' * 45}',
              kind: GoalKind.single,
              plannedDay: clock.day.addDays(day),
            ),
          );
        }
      }
      final request = await build();
      expect(request.scheduleTruncated, isTrue);
      expect(request.toJson()['schedule_truncated'], isTrue);
      expect(request.schedule!.length, inExclusiveRange(0, 14));
      expect(request.schedule!.every((day) => day.items.length == 2), isTrue);
      expect(
        jsonEncode(request.toJson()['schedule']).characters.length,
        lessThanOrEqualTo(3000),
      );
      expect(request.stats, hasLength(28));
      expect(TurnRequest.fromJson(request.toJson()).scheduleTruncated, isTrue);
    },
  );

  test('oversized first date is not partly sent or silently skipped', () async {
    for (var i = 0; i < 30; i++) {
      await goals.create(
        GoalDraft(
          title: 'TEST $i ${'字' * 45}',
          kind: GoalKind.single,
          plannedDay: clock.day,
        ),
      );
    }
    await goals.create(
      GoalDraft(
        title: 'TEST tomorrow',
        kind: GoalKind.single,
        plannedDay: clock.day.addDays(1),
      ),
    );
    final request = await build();
    expect(request.schedule, isEmpty);
    expect(request.scheduleTruncated, isTrue);
  });

  test(
    'overall 64KB limit fails before transport without dropping memories',
    () async {
      await db.transaction(() async {
        for (var i = 0; i < 200; i++) {
          await store.memories.add(
            MemoryDraft(category: '偏好', text: '测' * 200),
          );
        }
      });
      final turn = await begin();
      await expectLater(
        runner.run(turn),
        throwsA(
          isA<AssistantFailure>().having(
            (e) => e.kind,
            'kind',
            AssistantFailureKind.tooLarge,
          ),
        ),
      );
      expect(service.requests, isEmpty);
      expect(await store.memories.list(), hasLength(200));
      expect((await store.messages(sessionId)).single.sentPayload, isNull);
      expect((await store.messages(sessionId)).single.status, 'failed');
    },
  );

  test(
    'runner summarizes before turn, persists cursor and sends the summary',
    () async {
      await fillChat();
      final stages = <AssistantRunStage>[];
      await runner.run(await begin('TEST next'), onStage: stages.add);
      expect(stages, [
        AssistantRunStage.summarizing,
        AssistantRunStage.sending,
        AssistantRunStage.saving,
      ]);
      expect(service.summaries, hasLength(1));
      expect(service.requests.last.messages, hasLength(20));
      expect(service.requests.last.summary, 'TEST 历史约束摘要');
      expect(
        (await store.session(sessionId)).summaryThrough,
        (await store.messages(sessionId)).first.id,
      );
    },
  );

  test('summary network failure is explicit and stops the turn without dropping context', () async {
    await fillChat();
    service.onSummary = (_) async =>
        throw const AssistantFailure(AssistantFailureKind.network);
    await expectLater(
      runner.run(await begin()),
      throwsA(
        isA<AssistantFailure>().having(
          (e) => e.kind,
          'kind',
          AssistantFailureKind.summary,
        ),
      ),
    );
    expect(service.requests, hasLength(10));
    expect((await store.session(sessionId)).summaryThrough, isNull);
    final rows = await store.messages(sessionId);
    expect(rows, hasLength(21));
    expect(rows.last.status, 'failed');
    expect(rows.last.sentPayload, isNull);
  });

  test(
    'cancellation discards even a service that returns a late successful reply',
    () async {
      final called = Completer<TurnRequest>();
      final pending = Completer<TurnResponse>();
      service.onTurn = (request) {
        called.complete(request);
        return pending.future;
      };
      final turn = await begin();
      final run = runner.run(turn);
      final failure = expectLater(run, throwsA(isA<AssistantFailure>()));
      final payload = await called.future;
      await store.cancel(turn);
      pending.complete(reply(payload));
      await failure;
      expect((await store.messages(sessionId)).single.status, 'discarded');
      expect(await store.memories.list(), isEmpty);
    },
  );

  test(
    'identity switch rejects late reply without updating either owner',
    () async {
      final called = Completer<TurnRequest>();
      final pending = Completer<TurnResponse>();
      service.onTurn = (request) {
        called.complete(request);
        return pending.future;
      };
      final turn = await begin();
      final failure = expectLater(
        runner.run(turn),
        throwsA(isA<AssistantFailure>()),
      );
      final payload = await called.future;
      final before = await db.select(db.assistantMessages).get();
      final identity = IdentityStore(db);
      await identity.finish(await identity.begin(accountA));
      pending.complete(reply(payload));
      await failure;
      expect(await db.select(db.assistantMessages).get(), before);
      expect(await db.select(db.assistantMemories).get(), isEmpty);
    },
  );

  for (final kind in [
    AssistantFailureKind.credential,
    AssistantFailureKind.busy,
    AssistantFailureKind.timeout,
    AssistantFailureKind.network,
    AssistantFailureKind.unavailable,
    AssistantFailureKind.invalidResponse,
  ]) {
    test('$kind does not retry automatically or create content', () async {
      service.onTurn = (_) async => throw AssistantFailure(kind);
      final turn = await begin();
      await expectLater(
        runner.run(turn),
        throwsA(isA<AssistantFailure>().having((e) => e.kind, 'kind', kind)),
      );
      expect(service.requests, hasLength(1));
      expect((await store.messages(sessionId)).single.status, 'failed');
      expect(await store.sessionProposals(sessionId), isEmpty);
      expect(await store.memories.list(), isEmpty);
    });
  }

  test(
    'real loopback transport body matches persisted request byte for byte',
    () async {
      await store.memories.updateSettings(agentEnabled: false);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final captured = Completer<String>();
      final subscription = server.listen((incoming) async {
        final body = await utf8.decoder.bind(incoming).join();
        captured.complete(body);
        final request = TurnRequest.fromJson(jsonDecode(body));
        incoming.response.headers.contentType = ContentType.json;
        incoming.response.write(jsonEncode(reply(request).toJson()));
        await incoming.response.close();
      });
      addTearDown(subscription.cancel);
      final real = AssistantConversationRunner(
        store: store,
        service: HttpAssistantService(
          endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
          allowInsecureLoopback: true,
          readCredential: () async => 'a' * 43,
        ),
      );
      await real.run(await begin());
      final rows = await store.messages(sessionId);
      expect(rows.first.sentPayload, await captured.future);
      expect(rows.map((row) => row.status), ['sent', 'sent']);
      expect(rows.first.sentPayload, isNot(contains('a' * 43)));
    },
  );
}
