import 'dart:io';

import 'package:drift/native.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/features/assistant/data/local_memory_store.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import '../support/test_clock.dart';
import 'generated/schema.dart';
import 'migration_defaults.dart';

void main() {
  final verifier = SchemaVerifier(GeneratedHelper());
  setUpAll(tzdata.initializeTimeZones);

  test('populated v12 upgrades and reopens with exact old values and explicit Agent defaults', () async {
    final schema = await verifier.schemaAt(12);
    final raw = schema.rawDatabase;
    raw.execute("INSERT INTO identity_states VALUES (1,'guest',7,NULL)");
    for (final owner in ['guest', 'account:test']) {
      raw.execute('INSERT INTO assistant_settings VALUES (?,1,42,0,1,0,0)', [
        owner,
      ]);
      raw.execute(
        "INSERT INTO assistant_sessions VALUES (?,?,'TEST title','TEST summary',NULL,1,2)",
        ['s-$owner', owner],
      );
      raw.execute(
        "INSERT INTO assistant_messages (id,session_id,owner,role,content,status,request_id,sent_payload,created_at) VALUES (?,?,?,'assistant','TEST body','sent','TEST request','{}',3)",
        ['m-$owner', 's-$owner', owner],
      );
      raw.execute(
        "INSERT INTO plan_proposals (id,owner,session_id,message_id,items_json) VALUES (?,?,?,?,'[]')",
        ['p-$owner', owner, 's-$owner', 'm-$owner'],
      );
      raw.execute(
        "INSERT INTO assistant_diary_proposals (id,owner,session_id,message_id,content) VALUES (?,?,?,?,'TEST private draft')",
        ['d-$owner', owner, 's-$owner', 'm-$owner'],
      );
    }
    final before = {
      for (final row in raw.select(
        "SELECT name FROM sqlite_schema WHERE type='table' ORDER BY name",
      ))
        row['name'] as String: raw
            .select('SELECT * FROM "${row['name']}" ORDER BY rowid')
            .map((row) => Map<String, Object?>.from(row))
            .toList(),
    };
    final directory = await Directory.systemTemp.createTemp(
      'agent-v13-synthetic-',
    );
    final file = File('${directory.path}/test.sqlite');
    raw.execute('VACUUM INTO ?', [file.path]);
    schema.close();
    try {
      for (var open = 0; open < 2; open++) {
        final db = AppDatabase(NativeDatabase(file));
        try {
          await verifier.migrateAndValidate(
            db,
            db.schemaVersion,
            options: const ValidationOptions(validateDropped: true),
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
              reason: 'open $open ${entry.key}',
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
      final db = AppDatabase(NativeDatabase(file));
      try {
        await LocalMemoryStore(LocalGoalRepository(db, TestClock()))
            .updateSettings(agentEnabled: false);
        final rows = await db
            .customSelect(
              'SELECT owner,agent_enabled,send_memories,send_stats,auto_memory FROM assistant_settings ORDER BY owner',
            )
            .get();
        expect(rows.map((row) => row.data).toList(), [
          {
            'owner': 'account:test',
            'agent_enabled': 1,
            'send_memories': 0,
            'send_stats': 0,
            'auto_memory': 0,
          },
          {
            'owner': 'guest',
            'agent_enabled': 0,
            'send_memories': 0,
            'send_stats': 0,
            'auto_memory': 0,
          },
        ]);
      } finally {
        await db.close();
      }
      final reopened = AppDatabase(NativeDatabase(file));
      try {
        expect(
          (await LocalMemoryStore(
            LocalGoalRepository(reopened, TestClock()),
          ).settings()).agentEnabled,
          isFalse,
        );
      } finally {
        await reopened.close();
      }
    } finally {
      await directory.delete(recursive: true);
    }
  });

  for (final table in [
    'assistant_settings',
    'assistant_messages',
    'plan_proposals',
  ]) {
    test(
      'failure after adding $table column rolls back schema and preserves synthetic data',
      () async {
        final schema = await verifier.schemaAt(12);
        addTearDown(schema.close);
        schema.rawDatabase.execute(
          "INSERT INTO planning_profiles VALUES ('guest','TEST preserve',5)",
        );
        final failed = _FailAgentColumn(schema.newConnection(), table);
        await expectLater(failed.select(failed.goals).get(), throwsStateError);
        expect(schema.rawDatabase.userVersion, 12);
        for (final name in [
          'assistant_settings',
          'assistant_messages',
          'plan_proposals',
        ]) {
          expect(
            schema.rawDatabase
                .select('PRAGMA table_info($name)')
                .map((row) => row['name']),
            isNot(
              contains(
                name == 'assistant_settings'
                    ? 'agent_enabled'
                    : 'agent_metadata',
              ),
            ),
          );
        }
        expect(
          schema.rawDatabase
              .select('SELECT preferences FROM planning_profiles')
              .single['preferences'],
          'TEST preserve',
        );
        await failed.close();
        final retry = AppDatabase(schema.newConnection());
        try {
          await verifier.migrateAndValidate(retry, retry.schemaVersion);
          expect(
            (await retry.select(retry.planningProfiles).getSingle())
                .preferences,
            'TEST preserve',
          );
        } finally {
          await retry.close();
        }
      },
    );
  }
}

class _FailAgentColumn extends AppDatabase {
  _FailAgentColumn(super.executor, this.table);
  final String table;
  @override
  Future<void> customStatement(String statement, [List<Object?>? args]) async {
    await super.customStatement(statement, args);
    if (statement.startsWith('ALTER TABLE "$table" ADD COLUMN')) {
      throw StateError('TEST interrupted Agent migration');
    }
  }
}
