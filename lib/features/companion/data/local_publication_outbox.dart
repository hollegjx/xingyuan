import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

import '../../../data/local/app_database.dart';
import 'companion_service.dart';
import 'local_publication_store.dart';
import 'local_sharing_store.dart';

class PublicationAttempt {
  const PublicationAttempt(this.row, this.source, this.sessionId);
  final StoredPublication row;
  final StoredPublicationSource source;
  final String sessionId;
  SharingCommand? get command => row.requestJson == null
      ? null
      : SharingCommand.fromJson(
          SharingCommandKind.values.byName(row.kind),
          jsonDecode(row.requestJson!),
        );
}

class PublicationPhoto {
  const PublicationPhoto(this.row, this.photo, this.remote);
  final StoredPublicationPhoto row;
  final StoredRecordPhoto photo;
  final CompanionPhotoMetadata? remote;
}

/// Durable transport state. A settled intent is not necessarily server-published:
/// receiptJson explicitly distinguishes server, local and superseded outcomes.
class LocalPublicationOutbox {
  LocalPublicationOutbox(this.sharing);
  final LocalSharingStore sharing;
  AppDatabase get db => sharing.db;
  String get owner => sharing.owner;
  LocalPublicationStore get capture =>
      LocalPublicationStore(sharing.pairing.goals);

  Future<StoredPublication?> _row(String operation) =>
      (db.select(db.sharingPublications)..where(
            (r) => r.owner.equals(owner) & r.operationId.equals(operation),
          ))
          .getSingleOrNull();

  Future<StoredPublicationSource?> _source(String id) => (db.select(
    db.sharingPublicationSources,
  )..where((r) => r.owner.equals(owner) & r.id.equals(id))).getSingleOrNull();

  Future<void> _grant(StoredPublicationSource source) async {
    final consent = await capture.available(source.goalId);
    if (source.owner != owner ||
        source.sessionId != sharing.sessionId ||
        consent?.sessionId != sharing.sessionId ||
        consent?.grant.id != source.grantId ||
        await capture.isRemoving(source)) {
      throw const CompanionServiceFailure('sharing_unavailable');
    }
  }

  Future<List<PublicationAttempt>> pending() => db.transaction(() async {
    await sharing.currentState();
    final rows =
        await (db.select(db.sharingPublications)
              ..where(
                (r) => r.owner.equals(owner) & r.status.isNotValue('succeeded'),
              )
              ..orderBy([(r) => OrderingTerm.asc(r.sequence)]))
            .get();
    final result = <PublicationAttempt>[];
    for (final row in rows) {
      final source = await _source(row.sourceId);
      if (source == null || source.sessionId != sharing.sessionId) {
        throw const CompanionServiceFailure('discarded');
      }
      result.add(PublicationAttempt(row, source, sharing.sessionId));
    }
    return result;
  });

  Stream<List<PublicationAttempt>> watchPending() => db
      .customSelect(
        'SELECT 1 AS publication_pending',
        readsFrom: {
          db.sharingPublications,
          db.sharingPublicationSources,
          db.sharingPublicationPhotos,
          db.sharingStates,
          db.pairingStates,
          db.sharingCommands,
          db.pairingCommands,
          db.identityStates,
        },
      )
      .watch()
      .asyncMap((_) => pending());

  Future<PublicationAttempt> begin(String operation, {bool retry = false}) =>
      db.transaction(() async {
        await sharing.currentState();
        final row = await _row(operation);
        if (row == null ||
            row.status == 'sending' ||
            row.status == 'succeeded' ||
            (!retry && (row.status != 'pending' || row.attempts != 0))) {
          throw const CompanionServiceFailure('operation_pending');
        }
        if (row.errorCode == 'publication_cancelled') {
          throw const CompanionServiceFailure('publication_cancelled');
        }
        final source = await _source(row.sourceId);
        if (source == null) throw const CompanionServiceFailure('discarded');
        final earlier =
            await (db.select(db.sharingPublications)..where(
                  (r) =>
                      r.owner.equals(owner) &
                      r.sourceId.equals(row.sourceId) &
                      r.sequence.isSmallerThanValue(row.sequence) &
                      r.status.isNotValue('succeeded'),
                ))
                .get();
        if (earlier.isNotEmpty) {
          throw const CompanionServiceFailure('operation_pending');
        }
        await _grant(source);
        final next = row.copyWith(
          status: 'sending',
          attempts: row.attempts + 1,
          errorCode: const Value(null),
        );
        await db
            .into(db.sharingPublications)
            .insertOnConflictUpdate(next.toCompanion(false));
        return PublicationAttempt(next, source, sharing.sessionId);
      });

