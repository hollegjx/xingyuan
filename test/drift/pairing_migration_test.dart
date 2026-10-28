import 'dart:io';

import 'package:drift/native.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';

import 'generated/schema.dart';
import 'migration_defaults.dart';

void main() {
  final verifier = SchemaVerifier(GeneratedHelper());

  test('v6 file upgrade preserves all old tables through a second open', () async {
    final schema = await verifier.schemaAt(6);
    final raw = schema.rawDatabase;
    for (final statement in [
      "INSERT INTO goals VALUES (1, '22222222-2222-4222-8222-222222222222', 'guest', 0, '2026-10-20', 100, NULL, NULL)",
      "INSERT INTO goal_titles VALUES (1, '2026-10-20', 'TEST private goal')",
      "INSERT INTO goal_schedules VALUES (1, '2026-10-20', 127, NULL, 1140, 30)",
      "INSERT INTO check_ins VALUES (1, 0, '2026-10-21', 1, '2026-10-21', 200, 'America/Los_Angeles', 'TEST original title', NULL)",
      "INSERT INTO goal_reminders VALUES (1, 0, 1200, 2, 0, 'disabled')",
      "INSERT INTO sync_states VALUES (1, 0, 0, NULL, NULL)",
      "INSERT INTO identity_states VALUES (1, 'guest', 7, NULL)",
      "INSERT INTO planning_profiles VALUES ('guest', 'TEST legacy', 50)",
      "INSERT INTO assistant_sessions (id, owner, title, created_at, updated_at) VALUES ('session', 'guest', 'TEST', 10, 20)",
      "INSERT INTO assistant_messages (id, session_id, owner, role, content, status, created_at) VALUES ('message', 'session', 'guest', 'user', 'TEST private', 'sent', 20)",
      "INSERT INTO assistant_memories (id, owner, category, content, created_at, updated_at) VALUES ('memory', 'guest', '偏好', 'TEST', 10, 20)",
      "INSERT INTO day_records (id, goal_id, owner, day, zone, content, saved_at, draft_text, draft_revision, created_at, updated_at) VALUES ('11111111-1111-4111-8111-111111111111', 1, 'guest', '2026-10-21', 'America/Los_Angeles', 'TEST saved\n😀', 200, 'TEST unsaved', 2, 100, 300)",
      "INSERT INTO record_photos (id, record_id, owner, filename, width, height, byte_count, sha256, saved_position, draft_position, created_at) VALUES ('33333333-3333-4333-8333-333333333333', '11111111-1111-4111-8111-111111111111', 'guest', '33333333-3333-4333-8333-333333333333.jpg', 1600, 1200, 12345, '${'a' * 64}', 0, 0, 200)",
      "INSERT INTO day_analysis_settings VALUES ('guest', 1, 1, 200)",
      "INSERT INTO day_analyses (id, owner, day, zone, request_json, response_json, status, created_at, updated_at) VALUES ('44444444-4444-4444-8444-444444444444', 'guest', '2026-10-21', 'America/Los_Angeles', '{\"TEST\":\"request\"}', '{\"TEST\":\"response\"}', 'succeeded', 200, 300)",
    ]) {
      raw.execute(statement);
    }
    final before = {
      for (final table in raw.select(
        "SELECT name FROM sqlite_schema WHERE type='table' ORDER BY name",
      ))
        table['name'] as String: raw
            .select('SELECT * FROM "${table['name']}" ORDER BY rowid')
            .map((row) => Map<String, Object?>.from(row))
            .toList(),
    };
    final directory = await Directory.systemTemp.createTemp('pairing-v7-');
    final file = File('${directory.path}/sample-v6.sqlite');
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
                  .map((row) => row.data)
                  .toList(),
              withAgentMigrationDefaults(entry.key, entry.value),
              reason: 'open $run, ${entry.key}',
            );
          }
          expect(await db.select(db.pairingStates).get(), isEmpty);
          expect(await db.select(db.pairingCommands).get(), isEmpty);
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

  for (final table in ['pairing_states', 'pairing_commands']) {
    test('unexpected v6 $table fails without changing stored data', () async {
      final schema = await verifier.schemaAt(6);
      schema.rawDatabase.execute('CREATE TABLE $table (id TEXT)');
      schema.rawDatabase.execute("INSERT INTO $table VALUES ('TEST keep')");
      final db = AppDatabase(schema.newConnection());
      try {
        await expectLater(db.select(db.goals).get(), throwsStateError);
        expect(schema.rawDatabase.userVersion, 6);
        expect(
          schema.rawDatabase.select('SELECT * FROM $table').single['id'],
          'TEST keep',
        );
        final other = table == 'pairing_states'
            ? 'pairing_commands'
            : 'pairing_states';
        expect(
          schema.rawDatabase.select(
            'SELECT name FROM sqlite_schema WHERE name=?',
            [other],
          ),
          isEmpty,
        );
      } finally {
        await db.close();
        schema.close();
      }
    });
  }
}
