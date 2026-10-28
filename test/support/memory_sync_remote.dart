import 'package:habit_checkin/data/sync/sync_identity.dart';
import 'package:habit_checkin/data/sync/sync_protocol.dart';

/// Contract/fault-injection substitute only. This is not evidence of RLS.
class MemorySyncBackend {
  final goals = <String, RemoteGoal>{};
  final receipts = <String, ({String request, SyncAccepted reply})>{};
  final attempts = <SyncRequest>[];
  int pulls = 0;

  SyncReply apply(SyncRequest request) {
    attempts.add(request);
    final key = '${request.identity.owner}/${request.operationId}';
    final receipt = receipts[key];
    if (receipt != null) {
      if (receipt.request != request.encode()) {
        throw const SyncFailure(SyncFailureKind.invalidData);
      }
      return receipt.reply;
    }
    final current = goals[request.document.id];
    if (current != null && current.identity != request.identity) {
      throw const SyncFailure(SyncFailureKind.denied);
    }
    if (current == null && request.baseRevision != 0) {
      throw const SyncFailure(SyncFailureKind.invalidData);
    }
    final proposed = current == null
        ? request.document
        : request.document.retainingHistoryFrom(current.document);
    if (current != null &&
        current.document.archivedDay != null &&
        proposed.archivedDay == null) {
      return SyncConflict(request.operationId, current);
    }
    final bool same =
        current != null && current.document.hasSameResult(proposed);
    if (current != null && !same && request.baseRevision != current.revision) {
      return SyncConflict(request.operationId, current);
    }
    final canonical = same
        ? current.document.retainingHistoryFrom(proposed)
        : proposed;
    final remote = RemoteGoal(
      identity: request.identity,
      revision: same ? current.revision : (current?.revision ?? 0) + 1,
      document: canonical,
    );
    final reply = SyncAccepted(request.operationId, remote);
    goals[remote.document.id] = remote;
    receipts[key] = (request: request.encode(), reply: reply);
    return reply;
  }
}

class MemorySyncRemote implements SyncRemote {
  MemorySyncRemote(this.backend, this.identity);
  final MemorySyncBackend backend;
  @override
  final SyncIdentity identity;
  SyncFailure? failure;
  Future<void> Function(SyncRequest)? beforePush;
  Future<SyncReply> Function(SyncRequest, SyncReply)? afterPush;
  Future<RemoteSnapshot> Function(RemoteSnapshot)? afterPull;
  int pushes = 0;

  @override
  Future<SyncReply> push(SyncRequest request) async {
    pushes++;
    if (failure case final error?) throw error;
    if (request.identity != identity) {
      throw const SyncFailure(SyncFailureKind.denied);
    }
    await beforePush?.call(request);
    final reply = backend.apply(request);
    return afterPush == null ? reply : await afterPush!(request, reply);
  }

  @override
  Future<RemoteSnapshot> pull() async {
    backend.pulls++;
    if (failure case final error?) throw error;
    final goals = backend.goals.values
        .where((g) => g.identity == identity)
        .toList();
    final result = RemoteSnapshot(
      identity: identity,
      goals: goals,
      totalCount: goals.length,
    );
    return afterPull == null ? result : await afterPull!(result);
  }
}
