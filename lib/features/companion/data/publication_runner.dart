import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

import '../../records/data/record_photo_files.dart';
import 'companion_service.dart';
import 'local_publication_outbox.dart';

/// One runner per sharing session. Initialization recovers state without sending;
/// the foreground owner calls run, and only explicit retries replay attempts.
class PublicationRunner extends ChangeNotifier {
  PublicationRunner({
    required this.outbox,
    required this.sharing,
    required this.media,
    required this.resolution,
    required this.files,
  });

  final LocalPublicationOutbox outbox;
  final CompanionSharingService sharing;
  final CompanionMediaService media;
  final CompanionPublicationService resolution;
  final RecordPhotoFiles files;
  List<PublicationAttempt> pending = [];
  String? error;
  bool invalidated = false;
  bool _disposed = false;
  Future<void>? _running;
  CompanionCancellation? _cancellation;
  StreamSubscription<bool>? _scope;
  StreamSubscription<List<PublicationAttempt>>? _queue;

  bool get available => !_disposed && !invalidated;
  bool get busy => _running != null;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _invalidate() {
    if (invalidated) return;
    invalidated = true;
    pending = [];
    _cancellation?.cancel();
    _notify();
  }

  Future<void> initialize() async {
    await outbox.recoverInterrupted();
    await _reload();
    if (!available) return;
    _scope = outbox.sharing.watchCurrent().listen((current) {
      if (!current) _invalidate();
    }, onError: (Object _) => _invalidate());
    _queue = outbox.watchPending().listen(
      (next) {
        if (!available) return;
        pending = next;
        _notify();
      },
      onError: (Object _) {
        // A scope or storage failure must never surface stale pending content.
        _invalidate();
      },
    );
  }

  Future<void> _reload() async {
    final next = await outbox.pending();
    if (available) {
      pending = next;
      _notify();
    }
  }

  bool canRetry(PublicationAttempt attempt) =>
      available && !busy && _retryable(attempt);

  bool _retryable(PublicationAttempt attempt) =>
      attempt.row.errorCode != 'publication_cancelled' &&
      (attempt.row.status == 'uncertain' ||
          attempt.row.status == 'pending' ||
          (attempt.row.status == 'failed' &&
              const {
                'network',
                'timeout',
                'unavailable',
                'device_busy',
                'unconfigured',
                'not_found',
                'credential',
                'cancelled',
                'request_interrupted',
                'request_read_timeout',
              }.contains(attempt.row.errorCode)));

  Future<void> run({String? retryOperation}) {
    if (!available) return Future.value();
    return _running ??= _drain(retryOperation).whenComplete(() {
      _running = null;
      _notify();
    });
  }

  Future<void> _drain(String? retryOperation) async {
    final cancellation = CompanionCancellation();
    _cancellation = cancellation;
    error = null;
    final visited = <String>{};
    try {
      while (available && !cancellation.isCancelled) {
        await _reload();
        final sources = <String>{};
        PublicationAttempt? next;
        for (final row in pending) {
          if (!sources.add(row.source.id) ||
              visited.contains(row.row.operationId) ||
              row.row.status == 'sending') {
            continue;
          }
          final successor = pending.any(
            (other) =>
                other.source.id == row.source.id &&
                other.row.sequence > row.row.sequence,
          );
          if (successor ||
              (row.row.status == 'pending' && row.row.attempts == 0) ||
              (row.row.operationId == retryOperation && _retryable(row))) {
            next = row;
            break;
          }
        }
        if (next == null) break;
        visited.add(next.row.operationId);
        await _send(next, cancellation);
      }
      if (available) await _reload();
    } catch (failure) {
      await _failed(_safe(failure));
    } finally {
      _cancellation = null;
    }
  }

  void _check(CompanionCancellation cancellation) {
    if (!available || cancellation.isCancelled) {
      throw const CompanionServiceFailure('cancelled', outcomeUnknown: true);
    }
  }

  CompanionAccess _access(PublicationAttempt attempt, {bool latest = false}) =>
      CompanionAccess(
        credentialScope: outbox.sharing.pairing.credentialScope,
        isCurrent: () async =>
            available && await outbox.isCurrent(attempt, latest: latest),
      );

