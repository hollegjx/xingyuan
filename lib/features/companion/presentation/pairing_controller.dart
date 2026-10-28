import 'dart:async';

import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

import '../data/companion_service.dart';
import '../data/local_pairing_store.dart';

class PairingController extends ChangeNotifier {
  PairingController({required this.store, required this.service});
  final LocalPairingStore store;
  final CompanionService service;
  PairingLocalSnapshot? snapshot;
  String draft = '';
  String? draftError;
  String? error;
  bool busy = false;
  bool refreshing = false;
  bool confirmed = false;
  bool _disposed = false;
  int _draftRevision = 0;
  int _edit = 0;
  int _savedEdit = 0;
  Future<void> _draftTail = Future.value();
  CompanionCancellation? _cancellation;

  bool get draftSaved => _edit == _savedEdit;
  bool get hasUncertainOperation =>
      snapshot?.command?.row.status == 'uncertain';
  bool get canStart =>
      !busy && !refreshing && !hasUncertainOperation && !_disposed;
  bool get canRetry =>
      !busy &&
      !refreshing &&
      snapshot?.command != null &&
      (hasUncertainOperation ||
          const {
            'network',
            'timeout',
            'unavailable',
            'device_busy',
            'unconfigured',
            'not_found',
            'credential',
            'unauthorized',
            'cancelled',
            'request_interrupted',
            'request_read_timeout',
          }.contains(snapshot!.command!.row.errorCode));

  CompanionAccess get _access => CompanionAccess(
    credentialScope: store.credentialScope,
    isCurrent: () async => !_disposed && await store.isCurrent(),
  );

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() async {
    await store.recoverInterrupted();
    await _reload();
  }

  Future<void> _reload() async {
    final next = await store.snapshot();
    if (_disposed) return;
    snapshot = next;
    if (draftSaved) {
      draft = next.row.draftCode;
      _draftRevision = next.row.draftRevision;
    }
    _notify();
  }

  Future<void> editDraft(String value) {
    if (_disposed) return Future.value();
    draft = value;
    final edit = ++_edit;
    draftError = null;
    _notify();
    _draftTail = _draftTail.then((_) async {
      try {
        _draftRevision = await store.writeDraft(
          value,
          expectedRevision: _draftRevision,
        );
        _savedEdit = edit;
        if (edit == _edit) draftError = null;
      } catch (failure) {
        draftError = failure is CompanionServiceFailure
            ? failure.message
            : '草稿未能保存，请重试。';
      }
      _notify();
    });
    return _draftTail;
  }

  Future<void> flushDraft() async {
    while (true) {
      final pending = _draftTail;
      await pending;
      if (identical(pending, _draftTail)) return;
    }
  }

  Future<void> refresh() async {
    if (busy || refreshing || _disposed) return;
    refreshing = true;
    error = null;
    final cancellation = CompanionCancellation();
    _cancellation = cancellation;
    _notify();
    try {
      final before = await store.snapshot();
      if (_disposed || cancellation.isCancelled) return;
      // Child pages may have cleared revoked pairing data while this page was hidden.
      if (snapshot?.row.stateRevision != before.row.stateRevision) {
        snapshot = before;
        confirmed = false;
        _notify();
      }
      final state = await service.state(
        access: _access,
        cancellation: cancellation,
      );
      if (_disposed || cancellation.isCancelled) return;
      confirmed = await store.acceptState(
        state,
        expectedRevision: before.row.stateRevision,
      );
    } catch (failure) {
      confirmed = false;
      error = _failure(failure).message;
      if (failure is CompanionServiceFailure &&
          const {
            'unauthorized',
            'forbidden',
            'pair_gone',
            'discarded',
          }.contains(failure.code)) {
        try {
          await store.forgetRemote();
        } catch (_) {
          // A superseded identity must not clear another identity's cache.
        }
      }
    } finally {
      refreshing = false;
      _cancellation = null;
      await _reloadSafely();
    }
  }

  Future<void> createInvite() =>
      _run(() => PairingCommand.createInvite(const Uuid().v4()));
  Future<void> cancelInvite(String invitationId) =>
      _run(() => PairingCommand.cancelInvite(const Uuid().v4(), invitationId));
  Future<void> leave(String groupId) =>
      _run(() => PairingCommand.leave(const Uuid().v4(), groupId));
  Future<void> join() => _run(() {
    if (draft.trim().isEmpty || draft.characters.length > 64) {
      throw const CompanionServiceFailure('invite_invalid');
    }
    return PairingCommand.join(const Uuid().v4(), draft);
  });
  Future<void> retry() => _run(null);

  Future<void> _run(PairingCommand Function()? build) async {
    if (build == null ? !canRetry : !canStart) return;
    busy = true;
    error = null;
    final cancellation = CompanionCancellation();
    _cancellation = cancellation;
    PairingAttempt? attempt;
    _notify();
    try {
      await flushDraft();
      if (!draftSaved) {
        error = draftError ?? '请先保存邀请码草稿。';
        return;
      }
      if (_disposed || cancellation.isCancelled) return;
      if (!service.configured) {
        throw const CompanionServiceFailure('unconfigured');
      }
      attempt = build == null
          ? await store.retry()
          : await store.start(build());
      await _reload();
      if (_disposed || cancellation.isCancelled) {
        throw const CompanionServiceFailure('cancelled', outcomeUnknown: true);
      }
      final receipt = await service.execute(
        attempt.command,
        access: _access,
        cancellation: cancellation,
      );
      if (_disposed || cancellation.isCancelled) {
        throw const CompanionServiceFailure('cancelled', outcomeUnknown: true);
      }
      confirmed = await _finish(attempt, receipt);
    } catch (failure) {
      confirmed = false;
      final safe = _failure(failure, unknown: attempt != null);
      error = safe.message;
      if (attempt != null) {
        try {
          await store.fail(attempt, safe);
          if (const {
            'unauthorized',
            'forbidden',
            'pair_gone',
            'discarded',
          }.contains(safe.code)) {
            await store.forgetRemote();
          }
        } catch (_) {
          // Leave the durable command for recovery if storage or identity changed.
        }
      }
    } finally {
      busy = false;
      _cancellation = null;
      await _reloadSafely();
    }
  }

  Future<void> _reloadSafely() async {
    if (_disposed) return;
    try {
      await _reload();
    } catch (_) {
      snapshot = null;
      confirmed = false;
      error = '本地配对状态暂时不可用，请返回后重试。';
    }
    _notify();
  }

  Future<bool> _finish(PairingAttempt attempt, PairingReceipt receipt) {
    final result = Completer<bool>();
    // Join success may clear a draft. Order it with edits and advance the CAS
    // revision before any text typed during that write reaches the database.
    _draftTail = _draftTail.then((_) async {
      try {
        final accepted = await store.finish(attempt, receipt);
        final next = await store.snapshot();
        _draftRevision = next.row.draftRevision;
        if (!_disposed) {
          snapshot = next;
          if (draftSaved) draft = next.row.draftCode;
        }
        result.complete(accepted);
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }

  CompanionServiceFailure _failure(Object failure, {bool unknown = false}) =>
      failure is CompanionServiceFailure
      ? failure
      : CompanionServiceFailure('unavailable', outcomeUnknown: unknown);

  void cancelWaiting() => _cancellation?.cancel();

  @override
  void dispose() {
    _disposed = true;
    _cancellation?.cancel();
    super.dispose();
  }
}
