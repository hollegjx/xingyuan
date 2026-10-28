import 'dart:io';

import 'package:drift/native.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';

import 'generated/schema.dart';
import 'migration_defaults.dart';

const _record = '11111111-1111-4111-8111-111111111111';

Future<void> _goal(AppDatabase db) => db.customStatement(
  "INSERT INTO goals (id, global_id, owner, kind, created_day, created_at) "
  "VALUES (1, '22222222-2222-4222-8222-222222222222', 'guest', 0, "
  "'2026-10-20', 100)",
);

Future<void> _insertRecord(
  AppDatabase db, {
  String id = _record,
  String owner = 'guest',
  String day = '2026-10-21',
}) => db.customStatement(
  'INSERT INTO day_records (id, goal_id, owner, day, created_at, updated_at) '
  'VALUES (?, 1, ?, ?, 100, 100)',
  [id, owner, day],
);

Future<void> _photo(
  AppDatabase db,
  int number, {
  String owner = 'guest',
  int? position,
  int bytes = 100,
  int width = 1600,
  String? filename,
}) => db.customStatement(
  'INSERT INTO record_photos '
  '(id, record_id, owner, filename, width, height, byte_count, sha256, '
  'saved_position, created_at) VALUES (?, ?, ?, ?, ?, 900, ?, ?, ?, 100)',
  [
    '33333333-3333-4333-8333-${number.toString().padLeft(12, '0')}',
    _record,
    owner,
    filename ??
        '33333333-3333-4333-8333-${number.toString().padLeft(12, '0')}.jpg',
    width,
    bytes,
    'a' * 64,
    position ?? number,
  ],
);

