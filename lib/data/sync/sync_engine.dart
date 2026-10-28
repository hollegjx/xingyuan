import 'dart:async';

import '../../features/reminders/reminder_coordinator.dart';
import 'identity_store.dart';
import 'sync_identity.dart';
import 'sync_protocol.dart';
import 'sync_queue.dart';

class SyncEngine {
  SyncEngine({
    required this.queue,
    required this.work,
    required this.lease,
    required this.connect,
    this.onLocalApplied,
    this.requestTimeout = const Duration(seconds: 30),
  });

  final SyncQueue queue;
  final SerialWork work;
  final IdentityLease lease;
  final SyncRemote Function(SyncIdentity) connect;
  final Future<void> Function()? onLocalApplied;
  final Duration requestTimeout;
  Future<SyncRunResult>? _running;
  SyncRemote? _remote;
  bool _again = false;
  bool _force = false;
  bool _disposed = false;

  void dispose() => _disposed = true;

  Future<SyncRunResult> run({bool forceRetry = false}) {
    if (_disposed) return Future.value(_stale);
    _again = true;
    _force |= forceRetry;
    return _running ??= _drive().whenComplete(() => _running = null);
  }

  Future<void> _check() async {
    if (_disposed) throw const StaleIdentity();
    await queue.identities.require(lease);
  }

  Future<SyncRunResult> _drive() async {
    var result = const SyncRunResult(status: SyncRunStatus.pending);
    try {
      do {
        _again = false;
        final force = _force;
        _force = false;
        result = await _pass(force);
      } while (_again && !_disposed);
      return _disposed ? _stale : result;
    } on StaleIdentity {
      return _stale;
    }
  }

  Future<SyncRunResult> _pass(bool force) async {
    await _check();
    if (lease.identity.isGuest) {
      return const SyncRunResult(status: SyncRunStatus.localOnly);
    }
    final remote = _remote ??= connect(lease.identity);
    if (remote.identity != lease.identity) {
      throw const SyncFailure(SyncFailureKind.denied);
    }
    var applied = false;
    SyncFailureKind? failure;
    while (true) {
      final request = await work.run(() async {
        await _check();
        return queue.prepareNext(lease, force: force);
      });
      if (request == null) break;
      try {
        // Network waits never hold the writes/reminders serial queue.
        await _check();
        final reply = await remote.push(request).timeout(requestTimeout);
        await work.run(() async {
          await _check();
          switch (reply) {
            case SyncAccepted():
              applied |= await queue.accept(lease, request, reply);
            case SyncConflict():
              await queue.conflict(lease, request, reply);
          }
        });
      } on TimeoutException {
        failure = SyncFailureKind.timeout;
        await _saveFailure(request, const SyncFailure(SyncFailureKind.timeout));
        break;
      } on SyncFailure catch (error) {
        failure = error.kind;
        await _saveFailure(request, error);
        break;
      }
    }
    var pulled = false;
    if (failure == null) {
      try {
        await _check();
        final snapshot = await remote.pull().timeout(requestTimeout);
        await work.run(() async {
          await _check();
          applied |= await queue.mergePull(lease, snapshot);
          pulled = true;
        });
      } on TimeoutException {
        failure = SyncFailureKind.timeout;
      } on SyncFailure catch (error) {
        failure = error.kind;
      }
    }
    if (applied && onLocalApplied != null) {
      await _check();
      try {
        await onLocalApplied!();
      } catch (_) {
        // Reminder errors have their own persisted retry state and cannot
        // undo a server acknowledgment or turn it into a sync failure.
      }
    }
    return work.run(() async {
      await _check();
      return queue.result(lease, pulled: pulled, failure: failure);
    });
  }

  Future<void> _saveFailure(SyncRequest request, SyncFailure failure) =>
      work.run(() async {
        await _check();
        await queue.fail(lease, request, failure);
      });

  static const _stale = SyncRunResult(status: SyncRunStatus.stale);
}
