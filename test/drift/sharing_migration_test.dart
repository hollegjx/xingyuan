import 'dart:io';

import 'package:drift/native.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';

import 'generated/schema.dart';

const _sharingTables = [
  'sharing_states',
  'sharing_grants_cache',
  'shared_records_cache',
  'shared_replies_cache',
  'sharing_drafts',
  'sharing_commands',
];

void main() {
  final verifier = SchemaVerifier(GeneratedHelper());
  test('v7 sharing migration preserves every old table through reopen', () async {
    final schema = await verifier.schemaAt(7);
    final raw = schema.rawDatabase;
    for (final sql in [
      "INSERT INTO goals VALUES (1, '22222222-2222-4222-8222-222222222222', 'guest', 0, '2026-10-20', 100, NULL, NULL)",
      "INSERT INTO goal_titles VALUES (1, '2026-10-20', 'SYNTHETIC private')",
      "INSERT INTO goal_schedules VALUES (1, '2026-10-20', 127, NULL, 1140, 30)",
      "INSERT INTO check_ins VALUES (1, 0, '2026-10-21', 1, '2026-10-21', 200, 'America/Los_Angeles', 'SYNTHETIC original', NULL)",
      "INSERT INTO identity_states VALUES (1, 'guest', 7, NULL)",
      "INSERT INTO day_records (id, goal_id, owner, day, zone, content, saved_at, draft_text, draft_revision, created_at, updated_at) VALUES ('11111111-1111-4111-8111-111111111111', 1, 'guest', '2026-10-21', 'America/Los_Angeles', 'SYNTHETIC saved', 200, 'SYNTHETIC draft', 2, 100, 300)",
      "INSERT INTO record_photos (id, record_id, owner, filename, width, height, byte_count, sha256, saved_position, draft_position, created_at) VALUES ('33333333-3333-4333-8333-333333333333', '11111111-1111-4111-8111-111111111111', 'guest', '33333333-3333-4333-8333-333333333333.jpg', 1600, 1200, 12345, '${'a' * 64}', 0, 0, 200)",
      "INSERT INTO day_analysis_settings VALUES ('guest', 1, 1, 200)",
      "INSERT INTO pairing_states (owner, credential_scope, generation, state_json, state_revision, refreshed_at, draft_code, draft_revision) VALUES ('guest', '${'a' * 64}', 2, '{}', 5, 200, 'SYNTHETIC draft', 3)",
      "INSERT INTO pairing_commands (owner, operation_id, generation, kind, request_json, status, error_code, attempts, base_state_revision, base_draft_revision, started_at, updated_at) VALUES ('guest', '44444444-4444-4444-8444-444444444444', 2, 'join', '{}', 'uncertain', 'interrupted', 1, 5, 3, 200, 300)",
    ]) {
      raw.execute(sql);
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
    final directory = await Directory.systemTemp.createTemp('sharing-v8-');
    final file = File('${directory.path}/sample-v7.sqlite');
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
              entry.value,
              reason: 'open $run, ${entry.key}',
            );
          }
          for (final table in _sharingTables) {
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

  for (final table in _sharingTables) {
    test(
      'unexpected v7 $table rolls back without changing the old schema',
      () async {
        final schema = await verifier.schemaAt(7);
        schema.rawDatabase.execute('CREATE TABLE $table (id TEXT)');
        schema.rawDatabase.execute(
          "INSERT INTO $table VALUES ('SYNTHETIC keep')",
        );
        final db = AppDatabase(schema.newConnection());
        try {
          await expectLater(db.select(db.goals).get(), throwsStateError);
          expect(schema.rawDatabase.userVersion, 7);
          expect(
            schema.rawDatabase.select('SELECT * FROM $table').single['id'],
            'SYNTHETIC keep',
          );
          for (final other in _sharingTables.where((name) => name != table)) {
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

  test(
    'corrupt v7 references are rejected before additive migration',
    () async {
      final schema = await verifier.schemaAt(7);
      schema.rawDatabase.execute('PRAGMA foreign_keys=OFF');
      schema.rawDatabase.execute(
        "INSERT INTO goal_titles VALUES (99, '2026-10-21', 'SYNTHETIC orphan')",
      );
      final db = AppDatabase(schema.newConnection());
      try {
        await expectLater(db.select(db.goals).get(), throwsStateError);
        expect(schema.rawDatabase.userVersion, 7);
        for (final table in _sharingTables) {
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
    },
  );
}
