import 'dart:async';

import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

import '../data/companion_service.dart';
import '../data/local_sharing_store.dart';

class _ReplyDraft {
  String text = '';
  String? error;
  int revision = 0;
  int edit = 0;
  int savedEdit = 0;
  Future<void> tail = Future.value();
  bool get saved => edit == savedEdit;
}

class SharingController extends ChangeNotifier {
  SharingController({required this.store, required this.service});
  final LocalSharingStore store;
  final CompanionSharingService service;
  SharingLocalSnapshot? snapshot;
  List<SharingLocalGoal> localGoals = [];
  final Map<String, List<SharedReply>> replies = {};
  final Map<String, _ReplyDraft> _drafts = {};
  final Map<String, Future<void>> _openingReplies = {};
  String? error;
  bool busy = false;
  bool refreshing = false;
  bool confirmed = false;
  bool invalidated = false;
  bool _disposed = false;
  CompanionCancellation? _cancellation;
  StreamSubscription<bool>? _scope;

  bool get available => !_disposed && !invalidated;
  bool get canStart => available && !busy && !refreshing;
  CompanionAccess get access => CompanionAccess(
    credentialScope: store.pairing.credentialScope,
    isCurrent: () async => available && await store.isCurrent(),
  );
  String replyText(String record) => _drafts[record]?.text ?? '';
  String? replyDraftError(String record) => _drafts[record]?.error;
  bool replyDraftSaved(String record) => _drafts[record]?.saved ?? true;
  bool replyReady(String record) => _drafts.containsKey(record);
  List<SharingAttempt> get pending => snapshot?.commands ?? const [];
  bool canRetry(SharingAttempt attempt) =>
      canStart &&
      (const {'pending', 'uncertain'}.contains(attempt.row.status) ||
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
  bool hasPendingReply(String record) => pending.any(
    (item) =>
        item.command.kind == SharingCommandKind.reply &&
        item.command.recordId == record &&
        item.row.status != 'failed',
  );

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _invalidate() {
    if (invalidated) return;
    invalidated = true;
    confirmed = false;
    snapshot = null;
    localGoals = [];
    replies.clear();
    _drafts.clear();
    _cancellation?.cancel();
    _notify();
  }

  Future<void> initialize() async {
    await store.recoverInterrupted();
    await _reload();
    if (_disposed) return;
    _scope = store.watchCurrent().listen((current) {
      if (!current) _invalidate();
    }, onError: (Object _) => _invalidate());
  }

  Future<void> _reload() async {
    final next = await store.snapshot();
    final goals = await store.personalGoals();
    if (!available) return;
    snapshot = next;
    localGoals = goals;
    final ids = next.records.map((record) => record.id).toSet();
    replies.removeWhere((id, _) => !ids.contains(id));
    _drafts.removeWhere((id, _) => !ids.contains(id));
    _notify();
  }

  Future<void> _reloadSafely() async {
    if (!available) return;
    try {
      await _reload();
    } catch (failure) {
      if (!await store.isCurrent()) {
        _invalidate();
      } else {
        error = '本地分享状态暂时不可用，请返回后重试。';
      }
    }
    _notify();
  }

  SharedPageRequest _page({int? before, int? revision, String? record}) =>
      SharedPageRequest.fromJson({
        'protocol': companionProtocol,
        'group_id': store.groupId,
        'before_sequence': before,
        'revision': before == null ? null : revision,
        'record_id': ?record,
      }, replies: record != null);

  void _check(CompanionCancellation cancellation) {
    if (!available || cancellation.isCancelled) {
      throw const CompanionServiceFailure('cancelled');
    }
  }

  void _cursor(int? previous, int? next) {
    if (previous != null && next != null && next >= previous) {
      throw const CompanionServiceFailure('invalid_response');
    }
  }

  Future<void> _feed(CompanionCancellation cancellation) async {
    final before = await store.snapshot();
    final grants = <SharingGrants>[];
    final feed = <SharedFeedPage>[];
    int? cursor;
    int? revision;
    do {
      _check(cancellation);
      final page = await service.grants(
        _page(before: cursor, revision: revision),
        access: access,
        cancellation: cancellation,
      );
      _cursor(cursor, page.nextBefore);
      revision ??= page.revision;
      if (page.revision != revision) {
        throw const CompanionServiceFailure('snapshot_changed');
      }
      grants.add(page);
      cursor = page.nextBefore;
    } while (cursor != null);
    do {
      _check(cancellation);
      final page = await service.feed(
        _page(before: cursor, revision: revision),
        access: access,
        cancellation: cancellation,
      );
      _cursor(cursor, page.nextBefore);
      if (page.revision != revision) {
        throw const CompanionServiceFailure('snapshot_changed');
      }
      feed.add(page);
      cursor = page.nextBefore;
    } while (cursor != null);
    _check(cancellation);
    if (!await store.acceptSnapshot(
      grantPages: grants,
      feedPages: feed,
      expectedRevision: before.state.cacheRevision,
    )) {
      throw const CompanionServiceFailure('snapshot_changed');
    }
    confirmed = true;
  }

  Future<void> _readReplies(
    String record,
    CompanionCancellation cancellation,
  ) async {
    final before = await store.snapshot();
    final pages = <SharedRepliesPage>[];
    int? cursor;
    int? revision;
    do {
      _check(cancellation);
      final page = await service.replies(
        _page(before: cursor, revision: revision, record: record),
        access: access,
        cancellation: cancellation,
      );
      _cursor(cursor, page.nextBefore);
      revision ??= page.revision;
      if (page.revision != revision) {
        throw const CompanionServiceFailure('snapshot_changed');
      }
      pages.add(page);
      cursor = page.nextBefore;
    } while (cursor != null);
    _check(cancellation);
    if (!await store.acceptReplies(
      record,
      pages,
      expectedRevision: before.state.cacheRevision,
    )) {
      throw const CompanionServiceFailure('snapshot_changed');
    }
    final result = await store.replies(record);
    if (available) replies[record] = result;
  }

  Future<void> _readWithRetry(Future<void> Function() read) async {
    for (var attempt = 0; ; attempt++) {
      try {
        await read();
        return;
      } on CompanionServiceFailure catch (failure) {
        if (failure.code != 'snapshot_changed' || attempt >= 1) rethrow;
      }
    }
  }

  Future<void> refresh({String? record}) async {
    if (!canStart) return;
    refreshing = true;
    error = null;
    final cancellation = CompanionCancellation();
    _cancellation = cancellation;
    _notify();
    try {
      await _refreshContent(cancellation, record: record);
    } catch (failure) {
      confirmed = false;
      await _failed(_failure(failure), record: record);
    } finally {
      refreshing = false;
      _cancellation = null;
      await _reloadSafely();
    }
  }

  Future<void> _refreshContent(
    CompanionCancellation cancellation, {
    String? record,
  }) async {
    await _readWithRetry(() => _feed(cancellation));
    await _reload();
    if (record != null &&
        snapshot?.records.any((r) => r.id == record) == true) {
      await _readWithRetry(() => _readReplies(record, cancellation));
    }
  }

  Future<void> openReplies(String record) => _openingReplies.putIfAbsent(
    record,
    () => _openReplies(record).whenComplete(() {
      _openingReplies.remove(record);
    }),
  );

  Future<void> _openReplies(String record) async {
    if (!available) return;
    if (!_drafts.containsKey(record)) {
      final draft = await store.draft(record);
      final cached = await store.replies(record);
      if (!available) return;
      _drafts[record] = _ReplyDraft()
        ..text = draft?.content ?? ''
        ..revision = draft?.revision ?? 0;
      replies[record] = cached;
      _notify();
    }
  }

  Future<void> editReply(String record, String text) {
    final draft = _drafts[record];
    if (!available || draft == null) return Future.value();
    draft.text = text;
    final edit = ++draft.edit;
    draft.error = null;
    _notify();
    draft.tail = draft.tail.then((_) async {
      try {
        draft.revision = await store.writeDraft(
          record,
          text,
          expectedRevision: draft.revision,
        );
        draft.savedEdit = edit;
        if (edit == draft.edit) draft.error = null;
      } catch (failure) {
        draft.error = failure is CompanionServiceFailure
            ? failure.message
            : '草稿未能保存，请重试。';
      }
      _notify();
    });
    return draft.tail;
  }

  Future<void> flushReply(String record) async {
    final draft = _drafts[record];
    if (draft == null) return;
    while (true) {
      final pending = draft.tail;
      await pending;
      if (identical(pending, draft.tail)) return;
    }
  }

  SharingCommand _command(
    SharingCommandKind kind,
    Map<String, Object?> fields,
  ) => SharingCommand.fromJson(kind, {
    'protocol': companionProtocol,
    'operation_id': const Uuid().v4(),
    'group_id': store.groupId,
    ...fields,
  });

  Future<bool> enable(String goal) =>
      _run(() => _command(SharingCommandKind.enable, {'goal_id': goal}));
  Future<bool> stop(String grant) =>
      _run(() => _command(SharingCommandKind.stop, {'grant_id': grant}));
  Future<bool> remove(String record) =>
      _run(() => _command(SharingCommandKind.remove, {'record_id': record}));
  Future<bool> deleteReply(String reply, String record) => _run(
    () => _command(SharingCommandKind.deleteReply, {'reply_id': reply}),
    record: record,
  );
  Future<bool> retry(SharingAttempt attempt) => _run(
    null,
    operation: attempt.command.operationId,
    record: attempt.row.recordId,
  );

  Future<void> discardFailed(SharingAttempt attempt) async {
    if (!canStart || attempt.row.status != 'failed') return;
    busy = true;
    _notify();
    try {
      await store.discardFailed(attempt.command.operationId);
    } catch (failure) {
      error = _failure(failure).message;
    } finally {
      busy = false;
      await _reloadSafely();
    }
  }

  Future<bool> sendReply(String record) {
    if (!canStart || hasPendingReply(record)) return Future.value(false);
    final text = replyText(record);
    if (text.trim().isEmpty || text.characters.length > 300) {
      error = text.trim().isEmpty ? '请先写下回复。' : '回复最多 300 字。';
      _notify();
      return Future.value(false);
    }
    return _run(
      () => _command(SharingCommandKind.reply, {
        'record_id': record,
        'text': text,
      }),
      record: record,
    );
  }

  Future<bool> _finish(SharingAttempt attempt, SharingReceipt receipt) async {
    final record = attempt.command.recordId;
    final draft = _drafts[record];
    if (attempt.command.kind != SharingCommandKind.reply || draft == null) {
      return store.finish(attempt, receipt);
    }
    final result = Completer<bool>();
    // Receipt-driven draft clearing shares the edit queue, including slow writes.
    draft.tail = draft.tail.then((_) async {
      try {
        final accepted = await store.finish(attempt, receipt);
        final stored = await store.draft(record!);
        draft.revision = stored?.revision ?? 0;
        if (draft.saved) draft.text = stored?.content ?? '';
        result.complete(accepted);
      } catch (failure, stack) {
        result.completeError(failure, stack);
      }
      _notify();
    });
    return result.future;
  }

  Future<bool> _run(
    SharingCommand Function()? build, {
    String? operation,
    String? record,
  }) async {
    if (!canStart) return false;
    busy = true;
    error = null;
    final cancellation = CompanionCancellation();
    _cancellation = cancellation;
    SharingAttempt? attempt;
    var succeeded = false;
    _notify();
    try {
      if (record != null) {
        await flushReply(record);
        if (!replyDraftSaved(record)) {
          error = replyDraftError(record) ?? '请先保存回复草稿。';
          return false;
        }
      }
      _check(cancellation);
      final queued = build == null ? null : await store.enqueue(build());
      operation ??= queued!.command.operationId;
      if (queued?.row.status != 'succeeded') {
        attempt = await store.begin(operation);
        await _reload();
        _check(cancellation);
        final receipt = await service.executeSharing(
          attempt.command,
          access: access,
          cancellation: cancellation,
        );
        if (!available || cancellation.isCancelled) {
          throw const CompanionServiceFailure(
            'cancelled',
            outcomeUnknown: true,
          );
        }
        succeeded = await _finish(attempt, receipt);
      } else {
        succeeded = true;
      }
      if (succeeded && available) {
        await _refreshContent(cancellation, record: record);
      }
    } catch (failure) {
      final safe = _failure(failure, unknown: attempt != null && !succeeded);
      if (attempt != null && !succeeded) {
        try {
          await store.fail(attempt, safe);
        } catch (_) {
          // Recovery retains an interrupted command if storage is unavailable.
        }
      }
      confirmed = false;
      await _failed(safe, record: record);
      if (succeeded && available) {
        error = '操作已完成，暂时无法刷新最新内容。${safe.message}';
      }
    } finally {
      busy = false;
      _cancellation = null;
      await _reloadSafely();
    }
    return succeeded;
  }

  CompanionServiceFailure _failure(Object failure, {bool unknown = false}) =>
      failure is CompanionServiceFailure
      ? failure
      : CompanionServiceFailure(
          failure is FormatException ? 'invalid_request' : 'unavailable',
          outcomeUnknown: unknown,
        );

  Future<void> _failed(
    CompanionServiceFailure failure, {
    String? record,
  }) async {
    error = failure.message;
    if (const {
      'unauthorized',
      'forbidden',
      'pair_gone',
      'pair_unavailable',
    }.contains(failure.code)) {
      try {
        await store.forgetRemote();
      } catch (_) {}
      _invalidate();
    } else if (failure.code == 'discarded') {
      _invalidate();
    } else if (failure.code == 'record_unavailable' && record != null) {
      try {
        await store.forgetRecord(record);
      } catch (_) {}
      _drafts.remove(record);
      replies.remove(record);
    }
  }

  void cancelWaiting() => _cancellation?.cancel();

  Future<CompanionPhotoDownload> downloadPhoto(
    String record,
    String photo,
    CompanionMediaService media, {
    required CompanionCancellation cancellation,
  }) async {
    void check() {
      _check(cancellation);
      if (snapshot?.records.any(
            (r) => r.id == record && r.photoIds.contains(photo),
          ) !=
          true) {
        throw const CompanionServiceFailure('discarded');
      }
    }

    check();
    try {
      final result = await media.downloadPhoto(
        CompanionPhotoRequest.fromJson({
          'protocol': companionProtocol,
          'group_id': store.groupId,
          'photo_id': photo,
        }),
        access: access,
        cancellation: cancellation,
      );
      check();
      return result;
    } on CompanionServiceFailure catch (failure) {
      if (const {
        'unauthorized',
        'forbidden',
        'pair_gone',
        'pair_unavailable',
      }.contains(failure.code)) {
        await _failed(failure);
      }
      rethrow;
    }
  }

  @override
  void dispose() {
    _invalidate();
    _disposed = true;
    _cancellation?.cancel();
    _scope?.cancel();
    super.dispose();
  }
}
