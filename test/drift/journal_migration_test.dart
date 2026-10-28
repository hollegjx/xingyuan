import 'dart:io';

import 'package:drift/native.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';

import 'generated/schema.dart';
import 'migration_defaults.dart';

const _journalTables = [
  'quick_notes',
  'diary_entries',
  'quick_note_photos',
  'diary_photos',
];

void main() {
  final verifier = SchemaVerifier(GeneratedHelper());

  for (var version = 1; version <= 10; version++) {
    test(
      'schema v$version migrates to current schema with matching constraints',
      () async {
        final schema = await verifier.schemaAt(version);
        final db = AppDatabase(schema.newConnection());
        try {
          await verifier.migrateAndValidate(
            db,
            db.schemaVersion,
            options: const ValidationOptions(validateDropped: true),
          );
          for (final table in _journalTables) {
            expect(
              await db.customSelect('SELECT * FROM $table').get(),
              isEmpty,
            );
          }
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
  }

  test('v10 file upgrade and reopen preserve all old table values with empty journal tables', () async {
    final schema = await verifier.schemaAt(10);
    final raw = schema.rawDatabase;
    const goal = '22222222-2222-4222-8222-222222222222';
    const record = '11111111-1111-4111-8111-111111111111';
    const photo = '33333333-3333-4333-8333-333333333333';
    for (final sql in [
      "INSERT INTO identity_states VALUES (1, 'guest', 7, NULL)",
      "INSERT INTO goals VALUES (1, '$goal', 'guest', 0, '2026-10-20', 100, NULL, NULL)",
      "INSERT INTO goal_titles VALUES (1, '2026-10-20', 'SYNTHETIC private goal')",
      "INSERT INTO goal_schedules VALUES (1, '2026-10-20', 127, NULL, 1140, 30)",
      "INSERT INTO check_ins VALUES (1, 0, '2026-10-21', 1, '2026-10-21', 200, 'America/Los_Angeles', 'SYNTHETIC original title', NULL)",
      "INSERT INTO goal_reminders VALUES (1, 0, 1200, 2, 0, 'disabled')",
      "INSERT INTO sync_states VALUES (1, 0, 0, NULL, NULL)",
      "INSERT INTO planning_profiles VALUES ('guest', 'SYNTHETIC old preference', 50)",
      "INSERT INTO day_records (id, goal_id, owner, day, content, saved_at, draft_text, created_at, updated_at) VALUES ('$record', 1, 'guest', '2026-10-21', 'SYNTHETIC saved', 200, 'SYNTHETIC draft', 100, 300)",
      "INSERT INTO record_photos (id, record_id, owner, filename, width, height, byte_count, sha256, saved_position, draft_position, created_at) VALUES ('$photo', '$record', 'guest', '$photo.jpg', 1600, 1200, 12345, '${'a' * 64}', 0, 0, 200)",
      "INSERT INTO assistant_sessions (id, owner, title, created_at, updated_at) VALUES ('session', 'guest', 'SYNTHETIC planning', 100, 200)",
      "INSERT INTO assistant_messages (id, session_id, owner, role, content, status, created_at) VALUES ('message', 'session', 'guest', 'user', 'SYNTHETIC conversation', 'sent', 20)",
      "INSERT INTO assistant_memories (id, owner, category, content, created_at, updated_at) VALUES ('memory', 'guest', '偏好', 'SYNTHETIC memory', 10, 20)",
      "INSERT INTO day_analysis_settings (owner) VALUES ('guest')",
      "INSERT INTO day_analyses (id, owner, day, zone, request_json, created_at, updated_at) VALUES ('$record', 'guest', '2026-10-21', 'Asia/Shanghai', '{}', 1, 1)",
      "INSERT INTO pairing_states (owner, credential_scope, generation, state_json, state_revision, refreshed_at, draft_code, draft_revision) VALUES ('guest', '${'a' * 64}', 2, '{}', 5, 200, 'SYNTHETIC code', 3)",
      "INSERT INTO sharing_states (owner, generation, session_id, group_id, member_id, partner_id) VALUES ('guest', 2, '44444444-4444-4444-8444-444444444444', '55555555-5555-4555-8555-555555555555', '66666666-6666-4666-8666-666666666666', '77777777-7777-4777-8777-777777777777')",
      "INSERT INTO sharing_grants_cache VALUES ('guest', '88888888-8888-4888-8888-888888888888', '$goal', '{}')",
      "INSERT INTO shared_records_cache VALUES ('guest', '99999999-9999-4999-8999-999999999999', '88888888-8888-4888-8888-888888888888', '66666666-6666-4666-8666-666666666666', 1, '{}')",
      "INSERT INTO sharing_drafts VALUES ('guest', '99999999-9999-4999-8999-999999999999', 'SYNTHETIC unsent reply', 3, 300)",
      "INSERT INTO sharing_commands (owner, operation_id, kind, subject, request_json, created_at, updated_at) VALUES ('guest', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'reply', 'SYNTHETIC subject', '{}', 200, 300)",
      "INSERT INTO chat_states (owner, session_id, draft_text, draft_revision) VALUES ('guest', '44444444-4444-4444-8444-444444444444', 'SYNTHETIC unsent chat', 3)",
      "INSERT INTO chat_messages_cache (owner, id, author_id, sequence, document_json) VALUES ('guest', 'cccccccc-cccc-4ccc-8ccc-cccccccccccc', '66666666-6666-4666-8666-666666666666', 1, '{}')",
      "INSERT INTO chat_commands (owner, operation_id, kind, content, created_at, updated_at) VALUES ('guest', 'dddddddd-dddd-4ddd-8ddd-dddddddddddd', 'send', 'SYNTHETIC pending chat', 200, 300)",
    ]) {
      raw.execute(sql);
    }
    final before = {
      for (final row in raw.select(
        "SELECT name FROM sqlite_schema WHERE type='table' ORDER BY name",
      ))
        row['name'] as String: raw
            .select('SELECT * FROM "${row['name']}" ORDER BY rowid')
            .map((r) => Map<String, Object?>.from(r))
            .toList(),
    };
    final directory = await Directory.systemTemp.createTemp('journal-v11-');
    final file = File('${directory.path}/synthetic-v10.sqlite');
    raw.execute('VACUUM INTO ?', [file.path]);
    schema.close();
    try {
      for (var run = 0; run < 2; run++) {
        final db = AppDatabase(NativeDatabase(file));
        try {
          await verifier.migrateAndValidate(db, db.schemaVersion);
          for (final entry in before.entries) {
            expect(
              (await db
                      .customSelect(
                        'SELECT * FROM "${entry.key}" ORDER BY rowid',
                      )
                      .get())
                  .map((r) => r.data)
                  .toList(),
              withAgentMigrationDefaults(entry.key, entry.value),
              reason: 'open $run ${entry.key}',
            );
          }
          for (final table in _journalTables) {
            expect(
              await db.customSelect('SELECT * FROM $table').get(),
              isEmpty,
            );
          }
          expect(
            await db.customSelect('PRAGMA foreign_key_check').get(),
            isEmpty,
          );
        } finally {
          await db.close();
        }
      }
    } finally {
      await directory.delete(recursive: true);
    }
  });

  for (final name in [..._journalTables, 'quick_notes_by_day']) {
    test(
      'unexpected v10 object $name preserves original data and version',
      () async {
        final schema = await verifier.schemaAt(10);
        schema.rawDatabase.execute('CREATE TABLE $name (id TEXT)');
        schema.rawDatabase.execute(
          "INSERT INTO $name VALUES ('SYNTHETIC preserve')",
        );
        final db = AppDatabase(schema.newConnection());
        try {
          await expectLater(db.select(db.goals).get(), throwsStateError);
          expect(schema.rawDatabase.userVersion, 10);
          expect(
            schema.rawDatabase.select('SELECT * FROM $name').single['id'],
            'SYNTHETIC preserve',
          );
          for (final other in _journalTables.where((t) => t != name)) {
            expect(
              schema.rawDatabase.select(
                'SELECT name FROM sqlite_schema WHERE name=?',
                [other],
              ),
              isEmpty,
            );
          }
        } finally {
          await db.close();
          schema.close();
        }
      },
    );
  }

  test('invalid old foreign key prevents the additive migration', () async {
    final schema = await verifier.schemaAt(10);
    schema.rawDatabase.execute('PRAGMA foreign_keys=OFF');
    schema.rawDatabase.execute(
      "INSERT INTO goal_titles VALUES (99, '2026-10-21', 'SYNTHETIC orphan')",
    );
    final db = AppDatabase(schema.newConnection());
    try {
      await expectLater(db.select(db.goals).get(), throwsStateError);
      expect(schema.rawDatabase.userVersion, 10);
      for (final table in _journalTables) {
        expect(
          schema.rawDatabase.select(
            'SELECT name FROM sqlite_schema WHERE name=?',
            [table],
          ),
          isEmpty,
        );
      }
      expect(
        schema.rawDatabase
            .select('SELECT title FROM goal_titles')
            .single['title'],
        'SYNTHETIC orphan',
      );
    } finally {
      await db.close();
      schema.close();
    }
  });

  test(
    'interrupted journal creation rolls back and retries without data loss',
    () async {
      final schema = await verifier.schemaAt(10);
      addTearDown(schema.close);
      schema.rawDatabase.execute(
        "INSERT INTO planning_profiles VALUES ('guest', 'SYNTHETIC preserve', 42)",
      );
      final failed = _FailJournalCreation(schema.newConnection());
      try {
        await expectLater(failed.select(failed.goals).get(), throwsStateError);
        expect(failed.created, [
          'quick_notes',
          'diary_entries',
          'quick_note_photos',
        ]);
        expect(failed.injected, isTrue);
        expect(schema.rawDatabase.userVersion, 10);
        for (final name in [..._journalTables, 'quick_notes_by_day']) {
          expect(
            schema.rawDatabase.select(
              'SELECT name FROM sqlite_schema WHERE name=?',
              [name],
            ),
            isEmpty,
          );
        }
        expect(
          schema.rawDatabase.select('SELECT * FROM planning_profiles').single,
          {
            'owner': 'guest',
            'preferences': 'SYNTHETIC preserve',
            'updated_at': 42,
          },
        );
      } finally {
        await failed.close();
      }
      final retried = AppDatabase(schema.newConnection());
      try {
        await verifier.migrateAndValidate(retried, retried.schemaVersion);
        final profile = await retried
            .select(retried.planningProfiles)
            .getSingle();
        expect(profile.preferences, 'SYNTHETIC preserve');
        expect(profile.updatedAt, 42);
        for (final table in _journalTables) {
          expect(
            await retried.customSelect('SELECT * FROM $table').get(),
            isEmpty,
          );
        }
      } finally {
        await retried.close();
      }
    },
  );

  for (final kind in ['quick', 'diary']) {
    test('$kind constraints isolate photo owners, saved/draft slots and metadata', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final entries = kind == 'quick' ? 'quick_notes' : 'diary_entries';
      final photos = kind == 'quick' ? 'quick_note_photos' : 'diary_photos';
      const entry = '11111111-1111-4111-8111-111111111111';
      await db.customStatement(
        "INSERT INTO $entries (id, owner, day, zone, created_at, updated_at) VALUES (?, 'guest', '2026-10-23', 'Asia/Shanghai', 1, 1)",
        [entry],
      );
      Future<void> photo(
        int slot, {
        String owner = 'guest',
        int width = 16,
        int bytes = 100,
        String? filename,
        int? position,
      }) {
        final id =
            '33333333-3333-4333-8333-${slot.toString().padLeft(12, '0')}';
        return db.customStatement(
          'INSERT INTO $photos (id, entry_id, owner, filename, width, height, byte_count, sha256, saved_position, created_at) VALUES (?, ?, ?, ?, ?, 8, ?, ?, ?, 1)',
          [
            id,
            entry,
            owner,
            filename ?? '$id.jpg',
            width,
            bytes,
            'a' * 64,
            position ?? slot,
          ],
        );
      }

      await expectLater(photo(0, owner: 'other'), throwsException);
      await expectLater(photo(0, width: 1601), throwsException);
      await expectLater(photo(0, bytes: 2097153), throwsException);
      await expectLater(photo(0, filename: '../secret.jpg'), throwsException);
      for (var i = 0; i < 3; i++) {
        await photo(i);
      }
      await expectLater(photo(3), throwsException);
      await expectLater(photo(4, position: 1), throwsException);
      await db.customStatement(
        'UPDATE $photos SET draft_position=saved_position',
      );
      await expectLater(
        db.customStatement('UPDATE $photos SET draft_position=3'),
        throwsException,
      );
      await expectLater(
        db.customStatement('UPDATE $photos SET draft_position=0'),
        throwsException,
      );
      await expectLater(
        db.customStatement('UPDATE $entries SET revision=-1'),
        throwsException,
      );
      await expectLater(
        db.customStatement('UPDATE $entries SET saved_at=1, deleted_at=1'),
        throwsException,
      );
      await expectLater(
        db.customStatement("UPDATE $entries SET last_operation_id='$entry'"),
        throwsException,
      );
      expect(await db.customSelect('PRAGMA foreign_key_check').get(), isEmpty);
    });
  }
}

class _FailJournalCreation extends AppDatabase {
  _FailJournalCreation(super.executor);

  final created = <String>[];
  bool injected = false;

  @override
  Future<void> customStatement(String statement, [List<Object?>? args]) async {
    final table = RegExp(r'CREATE TABLE IF NOT EXISTS "([^"]+)"')
        .firstMatch(statement)
        ?.group(1);
    if (table == 'diary_photos') {
      injected = true;
      throw StateError('Synthetic interrupted journal migration');
    }
    await super.customStatement(statement, args);
    if (_journalTables.contains(table)) created.add(table!);
  }
}
