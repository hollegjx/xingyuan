import 'dart:convert';

import 'package:characters/characters.dart';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

import '../../../data/local/app_database.dart';
import '../../goals/domain/goal.dart';
import 'companion_service.dart';
import 'local_pairing_store.dart';

class SharingAttempt {
  SharingAttempt(this.row, this.sessionId)
    : command = SharingCommand.fromJson(
        SharingCommandKind.values.byName(row.kind),
        jsonDecode(row.requestJson),
      );
  final StoredSharingCommand row;
  final String sessionId;
  final SharingCommand command;
}

class SharingLocalSnapshot {
  SharingLocalSnapshot(this.state, this.grants, this.records, this.commands);
  final StoredSharingState state;
  final List<SharingGrant> grants;
  final List<SharedRecord> records;
  final List<SharingAttempt> commands;
}

class SharingLocalGoal {
  const SharingLocalGoal(this.goal, this.globalId);
  final Goal goal;
  final String globalId;
}

class LocalSharingStore {
  LocalSharingStore._(
    this.pairing,
    this.groupId,
    this.memberId,
    this.partnerId,
    this.sessionId,
  );
  final LocalPairingStore pairing;
  final String groupId;
  final String memberId;
  final String partnerId;
  final String sessionId;
  String get owner => pairing.owner;
  AppDatabase get db => pairing.db;
  int get _now => pairing.goals.clock.read().instant.microsecondsSinceEpoch;

  static Future<LocalSharingStore> open(LocalPairingStore pairing) =>
      pairing.db.transaction(() async {
        final paired = (await pairing.snapshot()).state;
        final group = paired?.group;
        if (group == null) {
          throw const CompanionServiceFailure('pair_unavailable');
        }
        final old = await (pairing.db.select(
          pairing.db.sharingStates,
        )..where((r) => r.owner.equals(pairing.owner))).getSingleOrNull();
        final changed =
            old == null ||
            old.generation != pairing.generation ||
            old.groupId != group.id ||
            old.memberId != paired!.memberId ||
            old.partnerId != group.partnerId;
        final store = LocalSharingStore._(
          pairing,
          group.id,
          paired!.memberId,
          group.partnerId,
          changed ? const Uuid().v4() : old.sessionId,
        );
        if (changed) {
          await store.db.clearSharingContent(store.owner);
          await store.db
              .into(store.db.sharingStates)
              .insert(
                SharingStatesCompanion.insert(
                  owner: store.owner,
                  generation: pairing.generation,
                  sessionId: store.sessionId,
                  groupId: group.id,
                  memberId: paired.memberId,
                  partnerId: group.partnerId,
                ),
              );
        }
        return store;
      });

  Future<StoredSharingState> _current() async {
    final paired = (await pairing.snapshot()).state;
    if (paired?.group?.id != groupId ||
        paired?.memberId != memberId ||
        paired?.group?.partnerId != partnerId) {
      throw const CompanionServiceFailure('discarded');
    }
    final row = await (db.select(
      db.sharingStates,
    )..where((r) => r.owner.equals(owner))).getSingleOrNull();
    if (row == null ||
        row.groupId != groupId ||
        row.generation != pairing.generation ||
        row.sessionId != sessionId ||
        row.memberId != memberId ||
        row.partnerId != partnerId) {
      throw const CompanionServiceFailure('discarded');
    }
    return row;
  }

