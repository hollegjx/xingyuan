import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

import '../../../data/local/app_database.dart';
import '../../../data/local/local_goal_repository.dart';
import 'companion_service.dart';

class RecordSharingConsent {
  const RecordSharingConsent._({
    required this.owner,
    required this.goalId,
    required this.sessionId,
    required this.grant,
  });
  final String owner;
  final int goalId;
  final String sessionId;
  final SharingGrant grant;
}

class RecordSharingState {
  const RecordSharingState(this.consent, this.draftShared, this.syncState);
  final RecordSharingConsent? consent;
  final bool draftShared;
  final String syncState;
}

/// Captures publication intent inside the personal mutation's transaction.
/// Transport must resolve an attempted head before sending its successor.
class LocalPublicationStore {
  LocalPublicationStore(this.goals);
  final LocalGoalRepository goals;
  AppDatabase get db => goals.db;
  String get owner => goals.owner;

  Future<RecordSharingState> recordState(String id) => db.transaction(() async {
    await goals.requireActiveIdentity();
    final record = await (db.select(
      db.dayRecords,
    )..where((r) => r.owner.equals(owner) & r.id.equals(id))).getSingle();
    final target = await available(record.goalId);
    final eligible = target != null && await validConsent(record, target);
    return RecordSharingState(
      eligible ? target : null,
      record.draftShareWithPartner &&
          await recordConsent(record, 'draft') != null,
      record.syncState,
    );
  });

  Stream<RecordSharingState> watchRecordState(String id) => db
      .customSelect(
        'SELECT 1 AS publication_record_state',
        readsFrom: {
          db.dayRecords,
          db.recordSharingConsents,
          db.sharingGrantsCache,
          db.sharingPublicationSources,
          db.sharingStates,
          db.pairingStates,
          db.sharingCommands,
          db.pairingCommands,
          db.identityStates,
        },
      )
      .watch()
      .asyncMap((_) => recordState(id));

  Future<RecordSharingConsent?> available(int goalId) => db.transaction(
    () async {
      await goals.requireActiveIdentity();
      final state = await (db.select(
        db.sharingStates,
      )..where((r) => r.owner.equals(owner))).getSingleOrNull();
      final pair = await (db.select(
        db.pairingStates,
      )..where((r) => r.owner.equals(owner))).getSingleOrNull();
      if (state == null ||
          pair?.stateJson == null ||
          pair!.generation != state.generation) {
        return null;
      }
      final paired = PairingState.fromJson(jsonDecode(pair.stateJson!));
      if (paired.group?.id != state.groupId ||
          paired.memberId != state.memberId ||
          paired.group?.partnerId != state.partnerId) {
        return null;
      }
      final leaving =
          await (db.select(db.pairingCommands)
                ..where((r) => r.owner.equals(owner) & r.kind.equals('leave')))
              .getSingleOrNull();
      if (leaving != null) return null;
      final goal =
          await (db.select(db.goals)
                ..where((r) => r.id.equals(goalId) & r.owner.equals(owner)))
              .getSingleOrNull();
      if (goal == null) return null;
      final row =
          await (db.select(db.sharingGrantsCache)..where(
                (r) => r.owner.equals(owner) & r.goalId.equals(goal.globalId),
              ))
              .getSingleOrNull();
      if (row == null) return null;
      final stopping =
          await (db.select(db.sharingCommands)..where(
                (r) =>
                    r.owner.equals(owner) &
                    r.subject.equals('grant:${row.id}') &
                    r.kind.equals('stop') &
                    r.status.isNotValue('succeeded'),
              ))
              .get();
      if (stopping.isNotEmpty) return null;
      return RecordSharingConsent._(
        owner: owner,
        goalId: goalId,
        sessionId: state.sessionId,
        grant: SharingGrant.fromJson(jsonDecode(row.documentJson)),
      );
    },
  );

  bool _matches(RecordSharingConsent a, RecordSharingConsent b) =>
      a.owner == b.owner &&
      a.goalId == b.goalId &&
      a.sessionId == b.sessionId &&
      a.grant.id == b.grant.id;

  // Eligibility is captured when the record is created, not inferred later
  // from clocks on two machines. This marker does not itself authorize sharing.
  Future<void> recordCreated(StoredDayRecord record) =>
      db.transaction(() async {
        final target = await available(record.goalId);
        if (target == null ||
            record.owner != owner ||
            record.revision != 0 ||
            record.draftText != null ||
            record.savedAt != null ||
            record.createdAt < target.grant.enabledAt.microsecondsSinceEpoch) {
          return;
        }
        await db
            .into(db.recordSharingConsents)
            .insert(
              RecordSharingConsentsCompanion.insert(
                owner: owner,
                recordId: record.id,
                stage: 'created',
                sessionId: target.sessionId,
                grantId: target.grant.id,
              ),
            );
      });

