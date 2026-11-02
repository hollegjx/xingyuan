import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';

import 'generated/schema.dart';

void main() {
  test(
    'v13 to v14 preserves all prior values and requires fresh version3 consent',
    () async {
      final verifier = SchemaVerifier(GeneratedHelper());
      final schema = await verifier.schemaAt(13);
      schema.rawDatabase.execute(
        "INSERT INTO identity_states VALUES (1,'guest',7,NULL)",
      );
      for (final owner in ['guest', 'account:test']) {
        schema.rawDatabase.execute(
          'INSERT INTO assistant_settings VALUES (?,2,42,0,1,0,0,1)',
          [owner],
        );
      }
      final before = {
        for (final row in schema.rawDatabase.select(
          "SELECT name FROM sqlite_schema WHERE type='table' ORDER BY name",
        ))
          row['name'] as String: schema.rawDatabase
              .select('SELECT * FROM "${row['name']}" ORDER BY rowid')
              .map((r) => Map<String, Object?>.from(r))
              .toList(),
      };
      final db = AppDatabase(schema.newConnection());
      try {
        await verifier.migrateAndValidate(
          db,
          14,
          options: const ValidationOptions(validateDropped: true),
        );
        for (final e in before.entries) {
          expect(
            (await db
                    .customSelect('SELECT * FROM "${e.key}" ORDER BY rowid')
                    .get())
                .map((r) => r.data)
                .toList(),
            [
              for (final row in e.value)
                {
                  ...row,
                  if (e.key == 'assistant_settings') ...{
                    'read_journal_on_request': 1,
                    'settings_revision': 0,
                  },
                },
            ],
            reason: e.key,
          );
        }
        expect(
          (await db.select(db.assistantSettings).get()).map(
            (r) => r.consentVersion,
          ),
          everyElement(2),
        );
        expect(
          await db.customSelect('PRAGMA foreign_key_check').get(),
          isEmpty,
        );
      } finally {
        await db.close();
      }
    },
  );
}
