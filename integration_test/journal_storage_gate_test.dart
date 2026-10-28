import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show GeneratedDatabase, Variable;
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/local/open_database.dart';
import 'package:habit_checkin/data/sync/identity_store.dart';
import 'package:habit_checkin/features/journal/data/journal_photo_files.dart';
import 'package:habit_checkin/features/journal/data/local_journal_store.dart';
import 'package:habit_checkin/features/journal/domain/journal_entry.dart';
import 'package:habit_checkin/features/records/data/record_photo.dart';
import 'package:habit_checkin/shared/local_date.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:uuid/uuid.dart';

import '../test/drift/generated/schema_v10.dart' as v10;
import '../test/support/test_clock.dart';

const _newTables = [
  'quick_notes',
  'diary_entries',
  'quick_note_photos',
  'diary_photos',
];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();

  testWidgets('isolated native journal migration and process recovery', (
    tester,
  ) async {
    const phase = String.fromEnvironment('JOURNAL_STORAGE_PHASE');
    const run = String.fromEnvironment('JOURNAL_STORAGE_RUN');
    expect(phase, anyOf('seed', 'write', 'reopen', 'verify'));
    expect(RegExp(r'^[a-zA-Z0-9-]{1,80}$').hasMatch(run), isTrue);
    final name = 'habit_checkin_journal_gate_$run';
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Text('TEST journal storage gate')),
      ),
    );
    if (phase == 'seed') {
      final db = v10.DatabaseAtV10(driftDatabase(name: name));
      try {
        expect(await db.customSelect('SELECT * FROM goals').get(), isEmpty);
        expect(
          await db
              .customSelect(
                "SELECT name FROM sqlite_schema WHERE name='journal_gate_evidence'",
              )
              .get(),
          isEmpty,
          reason: 'Use a fresh run token; never replace an earlier probe',
        );
        await db.transaction(() async {
          for (final statement in [
            "INSERT INTO identity_states VALUES (1, 'guest', 7, NULL)",
            "INSERT INTO goals VALUES (1, '22222222-2222-4222-8222-222222222222', 'guest', 0, '2026-10-20', 100, NULL, NULL)",
            "INSERT INTO goal_titles VALUES (1, '2026-10-20', 'SYNTHETIC legacy goal')",
            "INSERT INTO goal_schedules VALUES (1, '2026-10-20', 127, NULL, 1140, 30)",
            "INSERT INTO check_ins VALUES (1, 0, '2026-10-21', 1, '2026-10-21', 200, 'America/Los_Angeles', 'SYNTHETIC original title', NULL)",
            "INSERT INTO goal_reminders VALUES (1, 0, 1200, 2, 0, 'disabled')",
            "INSERT INTO sync_states VALUES (1, 0, 0, NULL, NULL)",
            "INSERT INTO planning_profiles VALUES ('guest', 'SYNTHETIC preference', 50)",
            "INSERT INTO day_records (id, goal_id, owner, day, content, saved_at, draft_text, created_at, updated_at) VALUES ('11111111-1111-4111-8111-111111111111', 1, 'guest', '2026-10-21', 'SYNTHETIC old saved', 200, 'SYNTHETIC old draft', 100, 300)",
          ]) {
            await db.customStatement(statement);
          }
          final snapshot = <String, Object?>{};
          final tables = await db
              .customSelect(
                "SELECT name FROM sqlite_schema WHERE type='table' ORDER BY name",
              )
              .get();
          for (final row in tables) {
            final table = row.read<String>('name');
            snapshot[table] = await _rows(db, table);
          }
          expect(snapshot, hasLength(41));
          await db.customStatement(
            'CREATE TABLE journal_gate_evidence '
            '(key TEXT PRIMARY KEY, value TEXT NOT NULL)',
          );
          await _record(db, 'legacy', snapshot);
        });
        expect(await _version(db), 10);
      } finally {
        await db.close();
      }
    } else {
      final db = openAppDatabase(name: name);
      try {
        expect(await _version(db), 12);
        await _verifyLegacy(db);
        final clock = TestClock()
          ..location = tz.getLocation('America/Los_Angeles')
          ..setDay(2026, 10, 22, hour: 23, minute: 59);
        final originalDay = clock.day;
        if (phase != 'write') {
          clock.instant = clock.instant.add(const Duration(minutes: 2));
          clock.location = tz.getLocation('Asia/Shanghai');
          expect(clock.day, isNot(originalDay));
        }
        final lease = await IdentityStore(db).active();
        final goals = LocalGoalRepository(
          db,
          clock,
          owner: lease.identity.owner,
          identityLease: lease,
        );
        final stores = <LocalJournalStore>[
          LocalQuickNoteStore(goals),
          LocalDiaryStore(goals),
        ];
        final root = Directory(
          p.join(
            (await getApplicationDocumentsDirectory()).path,
            'journal_gate_photos_$run',
          ),
        );
        if (phase == 'write') {
          for (final table in _newTables) {
            expect(await _rows(db, table), isEmpty);
          }
          final source = img.Image(width: 24, height: 18);
          source.exif.gpsIfd
            ..gpsLatitude = 12.34
            ..gpsLatitudeRef = 'N';
          final photo = await sanitizeRecordPhoto(img.encodeJpg(source));
          final expected = <String, Object?>{};
          for (final store in stores) {
            var value = await _begin(store, originalDay);
            value = await store.writeDraft(
              value.entry.id,
              content: 'SYNTHETIC saved ${store.kind.name}',
              expectedDraftRevision: value.entry.draftRevision,
            );
            final files = JournalPhotoFiles(root, store.owner, store.kind);
            value = await store.addPhoto(
              value.entry.id,
              photo: await files.write(photo),
              expectedDraftRevision: value.entry.draftRevision,
            );
            value = await _save(store, value, const Uuid().v4());
            value = await _begin(store, originalDay, id: value.entry.id);
            value = await store.writeDraft(
              value.entry.id,
              content: 'SYNTHETIC unsaved ${store.kind.name}',
              expectedDraftRevision: value.entry.draftRevision,
            );
            value = await store.addPhoto(
              value.entry.id,
              photo: await files.write(photo),
              expectedDraftRevision: value.entry.draftRevision,
            );
            expect(value.savedPhotos, hasLength(1));
            expect(value.draftPhotos, hasLength(2));
            expected[store.kind.name] = _fingerprint(value);
          }
          await _record(db, 'drafts', expected);
        } else {
          final expected = await _stored(
            db,
            phase == 'reopen' ? 'drafts' : 'committed',
          );
          final committed = <String, Object?>{};
          for (final store in stores) {
            final value = (await store.savedOn(originalDay)).single;
            expect(_fingerprint(value), expected[store.kind.name]);
            expect(value.entry.zone, 'America/Los_Angeles');
            expect(await store.onDay(clock.day), isEmpty);
            final files = JournalPhotoFiles(root, store.owner, store.kind);
            for (final photo in [...value.savedPhotos, ...value.draftPhotos]) {
              final bytes = await files.read(photo);
              expect(bytes, hasLength(photo.byteCount));
              expect(img.decodeJpg(bytes)!.exif.isEmpty, isTrue);
            }
            if (phase == 'reopen') {
              expect(value.entry.content, 'SYNTHETIC saved ${store.kind.name}');
              expect(
                value.entry.draftText,
                'SYNTHETIC unsaved ${store.kind.name}',
              );
              final operation = const Uuid().v4();
              final saved = await _save(store, value, operation);
              expect(
                _fingerprint(await _save(store, value, operation)),
                _fingerprint(saved),
              );
              expect(saved.savedPhotos, hasLength(2));
              expect(saved.entry.draftText, isNull);
              expect(saved.draftPhotos, isEmpty);
              committed[store.kind.name] = _fingerprint(saved);
            } else {
              expect(
                value.entry.content,
                'SYNTHETIC unsaved ${store.kind.name}',
              );
              expect(value.entry.draftText, isNull);
              expect(value.savedPhotos, hasLength(2));
              expect(value.draftPhotos, isEmpty);
            }
            expect(await store.savedOn(originalDay), hasLength(1));
          }
          if (phase == 'reopen') await _record(db, 'committed', committed);
        }
        await _verifyLegacy(db);
        expect(
          await db.customSelect('PRAGMA foreign_key_check').get(),
          isEmpty,
        );
        expect(
          (await db.customSelect('PRAGMA integrity_check').getSingle())
              .read<String>('integrity_check'),
          'ok',
        );
      } finally {
        await db.close();
      }
    }
    // ignore: avoid_print
    print('JOURNAL_STORAGE phase=$phase passed synthetic-only=true');
  });
}

