import 'dart:convert';

import 'goal_document.dart';
import 'sync_identity.dart';

enum SyncOperationKind {
  create('create'),
  edit('edit'),
  setCompleted('set_completed'),
  setUncompleted('set_uncompleted'),
  archive('archive'),
  importGuest('import_guest'),
  resolveConflict('resolve_conflict');

  const SyncOperationKind(this.wireName);
  final String wireName;

  static SyncOperationKind parse(String value) => values.firstWhere(
    (kind) => kind.wireName == value,
    orElse: () => throw const SyncFailure(SyncFailureKind.invalidData),
  );
}

enum SyncFailureKind {
  network,
  timeout,
  server,
  rateLimited,
  authentication,
  denied,
  invalidData,
}

class SyncFailure implements Exception {
  const SyncFailure(this.kind, {this.retryAfter});
  final SyncFailureKind kind;
  final Duration? retryAfter;

  @override
  String toString() => 'SyncFailure(${kind.name})';
}

class SyncRequest {
  const SyncRequest({
    required this.identity,
    required this.operationId,
    required this.kind,
    required this.baseRevision,
    required this.document,
  });

  final SyncIdentity identity;
  final String operationId;
  final SyncOperationKind kind;
  final int baseRevision;
  final GoalDocument document;

  // Owner is obtained from verified authentication on the server, not JSON.
  Map<String, Object?> toJson() => {
    'operation_id': operationId,
    'kind': kind.wireName,
    'base_revision': baseRevision,
    // A persisted v1 operation may already have reached the server. Replaying
    // its id with a v2 body would change its immutable request fingerprint.
    'document': document.toJson(preserveWireVersion: true),
  };
  String encode() => jsonEncode(toJson());
}

class RemoteGoal {
  RemoteGoal({
    required this.identity,
    required this.revision,
    required this.document,
  }) {
    if (identity.isGuest || revision < 1) {
      throw const SyncFailure(SyncFailureKind.invalidData);
    }
  }

  final SyncIdentity identity;
  final int revision;
  final GoalDocument document;
}

sealed class SyncReply {
  const SyncReply(this.operationId, this.goal);
  final String operationId;
  final RemoteGoal goal;
}

class SyncAccepted extends SyncReply {
  const SyncAccepted(super.operationId, super.goal);
}

class SyncConflict extends SyncReply {
  const SyncConflict(super.operationId, super.goal);
}

class RemoteSnapshot {
  RemoteSnapshot({
    required this.identity,
    required List<RemoteGoal> goals,
    required this.totalCount,
  }) : goals = List.unmodifiable(goals);

  final SyncIdentity identity;
  final List<RemoteGoal> goals;
  final int totalCount;
}

/// Bound to one authenticated account. Implementations must not substitute
/// another account's session during a retry or silently truncate a snapshot.
abstract interface class SyncRemote {
  SyncIdentity get identity;
  Future<SyncReply> push(SyncRequest request);
  Future<RemoteSnapshot> pull();
}

enum SyncRunStatus {
  localOnly,
  synced,
  pending,
  conflict,
  failed,
  needsLogin,
  stale,
}

class SyncRunResult {
  const SyncRunResult({
    required this.status,
    this.pending = 0,
    this.conflicts = 0,
    this.failure,
  });
  final SyncRunStatus status;
  final int pending;
  final int conflicts;
  final SyncFailureKind? failure;
}
