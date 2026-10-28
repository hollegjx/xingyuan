import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/sync/identity_store.dart';
import 'package:habit_checkin/data/sync/sync_identity.dart';
import 'package:habit_checkin/features/journal/data/journal_photo_files.dart';
import 'package:habit_checkin/features/journal/data/local_journal_store.dart';
import 'package:habit_checkin/features/journal/domain/journal_entry.dart';
import 'package:habit_checkin/features/journal/presentation/journal_editor_controller.dart';
import 'package:habit_checkin/features/records/data/record_photo_picker.dart';
import 'package:image/image.dart' as img;
import 'package:timezone/data/latest.dart' as tzdata;

import 'support/test_clock.dart';

class _Picker extends RecordPhotoPicker {
  Future<Uint8List?> Function()? onPick;
  int calls = 0;
  @override
  Future<Uint8List?> pick(RecordPhotoSource source) async {
    calls++;
    return onPick?.call();
  }
}

class _Store extends LocalQuickNoteStore {
  _Store(super.goals);
  Completer<void>? delay;
  bool failDraft = false;
  bool loseSaveResult = false;

  @override
  Future<JournalSnapshot> writeDraft(
    String id, {
    required String content,
    required int expectedDraftRevision,
  }) async {
    await delay?.future;
    if (failDraft) throw const FileSystemException('SYNTHETIC disk full');
    return super.writeDraft(
      id,
      content: content,
      expectedDraftRevision: expectedDraftRevision,
    );
  }

  @override
  Future<JournalSnapshot> save(
    String id, {
    required String operationId,
    required int expectedRevision,
    required int expectedDraftRevision,
  }) async {
    final result = await super.save(
      id,
      operationId: operationId,
      expectedRevision: expectedRevision,
      expectedDraftRevision: expectedDraftRevision,
    );
    if (loseSaveResult) {
      loseSaveResult = false;
      throw StateError('SYNTHETIC lost completion');
    }
    return result;
  }
}