  Future<bool> isCurrent() async {
    try {
      await db.transaction(_current);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<StoredSharingState> currentState() => db.transaction(_current);

  Future<void> advanceCache() => db.transaction(() async {
    await _advance(await _current());
  });

  Stream<bool> watchCurrent() => db
      .customSelect(
        'SELECT 1 AS sharing_scope',
        readsFrom: {db.pairingStates, db.sharingStates, db.identityStates},
      )
      .watch()
      .asyncMap((_) => isCurrent());

  Future<void> forgetRemote() => db.transaction(() async {
    await _current();
    await pairing.forgetRemote();
  });

  Future<void> forgetRecord(String record) => db.transaction(() async {
    final current = await _current();
    await _dropRecord(record);
    await _advance(current);
  });

  Future<List<SharingLocalGoal>> personalGoals() => db.transaction(() async {
    await _current();
    final goals = await pairing.goals.loadGoals();
    final rows = await (db.select(
      db.goals,
    )..where((r) => r.owner.equals(owner))).get();
    final ids = {for (final row in rows) row.id: row.globalId};
    return [for (final goal in goals) SharingLocalGoal(goal, ids[goal.id]!)];
  });

  Future<void> discardFailed(String operation) => db.transaction(() async {
    await _current();
    final command = await _command(operation);
    if (command?.status != 'failed') {
      throw const CompanionServiceFailure('operation_pending');
    }
    await (db.delete(db.sharingCommands)..where(
          (r) => r.owner.equals(owner) & r.operationId.equals(operation),
        ))
        .go();
  });

  Future<SharingLocalSnapshot> snapshot() => db.transaction(() async {
    final state = await _current();
    final grants = await (db.select(
      db.sharingGrantsCache,
    )..where((r) => r.owner.equals(owner))).get();
    final records =
        await (db.select(db.sharedRecordsCache)
              ..where((r) => r.owner.equals(owner))
              ..orderBy([(r) => OrderingTerm.desc(r.sequence)]))
            .get();
    final commands =
        await (db.select(db.sharingCommands)
              ..where(
                (r) => r.owner.equals(owner) & r.status.isNotValue('succeeded'),
              )
              ..orderBy([(r) => OrderingTerm.asc(r.sequence)]))
            .get();
    return SharingLocalSnapshot(
      state,
      List.unmodifiable(
        grants.map((r) => SharingGrant.fromJson(jsonDecode(r.documentJson))),
      ),
      List.unmodifiable(
        records.map((r) => SharedRecord.fromJson(jsonDecode(r.documentJson))),
      ),
      List.unmodifiable(commands.map((row) => SharingAttempt(row, sessionId))),
    );
  });

  SharedPageRequest _page(int? before, int? revision, {String? record}) =>
      SharedPageRequest.fromJson({
        'protocol': companionProtocol,
        'group_id': groupId,
        'before_sequence': before,
        'revision': before == null ? null : revision,
        'record_id': ?record,
      }, replies: record != null);

  void _author(String id) {
    if (id != memberId && id != partnerId) {
      throw const CompanionServiceFailure('invalid_response');
    }
  }

  Future<bool> acceptSnapshot({
    required List<SharingGrants> grantPages,
    required List<SharedFeedPage> feedPages,
    required int expectedRevision,
  }) => db.transaction(() async {
    final current = await _current();
    if (current.cacheRevision != expectedRevision) return false;
    if (grantPages.isEmpty || feedPages.isEmpty) {
      throw const CompanionServiceFailure('invalid_response');
    }
    final revision = grantPages.first.revision;
    if (current.serverRevision != null && revision < current.serverRevision!) {
      return false;
    }
    final grants = <SharingGrant>[];
    final records = <SharedRecord>[];
    int? before;
    for (var i = 0; i < grantPages.length; i++) {
      final page = SharingGrants.fromJson(
        grantPages[i].toJson(),
        request: _page(before, revision),
      );
      if (page.revision != revision ||
          (i + 1 < grantPages.length && page.nextBefore == null)) {
        throw const CompanionServiceFailure('snapshot_changed');
      }
      grants.addAll(page.grants);
      before = page.nextBefore;
    }
    if (before != null) throw const CompanionServiceFailure('snapshot_changed');
    for (var i = 0; i < feedPages.length; i++) {
      final page = SharedFeedPage.fromJson(
        feedPages[i].toJson(),
        request: _page(before, revision),
      );
      if (page.revision != revision ||
          (i + 1 < feedPages.length && page.nextBefore == null)) {
        throw const CompanionServiceFailure('snapshot_changed');
      }
      records.addAll(page.records);
      before = page.nextBefore;
    }
    if (before != null ||
        grants.map((g) => g.id).toSet().length != grants.length ||
        grants.map((g) => g.goalId).toSet().length != grants.length ||
        records.map((r) => r.id).toSet().length != records.length) {
      throw const CompanionServiceFailure('invalid_response');
    }
    final grantIds = grants.map((g) => g.id).toSet();
    for (final record in records) {
      _author(record.authorId);
      if (record.authorId == memberId && !grantIds.contains(record.grantId)) {
        throw const CompanionServiceFailure('invalid_response');
      }
    }
    final retained = records.map((r) => r.id).toSet();
    final old = await (db.select(
      db.sharedRecordsCache,
    )..where((r) => r.owner.equals(owner))).get();
    final oldRecords = {for (final row in old) row.id: row};
    for (final record in records) {
      final cached = oldRecords[record.id];
      if (cached == null) continue;
      final previous = SharedRecord.fromJson(jsonDecode(cached.documentJson));
      if (record.authorId != previous.authorId ||
          record.grantId != previous.grantId ||
          record.sequence != previous.sequence ||
          record.revision < previous.revision ||
          (record.revision == previous.revision &&
              jsonEncode(record.toJson()) != cached.documentJson)) {
        throw const CompanionServiceFailure('invalid_response');
      }
    }
    final oldGrants = await (db.select(
      db.sharingGrantsCache,
    )..where((r) => r.owner.equals(owner))).get();
    final grantsById = {for (final row in oldGrants) row.id: row};
    for (final grant in grants) {
      final previous = grantsById[grant.id];
      if (previous != null &&
          previous.documentJson != jsonEncode(grant.toJson())) {
        throw const CompanionServiceFailure('invalid_response');
      }
    }
    for (final grant in oldGrants) {
      if (!grantIds.contains(grant.id)) await _dropGrant(grant.id);
    }
    for (final row in old) {
      if (!retained.contains(row.id)) await _dropRecord(row.id);
    }
    for (final grant in grants) {
      await db
          .into(db.sharingGrantsCache)
          .insertOnConflictUpdate(
            SharingGrantsCacheCompanion.insert(
              owner: owner,
              id: grant.id,
              goalId: grant.goalId,
              documentJson: jsonEncode(grant.toJson()),
            ),
          );
    }
    for (final record in records) {
      await db
          .into(db.sharedRecordsCache)
          .insertOnConflictUpdate(
            SharedRecordsCacheCompanion.insert(
              owner: owner,
              id: record.id,
              grantId: record.grantId,
              authorId: record.authorId,
              sequence: record.sequence,
              documentJson: jsonEncode(record.toJson()),
            ),
          );
    }
    await db
        .into(db.sharingStates)
        .insertOnConflictUpdate(
          current
              .copyWith(
                cacheRevision: current.cacheRevision + 1,
                serverRevision: Value(revision),
                refreshedAt: Value(_now),
              )
              .toCompanion(false),
        );
    return true;
  });

  Future<void> _dropRecord(String id, {String? keepOperation}) async {
    final sources = await (db.select(
      db.sharingPublicationSources,
    )..where((r) => r.owner.equals(owner) & r.remoteId.equals(id))).get();
    for (final source in sources) {
      final records =
          await (db.select(db.dayRecords)..where(
                (r) =>
                    r.owner.equals(owner) &
                    r.goalId.equals(source.goalId) &
                    r.day.equals(source.day),
              ))
              .get();
      for (final record in records) {
        await (db.delete(db.recordSharingConsents)..where(
              (r) =>
                  r.owner.equals(owner) &
                  r.recordId.equals(record.id) &
                  r.stage.isNotValue('created'),
            ))
            .go();
        await (db.update(
          db.dayRecords,
        )..where((r) => r.owner.equals(owner) & r.id.equals(record.id))).write(
          const DayRecordsCompanion(
            shareWithPartner: Value(false),
            draftShareWithPartner: Value(false),
            syncState: Value('local'),
          ),
        );
      }
      await (db.delete(
        db.sharingPublicationSources,
      )..where((r) => r.owner.equals(owner) & r.id.equals(source.id))).go();
    }
    await (db.delete(db.sharingCommands)..where(
          (r) =>
              r.owner.equals(owner) &
              r.recordId.equals(id) &
              (keepOperation == null
                  ? const Constant(true)
                  : r.operationId.isNotValue(keepOperation)),
        ))
        .go();
    await (db.delete(
      db.sharedRecordsCache,
    )..where((r) => r.owner.equals(owner) & r.id.equals(id))).go();
  }

  Future<void> _dropGrant(String id, {String? keepOperation}) async {
    await db.clearPublicationIndicators(owner, grantId: id);
    final commands = await (db.select(
      db.sharingCommands,
    )..where((r) => r.owner.equals(owner))).get();
    for (final row in commands) {
      final command = SharingAttempt(row, sessionId).command;
      if (command.grantId == id && command.operationId != keepOperation) {
        await (db.delete(db.sharingCommands)..where(
              (r) =>
                  r.owner.equals(owner) &
                  r.operationId.equals(command.operationId),
            ))
            .go();
      }
    }
    final records = await (db.select(
      db.sharedRecordsCache,
    )..where((r) => r.owner.equals(owner) & r.grantId.equals(id))).get();
    for (final record in records) {
      await _dropRecord(record.id);
    }
    await (db.delete(
      db.sharingGrantsCache,
    )..where((r) => r.owner.equals(owner) & r.id.equals(id))).go();
  }

  Future<SharedRecord> _record(String id) async {
    final row = await (db.select(
      db.sharedRecordsCache,
    )..where((r) => r.owner.equals(owner) & r.id.equals(id))).getSingleOrNull();
    if (row == null) throw const CompanionServiceFailure('record_unavailable');
    return SharedRecord.fromJson(jsonDecode(row.documentJson));
  }

  Future<List<SharedReply>> replies(String record) => db.transaction(() async {
    await _current();
    await _record(record);
    final rows =
        await (db.select(db.sharedRepliesCache)
              ..where((r) => r.owner.equals(owner) & r.recordId.equals(record))
              ..orderBy([(r) => OrderingTerm.asc(r.sequence)]))
            .get();
    return List.unmodifiable(
      rows.map((r) => SharedReply.fromJson(jsonDecode(r.documentJson))),
    );
  });

  Future<bool> acceptReplies(
    String record,
    List<SharedRepliesPage> pages, {
    required int expectedRevision,
  }) => db.transaction(() async {
    final current = await _current();
    if (current.cacheRevision != expectedRevision) return false;
    await _record(record);
    if (pages.isEmpty) throw const CompanionServiceFailure('invalid_response');
    final revision = pages.first.revision;
    if (current.serverRevision != null && revision < current.serverRevision!) {
      return false;
    }
    final replies = <SharedReply>[];
    int? before;
    for (var i = 0; i < pages.length; i++) {
      final page = SharedRepliesPage.fromJson(
        pages[i].toJson(),
        request: _page(before, revision, record: record),
      );
      if (page.revision != revision ||
          (i + 1 < pages.length && page.nextBefore == null)) {
        throw const CompanionServiceFailure('snapshot_changed');
      }
      replies.addAll(page.replies);
      before = page.nextBefore;
    }
    if (before != null ||
        replies.map((r) => r.id).toSet().length != replies.length) {
      throw const CompanionServiceFailure('invalid_response');
    }
    final cachedReplies = await (db.select(
      db.sharedRepliesCache,
    )..where((r) => r.owner.equals(owner))).get();
    final repliesById = {for (final row in cachedReplies) row.id: row};
    for (final reply in replies) {
      _author(reply.authorId);
      final previous = repliesById[reply.id];
      if (previous != null &&
          previous.documentJson != jsonEncode(reply.toJson())) {
        throw const CompanionServiceFailure('invalid_response');
      }
    }
    await (db.delete(
      db.sharedRepliesCache,
    )..where((r) => r.owner.equals(owner) & r.recordId.equals(record))).go();
    for (final reply in replies) {
      await db
          .into(db.sharedRepliesCache)
          .insert(
            SharedRepliesCacheCompanion.insert(
              owner: owner,
              id: reply.id,
              recordId: record,
              authorId: reply.authorId,
              sequence: reply.sequence,
              documentJson: jsonEncode(reply.toJson()),
            ),
          );
    }
    await _advance(current.copyWith(serverRevision: Value(revision)));
    return true;
  });

  Future<void> _advance(StoredSharingState current) => db
      .into(db.sharingStates)
      .insertOnConflictUpdate(
        current
            .copyWith(cacheRevision: current.cacheRevision + 1)
            .toCompanion(false),
      );

  Future<StoredSharingDraft?> _draft(String record) =>
      (db.select(db.sharingDrafts)
            ..where((r) => r.owner.equals(owner) & r.recordId.equals(record)))
          .getSingleOrNull();

  Future<StoredSharingDraft?> draft(String record) => db.transaction(() async {
    await _current();
    await _record(record);
    return _draft(record);
  });

  Future<int> writeDraft(
    String record,
    String text, {
    required int expectedRevision,
  }) => db.transaction(() async {
    await _current();
    await _record(record);
    final old = await _draft(record);
    if ((old?.revision ?? 0) != expectedRevision) {
      throw const CompanionServiceFailure('draft_conflict');
    }
    if (text.characters.length > 10000) {
      throw const CompanionServiceFailure('request_too_large');
    }
    final revision = expectedRevision + 1;
    await db
        .into(db.sharingDrafts)
        .insertOnConflictUpdate(
          SharingDraftsCompanion.insert(
            owner: owner,
            recordId: record,
            content: Value(text),
            revision: Value(revision),
            updatedAt: _now,
          ),
        );
    return revision;
  });

  String _subject(SharingCommand command) => switch (command.kind) {
    SharingCommandKind.enable => 'goal:${command.goalId}',
    SharingCommandKind.stop => 'grant:${command.grantId}',
    SharingCommandKind.publish =>
      'source:${command.grantId}:${command.sourceId}',
    SharingCommandKind.remove => 'record:${command.recordId}',
    SharingCommandKind.reply => 'reply:${command.operationId}',
    SharingCommandKind.deleteReply => 'delete-reply:${command.replyId}',
  };

  Future<void> _permission(SharingCommand command) async {
    if (command.groupId != groupId) {
      throw const CompanionServiceFailure('pair_unavailable');
    }
    switch (command.kind) {
      case SharingCommandKind.enable:
        final goal =
            await (db.select(db.goals)..where(
                  (r) =>
                      r.owner.equals(owner) &
                      r.globalId.equals(command.goalId!),
                ))
                .getSingleOrNull();
        if (goal == null || goal.archivedAt != null) {
          throw const CompanionServiceFailure('sharing_unavailable');
        }
      case SharingCommandKind.stop:
      case SharingCommandKind.publish:
        final grant =
            await (db.select(db.sharingGrantsCache)..where(
                  (r) => r.owner.equals(owner) & r.id.equals(command.grantId!),
                ))
                .getSingleOrNull();
        if (grant == null) {
          throw const CompanionServiceFailure('sharing_unavailable');
        }
      case SharingCommandKind.remove:
      case SharingCommandKind.reply:
        final record = await _record(command.recordId!);
        if (command.kind == SharingCommandKind.remove &&
            record.authorId != memberId) {
          throw const CompanionServiceFailure('record_unavailable');
        }
        if (command.kind == SharingCommandKind.remove) {
          final sources =
              await (db.select(db.sharingPublicationSources)..where(
                    (r) => r.owner.equals(owner) & r.remoteId.equals(record.id),
                  ))
                  .get();
          for (final source in sources) {
            final pending =
                await (db.select(db.sharingPublications)..where(
                      (r) =>
                          r.owner.equals(owner) &
                          r.sourceId.equals(source.id) &
                          r.status.isNotValue('succeeded'),
                    ))
                    .get();
            if (pending.isNotEmpty) {
              throw const CompanionServiceFailure('operation_pending');
            }
          }
        }
      case SharingCommandKind.deleteReply:
        final reply =
            await (db.select(db.sharedRepliesCache)..where(
                  (r) => r.owner.equals(owner) & r.id.equals(command.replyId!),
                ))
                .getSingleOrNull();
        if (reply == null || reply.authorId != memberId) {
          throw const CompanionServiceFailure('reply_unavailable');
        }
    }
  }

  Future<StoredSharingCommand?> _command(String operation) =>
      (db.select(db.sharingCommands)..where(
            (r) => r.owner.equals(owner) & r.operationId.equals(operation),
          ))
          .getSingleOrNull();

  Future<SharingAttempt> enqueue(SharingCommand request) => db.transaction(
    () async {
      await _current();
      final command = SharingCommand.fromJson(request.kind, request.toJson());
      final json = jsonEncode(command.toJson());
      final old = await _command(command.operationId);
      if (old != null) {
        if (old.kind != command.kind.name || old.requestJson != json) {
          throw const CompanionServiceFailure('operation_conflict');
        }
        return SharingAttempt(old, sessionId);
      }
      await _permission(command);
      final subject = _subject(command);
      final pending =
          await (db.select(db.sharingCommands)..where(
                (r) =>
                    r.owner.equals(owner) &
                    r.subject.equals(subject) &
                    r.status.isIn(['pending', 'sending', 'uncertain']),
              ))
              .get();
      if (pending.isNotEmpty) {
        throw const CompanionServiceFailure('operation_pending');
      }
      final draft = command.kind == SharingCommandKind.reply
          ? await _draft(command.recordId!)
          : null;
      final recordId = command.kind == SharingCommandKind.deleteReply
          ? (await (db.select(db.sharedRepliesCache)..where(
                      (r) =>
                          r.owner.equals(owner) & r.id.equals(command.replyId!),
                    ))
                    .getSingle())
                .recordId
          : command.recordId;
      await db
          .into(db.sharingCommands)
          .insert(
            SharingCommandsCompanion.insert(
              owner: owner,
              operationId: command.operationId,
              kind: command.kind.name,
              subject: subject,
              recordId: Value(recordId),
              requestJson: json,
              draftRevision: Value(
                draft?.content == command.text ? draft?.revision : null,
              ),
              createdAt: _now,
              updatedAt: _now,
            ),
          );
      return SharingAttempt((await _command(command.operationId))!, sessionId);
    },
  );

  Future<SharingAttempt> begin(String operation) => db.transaction(() async {
    await _current();
    final row = await _command(operation);
    if (row == null || ['sending', 'succeeded'].contains(row.status)) {
      throw const CompanionServiceFailure('operation_pending');
    }
    if (row.status == 'failed' && row.errorCode == 'publication_cancelled') {
      throw const CompanionServiceFailure('publication_cancelled');
    }
    final attempt = SharingAttempt(row, sessionId);
    await _permission(attempt.command);
    final next = row.copyWith(
      status: 'sending',
      attempts: row.attempts + 1,
      errorCode: const Value(null),
      updatedAt: _now,
    );
    await db
        .into(db.sharingCommands)
        .insertOnConflictUpdate(next.toCompanion(false));
    return SharingAttempt(next, sessionId);
  });

  Future<StoredSharingCommand?> _matching(SharingAttempt attempt) async {
    final old = await _command(attempt.command.operationId);
    if (old == null ||
        attempt.sessionId != sessionId ||
        old.owner != attempt.row.owner ||
        old.status != 'sending' ||
        old.attempts != attempt.row.attempts ||
        old.requestJson != attempt.row.requestJson ||
        old.kind != attempt.row.kind) {
      return null;
    }
    return old;
  }

  Future<bool> finish(
    SharingAttempt attempt,
    SharingReceipt receipt,
  ) => db.transaction(() async {
    final current = await _current();
    final old = await _matching(attempt);
    if (old == null) return false;
    final valid = SharingReceipt.fromJson(
      receipt.toJson(),
      command: attempt.command,
    );
    await db
        .into(db.sharingCommands)
        .insertOnConflictUpdate(
          old
              .copyWith(
                status: 'succeeded',
                receiptJson: Value(jsonEncode(valid.toJson())),
                errorCode: const Value(null),
                updatedAt: _now,
              )
              .toCompanion(false),
        );
    final command = attempt.command;
    if (command.kind == SharingCommandKind.reply) {
      final draft = await _draft(command.recordId!);
      if (draft != null &&
          draft.revision == old.draftRevision &&
          draft.content == command.text) {
        await db
            .into(db.sharingDrafts)
            .insertOnConflictUpdate(
              draft
                  .copyWith(
                    content: '',
                    revision: draft.revision + 1,
                    updatedAt: _now,
                  )
                  .toCompanion(false),
            );
      }
    } else if (command.kind == SharingCommandKind.stop) {
      await _dropGrant(command.grantId!, keepOperation: command.operationId);
    } else if (command.kind == SharingCommandKind.remove) {
      await _dropRecord(command.recordId!, keepOperation: command.operationId);
    } else if (command.kind == SharingCommandKind.deleteReply) {
      await (db.delete(db.sharedRepliesCache)..where(
            (r) => r.owner.equals(owner) & r.id.equals(command.replyId!),
          ))
          .go();
    }
    await _advance(current);
    return true;
  });

  Future<bool> fail(SharingAttempt attempt, CompanionServiceFailure failure) =>
      db.transaction(() async {
        await _current();
        final old = await _matching(attempt);
        if (old == null) return false;
        await db
            .into(db.sharingCommands)
            .insertOnConflictUpdate(
              old
                  .copyWith(
                    status: failure.outcomeUnknown ? 'uncertain' : 'failed',
                    errorCode: Value(sharingErrorCode(failure.code)),
                    updatedAt: _now,
                  )
                  .toCompanion(false),
            );
        return true;
      });

  Future<void> recoverInterrupted() => db.transaction(() async {
    await _current();
    await (db.update(
      db.sharingCommands,
    )..where((r) => r.owner.equals(owner) & r.status.equals('sending'))).write(
      SharingCommandsCompanion(
        status: const Value('uncertain'),
        errorCode: const Value('interrupted'),
        updatedAt: Value(_now),
      ),
    );
  });
}

String sharingErrorCode(String code) =>
    const {
      'unconfigured',
      'not_found',
      'credential',
      'unauthorized',
      'forbidden',
      'pair_gone',
      'pair_unavailable',
      'sharing_unavailable',
      'record_unavailable',
      'reply_unavailable',
      'photo_unavailable',
      'photo_attached',
      'photo_format',
      'photo_size',
      'photo_dimensions',
      'upload_in_progress',
      'history_not_shareable',
      'revision_conflict',
      'snapshot_changed',
      'operation_conflict',
      'publication_cancelled',
      'device_busy',
      'discarded',
      'cancelled',
      'timeout',
      'network',
      'unavailable',
      'invalid_response',
      'invalid_request',
      'invalid_content_type',
      'request_too_large',
      'request_read_timeout',
      'request_interrupted',
    }.contains(code)
    ? code
    : 'unavailable';
