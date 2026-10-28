import 'dart:async';
import 'dart:convert';

import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

import '../../records/data/record_photo.dart';
import '../data/chat_photo_files.dart';
import '../data/companion_service.dart';
import '../data/local_chat_store.dart';

class ChatController extends ChangeNotifier {
  ChatController({
    required this.store,
    required this.service,
    required this.media,
    required this.files,
  });

  final LocalChatStore store;
  final CompanionChatService service;
  final CompanionMediaService media;
  final ChatPhotoFiles files;
  ChatLocalSnapshot? snapshot;
  String draftText = '';
  String? draftPhotoId;
  String? draftError;
  String? error;
  bool busy = false;
  bool preparing = false;
  bool invalidated = false;
  bool _disposed = false;
  bool _ready = false;
  bool _foreground = true;
  bool _acceptedInWork = false;
  bool _readingAfterWrite = false;
  int _draftRevision = 0;
  int _edit = 0;
  int _savedEdit = 0;
  Future<void> _draftTail = Future.value();
  Future<void>? _working;
  CompanionCancellation? _cancellation;
  final _downloads = <CompanionCancellation>{};
  StreamSubscription<bool>? _scope;

  bool get available => !_disposed && !invalidated;
  bool get draftSaved => _ready && _savedEdit == _edit && draftError == null;
  List<ChatAttempt> get pending => snapshot?.commands ?? const [];
  int get unread =>
      snapshot?.messages
          .where(
            (m) =>
                m.authorId != store.memberId &&
                m.sequence > snapshot!.state.readSequence,
          )
          .length ??
      0;
  CompanionAccess get access => CompanionAccess(
    credentialScope: store.sharing.pairing.credentialScope,
    isCurrent: () async => available && await store.isCurrent(),
  );

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _invalidate() {
    if (invalidated) return;
    invalidated = true;
    snapshot = null;
    draftText = '';
    draftPhotoId = null;
    draftError = null;
    cancelWaiting();
    _notify();
  }

  Future<void> initialize() async {
    await store.recoverInterrupted();
    final initial = await store.snapshot();
    if (!available) return;
    snapshot = initial;
    draftText = initial.state.draftText;
    draftPhotoId = initial.state.draftPhotoId;
    _draftRevision = initial.state.draftRevision;
    _ready = true;
    _scope = store.watchCurrent().listen((current) {
      if (!current) _invalidate();
    }, onError: (Object _) => _invalidate());
    _notify();
  }

  Future<void> _reload() async {
    final next = await store.snapshot();
    if (available) snapshot = next;
    _notify();
  }

  Future<void> _reloadSafely() async {
    if (!available) return;
    try {
      await _reload();
    } catch (_) {
      if (!await store.isCurrent()) {
        _invalidate();
      } else {
        error = '本地聊天状态暂时不可用，请返回后重试。';
      }
    }
    _notify();
  }

  Future<void> editText(String text) => _editDraft(text, draftPhotoId);
  Future<void> removeDraftPhoto() => _editDraft(draftText, null);

  Future<void> _editDraft(String text, String? photo, {ChatPhotoInput? added}) {
    if (!available || !_ready) return Future.value();
    draftText = text;
    draftPhotoId = photo;
    final edit = ++_edit;
    draftError = null;
    _notify();
    _draftTail = _draftTail.then((_) async {
      try {
        if (!available) return;
        _draftRevision = await store.writeDraft(
          text,
          photoId: photo,
          addedPhoto: added,
          expectedRevision: _draftRevision,
        );
        _savedEdit = edit;
        if (_edit == edit) draftError = null;
      } catch (failure) {
        if (available) draftError = _failure(failure).message;
      }
      _notify();
    });
    return _draftTail;
  }

  Future<void> flushDraft() async {
    while (true) {
      final tail = _draftTail;
      await tail;
      if (identical(tail, _draftTail)) return;
    }
  }

  Future<bool> attachPhoto(Uint8List bytes) async {
    if (!available || !_ready || preparing) return false;
    preparing = true;
    error = null;
    _notify();
    ChatPhotoInput? input;
    try {
      final photo = await sanitizeRecordPhoto(bytes);
      if (!available) return false;
      input = await files.write(store, photo);
      if (!available) return false;
      await _editDraft(draftText, input.id, added: input);
      return available && draftSaved;
    } catch (failure) {
      if (available) {
        error = failure is RecordPhotoException
            ? failure.message
            : '图片未能保存，请重试。';
      }
      return false;
    } finally {
      if (input != null) {
        try {
          await files.removeUnregistered(input);
        } catch (_) {}
      }
      preparing = false;
      await _reloadSafely();
    }
  }

