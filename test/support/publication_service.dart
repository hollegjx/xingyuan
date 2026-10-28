import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:habit_checkin/features/companion/data/companion_service.dart';
import 'package:image/image.dart' as img;
import 'package:xingyuan_core/xingyuan_core.dart';

import 'pairing_fixtures.dart';
import 'sharing_fixtures.dart';

class TestPublicationService extends TestSharingService
    implements CompanionPublicationService {
  final resolutions = <SharingCommand>[];
  final uploads = <CompanionPhotoUpload>[];
  final cancelled = <String>{};
  final _sources = <String, String>{};
  final _uploads = <String, CompanionPhotoReceipt>{};
  final _photoBytes = <String, List<int>>{};
  int _sequence = 10;
  Future<void> Function(SharingCommand command)? afterPublication;
  Completer<void>? publicationGate;

  Future<void> _check(
    CompanionAccess access,
    CompanionCancellation? cancellation,
  ) async {
    if (cancellation?.isCancelled == true) {
      throw const CompanionServiceFailure('cancelled', outcomeUnknown: true);
    }
    if (!await access.isCurrent()) {
      throw const CompanionServiceFailure('discarded', outcomeUnknown: true);
    }
  }

  @override
  Future<SharingReceipt> executeSharing(
    SharingCommand command, {
    required CompanionAccess access,
    CompanionCancellation? cancellation,
  }) async {
    if (command.kind != SharingCommandKind.publish) {
      final receipt = await super.executeSharing(
        command,
        access: access,
        cancellation: cancellation,
      );
      if (command.kind == SharingCommandKind.remove) {
        _sources.removeWhere((_, id) => id == command.recordId);
      }
      return receipt;
    }
    sharedCommands.add(command);
    await publicationGate?.future;
    await _check(access, cancellation);
    if (sharedFailure case final failure?) throw failure;
    if (cancelled.contains(command.operationId)) {
      throw const CompanionServiceFailure('publication_cancelled');
    }
    var receipt = receipts[command.operationId];
    if (receipt == null) {
      final id = _sources.putIfAbsent(
        command.sourceId!,
        () => sharingId(++_sequence),
      );
      final old = sharedRecords.where((r) => r['id'] == id).firstOrNull;
      final sequence = old?['sequence'] ?? ++_sequence;
      sharedRecords.removeWhere((r) => r['id'] == id);
      sharedRecords.add({
        'id': id,
        'author_id': testMemberId,
        'grant_id': command.grantId,
        'sequence': sequence,
        'revision': command.baseRevision! + 1,
        'title': command.title,
        'occurred_at': command.occurredAt!.toIso8601String(),
        'completed_at': command.completedAt?.toIso8601String(),
        'text': command.text,
        'photo_ids': command.photoIds,
      });
      revision++;
      receipt = SharingReceipt.fromJson({
        'protocol': companionProtocol,
        'operation_id': command.operationId,
        'group_id': command.groupId,
        'resource_id': id,
        'revision': command.baseRevision! + 1,
      }, command: command);
      receipts[command.operationId] = receipt;
    }
    await afterPublication?.call(command);
    if (afterCommitFailure case final failure?) throw failure;
    await _check(access, cancellation);
    return receipt;
  }

  @override
  Future<CompanionPhotoReceipt> uploadPhoto(
    CompanionPhotoUpload request, {
    required CompanionAccess access,
    CompanionCancellation? cancellation,
  }) async {
    uploads.add(request);
    await photoGate?.future;
    await _check(access, cancellation);
    if (photoFailure case final failure?) throw failure;
    final decoded = img.decodeJpg(request.bytes)!;
    _photoBytes[request.operationId] = request.bytes;
    return _uploads.putIfAbsent(
      request.operationId,
      () => CompanionPhotoReceipt.fromJson({
        'protocol': companionProtocol,
        'operation_id': request.operationId,
        'photo': {
          'id': sharingId(1000 + _uploads.length),
          'group_id': request.groupId,
          'author_id': testMemberId,
          'purpose': request.purpose.name,
          'grant_id': request.grantId,
          'width': decoded.width,
          'height': decoded.height,
          'byte_count': request.bytes.length,
          'sha256': sha256.convert(request.bytes).toString(),
        },
      }, request: request),
    );
  }

  @override
  Future<CompanionPhotoDownload> downloadPhoto(
    CompanionPhotoRequest request, {
    required CompanionAccess access,
    CompanionCancellation? cancellation,
  }) async {
    photoReads.add(request.photoId);
    await _check(access, cancellation);
    final entry = _uploads.entries.singleWhere(
      (e) => e.value.photo.id == request.photoId,
    );
    return CompanionPhotoDownload.fromJson({
      'protocol': companionProtocol,
      'photo': entry.value.photo.toJson(),
      'jpeg_base64': base64Encode(_photoBytes[entry.key]!),
    }, request: request);
  }

  @override
  Future<PublicationResolution> resolvePublication(
    SharingCommand command, {
    required CompanionAccess access,
    CompanionCancellation? cancellation,
  }) async {
    resolutions.add(command);
    await _check(access, cancellation);
    final receipt = receipts[command.operationId];
    if (receipt == null) cancelled.add(command.operationId);
    final request = PublicationResolveRequest.fromJson({
      'protocol': companionProtocol,
      'operation_id': command.operationId,
      'group_id': command.groupId,
      'fingerprint': sha256
          .convert(utf8.encode(command.fingerprintInput))
          .toString(),
    });
    return PublicationResolution.fromJson({
      ...request.toJson(),
      'receipt': receipt?.toJson(),
      'error_code': receipt == null ? 'publication_cancelled' : null,
    }, request: request);
  }
}
