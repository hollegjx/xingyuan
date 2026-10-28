import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:habit_checkin/features/companion/data/companion_service.dart';
import 'package:image/image.dart' as img;
import 'package:xingyuan_core/xingyuan_core.dart';

import 'pairing_fixtures.dart';

String sharingId(int n) =>
    '00000000-0000-4000-8000-${n.toString().padLeft(12, '0')}';
const sharingInstant = '2026-10-21T10:00:00.000Z';
final testRecordId = sharingId(5);
final testGrantId = sharingId(4);

Map<String, Object?> syntheticSharedRecord({
  String? id,
  String? author,
  int sequence = 1,
  int revision = 1,
  List<String> photos = const [],
}) => {
  'id': id ?? testRecordId,
  'author_id': author ?? testMemberId,
  'grant_id': testGrantId,
  'sequence': sequence,
  'revision': revision,
  'title': 'SYNTHETIC reading',
  'occurred_at': sharingInstant,
  'completed_at': sharingInstant,
  'text': 'SYNTHETIC shared note',
  'photo_ids': photos,
};

class TestSharingService extends TestCompanionService
    implements CompanionSharingService, CompanionMediaService {
  TestSharingService() {
    current = testPairingState(paired: true);
  }

  final sharedCommands = <SharingCommand>[];
  final sharedGrants = <Map<String, Object?>>[];
  final sharedRecords = <Map<String, Object?>>[];
  final sharedReplies = <Map<String, Object?>>[];
  final photoReads = <String>[];
  final receipts = <String, SharingReceipt>{};
  Completer<void>? sharedGate;
  Completer<void>? photoGate;
  CompanionServiceFailure? sharedFailure;
  CompanionServiceFailure? afterCommitFailure;
  CompanionServiceFailure? sharedReadFailure;
  CompanionServiceFailure? photoFailure;
  Future<void> Function(String kind, SharedPageRequest request)? beforeRead;
  int revision = 1;
  int grantReads = 0;
  int feedReads = 0;
  int replyReads = 0;
  int pageSize = 50;

  void seed(
    String goal, {
    bool partner = false,
    List<String> photos = const [],
  }) {
    sharedGrants.add({
      'id': testGrantId,
      'goal_id': goal,
      'sequence': 1,
      'enabled_at': sharingInstant,
    });
    sharedRecords.add(
      syntheticSharedRecord(
        author: partner ? testPartnerId : testMemberId,
        photos: photos,
      ),
    );
  }

  Future<void> _read(
    String kind,
    SharedPageRequest request,
    CompanionAccess access,
  ) async {
    await beforeRead?.call(kind, request);
    if (!await access.isCurrent()) {
      throw const CompanionServiceFailure('discarded');
    }
    if (sharedReadFailure case final failure?) throw failure;
    if (request.revision != null && request.revision != revision) {
      throw const CompanionServiceFailure('snapshot_changed');
    }
  }

  Map<String, Object?> _page(
    SharedPageRequest request,
    String key,
    List<Map<String, Object?>> rows,
  ) {
    final remaining =
        rows
            .where(
              (row) =>
                  request.beforeSequence == null ||
                  (row['sequence']! as int) < request.beforeSequence!,
            )
            .toList()
          ..sort(
            (a, b) => (b['sequence']! as int).compareTo(a['sequence']! as int),
          );
    final page = remaining.take(pageSize).toList();
    return {
      'protocol': companionProtocol,
      'group_id': testGroupId,
      'revision': revision,
      if (request.recordId != null) 'record_id': request.recordId,
      key: page,
      'next_before': remaining.length > page.length
          ? page.last['sequence']
          : null,
    };
  }

  @override
  Future<SharingGrants> grants(
    SharedPageRequest request, {
    required CompanionAccess access,
    CompanionCancellation? cancellation,
  }) async {
    grantReads++;
    await _read('grants', request, access);
    return SharingGrants.fromJson(
      _page(request, 'grants', sharedGrants),
      request: request,
    );
  }

  @override
  Future<SharedFeedPage> feed(
    SharedPageRequest request, {
    required CompanionAccess access,
    CompanionCancellation? cancellation,
  }) async {
    feedReads++;
    await _read('feed', request, access);
    return SharedFeedPage.fromJson(
      _page(request, 'records', sharedRecords),
      request: request,
    );
  }

  @override
  Future<SharedRecord> record(
    SharedResourceRequest request, {
    required CompanionAccess access,
    CompanionCancellation? cancellation,
  }) async =>
      throw UnimplementedError('Use the feed fixture for controller reads.');

  @override
  Future<SharedRepliesPage> replies(
    SharedPageRequest request, {
    required CompanionAccess access,
    CompanionCancellation? cancellation,
  }) async {
    replyReads++;
    await _read('replies', request, access);
    if (!sharedRecords.any((row) => row['id'] == request.recordId)) {
      throw const CompanionServiceFailure('record_unavailable');
    }
    return SharedRepliesPage.fromJson(
      _page(
        request,
        'replies',
        sharedReplies
            .where((row) => row['record_id'] == request.recordId)
            .toList(),
      ),
      request: request,
    );
  }

  @override
  Future<SharingReceipt> executeSharing(
    SharingCommand command, {
    required CompanionAccess access,
    CompanionCancellation? cancellation,
  }) async {
    sharedCommands.add(command);
    await sharedGate?.future;
    if (!await access.isCurrent()) {
      throw const CompanionServiceFailure('discarded', outcomeUnknown: true);
    }
    if (sharedFailure case final failure?) throw failure;
    if (receipts[command.operationId] case final receipt?) return receipt;
    String resource;
    var resultRevision = 0;
    switch (command.kind) {
      case SharingCommandKind.enable:
        resource = sharingId(100 + receipts.length);
        sharedGrants.add({
          'id': resource,
          'goal_id': command.goalId,
          'sequence': sharedGrants.length + 1,
          'enabled_at': sharingInstant,
        });
      case SharingCommandKind.stop:
        resource = command.grantId!;
        final records = sharedRecords
            .where((r) => r['grant_id'] == resource)
            .map((r) => r['id'])
            .toSet();
        sharedGrants.removeWhere((r) => r['id'] == resource);
        sharedRecords.removeWhere((r) => records.contains(r['id']));
        sharedReplies.removeWhere((r) => records.contains(r['record_id']));
      case SharingCommandKind.remove:
        resource = command.recordId!;
        sharedRecords.removeWhere((r) => r['id'] == resource);
        sharedReplies.removeWhere((r) => r['record_id'] == resource);
      case SharingCommandKind.reply:
        resource = sharingId(200 + receipts.length);
        resultRevision = 1;
        sharedReplies.add({
          'id': resource,
          'record_id': command.recordId,
          'author_id': testMemberId,
          'sequence': sharedReplies.length + 1,
          'text': command.text,
          'created_at': sharingInstant,
        });
      case SharingCommandKind.deleteReply:
        resource = command.replyId!;
        sharedReplies.removeWhere((r) => r['id'] == resource);
      case SharingCommandKind.publish:
        throw UnimplementedError('Publication is tested separately.');
    }
    revision++;
    final receipt = SharingReceipt.fromJson({
      'protocol': companionProtocol,
      'operation_id': command.operationId,
      'group_id': testGroupId,
      'resource_id': resource,
      'revision': resultRevision,
    }, command: command);
    receipts[command.operationId] = receipt;
    if (afterCommitFailure case final failure?) throw failure;
    return receipt;
  }

  @override
  Future<CompanionPhotoDownload> downloadPhoto(
    CompanionPhotoRequest request, {
    required CompanionAccess access,
    CompanionCancellation? cancellation,
  }) async {
    photoReads.add(request.photoId);
    await photoGate?.future;
    if (!await access.isCurrent()) {
      throw const CompanionServiceFailure('discarded');
    }
    if (photoFailure case final failure?) throw failure;
    final bytes = Uint8List.fromList(
      img.encodeJpg(
        img.Image(width: 2, height: 2)..clear(img.ColorRgb8(80, 150, 120)),
      ),
    );
    return CompanionPhotoDownload.fromJson({
      'protocol': companionProtocol,
      'photo': {
        'id': request.photoId,
        'group_id': request.groupId,
        'author_id': testMemberId,
        'purpose': 'record',
        'grant_id': testGrantId,
        'width': 2,
        'height': 2,
        'byte_count': bytes.length,
        'sha256': sha256.convert(bytes).toString(),
      },
      'jpeg_base64': base64Encode(bytes),
    }, request: request);
  }

  @override
  Future<CompanionPhotoReceipt> uploadPhoto(
    CompanionPhotoUpload request, {
    required CompanionAccess access,
    CompanionCancellation? cancellation,
  }) async => throw UnimplementedError();
  @override
  Future<void> removePhoto(
    CompanionPhotoRequest request, {
    required CompanionAccess access,
    CompanionCancellation? cancellation,
  }) async => throw UnimplementedError();
}
