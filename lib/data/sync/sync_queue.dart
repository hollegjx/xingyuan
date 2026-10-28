import 'dart:math' as math;

import 'package:drift/drift.dart';

import '../local/app_database.dart';
import 'goal_document.dart';
import 'identity_store.dart';
import 'local_sync_store.dart';
import 'sync_identity.dart';
import 'sync_protocol.dart';

enum ConflictChoice { local, remote }

class ConflictResolution {
  const ConflictResolution(this.operationId, {required this.archivePreserved});
  final String operationId;
  final bool archivePreserved;
}

class SyncQueue {
  SyncQueue(this.local);
  final LocalSyncStore local;
  AppDatabase get db => local.db;
  IdentityStore get identities => IdentityStore(db);
  int get _now => local.clock.read().instant.microsecondsSinceEpoch;

  Future<SyncRequest?> prepareNext(IdentityLease lease, {bool force = false}) =>
      db.transaction(() async {
        await _requireAccount(lease);
        final conflicts =
            await (db.select(db.syncConflicts)..where(
                  (r) =>
                      r.owner.equals(lease.identity.owner) &
                      r.resolvedAt.isNull(),
                ))
                .get();
        final blocked = conflicts.map((r) => r.goalId).toSet();
        final rows =
            await (db.select(db.syncOutbox)
                  ..where(
                    (r) =>
                        r.owner.equals(lease.identity.owner) &
                        r.state.isNotValue('superseded'),
                  )
                  ..orderBy([(r) => OrderingTerm.asc(r.sequence)]))
                .get();
        final seen = <int>{};
        for (final row in rows) {
          if (!seen.add(row.goalId) || blocked.contains(row.goalId)) continue;
          if (row.state != 'pending' && row.state != 'in_flight') continue;
          if (row.retryAfter != null &&
              row.retryAfter! > _now &&
              (!force || row.lastError == SyncFailureKind.rateLimited.name)) {
            continue;
          }
          if (!force &&
              {
                SyncFailureKind.authentication.name,
                SyncFailureKind.denied.name,
                SyncFailureKind.invalidData.name,
              }.contains(row.lastError)) {
            continue;
          }
          final goal = await _goal(row.goalId, lease.identity.owner);
          final document = GoalDocument.decode(row.documentJson);
          if (document.id != goal.globalId) _invalid();
          final state = await _state(row.goalId);
          final base = row.baseRevision ?? state.serverRevision;
          await (db.update(
            db.syncOutbox,
          )..where((r) => r.sequence.equals(row.sequence))).write(
            SyncOutboxCompanion(
              baseRevision: Value(base),
              state: const Value('in_flight'),
              attempts: Value(row.attempts + 1),
              lastError: const Value(null),
              retryAfter: const Value(null),
            ),
          );
          return SyncRequest(
            identity: lease.identity,
            operationId: row.operationId,
            kind: SyncOperationKind.parse(row.kind),
            baseRevision: base,
            document: document,
          );
        }
        return null;
      });

  Future<bool> accept(
    IdentityLease lease,
    SyncRequest request,
    SyncAccepted reply,
  ) => db.transaction(() async {
    final row = await _operation(lease, request);
    _validateReply(request, reply);
    final canonical = reply.goal.document;
    if (canonical.retainingHistoryFrom(request.document).encode() !=
            canonical.encode() ||
        !request.document
            .retainingHistoryFrom(canonical)
            .hasSameResult(canonical)) {
      _invalid();
    }
    final state = await _state(row.goalId);
    if (reply.goal.revision < state.serverRevision) _invalid();
    final clean = state.localRevision == row.localRevision;
    if (clean) {
      await local.applyDocument(canonical, owner: lease.identity.owner);
    }
    await _confirm(row.goalId, reply.goal);
    await (db.delete(
      db.syncOutbox,
    )..where((r) => r.sequence.equals(row.sequence))).go();
    return clean;
  });

  Future<void> conflict(
    IdentityLease lease,
    SyncRequest request,
    SyncConflict reply,
  ) => db.transaction(() async {
    final row = await _operation(lease, request);
    _validateReply(request, reply);
    final working = await local.readDocument(
      row.goalId,
      owner: lease.identity.owner,
    );
    if (!working.hasSameOrigin(reply.goal.document)) _invalid();
    await db
        .into(db.syncConflicts)
        .insert(
          SyncConflictsCompanion.insert(
            owner: lease.identity.owner,
            goalId: row.goalId,
            operationId: request.operationId,
            baseRevision: request.baseRevision,
            remoteRevision: reply.goal.revision,
            localJson: working.encode(),
            remoteJson: reply.goal.document.encode(),
            createdAt: _now,
          ),
        );
    await (db.update(
      db.syncOutbox,
    )..where((r) => r.sequence.equals(row.sequence))).write(
      const SyncOutboxCompanion(
        state: Value('conflict'),
        retryAfter: Value(null),
      ),
    );
  });

