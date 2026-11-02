import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/sync/identity_store.dart';
import 'package:habit_checkin/features/assistant/data/assistant_conversation_runner.dart';
import 'package:habit_checkin/features/assistant/data/assistant_record_tools.dart';
import 'package:habit_checkin/features/assistant/data/local_conversation_store.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:xingyuan_core/xingyuan_core.dart';

import 'assistant_c69_tools_test.dart' show C69ScriptedService;
import 'support/test_clock.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);
  for (final mode in [
    'fixed-today-scope',
    'outside-eight-day-window',
    'next-day',
    'fallback-control',
    'summary-and-followup',
  ]) {
    test('AI1 record-derived old-day text is excluded: $mode', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final clock = TestClock()..setDay(2026, 11, 1);
      final store = LocalConversationStore(
        LocalGoalRepository(
          db,
          clock,
          identityLease: await IdentityStore(db).active(),
        ),
      );
      await store.memories.consent();
      final session = await store.createSession();
      const marker = 'SYNTHETIC_PRIVATE_DAY_OCT31_9b6f';
      await db
          .into(db.quickNotes)
          .insert(
            QuickNotesCompanion.insert(
              id: '11111111-1111-4111-8111-111111111111',
              owner: store.owner,
              day: '2026-10-31',
              zone: 'Asia/Shanghai',
              createdAt: 1,
              updatedAt: 1,
              content: const Value(marker),
              savedAt: const Value(1),
            ),
          );
      final service = C69ScriptedService();
      final runner = AssistantConversationRunner(
        store: store,
        service: service,
      );
      service.tool('get_journal_text', {
        'day': '2026-10-31',
        'kinds': ['quickNote'],
      });
      service.reply('Synthetic review: $marker');
      var confirmations = 0;
      await runner.run(
        await store.begin(session, 'TEST review October 31'),
        confirmRead: (_, _) async {
          confirmations++;
          return true;
        },
      );
      expect(confirmations, 1);
      expect(jsonEncode(service.requestsSeen.last.toJson()), contains(marker));
      if (mode == 'summary-and-followup') {
        await (db.update(
          db.assistantSessions,
        )..where((row) => row.id.equals(session))).write(
          AssistantSessionsCompanion(
            summary: const Value('Synthetic summary: $marker'),
            summaryThrough: Value(
              (await db.select(db.assistantMessages).get()).last.id,
            ),
          ),
        );
      }
      final priorRequests = service.requestsSeen.length;
      if (mode == 'outside-eight-day-window') clock.setDay(2026, 11, 9);
      if (mode == 'next-day') clock.setDay(2026, 11, 2);
      if (mode == 'fallback-control') service.capable = false;
      service.reply('Synthetic current-only answer');
      await runner.run(
        await store.begin(session, 'TEST only today'),
        recordScope: AssistantRecordScope(CalendarDate.parse(clock.day.key), {
          'summary',
          'quickNote',
          'diary',
        }),
        confirmRead: (_, _) async {
          confirmations++;
          return false;
        },
      );
      expect(
        confirmations,
        1,
        reason: 'Second run grants no old-day permission',
      );
      final outbound = jsonEncode(service.requestsSeen[priorRequests].toJson());
      expect(
        outbound,
        isNot(contains(marker)),
        reason: 'First outbound request must honor current date scope before any tool authorization',
      );
      expect((await db.select(db.quickNotes).get()).single.content, marker);
      expect(
        (await db.select(db.assistantMessages).get()).any(
          (message) => message.content.contains(marker),
        ),
        isTrue,
        reason: 'Local chat is retained',
      );
      if (mode == 'summary-and-followup') {
        service.reply('Synthetic followup');
        await runner.run(await store.begin(session, 'TEST followup'));
        expect(
          jsonEncode(service.requestsSeen.last.toJson()),
          isNot(contains(marker)),
        );
      }
    });
  }
}
