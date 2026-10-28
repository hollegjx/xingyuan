import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';

import 'generated/schema.dart';
import 'migration_defaults.dart';

void main() {
  final verifier = SchemaVerifier(GeneratedHelper());
  test('v11 to current keeps every old table value, including private drafts/photos', () async {
    final schema = await verifier.schemaAt(11);
    addTearDown(schema.close);
    final raw = schema.rawDatabase;
    const id = '11111111-1111-4111-8111-111111111111';
    const photo = '22222222-2222-4222-8222-222222222222';
    raw.execute("INSERT INTO identity_states VALUES (1,'guest',3,NULL)");
    raw.execute(
      "INSERT INTO diary_entries (id,owner,day,zone,content,saved_at,draft_text,created_at,updated_at) VALUES ('$id','guest','2026-10-24','Asia/Shanghai','SYNTHETIC saved',2,'SYNTHETIC draft',1,3)",
    );
    raw.execute(
      "INSERT INTO diary_photos (id,entry_id,owner,filename,width,height,byte_count,sha256,saved_position,draft_position,created_at) VALUES ('$photo','$id','guest','$photo.jpg',10,10,100,'${'a' * 64}',0,0,2)",
    );
    raw.execute(
      "INSERT INTO assistant_sessions (id,owner,title,created_at,updated_at) VALUES ('s','guest','SYNTHETIC session',1,1)",
    );
    raw.execute(
      "INSERT INTO assistant_messages (id,session_id,owner,role,content,status,created_at) VALUES ('m','s','guest','user','SYNTHETIC chat','sent',1)",
    );
    final before = {
      for (final row in raw.select(
        "SELECT name FROM sqlite_schema WHERE type='table' ORDER BY name",
      ))
        row['name'] as String: raw
            .select('SELECT * FROM "${row['name']}" ORDER BY rowid')
            .map((r) => Map<String, Object?>.from(r))
            .toList(),
    };
    final db = AppDatabase(schema.newConnection());
    addTearDown(db.close);
    await verifier.migrateAndValidate(
      db,
      db.schemaVersion,
      options: const ValidationOptions(validateDropped: true),
    );
    for (final table in before.entries) {
      expect(
        (await db
                .customSelect('SELECT * FROM "${table.key}" ORDER BY rowid')
                .get())
            .map((r) => r.data)
            .toList(),
        withAgentMigrationDefaults(table.key, table.value),
        reason: table.key,
      );
    }
    expect(await db.select(db.assistantDiaryProposals).get(), isEmpty);
    expect(await db.customSelect('PRAGMA foreign_key_check').get(), isEmpty);
  });

  test(
    'unexpected v11 proposal table does not change data or version',
    () async {
      final schema = await verifier.schemaAt(11);
      addTearDown(schema.close);
      schema.rawDatabase.execute(
        'CREATE TABLE assistant_diary_proposals (id TEXT)',
      );
      schema.rawDatabase.execute(
        "INSERT INTO assistant_diary_proposals VALUES ('SYNTHETIC preserve')",
      );
      final db = AppDatabase(schema.newConnection());
      addTearDown(db.close);
      await expectLater(db.select(db.goals).get(), throwsStateError);
      expect(schema.rawDatabase.userVersion, 11);
      expect(
        schema.rawDatabase
            .select('SELECT * FROM assistant_diary_proposals')
            .single['id'],
        'SYNTHETIC preserve',
      );
    },
  );

  test('failure after creating proposal table rolls back additive migration', () async {
    final schema = await verifier.schemaAt(11);
    addTearDown(schema.close);
    schema.rawDatabase.execute(
      "INSERT INTO planning_profiles VALUES ('guest','SYNTHETIC keep',4)",
    );
    final failed = _FailProposalCreation(schema.newConnection());
    await expectLater(failed.select(failed.goals).get(), throwsStateError);
    expect(schema.rawDatabase.userVersion, 11);
    expect(
      schema.rawDatabase.select(
        "SELECT name FROM sqlite_schema WHERE name='assistant_diary_proposals'",
      ),
      isEmpty,
    );
    expect(
      schema.rawDatabase
          .select('SELECT * FROM planning_profiles')
          .single['preferences'],
      'SYNTHETIC keep',
    );
    await failed.close();
    final retry = AppDatabase(schema.newConnection());
    addTearDown(retry.close);
    await verifier.migrateAndValidate(retry, retry.schemaVersion);
    expect(
      (await retry.select(retry.planningProfiles).getSingle()).preferences,
      'SYNTHETIC keep',
    );
  });
}

class _FailProposalCreation extends AppDatabase {
  _FailProposalCreation(super.executor);
  @override
  Future<void> customStatement(String statement, [List<Object?>? args]) async {
    await super.customStatement(statement, args);
    if (statement.startsWith(
      'CREATE TABLE IF NOT EXISTS "assistant_diary_proposals"',
    )) {
      throw StateError('Synthetic migration interruption');
    }
  }
}
