import 'dart:convert';

import 'package:characters/characters.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/sync/identity_store.dart';
import 'package:habit_checkin/features/assistant/data/assistant_conversation_runner.dart';
import 'package:habit_checkin/features/assistant/data/assistant_record_tools.dart';
import 'package:habit_checkin/features/assistant/data/local_conversation_store.dart';
import 'package:habit_checkin/features/assistant/data/local_agent_source.dart';
import 'package:habit_checkin/features/assistant/domain/agent_run_metadata.dart';
import 'package:habit_checkin/features/assistant/presentation/assistant_conversation_controller.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:xingyuan_core/xingyuan_core.dart';

import 'assistant_c69_tools_test.dart' show C69ScriptedService;
import 'support/test_clock.dart';
import 'support/scripted_agent_service.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);
  late AppDatabase db;
  late LocalConversationStore store;
  late C69ScriptedService service;
  late AssistantConversationRunner runner;
  late String session;
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    final clock = TestClock()..setDay(2026, 11, 2);
    store = LocalConversationStore(
      LocalGoalRepository(
        db,
        clock,
        identityLease: await IdentityStore(db).active(),
      ),
    );
    await store.memories.consent();
    session = await store.openContinuous();
    service = C69ScriptedService();
    runner = AssistantConversationRunner(store: store, service: service);
  });
  tearDown(() => db.close());

  void replyWithMemory(String text, String memory) {
    service.script.add(
      (r) => agentResponse(r, text: text)..['memory_summary'] = memory,
    );
  }

  Future<void> seedNote(String day) => db
      .into(db.quickNotes)
      .insert(
        QuickNotesCompanion.insert(
          id: '11111111-1111-4111-8111-${day.replaceAll('-', '').padLeft(12, '0')}',
          owner: store.owner,
          day: day,
          zone: 'Asia/Shanghai',
          createdAt: 1,
          updatedAt: 1,
          content: const Value('SYNTHETIC_RECORD'),
          savedAt: const Value(1),
        ),
      );

  test(
    'continuous chat reopens, retains transcript and model memory',
    () async {
      final old = await store.createSession();
      expect(await store.openContinuous(), session);
      replyWithMemory('Hello', 'Prefers concise replies');
      await runner.run(await store.begin(session, 'Remember concise replies'));
      expect((await store.session(session)).summary, 'Prefers concise replies');
      service.reply('Followup'); // Old v2 server can omit memory update.
      await runner.run(await store.begin(session, 'Continue'));
      final payload = jsonDecode(
        service.requestsSeen.last.messages.first['content'] as String,
      ) as Map;
      expect(payload['summary'], 'Prefers concise replies');
      expect((payload['messages'] as List).length, 3);
      final controller = AssistantConversationController(
        store: store,
        service: service,
      );
      await controller.initialize();
      await controller.openContinuous();
      expect(controller.session!.id, session);
      expect(controller.messages.length, 4);
      expect(controller.memorySummary, 'Prefers concise replies');
      expect(await store.messages(old), isEmpty);
      controller.dispose();
    },
  );

  test(
    'long Chinese context clips oldest whole messages, keeps current input',
    () async {
      for (var i = 0; i < 35; i++) {
        await db
            .into(db.assistantMessages)
            .insert(
              AssistantMessagesCompanion.insert(
                id: 'history-$i',
                sessionId: session,
                owner: store.owner,
                role: i.isEven ? 'user' : 'assistant',
                content: '$i${'中' * 900}',
                status: 'sent',
                createdAt: i,
              ),
            );
      }
      final turn = await store.begin(session, 'CURRENT');
      final payload = jsonDecode(
        await store.agentInput(turn, recordsSupported: true),
      ) as Map;
      final messages = payload['messages'] as List;
      expect(messages.last['text'], 'CURRENT');
      expect(messages.first['text'], startsWith('22'));
      expect(
        messages.fold<int>(
          0,
          (n, r) => n + (r['text'] as String).characters.length,
        ),
        lessThanOrEqualTo(12000),
      );
      expect((await store.messages(session)).length, 36);
      expect(
        (await store.input(turn, recordsSupported: true)).needsSummary,
        isFalse,
      );
    },
  );

  test('clear cancels pending context and survives reopening without deleting chat', () async {
    replyWithMemory('OLD_REPLY', 'OLD_MEMORY');
    await runner.run(await store.begin(session, 'OLD_INPUT'));
    final pending = await store.begin(session, 'IN_FLIGHT');
    await store.clearMemorySummary(session);
    expect(await store.isCurrent(pending), isFalse);
    await store.fail(pending);
    final fresh = await store.begin(await store.openContinuous(), 'NEW_INPUT');
    final payload = await store.agentInput(fresh, recordsSupported: true);
    expect(payload, isNot(contains('OLD_')));
    expect(payload, isNot(contains('IN_FLIGHT')));
    expect(payload, contains('NEW_INPUT'));
    expect((await store.messages(session)).length, 4);
  });

  test(
    'seven dates, multiple dates and kinds without confirmation or fixed scope',
    () async {
      var confirmations = 0;
      final turn = await store.begin(session, 'Review relevant records');
      final tools = AssistantRecordTools(
        store,
        turn,
        CalendarDate.parse('2026-11-02'),
        confirm: (_, _) async {
          confirmations++;
          return false;
        },
        scope: AssistantRecordScope(CalendarDate.parse('2026-11-02'), {
          'summary',
        }),
      );
      await seedNote('2026-10-27');
      await seedNote('2026-11-02');
      for (final day in ['2026-10-27', '2026-11-02', '2026-10-26']) {
        final call = AssistantAgentCall.parse({
          'id': 'read-$day',
          'type': 'function',
          'function': {
            'name': 'get_journal_text',
            'arguments': jsonEncode({
              'day': day,
              'kinds': ['quickNote'],
            }),
          },
        }, CalendarDate.parse('2026-11-02'));
        final result = await tools.execute(call);
        expect(result['status'], day == '2026-10-26' ? 'not_authorized' : 'ok');
      }
      expect(confirmations, 0);
      expect(tools.receipts.map((r) => r['count']), [1, 1, 0]);
      expect(tools.receipts.map((r) => r['day']), [
        '2026-10-27',
        '2026-11-02',
        '2026-10-26',
      ]);
    },
  );

  for (final mode in ['off', 'fallback', 'enabled']) {
    test('record-derived history and summary transport: $mode', () async {
      await seedNote('2026-11-02');
      service.tool('get_journal_text', {
        'day': '2026-11-02',
        'kinds': ['quickNote'],
      });
      replyWithMemory('RECORD_DERIVED_REPLY', 'RECORD_DERIVED_MEMORY');
      await runner.run(await store.begin(session, 'Review'));
      if (mode == 'off') {
        await store.memories.updateSettings(readJournalOnRequest: false);
      }
      if (mode == 'fallback') service.capable = false;
      service.reply('Next');
      await runner.run(await store.begin(session, 'Continue'));
      final payload = jsonEncode(service.requestsSeen.last.toJson());
      expect(payload.contains('RECORD_DERIVED'), mode == 'enabled');
      expect(
        payload,
        isNot(contains('SYNTHETIC_RECORD')),
      ); // Only reply/summary persist.
      if (mode != 'enabled') {
        final turn = await store.begin(session, 'Preferences');
        expect(await LocalAgentSource(store, turn).preferences(), isEmpty);
      }
    });
  }

  test(
    'master switch invalidates cached reads and late memory commits',
    () async {
      await seedNote('2026-11-02');
      final turn = await store.begin(session, 'Read');
      final tools = AssistantRecordTools(
        store,
        turn,
        CalendarDate.parse('2026-11-02'),
      );
      final call = AssistantAgentCall.parse({
        'id': 'read',
        'type': 'function',
        'function': {
          'name': 'get_journal_text',
          'arguments': jsonEncode({
            'day': '2026-11-02',
            'kinds': ['quickNote'],
          }),
        },
      }, CalendarDate.parse('2026-11-02'));
      expect((await tools.execute(call))['status'], 'ok');
      await store.memories.updateSettings(readJournalOnRequest: false);
      await expectLater(tools.execute(call), throwsA(anything));
      expect(await store.isCurrent(turn), isFalse);
      await store.fail(turn);
      final next = await store.begin(session, 'Read again');
      final fresh = AssistantRecordTools(
        store,
        next,
        CalendarDate.parse('2026-11-02'),
      );
      expect((await fresh.execute(call))['status'], 'not_authorized');
    },
  );

  test(
    'off switch excludes source-linked memory from another local session',
    () async {
      final old = await store.createSession();
      await db
          .into(db.assistantMemories)
          .insert(
            AssistantMemoriesCompanion.insert(
              id: 'synthetic-memory',
              owner: store.owner,
              category: '其他',
              content: 'SYNTHETIC_DERIVED_MEMORY',
              sourceSessionId: Value(old),
              createdAt: 1,
              updatedAt: 1,
            ),
          );
      expect(
        (await store.memories.forRequest())!.single.text,
        'SYNTHETIC_DERIVED_MEMORY',
      );
      await store.memories.updateSettings(readJournalOnRequest: false);
      expect(await store.memories.forRequest(), isEmpty);
      final turn = await store.begin(session, 'Preferences');
      expect(await LocalAgentSource(store, turn).preferences(), isEmpty);
      expect(
        (await store.memories.list()).single.content,
        'SYNTHETIC_DERIVED_MEMORY',
      );
    },
  );

  for (final invalidation in ['off', 'clear']) {
    test('late model summary commit is rejected after $invalidation', () async {
      final turn = await store.begin(session, 'Hello');
      final request = AssistantAgentRequest.fromJson({
        'protocol': assistantAgentProtocol,
        'request_id': turn.requestId,
        'run_id': null,
        'turn': 1,
        'now': {
          'date': '2026-11-02',
          'time': '12:00',
          'weekday': 1,
          'time_zone': 'Asia/Shanghai',
        },
        'messages': [
          {
            'role': 'user',
            'content': await store.agentInput(turn, recordsSupported: true),
          },
        ],
      });
      await store.recordAgentRequest(turn, request);
      if (invalidation == 'off') {
        await store.memories.updateSettings(readJournalOnRequest: false);
      } else {
        await store.clearMemorySummary(session);
      }
      await expectLater(
        store.commitAgentResponse(
          turn,
          text: 'LATE_REPLY',
          memorySummary: 'LATE_MEMORY',
          metadata: AgentRunMetadata(date: request.now.date),
        ),
        throwsA(anything),
      );
      expect((await store.session(session)).summary, isNull);
      expect(
        (await store.messages(session)).where((m) => m.role == 'assistant'),
        isEmpty,
      );
    });
  }

  test('diary proposal is a card and does not save a diary', () async {
    service.tool('get_day_summary', {'day': '2026-11-02'});
    service.tool('get_journal_text', {
      'day': '2026-11-02',
      'kinds': ['quickNote', 'diary'],
    });
    service.tool('create_diary_draft', {
      'day': '2026-11-02',
      'text': 'Synthetic draft',
    });
    await runner.run(await store.begin(session, '用今天写日记'));
    expect(await db.select(db.diaryEntries).get(), isEmpty);
    expect(
      (await db.select(db.assistantDiaryProposals).get()).single.content,
      'Synthetic draft',
    );
    expect(service.requestsSeen.length, 3);
  });
}