  Future<void> fail(
    IdentityLease lease,
    SyncRequest request,
    SyncFailure failure,
  ) => db.transaction(() async {
    final row = await _operation(lease, request);
    final seconds = math.min(
      300,
      2 << math.min(math.max(0, row.attempts - 1), 8),
    );
    final delay = math.max(
      Duration(seconds: seconds).inMicroseconds,
      failure.retryAfter?.inMicroseconds ?? 0,
    );
    await (db.update(
      db.syncOutbox,
    )..where((r) => r.sequence.equals(row.sequence))).write(
      SyncOutboxCompanion(
        lastError: Value(failure.kind.name),
        retryAfter: Value(_now + delay),
      ),
    );
  });

  Future<bool> mergePull(IdentityLease lease, RemoteSnapshot snapshot) =>
      db.transaction(() async {
        await _requireAccount(lease);
        if (snapshot.identity != lease.identity ||
            snapshot.totalCount != snapshot.goals.length ||
            snapshot.goals.map((r) => r.document.id).toSet().length !=
                snapshot.goals.length) {
          _invalid();
        }
        final remoteIds = snapshot.goals.map((r) => r.document.id).toSet();
        final localGoals = await (db.select(
          db.goals,
        )..where((r) => r.owner.equals(lease.identity.owner))).get();
        for (final goal in localGoals) {
          if ((await _state(goal.id)).serverRevision > 0 &&
              !remoteIds.contains(goal.globalId)) {
            _invalid();
          }
        }
        var applied = false;
        for (final remote in snapshot.goals) {
          if (remote.identity != lease.identity) _invalid();
          final existing =
              await (db.select(db.goals)
                    ..where((r) => r.globalId.equals(remote.document.id)))
                  .getSingleOrNull();
          if (existing != null) {
            if (existing.owner != lease.identity.owner) {
              throw const SyncFailure(SyncFailureKind.denied);
            }
            final pending =
                await (db.select(db.syncOutbox)..where(
                      (r) =>
                          r.goalId.equals(existing.id) &
                          r.state.isNotValue('superseded'),
                    ))
                    .get();
            if (pending.isNotEmpty) continue;
            final state = await _state(existing.id);
            if (state.serverRevision == 0 &&
                state.localRevision > 0 &&
                (await local.readDocument(
                      existing.id,
                      owner: lease.identity.owner,
                    )).encode() !=
                    remote.document.encode()) {
              _invalid();
            }
            if (remote.revision < state.serverRevision) continue;
            if (state.confirmedJson != null &&
                remote.revision == state.serverRevision &&
                !GoalDocument.decode(state.confirmedJson!)
                    .hasSameResult(remote.document)) {
              _invalid();
            }
          }
          final id = await local.applyDocument(
            remote.document,
            owner: lease.identity.owner,
          );
          await _confirm(id, remote);
          applied = true;
        }
        return applied;
      });

  Future<ConflictResolution> resolve({
    required IdentityLease lease,
    required String conflictId,
    required ConflictChoice choice,
    required int expectedLocalRevision,
    required int expectedRemoteRevision,
  }) => db.transaction(() async {
    await _requireAccount(lease);
    final conflict =
        await (db.select(db.syncConflicts)..where(
              (r) =>
                  r.id.equals(conflictId) &
                  r.owner.equals(lease.identity.owner) &
                  r.resolvedAt.isNull(),
            ))
            .getSingleOrNull();
    if (conflict == null) throw StateError('Conflict is no longer available');
    final state = await _state(conflict.goalId);
    if (state.localRevision != expectedLocalRevision ||
        conflict.remoteRevision != expectedRemoteRevision) {
      throw StateError('Conflict changed before resolution');
    }
    final working = await local.readDocument(
      conflict.goalId,
      owner: lease.identity.owner,
    );
    final remote = GoalDocument.decode(conflict.remoteJson);
    var chosen = choice == ConflictChoice.local
        ? working.retainingHistoryFrom(remote)
        : remote.retainingHistoryFrom(working);
    final other = choice == ConflictChoice.local ? remote : working;
    final archivePreserved =
        chosen.archivedDay == null && other.archivedDay != null;
    if (archivePreserved) {
      chosen = GoalDocument.fromJson({
        ...chosen.toJson(),
        'archived_day': other.archivedDay!.key,
        'archived_at': other.archivedAt!.microsecondsSinceEpoch,
      });
    }
    await local.applyDocument(chosen, owner: lease.identity.owner);
    final operationId = (await local.recordMutation(
      conflict.goalId,
      owner: lease.identity.owner,
      kind: SyncOperationKind.resolveConflict,
    ))!;
    await (db.update(
      db.syncOutbox,
    )..where((r) => r.operationId.equals(operationId))).write(
      SyncOutboxCompanion(baseRevision: Value(conflict.remoteRevision)),
    );
    await (db.update(db.syncOutbox)..where(
          (r) =>
              r.goalId.equals(conflict.goalId) &
              r.owner.equals(lease.identity.owner) &
              r.state.isNotValue('superseded') &
              r.operationId.isNotValue(operationId),
        ))
        .write(
          SyncOutboxCompanion(
            state: const Value('superseded'),
            supersededBy: Value(operationId),
          ),
        );
    await (db.update(
      db.syncConflicts,
    )..where((r) => r.id.equals(conflictId))).write(
      SyncConflictsCompanion(
        resolvedAt: Value(_now),
        resolution: Value(choice.name),
      ),
    );
    return ConflictResolution(operationId, archivePreserved: archivePreserved);
  });