Future<int> _version(GeneratedDatabase db) async =>
    (await db.customSelect('PRAGMA user_version').getSingle()).read<int>(
      'user_version',
    );

Future<List<Map<String, Object?>>> _rows(
  GeneratedDatabase db,
  String table,
) async {
  expect(RegExp(r'^[a-z_]+$').hasMatch(table), isTrue);
  return (await db.customSelect('SELECT * FROM "$table" ORDER BY rowid').get())
      .map((row) => row.data)
      .toList();
}

Future<void> _record(GeneratedDatabase db, String key, Object value) =>
    db.customStatement('INSERT INTO journal_gate_evidence VALUES (?, ?)', [
      key,
      jsonEncode(value),
    ]);

Future<Map<String, dynamic>> _stored(GeneratedDatabase db, String key) async =>
    jsonDecode(
      (await db
              .customSelect(
                'SELECT value FROM journal_gate_evidence WHERE key = ?',
                variables: [Variable.withString(key)],
              )
              .getSingle())
          .read<String>('value'),
    ) as Map<String, dynamic>;

Future<void> _verifyLegacy(GeneratedDatabase db) async {
  final expected = await _stored(db, 'legacy');
  expect(expected, hasLength(41));
  for (final table in expected.entries) {
    expect(await _rows(db, table.key), table.value, reason: table.key);
  }
}

