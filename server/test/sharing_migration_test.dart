import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:xingyuan_server/src/companion_store.dart';

void main() {
  late Directory directory;
  late String path;
  const a = '00000000-0000-4000-8000-000000000001';
  const b = '00000000-0000-4000-8000-000000000002';
  const group = '00000000-0000-4000-8000-000000000003';
  const tables = [
    'members',
    'companion_groups',
    'group_members',
    'invitations',
    'pairing_operations',
    'join_failures',
  ];
  Map<String, List<Map<String, Object?>>> snapshot(Database db) => {
    for (final table in tables)
      table: db
          .select(
            table == 'companion_groups'
                ? 'SELECT id,created_at,closed_at FROM companion_groups ORDER BY rowid'
                : 'SELECT * FROM $table ORDER BY rowid',
          )
          .map((r) => Map<String, Object?>.from(r))
          .toList(),
  };
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('sharing-migration-');
    path = '${directory.path}/v1.db';
    final db = sqlite3.open(path);
    try {
      db.execute(
        File('test/fixtures/companion_schema_v1.sql').readAsStringSync(),
      );
      db.execute('PRAGMA application_id=1481065296');
      db.userVersion = 1;
      db.execute('INSERT INTO members VALUES (?,?,?), (?,?,?)', [
        a,
        'qa-a',
        1,
        b,
        'qa-b',
        2,
      ]);
      db.execute('INSERT INTO companion_groups VALUES (?,?,NULL)', [group, 3]);
      db.execute(
        'INSERT INTO group_members VALUES (?,?,?,NULL), (?,?,?,NULL)',
        [group, a, 3, group, b, 3],
      );
      db.execute("INSERT INTO invitations VALUES (?,?,NULL,?,'used',?,?,?)", [
        'old-invite',
        a,
        'synthetic-hash',
        1,
        900,
        b,
      ]);
      db.execute(
        "INSERT INTO pairing_operations VALUES (?,?,?,'join',?,200,NULL,NULL,?)",
        [b, 'old-operation', 'synthetic-fingerprint', group, 3],
      );
      db.execute('INSERT INTO join_failures VALUES (?,?,?)', [
        a,
        'old-failure',
        4,
      ]);
    } finally {
      db.close();
    }
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test(
    'frozen v1 upgrade preserves every old row and stable pair on reopen',
    () {
      final beforeDb = sqlite3.open(path, mode: OpenMode.readOnly);
      final before = snapshot(beforeDb);
      beforeDb.close();
      for (var i = 0; i < 2; i++) {
        final store = CompanionStore.open(path);
        expect(store.state('qa-a').group!.id, group);
        expect(store.state('qa-b').memberId, b);
        store.close();
        final db = sqlite3.open(path, mode: OpenMode.readOnly);
        try {
          expect(db.userVersion, 4);
          expect(snapshot(db), before);
          expect(db.select('PRAGMA foreign_key_check'), isEmpty);
          expect(
            db.select('PRAGMA integrity_check').single.values.single,
            'ok',
          );
          expect(db.select('SELECT * FROM sharing_grants'), isEmpty);
        } finally {
          db.close();
        }
      }
    },
  );

  test(
    'conflicting sharing table rolls migration back without modifying old file',
    () {
      final db = sqlite3.open(path);
      db.execute('CREATE TABLE sharing_grants (private_value TEXT)');
      db.execute("INSERT INTO sharing_grants VALUES ('preserve')");
      db.close();
      final before = File(path).readAsBytesSync();
      expect(() => CompanionStore.open(path), throwsA(isA<SqliteException>()));
      expect(File(path).readAsBytesSync(), before);
      final after = sqlite3.open(path, mode: OpenMode.readOnly);
      expect(after.userVersion, 1);
      expect(
        after.select('SELECT * FROM sharing_grants').single['private_value'],
        'preserve',
      );
      after.close();
    },
  );

  test('broken v1 foreign keys are rejected before any migration writes', () {
    final db = sqlite3.open(path);
    db.execute('INSERT INTO group_members VALUES (?,?,?,NULL)', [
      'missing-group',
      'missing-member',
      5,
    ]);
    db.close();
    final before = File(path).readAsBytesSync();
    expect(() => CompanionStore.open(path), throwsFormatException);
    expect(File(path).readAsBytesSync(), before);
    final after = sqlite3.open(path, mode: OpenMode.readOnly);
    expect(after.userVersion, 1);
    after.close();
  });
}