  Future<SyncRunResult> result(
    IdentityLease lease, {
    required bool pulled,
    SyncFailureKind? failure,
  }) => db.transaction(() async {
    await identities.require(lease);
    if (lease.identity.isGuest) {
      return const SyncRunResult(status: SyncRunStatus.localOnly);
    }
    final pending =
        await (db.select(db.syncOutbox)..where(
              (r) =>
                  r.owner.equals(lease.identity.owner) &
                  r.state.isNotValue('superseded'),
            ))
            .get();
    final conflicts =
        await (db.select(db.syncConflicts)..where(
              (r) =>
                  r.owner.equals(lease.identity.owner) & r.resolvedAt.isNull(),
            ))
            .get();
    final needsLogin =
        failure == SyncFailureKind.authentication ||
        pending.any((r) => r.lastError == SyncFailureKind.authentication.name);
    final hasError = failure != null || pending.any((r) => r.lastError != null);
    return SyncRunResult(
      status: needsLogin
          ? SyncRunStatus.needsLogin
          : hasError
          ? SyncRunStatus.failed
          : conflicts.isNotEmpty
          ? SyncRunStatus.conflict
          : pending.isNotEmpty || !pulled
          ? SyncRunStatus.pending
          : SyncRunStatus.synced,
      pending: pending.length,
      conflicts: conflicts.length,
      failure: failure,
    );
  });

  Future<void> _requireAccount(IdentityLease lease) async {
    await identities.require(lease);
    if (lease.identity.isGuest) throw const StaleIdentity();
  }

  Future<StoredGoal> _goal(int id, String owner) async {
    final row = await (db.select(
      db.goals,
    )..where((r) => r.id.equals(id) & r.owner.equals(owner))).getSingleOrNull();
    if (row == null) _invalid();
    return row;
  }

  Future<StoredSyncState> _state(int id) =>
      (db.select(db.syncStates)..where((r) => r.goalId.equals(id))).getSingle();

  Future<StoredSyncOperation> _operation(
    IdentityLease lease,
    SyncRequest request,
  ) async {
    await _requireAccount(lease);
    if (request.identity != lease.identity) _invalid();
    final row =
        await (db.select(db.syncOutbox)..where(
              (r) =>
                  r.operationId.equals(request.operationId) &
                  r.owner.equals(lease.identity.owner),
            ))
            .getSingleOrNull();
    if (row == null ||
        row.state != 'in_flight' ||
        row.baseRevision != request.baseRevision ||
        row.documentJson != request.document.encode() ||
        row.kind != request.kind.wireName) {
      _invalid();
    }
    final goal = await _goal(row.goalId, lease.identity.owner);
    if (goal.globalId != request.document.id) _invalid();
    return row;
  }

  void _validateReply(SyncRequest request, SyncReply reply) {
    if (reply.operationId != request.operationId ||
        reply.goal.identity != request.identity ||
        !reply.goal.document.hasSameOrigin(request.document) ||
        reply.goal.revision < request.baseRevision) {
      _invalid();
    }
  }

  Future<void> _confirm(int id, RemoteGoal remote) =>
      (db.update(db.syncStates)..where((r) => r.goalId.equals(id)))
          .write(
            SyncStatesCompanion(
              serverRevision: Value(remote.revision),
              confirmedJson: Value(remote.document.encode()),
              lastSyncedAt: Value(_now),
            ),
          )
          .then((_) {});
}

Never _invalid() => throw const SyncFailure(SyncFailureKind.invalidData);
