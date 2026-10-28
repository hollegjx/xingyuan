import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/sync/identity_store.dart';
import 'package:habit_checkin/data/sync/sync_identity.dart';
import 'package:habit_checkin/features/companion/data/local_publication_store.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:habit_checkin/features/records/data/local_day_record_store.dart';
import 'package:habit_checkin/features/records/data/record_photo.dart';
import 'package:habit_checkin/features/records/data/record_photo_files.dart';
import 'package:habit_checkin/features/records/data/record_photo_picker.dart';
import 'package:habit_checkin/features/records/presentation/day_record_controller.dart';
import 'package:image/image.dart' as img;
import 'package:timezone/data/latest.dart' as tzdata;

import 'support/test_clock.dart';

class TestRecordPicker extends RecordPhotoPicker {
  Future<Uint8List?> Function()? onPick;
  int calls = 0;
  @override
  Future<Uint8List?> pick(RecordPhotoSource source) async {
    calls++;
    return onPick?.call();
  }
}

class SlowRecordStore extends LocalDayRecordStore {
  SlowRecordStore(super.goals);
  Completer<void>? delay;
  bool fail = false;
  @override
  Future<DayRecordSnapshot> writeDraft(
    String id, {
    required String content,
    required int expectedDraftRevision,
    bool? shareWithPartner,
    RecordSharingConsent? sharingConsent,
  }) async {
    await delay?.future;
    if (fail) throw const FileSystemException('TEST disk full');
    return super.writeDraft(
      id,
      content: content,
      expectedDraftRevision: expectedDraftRevision,
      shareWithPartner: shareWithPartner,
      sharingConsent: sharingConsent,
    );
  }
}

