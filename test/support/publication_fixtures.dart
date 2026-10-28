import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/sync/identity_store.dart';
import 'package:habit_checkin/features/companion/data/local_pairing_store.dart';
import 'package:habit_checkin/features/companion/data/local_publication_outbox.dart';
import 'package:habit_checkin/features/companion/data/local_sharing_store.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:habit_checkin/features/records/data/local_day_record_store.dart';
import 'package:habit_checkin/features/records/data/record_photo.dart';
import 'package:habit_checkin/features/records/data/record_photo_files.dart';
import 'package:image/image.dart' as img;
import 'package:uuid/uuid.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

import 'pairing_fixtures.dart';
import 'sharing_fixtures.dart';
import 'test_clock.dart';

class PublicationFixture {
  PublicationFixture({String? credentialScope})
    : credentialScope = credentialScope ?? 'a' * 64;
  final String credentialScope;
  late Directory directory;
  late AppDatabase db;
  late LocalGoalRepository goals;
  late LocalDayRecordStore records;
  late LocalPairingStore pairing;
  late LocalSharingStore sharing;
  late LocalPublicationOutbox outbox;
  late RecordPhotoFiles files;
  late int goalId;
  final clock = TestClock()..instant = DateTime.utc(2026, 10, 21, 10, 1);

  Future<void> open() async {
    directory = await Directory.systemTemp.createTemp('publication-outbox-');
    db = AppDatabase(NativeDatabase(File('${directory.path}/data.sqlite')));
    await _bind();
    goalId = await goals.create(
      const GoalDraft(title: 'SYNTHETIC reading', kind: GoalKind.habit),
    );
    await pairing.acceptState(
      testPairingState(paired: true),
      expectedRevision: 0,
    );
    sharing = await LocalSharingStore.open(pairing);
    outbox = LocalPublicationOutbox(sharing);
    await seed();
  }

  Future<void> _bind() async {
    final lease = await IdentityStore(db).active();
    goals = LocalGoalRepository(db, clock, identityLease: lease);
    records = LocalDayRecordStore(goals);
    pairing = await LocalPairingStore.open(
      goals,
      credentialScope: credentialScope,
    );
    files = RecordPhotoFiles(
      Directory('${directory.path}/photos'),
      goals.owner,
    );
  }

  Future<void> seed({
    bool active = true,
    List<Map<String, Object?>> feed = const [],
  }) async {
    final state = await sharing.currentState();
    final globalId = (await db.select(db.goals).get()).single.globalId;
    final page = SharedPageRequest.fromJson({
      'protocol': companionProtocol,
      'group_id': testGroupId,
      'before_sequence': null,
      'revision': null,
    });
    await sharing.acceptSnapshot(
      grantPages: [
        SharingGrants.fromJson({
          'protocol': companionProtocol,
          'group_id': testGroupId,
          'revision': (state.serverRevision ?? 0) + 1,
          'grants': [
            if (active)
              {
                'id': testGrantId,
                'goal_id': globalId,
                'sequence': 1,
                'enabled_at': sharingInstant,
              },
          ],
          'next_before': null,
        }, request: page),
      ],
      feedPages: [
        SharedFeedPage.fromJson({
          'protocol': companionProtocol,
          'group_id': testGroupId,
          'revision': (state.serverRevision ?? 0) + 1,
          'records': feed,
          'next_before': null,
        }, request: page),
      ],
      expectedRevision: state.cacheRevision,
    );
  }

  Future<void> reopen() async {
    await db.close();
    db = AppDatabase(NativeDatabase(File('${directory.path}/data.sqlite')));
    await _bind();
    sharing = await LocalSharingStore.open(pairing);
    outbox = LocalPublicationOutbox(sharing);
  }

  Future<DayRecordSnapshot> draft(String text, {bool share = true}) async {
    final row = await records.beginDraft(goalId, clock.day);
    return records.writeDraft(
      row.record.id,
      content: text,
      expectedDraftRevision: row.record.draftRevision,
      shareWithPartner: share,
      sharingConsent: share
          ? await records.publications.available(goalId)
          : null,
    );
  }

  Future<DayRecordSnapshot> addPhoto(DayRecordSnapshot value) async {
    final source = img.Image(width: 24, height: 12);
    img.fill(source, color: img.ColorRgb8(16, 150, 92));
    final clean = await sanitizeRecordPhoto(img.encodeJpg(source));
    return records.addPhoto(
      value.record.id,
      photo: await files.write(clean),
      expectedDraftRevision: value.record.draftRevision,
    );
  }

  Future<DayRecordSnapshot> save(DayRecordSnapshot value) => records.save(
    value.record.id,
    operationId: const Uuid().v4(),
    expectedRevision: value.record.revision,
    expectedDraftRevision: value.record.draftRevision,
  );

  Future<void> deleteRecord() async {
    final value = (await records.at(goalId, clock.day))!;
    await records.delete(
      value.record.id,
      operationId: const Uuid().v4(),
      expectedRevision: value.record.revision,
    );
  }

  Future<PublicationAttempt> begin({bool retry = false}) async => outbox.begin(
    (await outbox.pending()).first.row.operationId,
    retry: retry,
  );

  Future<CompanionPhotoUpload> upload(
    PublicationAttempt attempt,
    PublicationPhoto photo,
  ) async => CompanionPhotoUpload.fromJson({
    'protocol': companionProtocol,
    'operation_id': photo.row.uploadOperationId,
    'group_id': testGroupId,
    'purpose': 'record',
    'grant_id': testGrantId,
    'jpeg_base64': base64Encode(await files.read(photo.photo)),
  });

  CompanionPhotoReceipt photoReceipt(
    CompanionPhotoUpload upload, {
    String? author,
    String? remote,
  }) => CompanionPhotoReceipt.fromJson({
    'protocol': companionProtocol,
    'operation_id': upload.operationId,
    'photo': {
      'id': remote ?? sharingId(70),
      'group_id': testGroupId,
      'author_id': author ?? testMemberId,
      'purpose': 'record',
      'grant_id': testGrantId,
      'width': 24,
      'height': 12,
      'byte_count': 123,
      'sha256': 'f' * 64,
    },
  }, request: upload);

  SharingReceipt receipt(PublicationAttempt attempt, {String? remote}) =>
      SharingReceipt.fromJson({
        'protocol': companionProtocol,
        'operation_id': attempt.row.operationId,
        'group_id': testGroupId,
        'resource_id': attempt.row.kind == 'remove'
            ? attempt.command!.recordId
            : remote ?? sharingId(50),
        'revision': attempt.row.kind == 'remove'
            ? 0
            : attempt.command!.baseRevision! + 1,
      }, command: attempt.command!);

  PublicationResolution cancelled(PublicationAttempt attempt) {
    final request = PublicationResolveRequest.fromJson({
      'protocol': companionProtocol,
      'operation_id': attempt.row.operationId,
      'group_id': testGroupId,
      'fingerprint': sha256
          .convert(utf8.encode(attempt.command!.fingerprintInput))
          .toString(),
    });
    return PublicationResolution.fromJson({
      ...request.toJson(),
      'receipt': null,
      'error_code': 'publication_cancelled',
    }, request: request);
  }

  Future<void> close() async {
    await db.close();
    await directory.delete(recursive: true);
  }
}
