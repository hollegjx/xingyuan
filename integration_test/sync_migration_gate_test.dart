import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/open_database.dart';
import 'package:integration_test/integration_test.dart';

import '../test/drift/generated/schema_v2.dart' as v2;
import '../test/support/sync_migration_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('v2 seed, current upgrade and reopen in separate iOS processes', (
    tester,
  ) async {
    const phase = String.fromEnvironment('SYNC_MIGRATION_PHASE');
    const run = String.fromEnvironment('SYNC_MIGRATION_RUN');
    expect(phase, anyOf('seed', 'upgrade', 'reopen'));
    expect(RegExp(r'^[a-zA-Z0-9-]+$').hasMatch(run), isTrue);
    final name = 'habit_checkin_sync_migration_$run';
    if (phase == 'seed') {
      final db = v2.DatabaseAtV2(driftDatabase(name: name));
      try {
        expect(
          await db.customSelect('SELECT * FROM goals').get(),
          isEmpty,
          reason: 'Use a fresh token; do not replace existing data',
        );
        await db.transaction(() async {
          for (final statement in migrationSeedStatements) {
            await db.customStatement(statement);
          }
          final before = <String, Object?>{};
          for (final table in migrationTables) {
            before[table] =
                (await db
                        .customSelect('SELECT * FROM $table ORDER BY rowid')
                        .get())
                    .map((row) => row.data)
                    .toList();
          }
          await db.customStatement(
            'CREATE TABLE migration_probe (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
          );
          await db.customStatement(
            'INSERT INTO migration_probe VALUES (?, ?)',
            ['before', jsonEncode(before)],
          );
        });
        expect(
          (await db.customSelect('PRAGMA user_version').getSingle()).read<int>(
            'user_version',
          ),
          2,
        );
      } finally {
        await db.close();
      }
    } else {
      final db = openAppDatabase(name: name);
      try {
        final stored = await db
            .customSelect(
              "SELECT value FROM migration_probe WHERE key = 'before'",
            )
            .getSingle();
        final before =
            jsonDecode(stored.read<String>('value')) as Map<String, dynamic>;
        for (final table in migrationTables) {
          final expected = before[table] as List<dynamic>;
          final columns = (expected.first as Map<String, dynamic>).keys;
          final rows = await db
              .customSelect('SELECT * FROM $table ORDER BY rowid')
              .get();
          expect(
            [
              for (final row in rows)
                {for (final column in columns) column: row.data[column]},
            ],
            expected,
            reason: 'Original values in $table',
          );
        }
        expect(
          (await db.customSelect('PRAGMA user_version').getSingle()).read<int>(
            'user_version',
          ),
          db.schemaVersion,
        );
        final goals = await (db.select(
          db.goals,
        )..orderBy([(row) => OrderingTerm.asc(row.id)])).get();
        final ids = goals.map((row) => row.globalId).toList();
        expect(ids.toSet(), hasLength(3));
        for (final id in ids) {
          expect(
            id,
            matches(
              r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
            ),
          );
        }
        expect(await db.select(db.syncOutbox).get(), isEmpty);
        expect(
          (await db.select(db.syncStates).get()).every(
            (row) => row.serverRevision == 0 && row.localRevision == 0,
          ),
          isTrue,
        );
        for (final row in await db.select(db.reminderOccurrences).get()) {
          expect(row.owner, goals.singleWhere((g) => g.id == row.goalId).owner);
        }
        expect(
          await db.customSelect('PRAGMA foreign_key_check').get(),
          isEmpty,
        );
        if (phase == 'upgrade') {
          await db.customStatement(
            'INSERT INTO migration_probe VALUES (?, ?)',
            ['global_ids', jsonEncode(ids)],
          );
        } else {
          final saved = await db
              .customSelect(
                "SELECT value FROM migration_probe WHERE key = 'global_ids'",
              )
              .getSingle();
          expect(ids, jsonDecode(saved.read<String>('value')));
        }
        // Synthetic counts only; never print stored personal content.
        // ignore: avoid_print
        print(
          'SYNC_MIGRATION phase=$phase v${db.schemaVersion} goals=${goals.length} oldTables=6 preserved=true outbox=0',
        );
      } finally {
        await db.close();
      }
    }
  });
}
