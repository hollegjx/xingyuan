import 'dart:io';

import 'package:characters/characters.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/features/assistant/data/local_memory_store.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import '../support/assistant_migration_fixture.dart';
import '../support/test_clock.dart';
import 'generated/schema.dart';

void seedV4(InitializedSchema schema, {String preference = 'TEST 夜晚读书'}) {
  final raw = schema.rawDatabase;
  for (final statement in assistantMigrationStatements) {
    raw.execute(statement);
  }
  raw.execute('INSERT INTO planning_profiles VALUES (?, ?, ?)', [
    'guest',
    preference,
    800,
  ]);
}

Map<String, List<Map<String, Object?>>> snapshotV4(InitializedSchema schema) =>
    {
      for (final table in schema.rawDatabase.select(
        "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name",
      ))
        table['name'] as String: schema.rawDatabase
            .select('SELECT * FROM "${table['name']}" ORDER BY rowid')
            .map((row) => Map<String, Object?>.from(row))
            .toList(),
    };

Future<void> expectOldValues(
  AppDatabase db,
  Map<String, List<Map<String, Object?>>> before,
) async {
  for (final entry in before.entries) {
    final rows = await db
        .customSelect('SELECT * FROM "${entry.key}" ORDER BY rowid')
        .get();
    expect(rows, hasLength(entry.value.length), reason: entry.key);
    for (var i = 0; i < rows.length; i++) {
      expect(
        {for (final key in entry.value[i].keys) key: rows[i].data[key]},
        entry.value[i],
        reason: '${entry.key} row $i',
      );
    }
  }
}

