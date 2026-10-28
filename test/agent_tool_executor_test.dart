import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/sync/identity_store.dart';
import 'package:habit_checkin/features/assistant/data/agent_tool_executor.dart';
import 'package:habit_checkin/features/assistant/data/assistant_service.dart';
import 'package:habit_checkin/features/assistant/data/local_agent_source.dart';
import 'package:habit_checkin/features/assistant/data/local_conversation_store.dart';
import 'package:habit_checkin/features/assistant/data/local_memory_store.dart';
import 'package:habit_checkin/features/assistant/domain/agent_planning.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:xingyuan_core/xingyuan_core.dart';

import 'support/sync_fixtures.dart';
import 'support/test_clock.dart';

final today = CalendarDate.parse('2026-10-28');
AgentToolCall call(String name, Map<String, dynamic> args, {int round = 1}) =>
    AgentToolCall.parse({
      'id': agentCallId('test_run', round),
      'type': 'function',
      'function': {'name': name, 'arguments': agentCanonical(args)},
    }, today);
Map<String, dynamic> range({int days = 0}) => {
  'from': today.key,
  'to': today.addDays(days).key,
};
Map<String, dynamic> candidate({int start = 600}) => {
  'title': 'TEST candidate',
  'date': today.key,
  'start_minute': start,
  'minutes': 30,
};

class Source implements AgentDataSource {
  bool allowed = true;
  bool failed = false;
  int reads = 0;
  int checks = 0;
  List<AgentScheduleItem> rows = [];
  List<String> memories = [];
  Future<void> Function()? waiting;
  @override
  Future<bool> authorize(String tool) async {
    checks++;
    return allowed;
  }

  @override
  Future<List<String>> preferences() async {
    reads++;
    return memories;
  }

  @override
  Future<List<AgentScheduleItem>> schedule(
    CalendarDate from,
    CalendarDate to,
  ) async {
    reads++;
    if (waiting != null) await waiting!();
    if (failed) throw StateError('TEST PRIVATE never echo');
    return List.unmodifiable(
      rows.where((row) => !row.date.isBefore(from) && !row.date.isAfter(to)),
    );
  }
}