void main() {
  final verifier = SchemaVerifier(GeneratedHelper());

  test(
    'analysis consent is not pre-granted and result states are consistent',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await db.customStatement(
        "INSERT INTO day_analysis_settings (owner) VALUES ('guest')",
      );
      final settings =
          (await db
                  .customSelect('SELECT * FROM day_analysis_settings')
                  .getSingle())
              .data;
      expect(settings['consent_version'], 0);
      expect(settings['consented_at'], isNull);
      await expectLater(
        db.customStatement(
          'UPDATE day_analysis_settings SET consent_version = 1',
        ),
        throwsException,
      );
      await db.customStatement(
        "INSERT INTO day_analyses (id, owner, day, zone, request_json, created_at, updated_at) VALUES (?, 'guest', '2026-10-21', 'Asia/Shanghai', '{}', 1, 1)",
        [_record],
      );
      await expectLater(
        db.customStatement("UPDATE day_analyses SET status='succeeded'"),
        throwsException,
      );
      await expectLater(
        db.customStatement("UPDATE day_analyses SET status='failed'"),
        throwsException,
      );
      await db.customStatement(
        "UPDATE day_analyses SET status='succeeded', response_json='{}'",
      );
    },
  );

  test(
    'unexpected v5 record table fails without changing the old database',
    () async {
      final schema = await verifier.schemaAt(5);
      schema.rawDatabase.execute('CREATE TABLE record_photos (id TEXT)');
      schema.rawDatabase.execute(
        "INSERT INTO record_photos VALUES ('TEST keep')",
      );
      final db = AppDatabase(schema.newConnection());
      try {
        await expectLater(db.select(db.goals).get(), throwsStateError);
        expect(schema.rawDatabase.userVersion, 5);
        expect(
          schema.rawDatabase.select('SELECT * FROM record_photos').single['id'],
          'TEST keep',
        );
        expect(
          schema.rawDatabase.select(
            "SELECT name FROM sqlite_schema WHERE name='day_records'",
          ),
          isEmpty,
        );
      } finally {
        await db.close();
        schema.close();
      }
    },
  );

  test(
    'v5 file upgrade preserves every old table and reopens as current',
    () async {
      final schema = await verifier.schemaAt(5);
      final raw = schema.rawDatabase;
      for (final statement in [
        "INSERT INTO goals VALUES (1, '22222222-2222-4222-8222-222222222222', 'guest', 0, '2026-10-20', 100, NULL, NULL)",
        "INSERT INTO goal_titles VALUES (1, '2026-10-20', 'TEST record migration')",
        "INSERT INTO goal_schedules VALUES (1, '2026-10-20', 127, NULL, 1140, 30)",
        "INSERT INTO check_ins VALUES (1, 0, '2026-10-20', 1, '2026-10-20', 200, 'America/Los_Angeles', 'TEST original title', NULL)",
        "INSERT INTO goal_reminders VALUES (1, 0, 1200, 2, 0, 'disabled')",
        "INSERT INTO sync_states VALUES (1, 0, 0, NULL, NULL)",
        "INSERT INTO identity_states VALUES (1, 'guest', 7, NULL)",
        "INSERT INTO planning_profiles VALUES ('guest', 'TEST legacy remains', 50)",
        "INSERT INTO assistant_sessions (id, owner, title, created_at, updated_at) VALUES ('session', 'guest', 'TEST', 10, 20)",
        "INSERT INTO assistant_messages (id, session_id, owner, role, content, status, created_at) VALUES ('message', 'session', 'guest', 'user', 'TEST only', 'sent', 20)",
        "INSERT INTO assistant_memories (id, owner, category, content, created_at, updated_at) VALUES ('memory', 'guest', '偏好', 'TEST', 10, 20)",
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
      final directory = await Directory.systemTemp.createTemp('day-record-v6-');
      final file = File('${directory.path}/sample-v5.sqlite');
      raw.execute('VACUUM INTO ?', [file.path]);
      schema.close();
      try {
        for (var run = 0; run < 2; run++) {
          final db = AppDatabase(NativeDatabase(file));
          try {
            expect(
              (await db.customSelect('PRAGMA user_version').getSingle())
                  .read<int>('user_version'),
              db.schemaVersion,
            );
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
                reason: entry.key,
              );
            }
            expect(
              await db.customSelect('SELECT * FROM day_records').get(),
              isEmpty,
            );
            expect(
              await db.customSelect('SELECT * FROM record_photos').get(),
              isEmpty,
            );
            expect(
              await db.customSelect('SELECT * FROM day_analyses').get(),
              isEmpty,
            );
            expect(
              await db
                  .customSelect('SELECT * FROM day_analysis_settings')
                  .get(),
              isEmpty,
            );
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
    },
  );

  test(
    'records are private local drafts and independent of check-ins',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await _goal(db);
      await _insertRecord(db);
      final row =
          (await db.customSelect('SELECT * FROM day_records').getSingle()).data;
      expect(row['share_with_partner'], 0);
      expect(row['sync_state'], 'local');
      expect(row['revision'], 0);
      expect(row['draft_text'], isNull);
      expect(await db.select(db.checkIns).get(), isEmpty);
    },
  );

  test('goal and photo composite references reject another owner', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await _goal(db);
    await expectLater(_insertRecord(db, owner: 'other'), throwsException);
    await _insertRecord(db);
    await expectLater(_photo(db, 0, owner: 'other'), throwsException);
    await _photo(db, 0);
    expect(await db.customSelect('PRAGMA foreign_key_check').get(), isEmpty);
  });

  test(
    'one record per goal day and at most three saved or draft photos',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await _goal(db);
      await _insertRecord(db);
      await expectLater(
        _insertRecord(db, id: '44444444-4444-4444-8444-444444444444'),
        throwsException,
      );
      for (var slot = 0; slot < 3; slot++) {
        await _photo(db, slot);
      }
      await expectLater(_photo(db, 3), throwsException);
      await expectLater(_photo(db, 4, position: 0), throwsException);
      await db.customStatement(
        'UPDATE record_photos SET draft_position = saved_position',
      );
      await expectLater(
        db.customStatement('UPDATE record_photos SET draft_position = 3'),
        throwsException,
      );
      await expectLater(
        db.customStatement('UPDATE record_photos SET draft_position = 0'),
        throwsException,
      );
    },
  );

  test(
    'photo metadata rejects oversized dimensions bytes and unsafe filenames',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await _goal(db);
      await _insertRecord(db);
      await expectLater(_photo(db, 0, width: 1601), throwsException);
      await expectLater(
        _photo(db, 0, bytes: 2 * 1024 * 1024 + 1),
        throwsException,
      );
      await expectLater(
        _photo(db, 0, filename: '../private.jpg'),
        throwsException,
      );
      await expectLater(_photo(db, 0, filename: 'photo.png'), throwsException);
      await _photo(db, 0, bytes: 2 * 1024 * 1024);
    },
  );
}
