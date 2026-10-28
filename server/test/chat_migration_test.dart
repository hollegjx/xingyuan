import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:xingyuan_server/src/companion_store.dart';

import 'support/media_fixtures.dart';
import 'support/sharing_fixtures.dart';

void main() {
  late Directory directory;
  late String path;
  String id(int n) =>
      '00000000-0000-4000-8000-${n.toString().padLeft(12, '0')}';
  final a = id(1), b = id(2), group = id(3), grant = id(4), record = id(5);
  final recordPhoto = id(10), chatPhoto = id(11);
  Map<String, Object?> snapshot(Database db) => {
    for (final row in db.select(
      "SELECT name FROM sqlite_schema WHERE type='table' ORDER BY name",
    ))
      row['name'] as String: db
          .select('SELECT * FROM "${row['name']}" ORDER BY rowid')
          .map((r) => Map<String, Object?>.from(r))
          .toList(),
  };
  List<Map<String, Object?>> schema(Database db) => db
      .select(
        'SELECT type,name,tbl_name,sql FROM sqlite_schema ORDER BY type,name',
      )
      .map((r) => Map<String, Object?>.from(r))
      .toList();
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('chat-migration-');
    path = '${directory.path}/data.db';
    final db = sqlite3.open(path);
    try {
      db.execute(
        File('test/fixtures/companion_schema_v3.sql').readAsStringSync(),
      );
      db.execute('PRAGMA application_id=1481065296');
      db.userVersion = 3;
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
        id(6),
        a,
        'synthetic-hash',
        1,
        900,
        b,
      ]);
      db.execute(
        "INSERT INTO pairing_operations VALUES (?,?,?,'join',?,200,NULL,NULL,?)",
        [b, id(7), 'synthetic-fingerprint', group, 3],
      );
      db.execute('INSERT INTO join_failures VALUES (?,?,?)', [a, id(8), 4]);
      db.execute('INSERT INTO sharing_grants VALUES (1,?,?,?,?,?,NULL)', [
        grant,
        group,
        a,
        id(9),
        4,
      ]);
      db.execute(
        "INSERT INTO shared_records VALUES (1,?,?,?,?,1,'SYNTHETIC',5,NULL,'SYNTHETIC TEXT',?)",
        [
          record,
          grant,
          id(12),
          a,
          jsonEncode([recordPhoto]),
        ],
      );
      db.execute(
        "INSERT INTO shared_replies VALUES (1,?,?,?,'SYNTHETIC REPLY',6)",
        [id(13), record, b],
      );
      db.execute(
        "INSERT INTO sharing_operations VALUES (?,?,?,?,'publish',?,1,200,NULL,5)",
        [a, id(14), group, 'fingerprint', record],
      );
      db.execute(
        "INSERT INTO companion_photos VALUES (?,?,?,'record',?,'ready',12,8,500,?,6)",
        [recordPhoto, group, a, grant, 'a' * 64],
      );
      db.execute(
        "INSERT INTO companion_photos VALUES (?,?,?,'chat',NULL,'ready',12,8,500,?,6)",
        [chatPhoto, group, a, 'b' * 64],
      );
      db.execute('INSERT INTO shared_record_photos VALUES (?,?,0)', [
        record,
        recordPhoto,
      ]);
      db.execute(
        "INSERT INTO media_operations VALUES (?,?,?,'upload',?,?,'succeeded',200,NULL,6)",
        [a, id(15), group, 'synthetic-fingerprint', chatPhoto],
      );
      db.execute('INSERT INTO photo_deletions VALUES (?,7,2,?)', [
        id(16),
        'generation',
      ]);
      expect(db.select('PRAGMA foreign_key_check'), isEmpty);
    } finally {
      db.close();
    }
  });
  tearDown(() async => directory.delete(recursive: true));

  test('frozen v3 upgrade preserves every old table, column, row, index and trigger', () {
    final original = sqlite3.open(path, mode: OpenMode.readOnly);
    final before = snapshot(original);
    final beforeSchema = schema(original);
    original.close();
    for (final rows in before.values) {
      expect(rows, isNotEmpty);
    }
    for (var i = 0; i < 2; i++) {
      final store = CompanionStore.open(path);
      try {
        expect(store.state('qa-a').group!.id, group);
        expect(
          store.sharedRecord('qa-b', group, record).text,
          'SYNTHETIC TEXT',
        );
        expect(
          store.photoFor('qa-b', mediaRequest(group, recordPhoto)).id,
          recordPhoto,
        );
        expect(
          store.photoFor('qa-a', mediaRequest(group, chatPhoto)).id,
          chatPhoto,
        );
        expect(
          () => store.photoFor('qa-b', mediaRequest(group, chatPhoto)),
          throwsA(isA<CompanionFailure>()),
        );
        expect(store.chatMessages('qa-b', sharePage(group)).messages, isEmpty);
      } finally {
        store.close();
      }
      final db = sqlite3.open(path, mode: OpenMode.readOnly);
      try {
        final after = snapshot(db);
        for (final table in before.keys) {
          expect(after[table], before[table], reason: table);
        }
        expect(
          schema(
            db,
          ).where((r) => beforeSchema.any((old) => old['name'] == r['name'])),
          beforeSchema,
        );
        expect(after.keys.toSet().difference(before.keys.toSet()), {
          'chat_state',
          'chat_messages',
          'chat_operations',
        });
        for (final table in [
          'chat_state',
          'chat_messages',
          'chat_operations',
        ]) {
          expect(after[table], isEmpty);
        }
        expect(db.userVersion, 4);
        expect(db.select('PRAGMA foreign_key_check'), isEmpty);
        expect(db.select('PRAGMA integrity_check').single.values.single, 'ok');
      } finally {
        db.close();
      }
    }
  });

  for (final table in ['chat_state', 'chat_messages', 'chat_operations']) {
    test('v3 $table name conflict rolls back the entire migration', () {
      final db = sqlite3.open(path);
      db.execute('CREATE TABLE $table (private TEXT)');
      db.execute("INSERT INTO $table VALUES ('SYNTHETIC preserve')");
      db.close();
      final before = File(path).readAsBytesSync();
      expect(() => CompanionStore.open(path), throwsA(isA<SqliteException>()));
      expect(File(path).readAsBytesSync(), before);
      final after = sqlite3.open(path, mode: OpenMode.readOnly);
      try {
        expect(after.userVersion, 3);
        expect(
          after.select('SELECT * FROM $table').single['private'],
          'SYNTHETIC preserve',
        );
      } finally {
        after.close();
      }
    });
  }

  test('v3 broken foreign keys are rejected before any migration write', () {
    final db = sqlite3.open(path);
    db.execute('INSERT INTO shared_record_photos VALUES (?,?,0)', [
      id(30),
      id(31),
    ]);
    db.close();
    final before = File(path).readAsBytesSync();
    expect(() => CompanionStore.open(path), throwsFormatException);
    expect(File(path).readAsBytesSync(), before);
  });

  test('future or wrong-identity databases are not modified', () {
    for (final pragma in [
      'PRAGMA user_version=5',
      'PRAGMA user_version=3; PRAGMA application_id=1',
    ]) {
      final db = sqlite3.open(path);
      db.execute(pragma);
      db.close();
      final before = File(path).readAsBytesSync();
      expect(() => CompanionStore.open(path), throwsFormatException);
      expect(File(path).readAsBytesSync(), before);
    }
  });
}
