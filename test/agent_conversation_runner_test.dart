import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/sync/identity_store.dart';
import 'package:habit_checkin/features/assistant/data/agent_conversation_runner.dart';
import 'package:habit_checkin/features/assistant/data/assistant_conversation_runner.dart';
import 'package:habit_checkin/features/assistant/data/assistant_service.dart';
import 'package:habit_checkin/features/assistant/data/local_conversation_store.dart';
import 'package:habit_checkin/features/assistant/data/local_memory_store.dart';
import 'package:habit_checkin/features/assistant/domain/agent_run_metadata.dart';
import 'package:habit_checkin/features/assistant/domain/plan_preview.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:xingyuan_core/xingyuan_core.dart';

import 'support/scripted_agent_service.dart';
import 'support/sync_fixtures.dart';
import 'support/test_clock.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);
  late AppDatabase db;
  late LocalConversationStore store;
  late LocalGoalRepository goals;
  late ScriptedAgentService service;
  late AssistantConversationRunner runner;
  late TestClock clock;
  late String session;
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    clock = TestClock()..setDay(2026, 10, 28);
    goals = LocalGoalRepository(
      db,
      clock,
      identityLease: await IdentityStore(db).active(),
    );
    store = LocalConversationStore(goals);
    service = ScriptedAgentService();
    runner = AssistantConversationRunner(store: store, service: service);
    session = await store.createSession();
    await store.memories.consent();
  });
  tearDown(() => db.close());
  Map<String, dynamic> item({int start = 600, int day = 0}) => {
    'title': 'TEST proposal',
    'date': clock.day.addDays(day).key,
    'start_minute': start,
    'minutes': 30,
  };
  Map<String, dynamic> range() => {'from': clock.day.key, 'to': clock.day.key};
  void tool(String name, Map<String, dynamic> args) => service.script.add(
    (r) async => agentResponse(r, tool: name, arguments: args),
  );
  void text([String answer = 'TEST answer']) =>
      service.script.add((r) async => agentResponse(r, text: answer));
  Future<CommittedAssistantTurn> run({List<AssistantRunStage>? stages}) async =>
      runner.run(
        await store.begin(session, 'TEST planning'),
        onStage: stages?.add,
      );

  test('default Agent general question is one call, no private fields or local writes', () async {
    text();
    final result = await run();
    expect((await store.memories.settings()).agentEnabled, isTrue);
    expect(service.requests, isEmpty);
    expect(service.summaries, isEmpty);
    expect(service.agentRequests, hasLength(1));
    expect(result.proposalId, isNull);
    expect(await goals.loadGoals(), isEmpty);
    expect(await store.memories.list(), isEmpty);
    expect(
      AgentRunMetadata.decode(result.message.agentMetadata!).trace,
      isEmpty,
    );
    expect(service.agentRequests.single.messages.single.keys, [
      'role',
      'content',
    ]);
    expect(
      jsonDecode((await store.messages(session)).first.sentPayload!),
      service.agentRequests.single.toJson(),
    );
  });

  test(
    'direct clarification does not query or send existing private data',
    () async {
      await goals.create(
        GoalDraft(
          title: 'TEST PRIVATE schedule canary',
          kind: GoalKind.single,
          plannedDay: clock.day,
        ),
      );
      await store.memories.add(
        const MemoryDraft(category: '偏好', text: 'TEST PRIVATE memory canary'),
      );
      service.script.add(
        (r) async => agentResponse(
          r,
          question: true,
          text: 'TEST which day and duration?',
        ),
      );
      final result = await run();
      expect(result.message.content, 'TEST which day and duration?');
      expect(service.agentRequests, hasLength(1));
      expect(service.summaries, isEmpty);
      expect(service.requests, isEmpty);
      expect(
        agentCanonical(service.agentRequests.single.toJson()),
        isNot(contains('PRIVATE')),
      );
      expect(
        AgentRunMetadata.decode(result.message.agentMetadata!).trace,
        isEmpty,
      );
      expect(result.proposalId, isNull);
      expect(await store.sessionProposals(session), isEmpty);
      expect(await goals.loadGoals(), hasLength(1));
      expect(await store.memories.list(), hasLength(1));
    },
  );

  test('explicit off uses legacy turn and can be changed without deleting conversations', () async {
    await store.memories.updateSettings(agentEnabled: false);
    await run();
    expect(service.agentRequests, isEmpty);
    expect(service.requests, hasLength(1));
    await store.memories.updateSettings(agentEnabled: true);
    text();
    await run();
    expect(service.agentRequests, hasLength(1));
    expect(await store.messages(session), hasLength(4));
  });

  test(
    'optional observation cannot mutate actual call, validation or draft',
    () async {
      tool('submit_plan_draft', {
        'items': [item()],
        'note': 'TEST unchanged',
      });
      var observed = 0;
      final result = await runner.run(
        await store.begin(session, 'TEST planning'),
        onToolResult: (call, value) {
          observed++;
          (call.arguments['items'] as List).clear();
          value['status'] = 'invalid';
          (value['data'] as Map).clear();
        },
      );
      expect(observed, 1);
      expect(result.message.content, 'TEST unchanged');
      final preview = PlanPreview.decode(
        (await store.proposals.read(result.proposalId!)).itemsJson,
      );
      expect(preview.items, hasLength(1));
      expect(preview.items.single.task.time, '10:00');
      expect(await goals.loadGoals(), isEmpty);
    },
  );

  test('real schedule -> slots -> invalid submit -> repaired submit preserves full transcript and drafts only', () async {
    await goals.create(
      GoalDraft(
        title: 'TEST busy',
        kind: GoalKind.single,
        plannedDay: clock.day,
        startMinute: 540,
        durationMinutes: 30,
      ),
    );
    tool('query_schedule', range());
    tool('find_free_slots', {
      ...range(),
      'minutes': 30,
      'window': {'start_minute': 540, 'end_minute': 660},
      'daily_cap': 120,
    });
    tool('submit_plan_draft', {
      'items': [item(start: 540)],
      'note': '',
    });
    tool('submit_plan_draft', {
      'items': [item(start: 600)],
      'note': 'TEST repaired',
    });
    final stages = <AssistantRunStage>[];
    final result = await run(stages: stages);
    expect(result.message.content, 'TEST repaired');
    expect(service.agentRequests, hasLength(4));
    expect(service.agentRequests.last.results.map((r) => r['status']), [
      'ok',
      'ok',
      'invalid',
    ]);
    expect(
      service.agentRequests.last.results.first['data']['items'].single['title'],
      'TEST busy',
    );
    expect(service.agentRequests.last.calls.map((c) => c.id), [
      'call_test_run_1',
      'call_test_run_2',
      'call_test_run_3',
    ]);
    expect(
      stages,
      containsAllInOrder([
        AssistantRunStage.querying,
        AssistantRunStage.finding,
        AssistantRunStage.adjusting,
        AssistantRunStage.confirming,
      ]),
    );
    expect(await goals.loadGoals(), hasLength(1));
    final proposal = await store.proposals.read(result.proposalId!);
    expect(proposal.status, 'draft');
    expect(
      PlanPreview.decode(proposal.itemsJson).items.single.task.time,
      '10:00',
    );
    expect(
      AgentRunMetadata.decode(proposal.agentMetadata!).trace,
      hasLength(4),
    );
    expect(result.message.agentMetadata, isNot(contains('TEST busy')));
    expect(result.message.agentMetadata, isNot(contains('TEST repaired')));
  });

  test('submit without model validation is always locally checked and may be repaired', () async {
    tool('submit_plan_draft', {
      'items': [item(start: 1430)],
      'note': '',
    });
    tool('submit_plan_draft', {
      'items': [item(day: 14)],
      'note': '',
    });
    final result = await run();
    expect(service.agentRequests.last.results.single['status'], 'invalid');
    expect(
      service
          .agentRequests
          .last
          .results
          .single['data']['issues']
          .single['code'],
      'invalid_field',
    );
    expect(
      PlanPreview.decode(
        (await store.proposals.read(result.proposalId!)).itemsJson,
      ).items.single.task.date.key,
      clock.day.addDays(14).key,
    );
    expect(await goals.loadGoals(), isEmpty);
  });

  test('only partial affected items are tagged; schedule never becomes an empty success', () async {
    await goals.create(
      GoalDraft(
        title: 'TEST unknown',
        kind: GoalKind.single,
        plannedDay: clock.day,
      ),
    );
    tool('submit_plan_draft', {
      'items': [item(), item(day: 1)],
      'note': '',
    });
    final result = await run();
    final metadata = AgentRunMetadata.decode(result.message.agentMetadata!);
    expect(metadata.partial, {0});
    expect(metadata.statuses, {'partial'});
    expect(metadata.banners, [agentDataMessages['partial']]);
    expect(await goals.loadGoals(), hasLength(1));
  });

  Future<(String, PlanPreview)> draft({int day = 0}) async {
    tool('submit_plan_draft', {
      'items': [item(day: day)],
      'note': '',
    });
    final result = await run();
    final id = result.proposalId!;
    return (id, PlanPreview.decode((await store.proposals.read(id)).itemsJson));
  }

  Future<String> inspection(String id, PlanPreview preview) async =>
      (await store.proposals.inspectAgent(id, preview))!.token;

  test('new conflict between preview and confirmation rejects save with no partial write', () async {
    final (id, preview) = await draft();
    final checked = await inspection(id, preview);
    await goals.create(
      GoalDraft(
        title: 'TEST newly busy',
        kind: GoalKind.single,
        plannedDay: clock.day,
        startMinute: 600,
        durationMinutes: 30,
      ),
    );
    await expectLater(
      store.proposals.apply(id, preview, expectedAgentValidation: checked),
      throwsA(isA<GoalRuleException>()),
    );
    expect(await goals.loadGoals(), hasLength(1));
    expect((await store.proposals.read(id)).status, 'draft');
    expect(
      (await store.proposals.inspectAgent(
        id,
        preview,
      ))!.validation.issues.single['code'],
      'conflict',
    );
  });

  test('new unknown schedule needs fresh preview plus explicit partial acknowledgement', () async {
    final (id, preview) = await draft();
    final checked = await inspection(id, preview);
    await goals.create(
      GoalDraft(
        title: 'TEST unknown',
        kind: GoalKind.single,
        plannedDay: clock.day,
      ),
    );
    await expectLater(
      store.proposals.apply(
        id,
        preview,
        expectedAgentValidation: checked,
        partialAcknowledged: true,
      ),
      throwsA(isA<GoalRuleException>()),
    );
    final updated = await inspection(id, preview);
    await expectLater(
      store.proposals.apply(id, preview, expectedAgentValidation: updated),
      throwsA(isA<GoalRuleException>()),
    );
    expect(await goals.loadGoals(), hasLength(1));
    final ids = await store.proposals.apply(
      id,
      preview,
      expectedAgentValidation: updated,
      partialAcknowledged: true,
    );
    expect(ids, hasLength(1));
    expect(await goals.loadGoals(), hasLength(2));
  });

  test('plus14 creates only on explicit confirmation; repeat confirmation remains idempotent', () async {
    final (id, preview) = await draft(day: 14);
    expect(await goals.loadGoals(), isEmpty);
    final checked = await inspection(id, preview);
    final ids = await store.proposals.apply(
      id,
      preview,
      expectedAgentValidation: checked,
    );
    expect(
      await store.proposals.apply(
        id,
        preview,
        expectedAgentValidation: checked,
      ),
      ids,
    );
    expect(await goals.loadGoals(), hasLength(1));
    expect(
      (await db.select(db.goalSchedules).getSingle()).plannedDay,
      clock.day.addDays(14).key,
    );
    final edited = preview.replace(
      preview.items.single.id,
      PlanTask.fromJson({
        'title': 'TEST changed',
        'date': clock.day.addDays(14).key,
        'time': '11:00',
        'minutes': 30,
      }, habit: false),
    );
    await expectLater(
      store.proposals.apply(id, edited, expectedAgentValidation: checked),
      throwsA(isA<GoalRuleException>()),
    );
    expect(await goals.loadGoals(), hasLength(1));
  });

  test('changed unknown schedule invalidates acknowledgement even with identical partial indexes', () async {
    Future<void> unknown(String title) => goals.create(
      GoalDraft(title: title, kind: GoalKind.single, plannedDay: clock.day),
    );
    await unknown('TEST original unknown');
    final (id, preview) = await draft();
    final checked = await inspection(id, preview);
    await unknown('TEST newly unknown');
    await expectLater(
      store.proposals.apply(
        id,
        preview,
        expectedAgentValidation: checked,
        partialAcknowledged: true,
      ),
      throwsA(isA<GoalRuleException>()),
    );
    expect(await goals.loadGoals(), hasLength(2));
    expect((await store.proposals.read(id)).status, 'draft');
  });

  for (final change in ['grant', 'consent', 'identity']) {
    test(
      '$change after preview refuses Agent confirmation without creating tasks',
      () async {
        final (id, preview) = await draft();
        final checked = await inspection(id, preview);
        switch (change) {
          case 'grant':
            await store.memories.updateSettings(sendSchedule: false);
          case 'consent':
            await store.memories.revokeConsent();
          case 'identity':
            final identities = IdentityStore(db);
            await identities.finish(await identities.begin(accountA));
        }
        await expectLater(
          store.proposals.apply(id, preview, expectedAgentValidation: checked),
          throwsA(
            change == 'identity'
                ? isA<StaleIdentity>()
                : isA<GoalRuleException>(),
          ),
        );
        expect(await db.select(db.goals).get(), isEmpty);
        expect((await db.select(db.planProposals).getSingle()).status, 'draft');
      },
    );
  }

  test('expired preview after day changes cannot be confirmed', () async {
    final (id, preview) = await draft();
    final checked = await inspection(id, preview);
    clock.setDay(2026, 10, 29);
    await expectLater(
      store.proposals.apply(id, preview, expectedAgentValidation: checked),
      throwsA(isA<GoalRuleException>()),
    );
    expect(await goals.loadGoals(), isEmpty);
  });

  test('D5 status is retained after denied duplicate and later optimistic model text', () async {
    await store.memories.updateSettings(sendSchedule: false);
    tool('query_schedule', range());
    tool('query_schedule', range());
    text('TEST optimistic claim');
    final result = await run();
    final duplicate = service.agentRequests.last.results.last;
    expect(duplicate, {
      'status': 'duplicate',
      'original_status': 'not_authorized',
      'result': {'status': 'not_authorized', 'data': null},
    });
    final metadata = AgentRunMetadata.decode(result.message.agentMetadata!);
    expect(metadata.banners, [agentDataMessages['not_authorized']]);
    expect(result.proposalId, isNull);
    expect(await goals.loadGoals(), isEmpty);
  });

  test('unauthorized submit never produces a confirmable proposal', () async {
    await store.memories.updateSettings(sendSchedule: false);
    tool('submit_plan_draft', {
      'items': [item()],
      'note': '',
    });
    final result = await run();
    expect(result.proposalId, isNull);
    expect(result.message.content, contains('未授权'));
    expect(service.agentRequests, hasLength(1));
  });

  test(
    'third repeated call stops without a third tool result or fourth request',
    () async {
      for (var i = 0; i < 3; i++) {
        tool('query_schedule', range());
      }
      final result = await run();
      expect(service.agentRequests, hasLength(3));
      expect(result.message.content, contains('重复查询'));
      expect(
        AgentRunMetadata.decode(result.message.agentMetadata!).trace,
        hasLength(2),
      );
    },
  );

  test('six model calls cap stops without proposal or seventh call', () async {
    for (var i = 0; i < 6; i++) {
      tool('query_schedule', {
        'from': clock.day.addDays(i).key,
        'to': clock.day.addDays(i).key,
      });
    }
    final result = await run();
    expect(service.agentRequests, hasLength(6));
    expect(result.message.content, contains('上限'));
    expect(result.proposalId, isNull);
  });

  test('six invalid submits stop with concrete issue list and no confirmable draft', () async {
    for (var i = 0; i < 6; i++) {
      tool('submit_plan_draft', {
        'items': [item(start: 1430)],
        'note': 'TEST attempt$i',
      });
    }
    final result = await run();
    expect(service.agentRequests, hasLength(6));
    expect(result.proposalId, isNull);
    expect(result.message.content, contains('没能排出不冲突的方案'));
    expect(result.message.content, contains('第 1 项'));
    expect(result.message.content, contains('日期、开始时间或时长无效'));
    expect(await goals.loadGoals(), isEmpty);
  });

  test(
    'server quota/refusal/violation stop remains explicit and creates no plan',
    () async {
      service.script.add(
        (r) async => agentResponse(r, stop: 'usage_violation'),
      );
      final result = await run();
      expect(result.proposalId, isNull);
      expect(result.message.content, contains('用量校验未通过'));
      expect(await goals.loadGoals(), isEmpty);
    },
  );

  test(
    'actual backend quota and restart codes have specific safe messages',
    () async {
      for (final code in [
        'run_call_limit',
        'run_token_limit',
        'daily_run_limit',
        'daily_token_limit',
      ]) {
        expect(agentStopMessage(code), contains('用量上限'), reason: code);
      }
      for (final code in ['invalid_usage', 'usage_exceeds_reservation']) {
        expect(agentStopMessage(code), contains('用量校验未通过'), reason: code);
      }
      for (final code in [
        'run_restart_required',
        'start_replayed',
        'turn_replayed',
        'history_mismatch',
      ]) {
        expect(agentStopMessage(code), contains('已失效'), reason: code);
      }
    },
  );

  test('first-call token preflight stops clearly without service or fake sent payload', () async {
    final turn = await store.begin(session, '👨‍👩‍👧‍👦' * 2000);
    await expectLater(
      runner.run(turn),
      throwsA(
        isA<AssistantFailure>().having(
          (failure) => failure.message,
          'message',
          contains('用量上限'),
        ),
      ),
    );
    expect(service.agentRequests, isEmpty);
    expect((await store.messages(session)).single.sentPayload, isNull);
    expect(await store.sessionProposals(session), isEmpty);
  });

  test('oversized grapheme UTF8 context fails before network and is not silently truncated', () async {
    final text = 'a${'\u0301' * 20}' * 2000;
    final turn = await store.begin(session, text);
    await expectLater(
      runner.run(turn),
      throwsA(
        isA<AssistantFailure>().having(
          (failure) => failure.kind,
          'kind',
          AssistantFailureKind.tooLarge,
        ),
      ),
    );
    expect(service.agentRequests, isEmpty);
    expect((await store.messages(session)).single.content, text);
    expect((await store.messages(session)).single.sentPayload, isNull);
  });

  test(
    'zero charged tokens are not accepted as a successful model response',
    () async {
      service.script.add((r) async => agentResponse(r, tokens: 0));
      await expectLater(run(), throwsA(isA<AssistantFailure>()));
      expect(await store.messages(session), hasLength(1));
    },
  );

  for (final malformed in [
    'call_id',
    'run_id',
    'turn',
    'parallel',
    'tokens',
    'unchanged_tokens',
    'remaining',
  ]) {
    test(
      'malformed $malformed response is rejected before tool/commit',
      () async {
        tool('query_schedule', range());
        service.script.add((r) async {
          final response = agentResponse(
            r,
            tool: 'submit_plan_draft',
            arguments: {
              'items': [item()],
              'note': '',
            },
          );
          switch (malformed) {
            case 'call_id':
              (response['tool_call'] as Map)['id'] = 'foreign';
            case 'run_id':
              response['run_id'] = 'foreign';
            case 'turn':
              response['turn'] = 1;
            case 'parallel':
              response['tool_calls'] = [
                response['tool_call'],
                response['tool_call'],
              ];
            case 'tokens':
              (response['budget'] as Map)['charged_tokens'] = 1;
            case 'unchanged_tokens':
              (response['budget'] as Map)['charged_tokens'] = 100;
            case 'remaining':
              (response['budget'] as Map)['remaining_ms'] = 60000;
          }
          return response;
        });
        await expectLater(run(), throwsA(isA<AssistantFailure>()));
        expect(await store.sessionProposals(session), isEmpty);
        expect(await goals.loadGoals(), isEmpty);
        expect((await store.messages(session)).single.status, 'failed');
      },
    );
  }

  for (final action in ['cancel', 'identity', 'grant', 'consent', 'mode']) {
    test(
      '$action interrupts a pending fake immediately, drops its later draft',
      () async {
        final entered = Completer<void>();
        final response = Completer<Map<String, dynamic>>();
        late AgentRequest request;
        service.script.add((r) {
          request = r;
          entered.complete();
          return response.future;
        });
        final turn = await store.begin(session, 'TEST planning');
        final future = runner.run(turn);
        final failed = expectLater(
          future.timeout(const Duration(seconds: 3)),
          throwsA(isA<AssistantFailure>()),
        );
        await entered.future;
        switch (action) {
          case 'cancel':
            await store.cancel(turn);
          case 'identity':
            final identities = IdentityStore(db);
            await identities.finish(await identities.begin(accountA));
          case 'grant':
            await store.memories.updateSettings(sendSchedule: false);
          case 'consent':
            await store.memories.revokeConsent();
          case 'mode':
            await store.memories.updateSettings(agentEnabled: false);
        }
        await failed;
        response.complete(
          agentResponse(
            request,
            tool: 'submit_plan_draft',
            arguments: {
              'items': [item()],
              'note': '',
            },
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(await db.select(db.planProposals).get(), isEmpty);
        expect(await db.select(db.goals).get(), isEmpty);
        expect(await db.select(db.assistantMessages).get(), hasLength(1));
      },
    );
  }

  test(
    'deadline rejects late model; no implicit retry or model summary',
    () async {
      final pending = Completer<Map<String, dynamic>>();
      late AgentRequest request;
      service.script.add((r) {
        request = r;
        return pending.future;
      });
      final turn = await store.begin(session, 'TEST planning');
      await expectLater(
        AgentConversationRunner(
          store: store,
          service: service,
          limit: const Duration(milliseconds: 150),
        ).run(turn),
        throwsA(isA<AssistantFailure>()),
      );
      pending.complete(agentResponse(request));
      await Future<void>.delayed(Duration.zero);
      expect(await goals.loadGoals(), isEmpty);
      expect(service.agentRequests, hasLength(1));
      expect(service.summaries, isEmpty);
    },
  );
}