void main() {
  setUpAll(tzdata.initializeTimeZones);
  final verifier = SchemaVerifier(GeneratedHelper());

  test(
    'v4 upgrade preserves all old rows and columns and converts each owner',
    () async {
      final schema = await verifier.schemaAt(4);
      seedV4(schema);
      final before = snapshotV4(schema);
      final db = AppDatabase(schema.newConnection());
      try {
        await verifier.migrateAndValidate(db, db.schemaVersion);
        await expectOldValues(db, before);
        final memories = await db.select(db.assistantMemories).get();
        expect(memories, hasLength(2));
        final guest = memories.singleWhere((row) => row.owner == 'guest');
        expect(guest.content, 'TEST 夜晚读书');
        expect(guest.category, '偏好');
        expect(guest.sourceLabel, '旧版偏好');
        expect(guest.sourceSessionId, isNull);
        expect(guest.createdAt, 800);
        expect(guest.updatedAt, 800);
        expect(guest.pinned, isFalse);
        expect(guest.expiresOn, isNull);
        for (final row in await db.select(db.goalSchedules).get()) {
          expect(row.startMinute, isNull);
          expect(row.durationMinutes, isNull);
        }
        expect(await db.select(db.assistantSessions).get(), isEmpty);
        expect(await db.select(db.reminderCancellations).get(), isEmpty);
        expect(
          await db.customSelect('PRAGMA foreign_key_check').get(),
          isEmpty,
        );
      } finally {
        await db.close();
        schema.close();
      }
    },
  );

  test(
    'v4 file migration is once-only across reopening, with Unicode intact',
    () async {
      final directory = await Directory.systemTemp.createTemp('assistant-v5-');
      final file = File('${directory.path}/upgrade.sqlite');
      final schema = await verifier.schemaAt(4);
      final preference = assistantLongMigrationPreference();
      seedV4(schema, preference: preference);
      final before = snapshotV4(schema);
      schema.rawDatabase.execute('VACUUM INTO ?', [file.path]);
      schema.close();
      var db = AppDatabase(NativeDatabase(file));
      try {
        await expectOldValues(db, before);
        final first = await db.select(db.assistantMemories).get();
        final store = LocalMemoryStore(LocalGoalRepository(db, TestClock()));
        expect(
          (await store.list()).map((row) => row.content).join(),
          preference,
        );
        expect(
          (await store.forRequest())!.map((row) => row.text).join(),
          preference,
        );
        await db.close();
        db = AppDatabase(NativeDatabase(file));
        await expectOldValues(db, before);
        expect(await db.select(db.assistantMemories).get(), first);
        final reopened = LocalMemoryStore(LocalGoalRepository(db, TestClock()));
        expect(
          (await reopened.list()).map((row) => row.content).join(),
          preference,
        );
        expect(
          (await reopened.forRequest())!.map((row) => row.text).join(),
          preference,
        );
        expect(
          (await db.customSelect('PRAGMA user_version').getSingle()).read<int>(
            'user_version',
          ),
          db.schemaVersion,
        );
      } finally {
        await db.close();
        await directory.delete(recursive: true);
      }
    },
  );

  for (final length in [1, 199, 200, 201, 399, 400, 401, 500]) {
    test(
      'v4 $length-grapheme preference splits losslessly in request order',
      () async {
        final schema = await verifier.schemaAt(4);
        final preference = assistantLongMigrationPreference().characters
            .take(length)
            .toString();
        seedV4(schema, preference: preference);
        final before = snapshotV4(schema);
        final db = AppDatabase(schema.newConnection());
        try {
          await verifier.migrateAndValidate(db, db.schemaVersion);
          await expectOldValues(db, before);
          final store = LocalMemoryStore(LocalGoalRepository(db, TestClock()));
          final memories = await store.list();
          expect(memories, hasLength((length + 199) ~/ 200));
          expect(memories.map((row) => row.content).join(), preference);
          expect(
            memories.map((row) => row.id).toSet(),
            hasLength(memories.length),
          );
          for (final memory in memories) {
            expect(memory.content.characters.length, inInclusiveRange(1, 200));
            expect(memory.owner, 'guest');
            expect(memory.sourceLabel, '旧版偏好');
            expect(memory.createdAt, 800);
            expect(memory.updatedAt, 800);
            expect(memory.sourceSessionId, isNull);
            expect(memory.sourceMessageId, isNull);
          }
          expect(
            (await store.forRequest())!.map((row) => row.text).join(),
            preference,
          );
          final all = await db.select(db.assistantMemories).get();
          expect(
            all.singleWhere((row) => row.owner == 'other-owner').content,
            'TEST separate owner',
          );
          expect(all.where((row) => row.owner == 'empty'), isEmpty);
        } finally {
          await db.close();
          schema.close();
        }
      },
    );
  }

  test(
    'legacy whitespace segments remain intact locally and in sent context',
    () async {
      final schema = await verifier.schemaAt(4);
      final preference = 'A${' ' * 399}B';
      seedV4(schema, preference: preference);
      final db = AppDatabase(schema.newConnection());
      try {
        final store = LocalMemoryStore(LocalGoalRepository(db, TestClock()));
        final rows = await store.list();
        expect(rows, hasLength(3));
        expect(rows[1].content, ' ' * 200);
        expect(rows.map((row) => row.content).join(), preference);
        expect(
          (await store.forRequest())!.map((row) => row.text).join(),
          preference,
        );
      } finally {
        await db.close();
        schema.close();
      }
    },
  );

  test(
    'migration failure rolls back added columns and tables without changing v4',
    () async {
      final schema = await verifier.schemaAt(4);
      seedV4(schema, preference: List.filled(201, '好').join());
      // CREATE TABLE IF NOT EXISTS skips this malformed table; inserting the
      // converted preference then fails after the new columns/tables exist.
      schema.rawDatabase.execute('CREATE TABLE assistant_memories (id TEXT)');
      final before = snapshotV4(schema);
      final db = AppDatabase(schema.newConnection());
      try {
        await expectLater(db.select(db.goals).get(), throwsException);
      } finally {
        await db.close();
      }
      try {
        expect(schema.rawDatabase.userVersion, 4);
        expect(snapshotV4(schema), before);
        expect(
          schema.rawDatabase
              .select('PRAGMA table_info(goal_schedules)')
              .map((row) => row['name']),
          isNot(contains('start_minute')),
        );
      } finally {
        schema.close();
      }
    },
  );

  test('assistant defaults and composite references isolate owners without uploads', () async {
    final db = AppDatabase(NativeDatabase.memory());
    try {
      await db
          .into(db.assistantSettings)
          .insert(AssistantSettingsCompanion.insert(owner: 'guest'));
      final settings = await db.select(db.assistantSettings).getSingle();
      expect(settings.consentVersion, 0);
      expect(settings.consentedAt, isNull);
      expect(
        settings.autoMemory &&
            settings.sendMemories &&
            settings.sendSchedule &&
            settings.sendStats,
        isTrue,
      );
      await db
          .into(db.assistantSessions)
          .insert(
            AssistantSessionsCompanion.insert(
              id: 'session',
              owner: 'guest',
              title: 'TEST',
              createdAt: 1,
              updatedAt: 1,
            ),
          );
      await expectLater(
        db
            .into(db.assistantMessages)
            .insert(
              AssistantMessagesCompanion.insert(
                id: 'bad',
                sessionId: 'session',
                owner: 'other',
                role: 'user',
                content: 'TEST',
                status: 'sent',
                createdAt: 1,
              ),
            ),
        throwsException,
      );
      await db
          .into(db.assistantMessages)
          .insert(
            AssistantMessagesCompanion.insert(
              id: 'message',
              sessionId: 'session',
              owner: 'guest',
              role: 'assistant',
              content: 'TEST',
              status: 'sent',
              createdAt: 1,
            ),
          );
      await expectLater(
        db
            .into(db.memoryEvents)
            .insert(
              MemoryEventsCompanion.insert(
                id: 'event',
                owner: 'other',
                messageId: 'message',
                op: 'add',
                memoryId: 'm',
              ),
            ),
        throwsException,
      );
      await expectLater(
        db
            .into(db.planProposals)
            .insert(
              PlanProposalsCompanion.insert(
                id: 'proposal',
                owner: 'other',
                sessionId: const Value('session'),
                messageId: const Value('message'),
                itemsJson: '[]',
              ),
            ),
        throwsException,
      );
      await db
          .into(db.assistantMemories)
          .insert(
            AssistantMemoriesCompanion.insert(
              id: 'memory',
              owner: 'guest',
              category: '偏好',
              content: 'TEST',
              sourceSessionId: const Value('session'),
              sourceMessageId: const Value('message'),
              createdAt: 1,
              updatedAt: 1,
            ),
          );
      await db.delete(db.assistantSessions).go();
      expect(await db.select(db.assistantMessages).get(), isEmpty);
      expect(await db.select(db.assistantMemories).get(), hasLength(1));
      expect(await db.select(db.syncOutbox).get(), isEmpty);
      expect(await db.customSelect('PRAGMA foreign_key_check').get(), isEmpty);
    } finally {
      await db.close();
    }
  });
}