  Future<bool> _superseded(
    PublicationAttempt attempt,
    CompanionCancellation cancellation,
  ) async {
    _check(cancellation);
    if (!await outbox.hasSuccessor(attempt)) return false;
    final command = attempt.command;
    // An outstanding removal must complete before a later opt-in publication.
    if (command?.kind == SharingCommandKind.remove) return false;
    if (attempt.row.errorCode == 'publication_cancelled' || command == null) {
      await outbox.supersede(attempt);
      return true;
    }
    final result = await resolution.resolvePublication(
      command,
      access: _access(attempt),
      cancellation: cancellation,
    );
    _check(cancellation);
    result.validateCommand(command);
    if (result.request.fingerprint !=
        sha256.convert(utf8.encode(command.fingerprintInput)).toString()) {
      throw const CompanionServiceFailure(
        'invalid_response',
        outcomeUnknown: true,
      );
    }
    if (result.receipt case final receipt?) {
      if (!await outbox.finish(attempt, receipt)) {
        throw const CompanionServiceFailure('discarded');
      }
    } else {
      await outbox.supersede(attempt, resolution: result);
    }
    return true;
  }

  Future<void> _send(
    PublicationAttempt queued,
    CompanionCancellation cancellation,
  ) async {
    PublicationAttempt? attempt;
    var startedTransport = false;
    try {
      _check(cancellation);
      if (queued.row.errorCode == 'publication_cancelled') {
        await _superseded(queued, cancellation);
        return;
      }
      attempt = await outbox.begin(
        queued.row.operationId,
        retry: queued.row.attempts != 0,
      );
      if (await _superseded(attempt, cancellation)) return;
      if (attempt.row.kind == 'remove' && attempt.source.remoteId == null) {
        await outbox.settleLocalRemoval(attempt);
        return;
      }
      if (attempt.command == null) {
        final photos = await outbox.photos(attempt);
        for (final photo in photos) {
          _check(cancellation);
          if (await _superseded(attempt, cancellation)) return;
          if (photo.remote != null) continue;
          final bytes = await files.read(photo.photo);
          _check(cancellation);
          if (await _superseded(attempt, cancellation)) return;
          final request = CompanionPhotoUpload.fromJson({
            'protocol': companionProtocol,
            'operation_id': photo.row.uploadOperationId,
            'group_id': outbox.sharing.groupId,
            'purpose': 'record',
            'grant_id': attempt.source.grantId,
            'jpeg_base64': base64Encode(bytes),
          });
          startedTransport = true;
          final receipt = await media.uploadPhoto(
            request,
            access: _access(attempt, latest: true),
            cancellation: cancellation,
          );
          _check(cancellation);
          await outbox.acceptPhoto(attempt, request, receipt);
        }
        if (await _superseded(attempt, cancellation)) return;
        attempt = await outbox.freeze(attempt);
      }
      _check(cancellation);
      if (await _superseded(attempt, cancellation)) return;
      startedTransport = true;
      final receipt = await sharing.executeSharing(
        attempt.command!,
        access: _access(attempt, latest: attempt.row.kind == 'publish'),
        cancellation: cancellation,
      );
      _check(cancellation);
      if (!await outbox.finish(attempt, receipt)) {
        throw const CompanionServiceFailure('discarded');
      }
    } catch (failure) {
      var safe = _safe(failure, unknown: startedTransport);
      if (attempt != null) {
        try {
          // A save/withdrawal may arrive during file or network I/O. Resolve the
          // frozen request, never replay its now-obsolete private body.
          if (const {
                'discarded',
                'publication_superseded',
              }.contains(safe.code) &&
              available &&
              !cancellation.isCancelled &&
              await outbox.isCurrent(attempt) &&
              await _superseded(attempt, cancellation)) {
            return;
          }
        } catch (resolutionFailure) {
          safe = _safe(resolutionFailure, unknown: true);
        }
        try {
          await outbox.fail(attempt, safe);
        } catch (_) {
          // The persisted sending state remains recoverable after storage loss.
        }
      }
      await _failed(safe);
    }
  }

  CompanionServiceFailure _safe(Object failure, {bool unknown = false}) =>
      failure is CompanionServiceFailure
      ? failure
      : CompanionServiceFailure(
          failure is FormatException ? 'invalid_response' : 'unavailable',
          outcomeUnknown: unknown,
        );

  Future<void> _failed(CompanionServiceFailure failure) async {
    error = failure.message;
    if (const {
      'unauthorized',
      'forbidden',
      'pair_gone',
      'pair_unavailable',
    }.contains(failure.code)) {
      try {
        await outbox.sharing.forgetRemote();
      } catch (_) {}
      _invalidate();
    } else if (!await outbox.sharing.isCurrent()) {
      _invalidate();
    }
    _notify();
  }

  void cancelWaiting() => _cancellation?.cancel();

  @override
  void dispose() {
    if (_disposed) return;
    _invalidate();
    _disposed = true;
    unawaited(_scope?.cancel());
    unawaited(_queue?.cancel());
    super.dispose();
  }
}