void main() {
  late Source source;
  late AgentToolExecutor executor;
  setUp(() {
    source = Source();
    executor = AgentToolExecutor(source: source, today: today);
  });

  test('unknown, injected identity, invalid dates/window and extra args fail before read', () async {
    for (final args in [
      {...range(), 'owner': 'foreign'},
      {'from': '2026-10-27', 'to': today.key},
      {'from': today.key, 'to': today.addDays(15).key},
    ]) {
      expect(() => call('query_schedule', args), throwsFormatException);
    }
    expect(() => call('read_diary', {}), throwsFormatException);
    expect(
      () => call('find_free_slots', {
        ...range(),
        'minutes': 30,
        'window': {'start_minute': 600, 'end_minute': 600},
        'daily_cap': null,
      }),
      throwsFormatException,
    );
    expect(source.reads, 0);
  });

  test(
    'first read and second cached duplicate preserve result; third stops',
    () async {
      source.rows = [
        AgentScheduleItem(
          title: 'TEST busy',
          date: today,
          startMinute: null,
          minutes: 30,
        ),
      ];
      final first = await executor.execute(call('query_schedule', range()));
      expect(first['status'], 'partial');
      final second = await executor.execute(
        call('query_schedule', {'to': today.key, 'from': today.key}, round: 2),
      );
      expect(second, {
        'status': 'duplicate',
        'original_status': 'partial',
        'result': first,
      });
      expect(source.reads, 1);
      await expectLater(
        executor.execute(call('query_schedule', range(), round: 3)),
        throwsA(isA<AgentToolStop>()),
      );
      expect(source.reads, 1);
      expect(source.checks, 4);
    },
  );

  test('denied never reads source or private cached content', () async {
    source.memories = ['TEST private preference'];
    await executor.execute(call('get_planning_preferences', {}));
    source.allowed = false;
    final result = await executor.execute(
      call('get_planning_preferences', {}, round: 2),
    );
    expect(result['original_status'], 'not_authorized');
    expect(agentCanonical(result), isNot(contains('private preference')));
    expect(source.reads, 1);
  });

  test(
    'failure returns no exception detail and duplicate retains failed',
    () async {
      source.failed = true;
      final first = await executor.execute(call('query_schedule', range()));
      expect(first, {'status': 'failed', 'data': null});
      expect(
        await executor.execute(call('query_schedule', range(), round: 2)),
        {'status': 'duplicate', 'original_status': 'failed', 'result': first},
      );
      expect(source.reads, 1);
    },
  );

  test(
    'authorization revoked during awaited query discards late data',
    () async {
      final entered = Completer<void>();
      final released = Completer<void>();
      source.waiting = () {
        entered.complete();
        return released.future;
      };
      final run = executor.execute(call('query_schedule', range()));
      final checked = expectLater(run, throwsA(isA<AgentToolStop>()));
      await entered.future;
      source.allowed = false;
      released.complete();
      await checked;
    },
  );

  test(
    'preferences10 and schedule60 caps produce explicit truncation',
    () async {
      source.memories = List.generate(11, (i) => 'TEST preference$i');
      final pref = await executor.execute(call('get_planning_preferences', {}));
      expect(pref['status'], 'truncated');
      expect((pref['data'] as Map)['preferences'], hasLength(10));
      source.rows = List.generate(
        61,
        (i) => AgentScheduleItem(
          title: 'TEST $i',
          date: today,
          startMinute: 300,
          minutes: 30,
        ),
      );
      final result = await executor.execute(call('query_schedule', range()));
      expect(result['status'], 'truncated');
      expect((result['data'] as Map)['items'], hasLength(60));
      validateAgentResult(result, 'query_schedule', today);
    },
  );

  test('submit and mandatory final validation reread full source, bypass old validation cache', () async {
    final items = [candidate()];
    expect(
      (await executor.execute(
        call('validate_plan', {'items': items}),
      ))['status'],
      'ok',
    );
    source.rows = [
      AgentScheduleItem(
        title: 'TEST inserted',
        date: today,
        startMinute: 600,
        minutes: 30,
      ),
    ];
    expect(
      (await executor.execute(
        call('submit_plan_draft', {'items': items, 'note': ''}),
      ))['status'],
      'invalid',
    );
    expect((await executor.validateDraft(items)).status, 'invalid');
    expect(source.reads, 3);
  });

  test('slot daily cap survives later validator and cannot be relaxed by a new tool call', () async {
    source.rows = [
      AgentScheduleItem(
        title: 'TEST busy',
        date: today,
        startMinute: 300,
        minutes: 60,
      ),
    ];
    await executor.execute(
      call('find_free_slots', {
        ...range(),
        'minutes': 30,
        'window': null,
        'daily_cap': 60,
      }),
    );
    expect(
      (await executor.validateDraft([candidate()])).issues.single['code'],
      'daily_cap',
    );
    final relaxed = await executor.execute(
      call('find_free_slots', {
        ...range(),
        'minutes': 30,
        'window': null,
        'daily_cap': null,
      }, round: 2),
    );
    expect((relaxed['data'] as Map)['slots'], isEmpty);
    expect(executor.dailyCaps[today.key], 60);
  });

  test('validated daily cap survives a failed schedule read and a later successful submit', () async {
    source.failed = true;
    expect(
      (await executor.execute(
        call('find_free_slots', {
          ...range(),
          'minutes': 30,
          'window': null,
          'daily_cap': 30,
        }),
      ))['status'],
      'failed',
    );
    source.failed = false;
    source.rows = [
      AgentScheduleItem(
        title: 'TEST busy',
        date: today,
        startMinute: 300,
        minutes: 30,
      ),
    ];
    final result = await executor.execute(
      call('submit_plan_draft', {
        'items': [candidate()],
        'note': '',
      }, round: 2),
    );
    expect(result['status'], 'invalid');
    expect((result['data'] as Map)['issues'].single['code'], 'daily_cap');
    expect(executor.dailyCaps[today.key], 30);
  });

  test('invalid local result is rejected rather than relayed', () async {
    source.memories = ['x' * 201];
    await expectLater(
      executor.execute(call('get_planning_preferences', {})),
      throwsFormatException,
    );
  });

  group('real local data boundary', () {
    late AppDatabase db;
    late TestClock clock;
    late LocalGoalRepository goals;
    late LocalConversationStore store;
    late String session;
    setUpAll(tzdata.initializeTimeZones);
    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      clock = TestClock()..setDay(2026, 10, 28);
      goals = LocalGoalRepository(db, clock);
      store = LocalConversationStore(goals);
      session = await store.createSession();
      await store.memories.consent();
    });
    tearDown(() => db.close());
    Future<AgentToolExecutor> local() async => AgentToolExecutor(
      source: LocalAgentSource(store, await store.begin(session, 'TEST plan')),
      today: today,
    );

    test('schedule versions/weekdays/plus14 and single occurrence preserve minimal fields', () async {
      final id = await goals.create(
        const GoalDraft(
          title: 'TEST habit',
          kind: GoalKind.habit,
          startMinute: 600,
          durationMinutes: 30,
        ),
      );
      await goals.edit(
        id,
        const GoalDraft(
          title: 'TEST habit',
          kind: GoalKind.habit,
          weekdays: 1 << 2,
          startMinute: 660,
          durationMinutes: 45,
        ),
      );
      await goals.create(
        GoalDraft(
          title: 'TEST single',
          kind: GoalKind.single,
          plannedDay: clock.day.addDays(14),
          startMinute: 720,
          durationMinutes: 30,
        ),
      );
      final archived = await goals.create(
        const GoalDraft(title: 'TEST archived', kind: GoalKind.habit),
      );
      await goals.archive(archived);
      await LocalGoalRepository(
        db,
        clock,
        owner: accountA.owner,
      ).create(const GoalDraft(title: 'TEST OTHER', kind: GoalKind.habit));
      final result = await (await local()).execute(
        call('query_schedule', range(days: 14)),
      );
      final rows = ((result['data'] as Map)['items'] as List).cast<Map>();
      expect(result['status'], 'ok');
      expect(rows, hasLength(4));
      expect(rows.first['start_minute'], 600);
      expect(rows[1]['start_minute'], 660);
      expect(rows.last['date'], today.addDays(14).key);
      expect(rows.where((row) => row['title'] == 'TEST single'), hasLength(1));
      expect(
        rows.every(
          (row) => row.keys.toSet().difference({
            'title',
            'date',
            'start_minute',
            'minutes',
          }).isEmpty,
        ),
        isTrue,
      );
      expect(agentCanonical(result), isNot(contains('OTHER')));
      expect(agentCanonical(result), isNot(contains('archived')));
    });

    test(
      'overdue single appears once today with unknown time; not15 repetitions',
      () async {
        clock.setDay(2026, 10, 27);
        await goals.create(
          GoalDraft(
            title: 'TEST overdue',
            kind: GoalKind.single,
            plannedDay: clock.day,
            startMinute: 600,
            durationMinutes: 30,
          ),
        );
        clock.setDay(2026, 10, 28);
        final result = await (await local()).execute(
          call('query_schedule', range(days: 14)),
        );
        expect(result['status'], 'partial');
        expect((result['data'] as Map)['items'], [
          {
            'title': 'TEST overdue',
            'date': today.key,
            'start_minute': null,
            'minutes': 30,
          },
        ]);
      },
    );

    test('only current authorized memories, no goal read for general preference query', () async {
      await store.memories.add(
        const MemoryDraft(category: '偏好', text: 'TEST permitted'),
      );
      await store.memories.add(
        MemoryDraft(
          category: '偏好',
          text: 'TEST expired',
          expiresOn: today.addDays(-1),
        ),
      );
      await LocalMemoryStore(
        LocalGoalRepository(db, clock, owner: accountA.owner),
      ).add(const MemoryDraft(category: '偏好', text: 'TEST foreign'));
      final result = await (await local()).execute(
        call('get_planning_preferences', {}),
      );
      expect(
        result,
        agentResult('ok', {
          'preferences': [
            {'text': 'TEST permitted'},
          ],
        }),
      );
      expect(await db.select(db.planProposals).get(), isEmpty);
      expect(await db.select(db.goals).get(), isEmpty);
    });

    for (final change in ['schedule', 'consent', 'identity', 'cancel']) {
      test('$change change stops before cached schedule is returned', () async {
        final turn = await store.begin(session, 'TEST plan');
        final executor = AgentToolExecutor(
          source: LocalAgentSource(store, turn),
          today: today,
        );
        await executor.execute(call('query_schedule', range()));
        switch (change) {
          case 'schedule':
            await store.memories.updateSettings(sendSchedule: false);
          case 'consent':
            await store.memories.revokeConsent();
          case 'identity':
            final identities = IdentityStore(db);
            await identities.finish(await identities.begin(accountA));
          case 'cancel':
            turn.cancellation.cancel();
        }
        await expectLater(
          executor.execute(call('query_schedule', range(), round: 2)),
          throwsA(isA<AssistantFailure>()),
        );
        expect(await db.select(db.planProposals).get(), isEmpty);
      });
    }

    test(
      'disabled category yields not_authorized and no private payload',
      () async {
        await store.memories.updateSettings(
          sendSchedule: false,
          sendMemories: false,
        );
        final executor = await local();
        for (final tool in [
          call('get_planning_preferences', {}),
          call('query_schedule', range()),
          call('find_free_slots', {
            ...range(),
            'minutes': 30,
            'window': null,
            'daily_cap': null,
          }),
          call('validate_plan', {
            'items': [candidate()],
          }),
          call('submit_plan_draft', {
            'items': [candidate()],
            'note': '',
          }),
        ]) {
          expect(
            await executor.execute(tool),
            agentResult('not_authorized', null),
          );
        }
      },
    );
  });
}