void main() {
  setUpAll(tzdata.initializeTimeZones);
  late Directory directory;
  late AppDatabase db;
  late TestClock clock;
  late LocalGoalRepository goals;
  late SlowRecordStore store;
  late RecordPhotoFiles files;
  late TestRecordPicker picker;
  late DayRecordController controller;
  late int goal;
  final sample = img.encodePng(img.Image(width: 40, height: 30));

  Future<void> bind() async {
    final lease = await IdentityStore(db).active();
    goals = LocalGoalRepository(
      db,
      clock,
      owner: lease.identity.owner,
      identityLease: lease,
    );
    store = SlowRecordStore(goals);
    files = RecordPhotoFiles(
      Directory('${directory.path}/photos'),
      goals.owner,
    );
    picker = TestRecordPicker();
    controller = DayRecordController(
      store: store,
      files: files,
      picker: picker,
    );
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('day-record-controller-');
    db = AppDatabase(NativeDatabase(File('${directory.path}/data.sqlite')));
    clock = TestClock()..setDay(2026, 10, 21);
    await bind();
    goal = await goals.create(
      const GoalDraft(
        title: 'TEST record',
        kind: GoalKind.habit,
        weekdays: 127,
      ),
    );
    await controller.initialize(goal, clock.day, editable: true);
  });
  tearDown(() async {
    controller.dispose();
    await db.close();
    await directory.delete(recursive: true);
  });

  test(
    'ordered slow drafts keep newest text and five save taps commit once',
    () async {
      store.delay = Completer<void>();
      final first = controller.setText('TEST first');
      final next = controller.setText('TEST newest\ntext');
      final saves = List.generate(5, (_) => controller.save());
      expect(controller.text, 'TEST newest\ntext');
      expect(controller.busy, isTrue);
      store.delay!.complete();
      await Future.wait([first, next]);
      expect(
        (await Future.wait(saves)).where((result) => result),
        hasLength(1),
      );
      final record = (await store.savedOn(clock.day)).single.record;
      expect(record.content, 'TEST newest\ntext');
      expect(record.revision, 1);
      expect(controller.dirty, isFalse);
    },
  );

  test('failed draft stays editable, cannot claim saved, and explicit retry recovers', () async {
    store.fail = true;
    await controller.setText('TEST disk retry');
    expect(controller.dirty, isTrue);
    expect(controller.error, isNotNull);
    expect(await controller.save(), isFalse);
    expect(await store.savedOn(clock.day), isEmpty);
    store.fail = false;
    await controller.setText(controller.text);
    expect(controller.dirty, isFalse);
    expect(await controller.save(), isTrue);
  });

  test('photo cancellation and denied permission leave text and completion independent', () async {
    await controller.setText('TEST text remains');
    picker.onPick = () async => null;
    expect(await controller.addPhoto(RecordPhotoSource.library), isTrue);
    picker.onPick = () async =>
        throw const RecordPhotoException('TEST permission denied');
    expect(await controller.addPhoto(RecordPhotoSource.camera), isFalse);
    expect(controller.text, 'TEST text remains');
    expect(controller.snapshot!.draftPhotos, isEmpty);
    await goals.setCompleted(goal, true, expectedDay: clock.day);
    expect(await controller.save(), isTrue);
    expect((await db.select(db.checkIns).get()).single.completed, isTrue);
  });

  test('photos and drafts survive process reopen; deleting record preserves completion', () async {
    picker.onPick = () async => sample;
    await controller.setText('TEST surviving draft');
    expect(await controller.addPhoto(RecordPhotoSource.library), isTrue);
    final photo = controller.snapshot!.draftPhotos.single;
    expect(await files.read(photo), isNotEmpty);
    controller.dispose();
    await db.close();
    db = AppDatabase(NativeDatabase(File('${directory.path}/data.sqlite')));
    await bind();
    await controller.initialize(goal, clock.day, editable: true);
    expect(controller.text, 'TEST surviving draft');
    expect(controller.snapshot!.draftPhotos.single.id, photo.id);
    expect(await controller.save(), isTrue);
    controller.dispose();
    controller = DayRecordController(
      store: store,
      files: files,
      picker: picker,
    );
    await controller.initialize(goal, clock.day, editable: true);
    await goals.setCompleted(goal, true, expectedDay: clock.day);
    expect(await controller.delete(), isTrue);
    expect((await db.select(db.checkIns).get()).single.completed, isTrue);
    expect(await store.savedOn(clock.day), isEmpty);
    expect(await store.photoFilenames(), isEmpty);
    expect(await files.directory.list().toList(), isEmpty);
  });

  test(
    'removing a saved photo from draft retains file until record save',
    () async {
      picker.onPick = () async => sample;
      await controller.addPhoto(RecordPhotoSource.library);
      await controller.save();
      controller.dispose();
      controller = DayRecordController(
        store: store,
        files: files,
        picker: picker,
      );
      await controller.initialize(goal, clock.day, editable: true);
      final photo = controller.snapshot!.savedPhotos.single;
      expect(await controller.removePhoto(photo.id), isTrue);
      expect(await files.read(photo), isNotEmpty);
      await controller.setText('TEST replace with text');
      expect(await controller.save(), isTrue);
      expect(await store.photoFilenames(), isEmpty);
      await expectLater(files.read(photo), throwsA(isA<FileSystemException>()));
    },
  );

  test(
    'identity changed while picker open rejects late photo result',
    () async {
      final pending = Completer<Uint8List?>();
      picker.onPick = () => pending.future;
      final operation = controller.addPhoto(RecordPhotoSource.library);
      while (picker.calls == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      final identities = IdentityStore(db);
      await identities.finish(
        await identities.begin(
          SyncIdentity.account('55555555-5555-4555-8555-555555555555'),
        ),
      );
      pending.complete(sample);
      expect(await operation, isFalse);
      expect(await db.select(db.recordPhotos).get(), isEmpty);
      expect(await files.directory.exists(), isFalse);
    },
  );

  test(
    'owner paths, integrity checks and orphan grace protect other photos',
    () async {
      picker.onPick = () async => sample;
      await controller.addPhoto(RecordPhotoSource.library);
      final photo = controller.snapshot!.draftPhotos.single;
      final other = RecordPhotoFiles(
        Directory('${directory.path}/photos'),
        SyncIdentity.account('55555555-5555-4555-8555-555555555555').owner,
      );
      expect(other.directory.path, isNot(files.directory.path));
      await expectLater(
        other.read(photo),
        throwsA(isA<RecordPhotoException>()),
      );
      await expectLater(
        files.remove('../escape'),
        throwsA(isA<RecordPhotoException>()),
      );
      final unregistered = await files.write(await sanitizeRecordPhoto(sample));
      final orphan = File('${files.directory.path}/${unregistered.filename}');
      await files.clean(store);
      expect(await orphan.exists(), isTrue);
      await orphan.setLastModified(
        DateTime.now().subtract(const Duration(days: 2)),
      );
      await files.clean(store);
      expect(await orphan.exists(), isFalse);
      expect(await files.read(photo), isNotEmpty);
      await File('${files.directory.path}/${photo.filename}')
          .writeAsBytes([1, 2, 3]);
      await expectLater(
        files.read(photo),
        throwsA(isA<RecordPhotoException>()),
      );
    },
  );
}