  Future<bool> _matches(
    PublicationAttempt attempt, {
    bool cancelled = false,
  }) async {
    await sharing.currentState();
    final row = await _row(attempt.row.operationId);
    final source = await _source(attempt.source.id);
    return attempt.sessionId == sharing.sessionId &&
        attempt.row.owner == owner &&
        source?.sessionId == sharing.sessionId &&
        source?.remoteId == attempt.source.remoteId &&
        source?.remoteRevision == attempt.source.remoteRevision &&
        row?.sourceId == attempt.source.id &&
        (cancelled
            ? row?.status == 'failed' &&
                  row?.errorCode == 'publication_cancelled' &&
                  attempt.row.status == 'failed' &&
                  attempt.row.errorCode == 'publication_cancelled'
            : row?.status == 'sending') &&
        row?.attempts == attempt.row.attempts &&
        row?.requestJson == attempt.row.requestJson;
  }

  Future<void> _require(
    PublicationAttempt attempt, {
    bool latest = false,
  }) async {
    if (!await _matches(attempt)) {
      throw const CompanionServiceFailure('discarded');
    }
    await _grant(attempt.source);
    if (latest && await hasSuccessor(attempt)) {
      throw const CompanionServiceFailure('publication_superseded');
    }
  }

  Future<bool> isCurrent(
    PublicationAttempt attempt, {
    bool latest = false,
  }) async {
    try {
      await db.transaction(() => _require(attempt, latest: latest));
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> hasSuccessor(PublicationAttempt attempt) =>
      db.transaction(() async {
        await sharing.currentState();
        final later =
            await (db.select(db.sharingPublications)
                  ..where(
                    (r) =>
                        r.owner.equals(owner) &
                        r.sourceId.equals(attempt.source.id) &
                        r.sequence.isBiggerThanValue(attempt.row.sequence),
                  )
                  ..limit(1))
                .get();
        return later.isNotEmpty;
      });

  CompanionPhotoMetadata _metadata(
    StoredPublicationPhoto mapping,
    StoredPublicationSource source,
  ) {
    final body = jsonDecode(mapping.receiptJson!);
    if (body is! Map<String, dynamic> ||
        body.length != 3 ||
        body['protocol'] != companionProtocol ||
        body['operation_id'] != mapping.uploadOperationId) {
      throw const CompanionServiceFailure('invalid_response');
    }
    final photo = CompanionPhotoMetadata.fromJson(body['photo']);
    if (photo.groupId != sharing.groupId ||
        photo.authorId != sharing.memberId ||
        photo.purpose != CompanionPhotoPurpose.record ||
        photo.grantId != source.grantId) {
      throw const CompanionServiceFailure('invalid_response');
    }
    return photo;
  }

  Future<List<PublicationPhoto>> photos(PublicationAttempt attempt) =>
      db.transaction(() async {
        await _require(attempt);
        final mappings =
            await (db.select(db.sharingPublicationPhotos)
                  ..where(
                    (r) =>
                        r.owner.equals(owner) &
                        r.operationId.equals(attempt.row.operationId),
                  )
                  ..orderBy([(r) => OrderingTerm.asc(r.position)]))
                .get();
        final result = <PublicationPhoto>[];
        for (final row in mappings) {
          final photo =
              await (db.select(db.recordPhotos)..where(
                    (r) => r.owner.equals(owner) & r.id.equals(row.photoId),
                  ))
                  .getSingle();
          if (photo.recordId != attempt.row.recordId ||
              !attempt.row.shareDetails) {
            throw const CompanionServiceFailure('invalid_request');
          }
          result.add(
            PublicationPhoto(
              row,
              photo,
              row.receiptJson == null ? null : _metadata(row, attempt.source),
            ),
          );
        }
        return result;
      });

  Future<void> acceptPhoto(
    PublicationAttempt attempt,
    CompanionPhotoUpload request,
    CompanionPhotoReceipt receipt,
  ) => db.transaction(() async {
    await _require(attempt);
    if (attempt.row.requestJson != null) {
      throw const CompanionServiceFailure('operation_pending');
    }
    final candidates = await photos(attempt);
    final mapping = candidates
        .where((p) => p.row.uploadOperationId == request.operationId)
        .singleOrNull;
    if (mapping == null ||
        request.groupId != sharing.groupId ||
        request.grantId != attempt.source.grantId ||
        request.purpose != CompanionPhotoPurpose.record ||
        request.bytes.length != mapping.photo.byteCount ||
        sha256.convert(request.bytes).toString() != mapping.photo.sha256) {
      throw const CompanionServiceFailure('invalid_request');
    }
    final valid = CompanionPhotoReceipt.fromJson(
      receipt.toJson(),
      request: request,
    );
    if (valid.photo.authorId != sharing.memberId) {
      throw const CompanionServiceFailure('invalid_response');
    }
    final encoded = jsonEncode(valid.toJson());
    if (mapping.row.receiptJson != null && mapping.row.receiptJson != encoded) {
      throw const CompanionServiceFailure('invalid_response');
    }
    await (db.update(db.sharingPublicationPhotos)..where(
          (r) =>
              r.owner.equals(owner) &
              r.operationId.equals(attempt.row.operationId) &
              r.photoId.equals(mapping.photo.id),
        ))
        .write(SharingPublicationPhotosCompanion(receiptJson: Value(encoded)));
  });

  Future<PublicationAttempt> freeze(PublicationAttempt attempt) =>
      db.transaction(() async {
        await _require(attempt, latest: true);
        if (attempt.command != null) return attempt;
        final row = attempt.row;
        final source = attempt.source;
        final uploaded = await photos(attempt);
        if (uploaded.any((p) => p.remote == null)) {
          throw const CompanionServiceFailure('photo_unavailable');
        }
        if (row.kind == 'remove' && source.remoteId == null) {
          throw const CompanionServiceFailure('operation_pending');
        }
        String instant(int value) => DateTime.fromMicrosecondsSinceEpoch(
          value,
          isUtc: true,
        ).toIso8601String();
        final command = SharingCommand.fromJson(
          SharingCommandKind.values.byName(row.kind),
          {
            'protocol': companionProtocol,
            'operation_id': row.operationId,
            'group_id': sharing.groupId,
            if (row.kind == 'remove') 'record_id': source.remoteId,
            if (row.kind == 'publish') ...{
              'grant_id': source.grantId,
              'source_id': source.id,
              'base_revision': source.remoteRevision,
              'title': row.title,
              'occurred_at': instant(row.occurredAt),
              'completed_at': row.completedAt == null
                  ? null
                  : instant(row.completedAt!),
              'share_details': row.shareDetails,
              'text': row.content,
              'photo_ids': uploaded.map((p) => p.remote!.id).toList(),
            },
          },
        );
        final next = row.copyWith(
          requestJson: Value(jsonEncode(command.toJson())),
        );
        await db
            .into(db.sharingPublications)
            .insertOnConflictUpdate(next.toCompanion(false));
        return PublicationAttempt(next, source, sharing.sessionId);
      });

  Future<void> _recordState(PublicationAttempt attempt, String state) async {
    if (attempt.row.recordId == null || await hasSuccessor(attempt)) return;
    await (db.update(db.dayRecords)..where(
          (r) =>
              r.owner.equals(owner) &
              r.id.equals(attempt.row.recordId!) &
              r.revision.equals(attempt.row.recordRevision!) &
              r.syncState.isIn(['pending', 'failed']),
        ))
        .write(DayRecordsCompanion(syncState: Value(state)));
  }

  Future<void> _settle(
    PublicationAttempt attempt,
    Map<String, Object?> outcome, {
    String? recordState,
  }) async {
    // Completion evidence stays for eligibility, but resolved private payloads
    // and upload pins are no longer needed for recovery.
    await db
        .into(db.sharingPublications)
        .insertOnConflictUpdate(
          attempt.row
              .copyWith(
                status: 'succeeded',
                receiptJson: Value(jsonEncode(outcome)),
                errorCode: const Value(null),
                requestJson: const Value(null),
                content: '',
                shareDetails: false,
              )
              .toCompanion(false),
        );
    await (db.delete(db.sharingPublicationPhotos)..where(
          (r) =>
              r.owner.equals(owner) &
              r.operationId.equals(attempt.row.operationId),
        ))
        .go();
    if (recordState != null) await _recordState(attempt, recordState);
    await sharing.advanceCache();
  }

  Future<bool> finish(
    PublicationAttempt attempt,
    SharingReceipt receipt,
  ) => db.transaction(() async {
    if (!await _matches(attempt)) return false;
    await _grant(attempt.source);
    final command = attempt.command;
    if (command == null) throw const CompanionServiceFailure('invalid_request');
    final valid = SharingReceipt.fromJson(receipt.toJson(), command: command);
    final source = attempt.source;
    if (command.kind == SharingCommandKind.publish &&
        source.remoteId != null &&
        valid.resourceId != source.remoteId) {
      throw const CompanionServiceFailure('invalid_response');
    }
    final published = command.kind == SharingCommandKind.publish;
    await db
        .into(db.sharingPublicationSources)
        .insertOnConflictUpdate(
          source
              .copyWith(
                remoteId: Value(published ? valid.resourceId : null),
                remoteRevision: published ? valid.revision : 0,
              )
              .toCompanion(false),
        );
    if (!published) await sharing.forgetRecord(valid.resourceId);
    await _settle(
      attempt,
      {'outcome': 'server', 'receipt': valid.toJson()},
      recordState: published && attempt.row.shareDetails
          ? 'confirmed'
          : 'local',
    );
    return true;
  });

  Future<void> settleLocalRemoval(PublicationAttempt attempt) =>
      db.transaction(() async {
        await _require(attempt);
        if (attempt.row.kind != 'remove' ||
            attempt.source.remoteId != null ||
            attempt.command != null) {
          throw const CompanionServiceFailure('invalid_request');
        }
        await _settle(attempt, {'outcome': 'local'}, recordState: 'local');
      });

  Future<void> supersede(
    PublicationAttempt attempt, {
    PublicationResolution? resolution,
  }) => db.transaction(() async {
    final cancelled = await _matches(attempt, cancelled: true);
    if (cancelled) {
      await _grant(attempt.source);
    } else {
      await _require(attempt);
    }
    if (!await hasSuccessor(attempt)) {
      throw const CompanionServiceFailure('operation_pending');
    }
    final command = attempt.command;
    if (command != null) {
      if (command.kind != SharingCommandKind.publish ||
          (!cancelled && resolution == null) ||
          (resolution != null &&
              (resolution.receipt != null ||
                  resolution.request.fingerprint !=
                      sha256
                          .convert(utf8.encode(command.fingerprintInput))
                          .toString()))) {
        throw const CompanionServiceFailure('operation_pending');
      }
      resolution?.validateCommand(command);
    } else if (resolution != null) {
      throw const CompanionServiceFailure('invalid_request');
    }
    await _settle(attempt, {
      'outcome': 'superseded',
      if (resolution != null) 'resolution': resolution.toJson(),
      if (cancelled) 'error_code': 'publication_cancelled',
    });
  });

  Future<bool> fail(
    PublicationAttempt attempt,
    CompanionServiceFailure failure,
  ) => db.transaction(() async {
    if (!await _matches(attempt)) return false;
    await db
        .into(db.sharingPublications)
        .insertOnConflictUpdate(
          attempt.row
              .copyWith(
                status: failure.outcomeUnknown ? 'uncertain' : 'failed',
                errorCode: Value(sharingErrorCode(failure.code)),
              )
              .toCompanion(false),
        );
    await _recordState(attempt, 'failed');
    return true;
  });

  Future<void> recoverInterrupted() => db.transaction(() async {
    await sharing.currentState();
    await (db.update(
      db.sharingPublications,
    )..where((r) => r.owner.equals(owner) & r.status.equals('sending'))).write(
      const SharingPublicationsCompanion(
        status: Value('uncertain'),
        errorCode: Value('interrupted'),
      ),
    );
  });
}