void main() {
  setUpAll(tzdata.initializeTimeZones);
  late Directory directory;
  late AppDatabase db;
  late TestClock clock;
  late _Store store;
  late _Picker picker;
  late JournalPhotoFiles files;
  final controllers = <JournalEditorController>[];
  final sample = img.encodePng(img.Image(width: 40, height: 30));

  Future<void> bind() async {
    final lease = await IdentityStore(db).active();
    final goals = LocalGoalRepository(
      db,
      clock,
      owner: lease.identity.owner,
      identityLease: lease,
    );
    store = _Store(goals);
    files = JournalPhotoFiles(directory, goals.owner, JournalKind.quickNote);
    picker = _Picker();
  }

  Future<JournalEditorController> editor({
    String? id,
    LocalJournalStore? source,
  }) async {
    final sourceStore = source ?? store;
    final c = JournalEditorController(
      store: sourceStore,
      files: source == null
          ? files
          : JournalPhotoFiles(directory, store.owner, source.kind),
      picker: picker,
    );
    controllers.add(c);
    await c.initialize(day: clock.day, id: id);
    return c;
  }

  void dispose(JournalEditorController c) {
    controllers.remove(c);
    c.dispose();
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('journal-controller-');
    db = AppDatabase(
      NativeDatabase(File('${directory.path}/synthetic.sqlite')),
    );
    clock = TestClock()..setDay(2026, 10, 23);
    await bind();
  });
  tearDown(() async {
    for (final controller in controllers) {
      controller.dispose();
    }
    controllers.clear();
    await db.close();
    await directory.delete(recursive: true);
  });

  test(
    'slow ordered drafts flush before save and repeated taps commit once',
    () async {
      final c = await editor();
      store.delay = Completer<void>();
      final writes = [
        c.setText('SYNTHETIC first'),
        c.setText('SYNTHETIC newest\nline'),
      ];
      final saves = List.generate(5, (_) => c.save());
      expect(c.dirty, isTrue);
      expect(c.busy, isTrue);
      store.delay!.complete();
      await Future.wait(writes);
      expect((await Future.wait(saves)).where((v) => v), hasLength(1));
      final row = (await store.savedOn(clock.day)).single.entry;
      expect(row.content, 'SYNTHETIC newest\nline');
      expect(row.revision, 1);
      expect(c.closed, isTrue);
    },
  );

  test('failed drafts cannot flush or save and explicit retry preserves newest text', () async {
    final c = await editor();
    store.failDraft = true;
    await c.setText('SYNTHETIC newest');
    expect(c.dirty, isTrue);
    await expectLater(c.flush(), throwsA(isA<FileSystemException>()));
    expect(await c.save(), isFalse);
    expect(await store.savedOn(clock.day), isEmpty);
    store.failDraft = false;
    await c.setText(c.text);
    await c.flush();
    expect(c.dirty, isFalse);
    expect(await c.save(), isTrue);
  });

  test(
    'retry after lost save result reuses operation id and does not duplicate',
    () async {
      final c = await editor();
      await c.setText('SYNTHETIC save');
      store.loseSaveResult = true;
      expect(await c.save(), isFalse);
      expect(c.closed, isFalse);
      expect(await c.save(), isTrue);
      final saved = await store.savedOn(clock.day);
      expect(saved, hasLength(1));
      expect(saved.single.entry.revision, 1);
    },
  );

  test(
    'accepted text finishes persisting after widget disposal without saving',
    () async {
      final c = await editor();
      store.delay = Completer<void>();
      final write = c.setText('SYNTHETIC pending');
      final id = c.snapshot!.entry.id;
      dispose(c);
      store.delay!.complete();
      await write;
      final entry = (await store.at(id))!.entry;
      expect(entry.draftText, 'SYNTHETIC pending');
      expect(entry.savedAt, isNull);
    },
  );

  for (final switchIdentity in [false, true]) {
    test(
      'late photo rejected after ${switchIdentity ? 'identity change' : 'editor disposal'}',
      () async {
        final c = await editor();
        final pending = Completer<Uint8List?>();
        picker.onPick = () => pending.future;
        final action = c.addPhoto(RecordPhotoSource.library);
        while (picker.calls == 0) {
          await Future<void>.delayed(Duration.zero);
        }
        if (switchIdentity) {
          final identities = IdentityStore(db);
          await identities.finish(
            await identities.begin(
              SyncIdentity.account('55555555-5555-4555-8555-555555555555'),
            ),
          );
        } else {
          dispose(c);
        }
        pending.complete(sample);
        expect(await action, isFalse);
        expect(await db.select(db.quickNotePhotos).get(), isEmpty);
        expect(await files.directory.exists(), isFalse);
      },
    );
  }

  test('photos and unsaved text survive database reopen without altering saved text', () async {
    var c = await editor();
    await c.setText('SYNTHETIC original');
    await c.save();
    final id = c.snapshot!.entry.id;
    dispose(c);
    c = await editor(id: id);
    picker.onPick = () async => sample;
    await c.setText('SYNTHETIC unfinished');
    expect(await c.addPhoto(RecordPhotoSource.library), isTrue);
    final photo = c.snapshot!.draftPhotos.single;
    dispose(c);
    await db.close();
    db = AppDatabase(
      NativeDatabase(File('${directory.path}/synthetic.sqlite')),
    );
    await bind();
    c = await editor(id: id);
    expect(c.text, 'SYNTHETIC unfinished');
    expect(c.snapshot!.entry.content, 'SYNTHETIC original');
    expect(c.snapshot!.draftPhotos.single.id, photo.id);
    expect(await files.read(photo), isNotEmpty);
    expect(await c.save(), isTrue);
    expect((await store.at(id))!.savedPhotos.single.id, photo.id);
  });

  test(
    'cancelled import and length error preserve text; fourth photo is refused',
    () async {
      final c = await editor();
      await c.setText('x' * 1001);
      expect(await c.addPhoto(RecordPhotoSource.library), isTrue);
      expect(c.text.length, 1001);
      expect(await c.save(), isFalse);
      expect(c.error, '正文最多 1000 字');
      picker.onPick = () async => sample;
      for (var i = 0; i < 3; i++) {
        expect(await c.addPhoto(RecordPhotoSource.library), isTrue);
      }
      final calls = picker.calls;
      expect(await c.addPhoto(RecordPhotoSource.library), isFalse);
      expect(picker.calls, calls);
    },
  );

  test(
    'diary editor reuses its day and preserves old photo until save or delete',
    () async {
      final diary = LocalDiaryStore(store.goals);
      var c = await editor(source: diary);
      picker.onPick = () async => sample;
      await c.addPhoto(RecordPhotoSource.library);
      expect(await c.save(), isTrue);
      final photo = c.snapshot!.savedPhotos.single;
      final id = c.snapshot!.entry.id;
      dispose(c);
      c = await editor(source: diary);
      expect(c.snapshot!.entry.id, id);
      await c.removePhoto(photo.id);
      expect(await c.files.read(photo), isNotEmpty);
      expect(await c.delete(), isTrue);
      expect(await diary.savedOn(clock.day), isEmpty);
      await expectLater(
        c.files.read(photo),
        throwsA(isA<FileSystemException>()),
      );
      expect(await db.select(db.goals).get(), isEmpty);
      expect(await db.select(db.checkIns).get(), isEmpty);
      expect(await db.select(db.syncOutbox).get(), isEmpty);
    },
  );
}
