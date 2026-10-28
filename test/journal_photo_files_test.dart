import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/sync/identity_store.dart';
import 'package:habit_checkin/data/sync/sync_identity.dart';
import 'package:habit_checkin/features/journal/data/journal_photo_files.dart';
import 'package:habit_checkin/features/journal/data/local_journal_store.dart';
import 'package:habit_checkin/features/journal/domain/journal_entry.dart';
import 'package:habit_checkin/features/records/data/local_day_record_store.dart';
import 'package:habit_checkin/features/records/data/record_photo.dart';
import 'package:habit_checkin/features/records/data/record_photo_files.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:uuid/uuid.dart';

import 'support/test_clock.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);
  late Directory root;
  late AppDatabase db;
  late LocalGoalRepository goals;
  late LocalQuickNoteStore notes;
  late LocalDiaryStore diary;
  late JournalPhotoFiles files;
  late TestClock clock;
  late SanitizedRecordPhoto image;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('journal-photos-');
    db = AppDatabase(NativeDatabase.memory());
    clock = TestClock()..setDay(2026, 10, 23);
    final lease = await IdentityStore(db).active();
    goals = LocalGoalRepository(
      db,
      clock,
      owner: lease.identity.owner,
      identityLease: lease,
    );
    notes = LocalQuickNoteStore(goals);
    diary = LocalDiaryStore(goals);
    files = JournalPhotoFiles(root, goals.owner, JournalKind.quickNote);
    final source = img.Image(width: 20, height: 16);
    source.exif.gpsIfd
      ..gpsLatitude = 12.34
      ..gpsLatitudeRef = 'N';
    image = await sanitizeRecordPhoto(img.encodeJpg(source));
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  Future<JournalSnapshot> attach(
    LocalJournalStore store,
    JournalPhotoFiles target,
  ) async {
    final draft = store is LocalQuickNoteStore
        ? await store.beginDraft()
        : await (store as LocalDiaryStore).beginDraft(clock.day);
    final photo = await target.write(image);
    return store.addPhoto(
      draft.entry.id,
      photo: photo,
      expectedDraftRevision: draft.entry.draftRevision,
    );
  }

  test('sanitized photos read with verified bytes and never share the record cleanup root', () async {
    final note = await attach(notes, files);
    final diaryFiles = JournalPhotoFiles(root, goals.owner, JournalKind.diary);
    final day = await attach(diary, diaryFiles);
    final records = RecordPhotoFiles(
      Directory(p.join(root.path, 'record_photos')),
      goals.owner,
    );
    final oldRecordOrphan = await records.write(image);
    final old = clock.instant.subtract(const Duration(days: 2));
    for (final (directory, id) in [
      (files.directory, note.draftPhotos.single.id),
      (diaryFiles.directory, day.draftPhotos.single.id),
      (records.directory, oldRecordOrphan.id),
    ]) {
      await File(p.join(directory.path, '$id.jpg')).setLastModified(old);
    }
    await records.clean(LocalDayRecordStore(goals));
    expect(
      await File(p.join(records.directory.path, oldRecordOrphan.filename))
          .exists(),
      isFalse,
    );
    await files.clean(notes);
    await diaryFiles.clean(diary);
    expect(await files.read(note.draftPhotos.single), image.bytes);
    expect(await diaryFiles.read(day.draftPhotos.single), image.bytes);
    expect(
      img.decodeJpg(await files.read(note.draftPhotos.single))!.exif.isEmpty,
      isTrue,
    );
    expect(files.directory.path, isNot(diaryFiles.directory.path));
  });

  test(
    'remove from a draft retains the saved file until explicit save',
    () async {
      var value = await attach(notes, files);
      value = await notes.save(
        value.entry.id,
        operationId: const Uuid().v4(),
        expectedRevision: value.entry.revision,
        expectedDraftRevision: value.entry.draftRevision,
      );
      final photo = value.savedPhotos.single;
      value = await notes.beginDraft(id: value.entry.id);
      value = await notes.writeDraft(
        value.entry.id,
        content: 'SYNTHETIC text',
        expectedDraftRevision: value.entry.draftRevision,
      );
      value = await notes.removePhoto(
        value.entry.id,
        photo.id,
        expectedDraftRevision: value.entry.draftRevision,
      );
      await files.clean(notes);
      expect(await files.read(photo), image.bytes);
      await notes.save(
        value.entry.id,
        operationId: const Uuid().v4(),
        expectedRevision: value.entry.revision,
        expectedDraftRevision: value.entry.draftRevision,
      );
      await files.clean(notes);
      expect(await notes.photoFilenames(), isEmpty);
      expect(
        await File(p.join(files.directory.path, photo.filename)).exists(),
        isFalse,
      );
    },
  );

  test(
    'orphan cleanup protects recent imports, unknown files and other features',
    () async {
      final old = await files.write(image);
      final recent = await files.write(image);
      final otherFiles = JournalPhotoFiles(
        root,
        goals.owner,
        JournalKind.diary,
      );
      final other = await otherFiles.write(image);
      final unknown = File(p.join(files.directory.path, 'keep.txt'));
      await unknown.writeAsString('SYNTHETIC unrelated');
      final oldFile = File(p.join(files.directory.path, old.filename));
      final part = File('${oldFile.path}.part');
      await part.writeAsBytes([1, 2, 3]);
      final before = clock.instant.subtract(const Duration(days: 2));
      for (final file in [
        oldFile,
        part,
        unknown,
        File(p.join(otherFiles.directory.path, other.filename)),
      ]) {
        await file.setLastModified(before);
      }
      await File(p.join(files.directory.path, recent.filename))
          .setLastModified(clock.instant);
      await files.clean(notes);
      expect(await oldFile.exists(), isFalse);
      expect(await part.exists(), isFalse);
      expect(
        await File(p.join(files.directory.path, recent.filename)).exists(),
        isTrue,
      );
      expect(await unknown.exists(), isTrue);
      expect(
        await File(p.join(otherFiles.directory.path, other.filename)).exists(),
        isTrue,
      );
    },
  );

  test(
    'wrong owner, wrong feature and tampered photo bytes are rejected',
    () async {
      final value = await attach(notes, files);
      final photo = value.draftPhotos.single;
      final foreign = JournalPhotoFiles(
        root,
        SyncIdentity.account('55555555-5555-4555-8555-555555555555').owner,
        JournalKind.quickNote,
      );
      await expectLater(
        foreign.read(photo),
        throwsA(isA<RecordPhotoException>()),
      );
      await expectLater(
        files.clean(diary),
        throwsA(isA<RecordPhotoException>()),
      );
      final file = File(p.join(files.directory.path, photo.filename));
      final changed = image.bytes.toList()..[0] = 0;
      await file.writeAsBytes(changed);
      await expectLater(
        files.read(photo),
        throwsA(isA<RecordPhotoException>()),
      );
      await file.writeAsBytes([1]);
      await expectLater(
        files.read(photo),
        throwsA(isA<RecordPhotoException>()),
      );
    },
  );

  test('identity transition prevents detached cleanup', () async {
    final value = await attach(notes, files);
    final photo = value.draftPhotos.single;
    await notes.removePhoto(
      value.entry.id,
      photo.id,
      expectedDraftRevision: value.entry.draftRevision,
    );
    await IdentityStore(db)
        .begin(SyncIdentity.account('55555555-5555-4555-8555-555555555555'));
    await expectLater(files.clean(notes), throwsA(isA<StaleIdentity>()));
    expect(
      await File(p.join(files.directory.path, photo.filename)).exists(),
      isTrue,
    );
  });
}
