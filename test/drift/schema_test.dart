import 'package:drift/native.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';

import 'generated/schema.dart';

class FutureDatabase extends AppDatabase {
  FutureDatabase(super.executor);

  @override
  int get schemaVersion => super.schemaVersion + 1;
}

void main() {
  final verifier = SchemaVerifier(GeneratedHelper());

  test('fresh database matches the committed v9 snapshot', () async {
    final db = AppDatabase(NativeDatabase.memory());
    try {
      await verifier.migrateAndValidate(
        db,
        db.schemaVersion,
        options: const ValidationOptions(validateDropped: true),
      );
    } finally {
      await db.close();
    }
  });

  test('migrating v1 directly to v9 preserves data and constraints', () async {
    final schema = await verifier.schemaAt(1);
    schema.rawDatabase.execute(
      "INSERT INTO goals (id, kind, created_day, created_at) "
      "VALUES (1, 1, '2026-10-09', 123)",
    );
    for (final statement in [
      "INSERT INTO goal_titles VALUES (1, '2026-10-09', 'TEST migration')",
      "INSERT INTO goal_schedules VALUES (1, '2026-10-09', 0, '2026-10-09')",
      "INSERT INTO check_ins VALUES "
          "(1, 1, 'once', 1, '2026-10-09', 456, 'Asia/Shanghai', "
          "'TEST original title', '2026-10-09')",
      "INSERT INTO goal_reminders VALUES (1, 1, 1200, 4, 1, 'pending')",
    ]) {
      schema.rawDatabase.execute(statement);
    }
    final before = {
      for (final table in [
        'goals',
        'goal_titles',
        'goal_schedules',
        'check_ins',
        'goal_reminders',
      ])
        table: schema.rawDatabase
            .select('SELECT * FROM $table')
            .map((row) => Map<String, Object?>.from(row))
            .toList(),
    };
    final db = AppDatabase(schema.newConnection());
    try {
      await verifier.migrateAndValidate(db, db.schemaVersion);
      for (final entry in before.entries) {
        final after = await db.customSelect('SELECT * FROM ${entry.key}').get();
        final originalColumns = entry.value.first.keys;
        expect(
          after
              .map(
                (row) => {
                  for (final column in originalColumns)
                    column: row.data[column],
                },
              )
              .toList(),
          entry.value,
        );
      }
      expect(await db.select(db.reminderOccurrences).get(), isEmpty);
      expect(await db.customSelect('PRAGMA foreign_key_check').get(), isEmpty);
    } finally {
      await db.close();
      schema.close();
    }
  });

  test('unsupported version fails without dropping stored data', () async {
    final schema = await verifier.schemaAt(1);
    schema.rawDatabase.execute(
      "INSERT INTO goals (id, kind, created_day, created_at) "
      "VALUES (1, 1, '2026-10-09', 123)",
    );
    final db = FutureDatabase(schema.newConnection());
    try {
      await expectLater(db.select(db.goals).get(), throwsStateError);
      expect(
        schema.rawDatabase
            .select('SELECT created_at FROM goals')
            .single['created_at'],
        123,
      );
      expect(schema.rawDatabase.userVersion, 1);
    } finally {
      await db.close();
      schema.close();
    }
  });
}
