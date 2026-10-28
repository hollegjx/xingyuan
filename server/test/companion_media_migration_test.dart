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
  const grant = '00000000-0000-4000-8000-000000000004';
  const record = '00000000-0000-4000-8000-000000000005';
  Map<String, Object?> snapshot(Database db) => {
    for (final table in db.select(
      "SELECT name FROM sqlite_schema WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
    ))
      table['name'] as String: db
          .select('SELECT * FROM "${table['name']}" ORDER BY rowid')
          .map((row) => Map<String, Object?>.from(row))
          .toList(),
  };
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('media-migration-');
    path = '${directory.path}/data.db';
    final db = sqlite3.open(path);
    try {
      db.execute(
        File('test/fixtures/companion_schema_v2.sql').readAsStringSync(),
      );
      db.execute('PRAGMA application_id=1481065296');
      db.userVersion = 2;
      db.execute('INSERT INTO members VALUES (?,?,?), (?,?,?)', [
        a,
        'qa-a',
        1,
        b,
        'qa-b',
        2,
      ]);
      db.execute('INSERT INTO companion_groups VALUES (?,?,NULL,?)', [
        group,
        3,
        7,
      ]);
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
      db.execute('INSERT INTO sharing_grants VALUES (1,?,?,?,?,?,NULL)', [
        grant,
        group,
        a,
        '00000000-0000-4000-8000-000000000006',
        4,
      ]);
      db.execute(
        "INSERT INTO shared_records VALUES (1,?,?,?,?,1,'SYNTHETIC',5,NULL,'SYNTHETIC TEXT','[]')",
        [record, grant, '00000000-0000-4000-8000-000000000007', a],
      );
      db.execute(
        "INSERT INTO shared_replies VALUES (1,?,?,?,'SYNTHETIC REPLY',6)",
        ['00000000-0000-4000-8000-000000000008', record, b],
      );
      db.execute(
        "INSERT INTO sharing_operations VALUES (?,?,?,?,'publish',?,1,200,NULL,5)",
        [
          a,
          '00000000-0000-4000-8000-000000000009',
          group,
          'fingerprint',
          record,
        ],
      );
    } finally {
      db.close();
    }
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test(
    'frozen v2 migration preserves every original table and row across reopen',
    () {
      final original = sqlite3.open(path, mode: OpenMode.readOnly);
      final before = snapshot(original);
      original.close();
      for (var i = 0; i < 2; i++) {
        final store = CompanionStore.open(path);
        expect(store.state('qa-a').group!.id, group);
        expect(
          store.sharedRecord('qa-b', group, record).text,
          'SYNTHETIC TEXT',
        );
        store.close();
        final db = sqlite3.open(path, mode: OpenMode.readOnly);
        try {
          final after = snapshot(db);
          for (final table in before.keys) {
            expect(after[table], before[table], reason: table);
          }
          expect(db.userVersion, 4);
          expect(db.select('PRAGMA foreign_key_check'), isEmpty);
          expect(
            db.select('PRAGMA integrity_check').single.values.single,
            'ok',
          );
          expect(db.select('SELECT * FROM companion_photos'), isEmpty);
        } finally {
          db.close();
        }
      }
    },
  );

  test('v2 name conflict rolls back without changing old file', () {
    final db = sqlite3.open(path);
    db.execute("CREATE TABLE companion_photos (private TEXT)");
    db.execute("INSERT INTO companion_photos VALUES ('SYNTHETIC preserve')");
    db.close();
    final before = File(path).readAsBytesSync();
    expect(() => CompanionStore.open(path), throwsA(isA<SqliteException>()));
    expect(File(path).readAsBytesSync(), before);
  });

  test('invalid v2 foreign keys are rejected before migration', () {
    final db = sqlite3.open(path);
    db.execute(
      "INSERT INTO shared_replies VALUES (2,'missing-reply','missing-record',?,'SYNTHETIC',6)",
      [b],
    );
    db.close();
    final before = File(path).readAsBytesSync();
    expect(() => CompanionStore.open(path), throwsFormatException);
    expect(File(path).readAsBytesSync(), before);
  });
}