Future<JournalSnapshot> _begin(
  LocalJournalStore store,
  LocalDate day, {
  String? id,
}) => switch (store) {
  LocalQuickNoteStore s => s.beginDraft(id: id, day: day),
  LocalDiaryStore s => s.beginDraft(day),
  _ => throw StateError('Unexpected journal store'),
};

Future<JournalSnapshot> _save(
  LocalJournalStore store,
  JournalSnapshot value,
  String operation,
) => store.save(
  value.entry.id,
  operationId: operation,
  expectedRevision: value.entry.revision,
  expectedDraftRevision: value.entry.draftRevision,
);

Map<String, Object?> _fingerprint(JournalSnapshot value) => {
  'id': value.entry.id,
  'owner': value.entry.owner,
  'day': value.entry.day,
  'zone': value.entry.zone,
  'content': value.entry.content,
  'draft': value.entry.draftText,
  'revision': value.entry.revision,
  'draftRevision': value.entry.draftRevision,
  'createdAt': value.entry.createdAt,
  'updatedAt': value.entry.updatedAt,
  'savedAt': value.entry.savedAt,
  'deletedAt': value.entry.deletedAt,
  'lastOperation': value.entry.lastOperationId,
  'lastOperationDraftRevision': value.entry.lastOperationDraftRevision,
  'savedPhotos': value.savedPhotos.map(_photo).toList(),
  'draftPhotos': value.draftPhotos.map(_photo).toList(),
};

Map<String, Object?> _photo(JournalPhoto value) => {
  'id': value.id,
  'entry': value.entryId,
  'owner': value.owner,
  'filename': value.filename,
  'width': value.width,
  'height': value.height,
  'bytes': value.byteCount,
  'sha256': value.sha256,
  'savedPosition': value.savedPosition,
  'draftPosition': value.draftPosition,
  'createdAt': value.createdAt,
};