  Future<bool> _eligible(
    StoredDayRecord record,
    RecordSharingConsent target,
  ) async {
    final source =
        await (db.select(db.sharingPublicationSources)..where(
              (r) =>
                  r.owner.equals(owner) &
                  r.goalId.equals(record.goalId) &
                  r.day.equals(record.day) &
                  r.grantId.equals(target.grant.id),
            ))
            .getSingleOrNull();
    if (source != null && await isRemoving(source)) return false;
    final row =
        await (db.select(db.recordSharingConsents)..where(
              (r) =>
                  r.owner.equals(owner) &
                  r.recordId.equals(record.id) &
                  r.stage.equals('created'),
            ))
            .getSingleOrNull();
    return row?.sessionId == target.sessionId &&
        row?.grantId == target.grant.id;
  }

  Future<bool> isRemoving(StoredPublicationSource source) async {
    if (source.remoteId == null) return false;
    final commands =
        await (db.select(db.sharingCommands)..where(
              (r) =>
                  r.owner.equals(owner) &
                  r.recordId.equals(source.remoteId!) &
                  r.kind.equals('remove') &
                  r.status.isNotValue('succeeded'),
            ))
            .get();
    return commands.isNotEmpty;
  }

  Future<bool> validConsent(
    StoredDayRecord record,
    RecordSharingConsent consent,
  ) => db.transaction(() async {
    final current = await available(record.goalId);
    return record.owner == owner &&
        current != null &&
        _matches(current, consent) &&
        record.createdAt >= current.grant.enabledAt.microsecondsSinceEpoch &&
        await _eligible(record, current);
  });

  Future<RecordSharingConsent?> recordConsent(
    StoredDayRecord record,
    String stage,
  ) => db.transaction(() async {
    final target = await available(record.goalId);
    if (target == null ||
        record.owner != owner ||
        record.createdAt < target.grant.enabledAt.microsecondsSinceEpoch ||
        !await _eligible(record, target)) {
      return null;
    }
    final stored =
        await (db.select(db.recordSharingConsents)..where(
              (r) =>
                  r.owner.equals(owner) &
                  r.recordId.equals(record.id) &
                  r.stage.equals(stage),
            ))
            .getSingleOrNull();
    return stored?.sessionId == target.sessionId &&
            stored?.grantId == target.grant.id
        ? target
        : null;
  });

  Future<void> writeConsent(
    String record,
    String stage,
    RecordSharingConsent? consent,
  ) => db.transaction(() async {
    await goals.requireActiveIdentity();
    if (stage != 'draft' && stage != 'saved') {
      throw const CompanionServiceFailure('invalid_request');
    }
    final row =
        await (db.select(db.dayRecords)
              ..where((r) => r.owner.equals(owner) & r.id.equals(record)))
            .getSingleOrNull();
    if (row == null || (consent != null && !await validConsent(row, consent))) {
      throw const CompanionServiceFailure('sharing_unavailable');
    }
    await (db.delete(db.recordSharingConsents)..where(
          (r) =>
              r.owner.equals(owner) &
              r.recordId.equals(record) &
              r.stage.equals(stage),
        ))
        .go();
    if (consent == null) return;
    await db
        .into(db.recordSharingConsents)
        .insert(
          RecordSharingConsentsCompanion.insert(
            owner: owner,
            recordId: record,
            stage: stage,
            sessionId: consent.sessionId,
            grantId: consent.grant.id,
          ),
        );
  });

