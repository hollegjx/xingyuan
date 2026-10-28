import 'dart:io';

import 'package:drift/native.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';

import '../support/sync_migration_fixture.dart';
import 'generated/schema.dart';

void seedV2(InitializedSchema schema) {
  for (final statement in migrationSeedStatements) {
    schema.rawDatabase.execute(statement);
  }
}

Map<String, List<Map<String, Object?>>> snapshot(InitializedSchema schema) => {
  for (final table in migrationTables)
    table: schema.rawDatabase
        .select('SELECT * FROM $table ORDER BY rowid')
        .map((row) => Map<String, Object?>.from(row))
        .toList(),
};

Future<void> verifyOldValues(
  AppDatabase db,
  Map<String, List<Map<String, Object?>>> before,
) async {
  for (final entry in before.entries) {
    final rows = await db
        .customSelect('SELECT * FROM ${entry.key} ORDER BY rowid')
        .get();
    final originalColumns = entry.value.first.keys;
    expect(
      [
        for (final row in rows)
          {for (final column in originalColumns) column: row.data[column]},
      ],
      entry.value,
      reason: 'Every original column in ${entry.key} must survive',
    );
  }
}

void main() {
  final verifier = SchemaVerifier(GeneratedHelper());

  test('empty v2 keeps deleted-goal autoincrement history', () async {
    final schema = await verifier.schemaAt(2);
    schema.rawDatabase.execute(
      "INSERT INTO goals (id, kind, created_day, created_at) "
      "VALUES (900, 0, '2026-10-10', 9000)",
    );
    schema.rawDatabase.execute('DELETE FROM goals');
    final db = AppDatabase(schema.newConnection());
    try {
      await verifier.migrateAndValidate(db, db.schemaVersion);
      expect(await db.select(db.goals).get(), isEmpty);
      expect(
        await db
            .into(db.goals)
            .insert(
              GoalsCompanion.insert(
                kind: 0,
                createdDay: '2026-10-11',
                createdAt: 11000,
              ),
            ),
        901,
      );
    } finally {
      await db.close();
      schema.close();
    }
  });

  test(
    'v2 upgrade preserves every old column and starts with no uploads',
    () async {
      final schema = await verifier.schemaAt(2);
      seedV2(schema);
      final before = snapshot(schema);
      final db = AppDatabase(schema.newConnection());
      try {
        await verifier.migrateAndValidate(db, db.schemaVersion);
        await verifyOldValues(db, before);
        final goals = await db.select(db.goals).get();
        expect(goals.map((g) => g.globalId).toSet(), hasLength(3));
        for (final goal in goals) {
          expect(
            goal.globalId,
            matches(
              r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
            ),
          );
        }
        final states = await db.select(db.syncStates).get();
        expect(states, hasLength(3));
        expect(
          states.every(
            (row) =>
                row.serverRevision == 0 &&
                row.localRevision == 0 &&
                row.confirmedJson == null &&
                row.lastSyncedAt == null,
          ),
          isTrue,
        );
        expect(await db.select(db.syncOutbox).get(), isEmpty);
        expect(await db.select(db.syncConflicts).get(), isEmpty);
        expect(await db.select(db.guestTransfers).get(), isEmpty);
        final identity = await db.select(db.identityStates).getSingle();
        expect(identity.owner, 'guest');
        expect(identity.generation, 0);
        expect(identity.targetOwner, isNull);
        final occurrences = await db.select(db.reminderOccurrences).get();
        for (final row in occurrences) {
          expect(
            row.owner,
            goals.singleWhere((goal) => goal.id == row.goalId).owner,
          );
        }
        final nextId = await db
            .into(db.goals)
            .insert(
              GoalsCompanion.insert(
                kind: 0,
                createdDay: '2026-10-11',
                createdAt: 11000,
              ),
            );
        expect(
          nextId,
          901,
          reason: 'Do not reuse previously allocated local IDs',
        );
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
    'migration failure rolls back table rebuild and permits repair retry',
    () async {
      final schema = await verifier.schemaAt(2);
      seedV2(schema);
      schema.rawDatabase.execute('PRAGMA foreign_keys = OFF');
      schema.rawDatabase.execute(
        "INSERT INTO reminder_occurrences VALUES "
        "(101, 999, '2026-10-11', 11099, 'Asia/Shanghai', 1, 0)",
      );
      final before = snapshot(schema);
      final db = AppDatabase(schema.newConnection());
      try {
        await expectLater(db.select(db.goals).get(), throwsException);
      } finally {
        await db.close();
      }
      try {
        expect(schema.rawDatabase.userVersion, 2);
        expect(snapshot(schema), before);
        expect(
          schema.rawDatabase
              .select('PRAGMA table_info(goals)')
              .any((row) => row['name'] == 'global_id'),
          isFalse,
        );
        expect(
          schema.rawDatabase.select(
            "SELECT name FROM sqlite_master WHERE name = 'sync_outbox'",
          ),
          isEmpty,
        );
        // Repair only the deliberately corrupt synthetic fixture.
        schema.rawDatabase.execute(
          'DELETE FROM reminder_occurrences WHERE goal_id = 999',
        );
        final retried = AppDatabase(schema.newConnection());
        try {
          await verifier.migrateAndValidate(retried, retried.schemaVersion);
          expect(await retried.select(retried.goals).get(), hasLength(3));
          expect(await retried.select(retried.syncOutbox).get(), isEmpty);
        } finally {
          await retried.close();
        }
      } finally {
        schema.close();
      }
    },
  );

  test(
    'file-backed v2 upgrade keeps UUIDs and old data over a new connection',
    () async {
      final directory = await Directory.systemTemp.createTemp('habit-sync-v3-');
      final file = File('${directory.path}/upgrade.sqlite');
      final schema = await verifier.schemaAt(2);
      seedV2(schema);
      final before = snapshot(schema);
      schema.rawDatabase.execute('VACUUM INTO ?', [file.path]);
      schema.close();
      try {
        final first = AppDatabase(NativeDatabase(file));
        late List<String> globalIds;
        try {
          await verifyOldValues(first, before);
          globalIds = (await first.select(first.goals).get())
              .map((row) => row.globalId)
              .toList();
        } finally {
          await first.close();
        }
        final reopened = AppDatabase(NativeDatabase(file));
        try {
          await verifyOldValues(reopened, before);
          expect(
            (await reopened.select(reopened.goals).get()).map(
              (row) => row.globalId,
            ),
            globalIds,
          );
          expect(await reopened.select(reopened.syncOutbox).get(), isEmpty);
          expect(
            await reopened.customSelect('PRAGMA foreign_key_check').get(),
            isEmpty,
          );
        } finally {
          await reopened.close();
        }
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );
}