  // Draft edits and enqueue share one queue. Later typing cannot be cleared by
  // an earlier slow enqueue or network acknowledgement.
  Future<bool> send() async {
    if (!available || !_ready || preparing) return false;
    if ((draftText.trim().isEmpty && draftPhotoId == null) ||
        draftText.characters.length > 1000) {
      error = draftText.characters.length > 1000
          ? '消息最多 1000 字。'
          : '请先写消息或选择图片。';
      _notify();
      return false;
    }
    preparing = true;
    error = null;
    final edit = _edit;
    var queued = false;
    _notify();
    _draftTail = _draftTail.then((_) async {
      try {
        if (!available || _savedEdit != edit || draftError != null) return;
        await store.enqueueSend(
          const Uuid().v4(),
          expectedDraftRevision: _draftRevision,
        );
        _draftRevision++;
        queued = true;
        if (_edit == edit && available) {
          draftText = '';
          draftPhotoId = null;
        }
      } catch (failure) {
        if (available) error = _failure(failure).message;
      }
    });
    await _draftTail;
    preparing = false;
    await _reloadSafely();
    if (queued && available) await runPending();
    return queued;
  }

  bool canRetry(ChatAttempt attempt) {
    if (!available || busy) return false;
    if (attempt.row.kind == 'send' &&
        pending.any(
          (p) =>
              p.row.kind == 'send' &&
              p.row.sequence < attempt.row.sequence &&
              p.row.status != 'succeeded',
        )) {
      return false;
    }
    return const {'pending', 'uncertain'}.contains(attempt.row.status) ||
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
              'photo_unavailable',
              'request_interrupted',
              'request_read_timeout',
            }.contains(attempt.row.errorCode));
  }

  bool canDiscard(ChatAttempt attempt) =>
      available &&
      !busy &&
      (attempt.row.status == 'failed' ||
          (attempt.row.status == 'pending' && attempt.row.attempts == 0));

  Future<void> discard(ChatAttempt attempt) async {
    if (!canDiscard(attempt)) return;
    await _work((_) async {
      await store.discard(attempt.row.operationId);
    });
    await runPending();
  }

  Future<void> remove(String messageId) => _work((cancel) async {
    final queued = await store.enqueueRemove(const Uuid().v4(), messageId);
    if (queued.row.status != 'succeeded') {
      await _execute(queued.row.operationId, cancel);
    }
    await _read(cancel);
  });

  Future<void> retry(ChatAttempt attempt) async {
    if (!canRetry(attempt)) return;
    await _work((cancel) async {
      await _execute(attempt.row.operationId, cancel);
      await _drain(cancel);
      await _read(cancel);
    });
  }

  Future<void> runPending() async {
    while (_working != null) {
      await _working;
    }
    if (!_foreground) return;
    await _work((cancel) async {
      await _drain(cancel);
      await _read(cancel);
    });
  }

  Future<void> _drain(CompanionCancellation cancel) async {
    while (available && !cancel.isCancelled) {
      final rows = (await store.snapshot()).commands;
      final firstSend = rows
          .where((p) => p.row.kind == 'send' && p.row.status != 'succeeded')
          .firstOrNull;
      final next = rows
          .where(
            (p) =>
                p.row.status == 'pending' &&
                (p.row.kind != 'send' || identical(p, firstSend)),
          )
          .firstOrNull;
      if (next == null) return;
      await _execute(next.row.operationId, cancel);
    }
  }

  void _check(CompanionCancellation cancel) {
    if (!available || !_foreground || cancel.isCancelled) {
      throw const CompanionServiceFailure('cancelled');
    }
  }

  Future<void> _execute(String operation, CompanionCancellation cancel) async {
    _check(cancel);
    var attempt = await store.begin(operation);
    var sent = false;
    try {
      await _reload();
      _check(cancel);
      if (attempt.row.localPhotoId != null &&
          attempt.row.photoReceiptJson == null) {
        final bytes = await files.read(store, attempt.row.localPhotoId!);
        final upload = CompanionPhotoUpload.fromJson({
          'protocol': companionProtocol,
          'operation_id': attempt.row.uploadOperationId,
          'group_id': store.groupId,
          'purpose': 'chat',
          'grant_id': null,
          'jpeg_base64': base64Encode(bytes),
        });
        _check(cancel);
        sent = true;
        final receipt = await media.uploadPhoto(
          upload,
          access: access,
          cancellation: cancel,
        );
        if (!available || cancel.isCancelled) {
          throw const CompanionServiceFailure(
            'cancelled',
            outcomeUnknown: true,
          );
        }
        attempt = await store.acceptUpload(attempt, upload, receipt);
      }
      attempt = await store.prepareRequest(attempt);
      _check(cancel);
      sent = true;
      final receipt = await service.executeChat(
        attempt.command,
        access: access,
        cancellation: cancel,
      );
      if (!available || cancel.isCancelled) {
        throw const CompanionServiceFailure('cancelled', outcomeUnknown: true);
      }
      if (!await store.finish(attempt, receipt)) {
        throw const CompanionServiceFailure('discarded');
      }
      _acceptedInWork = true;
    } catch (failure) {
      final safe = _failure(failure, unknown: sent);
      try {
        await store.fail(attempt, safe);
      } catch (_) {}
      rethrow;
    }
  }

  Future<void> refresh() => _work(_read);

  Future<void> _read(CompanionCancellation cancel) async {
    _readingAfterWrite = _acceptedInWork;
    for (var retry = 0; ; retry++) {
      try {
        final before = await store.snapshot();
        final pages = <ChatPage>[];
        int? cursor;
        int? revision;
        do {
          _check(cancel);
          final page = await service.messages(
            SharedPageRequest.fromJson({
              'protocol': companionProtocol,
              'group_id': store.groupId,
              'before_sequence': cursor,
              'revision': cursor == null ? null : revision,
            }),
            access: access,
            cancellation: cancel,
          );
          if ((cursor != null &&
                  page.nextBefore != null &&
                  page.nextBefore! >= cursor) ||
              (revision != null && page.revision != revision)) {
            throw const CompanionServiceFailure('snapshot_changed');
          }
          revision ??= page.revision;
          pages.add(page);
          cursor = page.nextBefore;
        } while (cursor != null);
        _check(cancel);
        if (!await store.acceptPages(
          pages,
          expectedRevision: before.state.cacheRevision,
        )) {
          throw const CompanionServiceFailure('snapshot_changed');
        }
        return;
      } on CompanionServiceFailure catch (failure) {
        if (failure.code != 'snapshot_changed' || retry >= 1) rethrow;
      }
    }
  }

  Future<void> _work(Future<void> Function(CompanionCancellation) body) {
    if (!available || !_ready || !_foreground) return Future.value();
    if (_working != null) return _working!;
    busy = true;
    error = null;
    _acceptedInWork = false;
    _readingAfterWrite = false;
    final cancel = CompanionCancellation();
    _cancellation = cancel;
    _notify();
    return _working = () async {
      try {
        await body(cancel);
      } catch (failure) {
        final safe = _failure(failure);
        await _failed(safe);
        if (_readingAfterWrite && available) {
          error = '消息操作已完成，暂时无法刷新最新内容。${safe.message}';
        }
      } finally {
        busy = false;
        _cancellation = null;
        await _reloadSafely();
      }
    }().whenComplete(() => _working = null);
  }

  CompanionServiceFailure _failure(Object failure, {bool unknown = false}) =>
      failure is CompanionServiceFailure
      ? failure
      : CompanionServiceFailure(
          failure is FormatException ? 'invalid_request' : 'unavailable',
          outcomeUnknown: unknown,
        );

  Future<void> _failed(CompanionServiceFailure failure) async {
    if (!available) return;
    error = failure.message;
    if (const {
      'unauthorized',
      'forbidden',
      'pair_gone',
      'pair_unavailable',
    }.contains(failure.code)) {
      try {
        await store.sharing.forgetRemote();
      } catch (_) {}
      _invalidate();
    } else if (failure.code == 'discarded') {
      _invalidate();
    }
  }

  Future<void> markRead() async {
    if (!available) return;
    final seen = snapshot?.messages.lastOrNull?.sequence ?? 0;
    try {
      await store.markRead(throughSequence: seen);
      await _reload();
    } catch (failure) {
      await _failed(_failure(failure));
    }
  }

  Future<CompanionPhotoDownload> downloadPhoto(
    String message,
    String photo,
    CompanionCancellation cancel,
  ) async {
    void check() {
      _check(cancel);
      if (snapshot?.messages.any(
            (m) => m.id == message && m.photoId == photo,
          ) !=
          true) {
        throw const CompanionServiceFailure('discarded');
      }
    }

    check();
    _downloads.add(cancel);
    try {
      final result = await media.downloadPhoto(
        CompanionPhotoRequest.fromJson({
          'protocol': companionProtocol,
          'group_id': store.groupId,
          'photo_id': photo,
        }),
        access: access,
        cancellation: cancel,
      );
      check();
      return result;
    } on CompanionServiceFailure catch (failure) {
      await _failed(failure);
      rethrow;
    } finally {
      _downloads.remove(cancel);
    }
  }

  void cancelWaiting() {
    _cancellation?.cancel();
    for (final cancel in _downloads) {
      cancel.cancel();
    }
  }

  void setForeground(bool value) {
    _foreground = value;
    if (!value) cancelWaiting();
  }

  @override
  void dispose() {
    _invalidate();
    _disposed = true;
    unawaited(_scope?.cancel());
    super.dispose();
  }
}