  Future<void> capture(
    int goalId,
    String day, {
    bool recordMutation = false,
    bool completionMutation = false,
  }) => db.transaction(() async {
    await goals.requireActiveIdentity();
    final target = await available(goalId);
    if (target == null) return;
    final now = goals.clock.read().instant.microsecondsSinceEpoch;
    final enabled = target.grant.enabledAt.microsecondsSinceEpoch;
    if (now < enabled) return;
    var source =
        await (db.select(db.sharingPublicationSources)..where(
              (r) =>
                  r.owner.equals(owner) &
                  r.grantId.equals(target.grant.id) &
                  r.goalId.equals(goalId) &
                  r.day.equals(day),
            ))
            .getSingleOrNull();
    final record =
        await (db.select(db.dayRecords)..where(
              (r) =>
                  r.owner.equals(owner) &
                  r.goalId.equals(goalId) &
                  r.day.equals(day),
            ))
            .getSingleOrNull();
    if (source != null && await isRemoving(source)) {
      if (record != null && recordMutation) await _local(record.id);
      return;
    }
    var checkin =
        await (db.select(db.checkIns)..where(
              (r) =>
                  r.goalId.equals(goalId) &
                  r.completedDay.equals(day) &
                  r.completed.equals(true) &
                  r.completedAt.isBiggerOrEqualValue(enabled),
            ))
            .getSingleOrNull();
    if (checkin != null && !completionMutation) {
      final captured = source == null
          ? <StoredPublication>[]
          : await (db.select(db.sharingPublications)..where(
                  (r) =>
                      r.owner.equals(owner) &
                      r.sourceId.equals(source!.id) &
                      r.completedAt.equals(checkin!.completedAt),
                ))
                .get();
      if (captured.isEmpty) checkin = null;
    }
    final details =
        record != null &&
        record.savedAt != null &&
        record.deletedAt == null &&
        record.shareWithPartner &&
        await recordConsent(record, 'saved') != null;
    final photos = details
        ? await (db.select(db.recordPhotos)
                ..where(
                  (r) =>
                      r.owner.equals(owner) &
                      r.recordId.equals(record.id) &
                      r.savedPosition.isNotNull(),
                )
                ..orderBy([(r) => OrderingTerm.asc(r.savedPosition)]))
              .get()
        : <StoredRecordPhoto>[];
    final publish =
        checkin != null ||
        (details && (record.content.trim().isNotEmpty || photos.isNotEmpty));
    if (source == null && !publish) return;
    if (source == null) {
      final sourceId = const Uuid().v4();
      await db
          .into(db.sharingPublicationSources)
          .insert(
            SharingPublicationSourcesCompanion.insert(
              id: sourceId,
              owner: owner,
              goalId: goalId,
              day: day,
              sessionId: target.sessionId,
              grantId: target.grant.id,
            ),
          );
      source =
          await (db.select(db.sharingPublicationSources)
                ..where((r) => r.owner.equals(owner) & r.id.equals(sourceId)))
              .getSingle();
    }
    if (source.sessionId != target.sessionId) return;
    final sourceId = source.id;
    // Only intents that have never started can be replaced. An upload also
    // counts as starting, even before the record's HTTP request is frozen.
    await (db.delete(db.sharingPublications)..where(
          (r) =>
              r.owner.equals(owner) &
              r.sourceId.equals(sourceId) &
              r.status.equals('pending') &
              r.attempts.equals(0) &
              r.requestJson.isNull(),
        ))
        .go();
    final unresolved =
        await (db.select(db.sharingPublications)..where(
              (r) =>
                  r.owner.equals(owner) &
                  r.sourceId.equals(sourceId) &
                  r.status.isNotValue('succeeded'),
            ))
            .get();
    if (!publish && source.remoteId == null && unresolved.isEmpty) {
      if (record != null && recordMutation) await _local(record.id);
      return;
    }
    final title =
        await (db.select(db.goalTitles)
              ..where(
                (r) =>
                    r.goalId.equals(goalId) &
                    r.effectiveDay.isSmallerOrEqualValue(day),
              )
              ..orderBy([(r) => OrderingTerm.desc(r.effectiveDay)])
              ..limit(1))
            .getSingle();
    final operation = const Uuid().v4();
    await db
        .into(db.sharingPublications)
        .insert(
          SharingPublicationsCompanion.insert(
            owner: owner,
            operationId: operation,
            sourceId: sourceId,
            recordId: Value(record?.id),
            recordRevision: Value(record?.revision),
            kind: publish ? 'publish' : 'remove',
            title: checkin?.titleSnapshot ?? title.title,
            occurredAt: now,
            completedAt: Value(checkin?.completedAt),
            shareDetails: details,
            content: details ? record.content : '',
          ),
        );
    for (var i = 0; i < photos.length; i++) {
      await db
          .into(db.sharingPublicationPhotos)
          .insert(
            SharingPublicationPhotosCompanion.insert(
              owner: owner,
              operationId: operation,
              photoId: photos[i].id,
              position: i,
              uploadOperationId: const Uuid().v4(),
            ),
          );
    }
    if (record != null && (recordMutation || details)) {
      await (db.update(db.dayRecords)
            ..where((r) => r.owner.equals(owner) & r.id.equals(record.id)))
          .write(const DayRecordsCompanion(syncState: Value('pending')));
    }
  });

  Future<void> _local(String record) =>
      (db.update(db.dayRecords)
            ..where((r) => r.owner.equals(owner) & r.id.equals(record)))
          .write(const DayRecordsCompanion(syncState: Value('local')));
}
