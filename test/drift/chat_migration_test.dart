import 'dart:io';

import 'package:drift/native.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';

import 'generated/schema.dart';

const _tables = [
  'chat_states',
  'chat_messages_cache',
  'chat_photos',
  'chat_commands',
];

void main() {
  final verifier = SchemaVerifier(GeneratedHelper());
  test('v9 to v10 preserves all original rows and introduces no chat data', () async {
    final schema = await verifier.schemaAt(9);
    final raw = schema.rawDatabase;
    for (final sql in [
      "INSERT INTO identity_states VALUES (1, 'guest', 7, NULL)",
      "INSERT INTO goals VALUES (1, '22222222-2222-4222-8222-222222222222', 'guest', 0, '2026-10-20', 100, NULL, NULL)",
      "INSERT INTO goal_titles VALUES (1, '2026-10-20', 'SYNTHETIC private')",
      "INSERT INTO goal_schedules VALUES (1, '2026-10-20', 127, NULL, 1140, 30)",
      "INSERT INTO check_ins VALUES (1, 0, '2026-10-21', 1, '2026-10-21', 200, 'America/Los_Angeles', 'SYNTHETIC original', NULL)",
      "INSERT INTO day_records (id, goal_id, owner, day, content, share_with_partner, saved_at, draft_text, draft_share_with_partner, created_at, updated_at) VALUES ('11111111-1111-4111-8111-111111111111', 1, 'guest', '2026-10-21', 'SYNTHETIC saved', 0, 200, 'SYNTHETIC draft', 0, 100, 300)",
      "INSERT INTO record_photos (id, record_id, owner, filename, width, height, byte_count, sha256, saved_position, draft_position, created_at) VALUES ('33333333-3333-4333-8333-333333333333', '11111111-1111-4111-8111-111111111111', 'guest', '33333333-3333-4333-8333-333333333333.jpg', 1600, 1200, 12345, '${'a' * 64}', 0, 0, 200)",
      "INSERT INTO assistant_sessions (id, owner, title, created_at, updated_at) VALUES ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'guest', 'SYNTHETIC planning', 100, 200)",
      "INSERT INTO pairing_states (owner, credential_scope, generation, state_json, state_revision, refreshed_at, draft_code, draft_revision) VALUES ('guest', '${'a' * 64}', 2, '{}', 5, 200, 'SYNTHETIC code', 3)",
      "INSERT INTO sharing_states (owner, generation, session_id, group_id, member_id, partner_id) VALUES ('guest', 2, '44444444-4444-4444-8444-444444444444', '55555555-5555-4555-8555-555555555555', '66666666-6666-4666-8666-666666666666', '77777777-7777-4777-8777-777777777777')",
      "INSERT INTO sharing_grants_cache VALUES ('guest', '88888888-8888-4888-8888-888888888888', '22222222-2222-4222-8222-222222222222', '{}')",
      "INSERT INTO shared_records_cache VALUES ('guest', '99999999-9999-4999-8999-999999999999', '88888888-8888-4888-8888-888888888888', '66666666-6666-4666-8666-666666666666', 1, '{}')",
      "INSERT INTO sharing_drafts VALUES ('guest', '99999999-9999-4999-8999-999999999999', 'SYNTHETIC unsent reply', 3, 300)",
      "INSERT INTO sharing_commands (owner, operation_id, kind, subject, request_json, created_at, updated_at) VALUES ('guest', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'reply', 'SYNTHETIC subject', '{}', 200, 300)",
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
    final directory = await Directory.systemTemp.createTemp('chat-v10-');
    final file = File('${directory.path}/v9.sqlite');
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
              entry.value,
              reason: 'open $run ${entry.key}',
            );
          }
          for (final table in _tables) {
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

  for (final table in _tables) {
    test('v9 conflict $table rolls back every new table', () async {
      final schema = await verifier.schemaAt(9);
      schema.rawDatabase.execute('CREATE TABLE $table (id TEXT)');
      schema.rawDatabase.execute(
        "INSERT INTO $table VALUES ('SYNTHETIC preserve')",
      );
      final db = AppDatabase(schema.newConnection());
      try {
        await expectLater(db.select(db.goals).get(), throwsStateError);
        expect(schema.rawDatabase.userVersion, 9);
        expect(
          schema.rawDatabase.select('SELECT * FROM $table').single['id'],
          'SYNTHETIC preserve',
        );
        for (final other in _tables.where((t) => t != table)) {
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
    });
  }

  test('corrupt v9 foreign keys are refused before migration', () async {
    final schema = await verifier.schemaAt(9);
    schema.rawDatabase.execute('PRAGMA foreign_keys=OFF');
    schema.rawDatabase.execute(
      "INSERT INTO goal_titles VALUES (99, '2026-10-21', 'SYNTHETIC orphan')",
    );
    final db = AppDatabase(schema.newConnection());
    try {
      await expectLater(db.select(db.goals).get(), throwsStateError);
      expect(schema.rawDatabase.userVersion, 9);
      for (final table in _tables) {
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
}
