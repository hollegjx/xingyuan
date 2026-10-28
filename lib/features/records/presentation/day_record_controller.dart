import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../goals/domain/goal.dart';
import '../../companion/data/local_publication_store.dart';
import '../../../shared/local_date.dart';
import '../data/local_day_record_store.dart';
import '../data/record_photo.dart';
import '../data/record_photo_files.dart';
import '../data/record_photo_picker.dart';

String recordErrorMessage(Object error) => switch (error) {
  RecordRuleException() => error.message,
  RecordPhotoException() => error.message,
  GoalRuleException() => error.message,
  _ => '未能保存，请重试。原有记录未被清空。',
};

class DayRecordController extends ChangeNotifier {
  DayRecordController({
    required this.store,
    required this.files,
    required this.picker,
  });

  final LocalDayRecordStore store;
  final RecordPhotoFiles files;
  final RecordPhotoPicker picker;
  DayRecordSnapshot? snapshot;
  String text = '';
  String? error;
  String? cleanupWarning;
  bool ready = false;
  bool readOnly = false;
  bool busy = false;
  bool closed = false;
  bool dirty = false;
  bool shareDetails = false;
  String syncState = 'local';
  RecordSharingConsent? _consent;
  StreamSubscription<RecordSharingState>? _sharing;
  bool get canShare => !readOnly && _consent != null;
  bool _disposed = false;
  int _inputVersion = 0;
  Object? _draftFailure;
  Future<void> _tail = Future.value();

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize(
    int goalId,
    LocalDate day, {
    required bool editable,
  }) async {
    final previous = await store.at(goalId, day);
    readOnly =
        !editable ||
        (day != store.goals.clock.read().day &&
            previous?.record.draftText == null);
    snapshot = readOnly ? previous : await store.beginDraft(goalId, day);
    text = snapshot?.record.draftText ?? snapshot?.record.content ?? '';
    if (snapshot case final value?) {
      try {
        _sharingChanged(await store.publications.recordState(value.record.id));
      } catch (_) {
        _consent = null;
        shareDetails = false;
      }
      _sharing = store.publications
          .watchRecordState(value.record.id)
          .listen(
            _sharingChanged,
            onError: (Object _) {
              _consent = null;
              shareDetails = false;
              _notify();
            },
          );
    }
    ready = true;
    await _clean();
    _notify();
  }

  Future<T> _enqueue<T>(Future<T> Function() work) {
    final result = _tail.then((_) => work());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> setText(String value) {
    if (!ready || readOnly || busy || closed) return Future.value();
    text = value;
    return _writeDraft(
      value,
      share: shareDetails,
      consent: shareDetails ? _consent : null,
    );
  }

  void _sharingChanged(RecordSharingState state) {
    if (_disposed) return;
    final previous = _consent;
    _consent = state.consent;
    syncState = state.syncState;
    if (_consent == null ||
        (previous != null &&
            (previous.sessionId != _consent!.sessionId ||
                previous.grant.id != _consent!.grant.id))) {
      shareDetails = false;
    } else if (!dirty && !busy) {
      shareDetails = state.draftShared;
    }
    _notify();
  }

  Future<void> setShareDetails(bool value) {
    if (!ready || readOnly || busy || closed || (value && !canShare)) {
      return Future.value();
    }
    shareDetails = value;
    return _writeDraft(text, share: value, consent: value ? _consent : null);
  }

  Future<void> _writeDraft(
    String value, {
    required bool share,
    required RecordSharingConsent? consent,
  }) {
    final version = ++_inputVersion;
    dirty = true;
    error = null;
    _notify();
    return _enqueue(() async {
      try {
        final current = snapshot!;
        snapshot = await store.writeDraft(
          current.record.id,
          content: value,
          expectedDraftRevision: current.record.draftRevision,
          shareWithPartner: share,
          sharingConsent: consent,
        );
        if (version == _inputVersion) {
          dirty = false;
          _draftFailure = null;
          error = null;
          shareDetails =
              snapshot!.record.draftShareWithPartner && _consent != null;
        }
      } catch (failure) {
        _draftFailure = failure;
        error = recordErrorMessage(failure);
      }
      _notify();
    });
  }

  Future<void> flush() async {
    await _tail;
    if (_draftFailure case final failure?) throw failure;
  }

  Future<bool> _action(Future<void> Function() work) async {
    if (!ready || busy || closed) return false;
    busy = true;
    error = null;
    _notify();
    try {
      await flush();
      await store.goals.requireActiveIdentity();
      await work();
      return true;
    } catch (failure) {
      error = recordErrorMessage(failure);
      return false;
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<bool> save() => _action(() async {
    if (readOnly) throw const RecordRuleException('过去或已归档的记录只可查看或删除');
    var current = snapshot!;
    if (current.record.draftShareWithPartner != shareDetails) {
      current = await store.writeDraft(
        current.record.id,
        content: text,
        expectedDraftRevision: current.record.draftRevision,
        shareWithPartner: shareDetails,
        sharingConsent: shareDetails ? _consent : null,
      );
      snapshot = current;
    }
    snapshot = await store.save(
      current.record.id,
      operationId: const Uuid().v4(),
      expectedRevision: current.record.revision,
      expectedDraftRevision: current.record.draftRevision,
    );
    closed = true;
    await _clean();
  });

  Future<bool> addPhoto(RecordPhotoSource source) => _action(() async {
    if (readOnly) throw const RecordRuleException('这条记录只可查看');
    if (snapshot!.draftPhotos.length >= 3) {
      throw const RecordRuleException('每条记录最多 3 张照片');
    }
    final bytes = await picker.pick(source);
    if (bytes == null) return;
    await store.goals.requireActiveIdentity();
    final sanitized = await sanitizeRecordPhoto(bytes);
    await store.goals.requireActiveIdentity();
    final photo = await files.write(sanitized);
    try {
      final current = snapshot!;
      snapshot = await store.addPhoto(
        current.record.id,
        photo: photo,
        expectedDraftRevision: current.record.draftRevision,
      );
    } catch (_) {
      // A failed attachment may leave a file, but never a saved broken link.
      // Deferred orphan cleanup also handles process death before this block.
      try {
        await files.remove(photo.id);
      } catch (_) {}
      rethrow;
    }
  });

  Future<bool> removePhoto(String id) => _action(() async {
    if (readOnly) throw const RecordRuleException('这条记录只可查看');
    final current = snapshot!;
    snapshot = await store.removePhoto(
      current.record.id,
      id,
      expectedDraftRevision: current.record.draftRevision,
    );
    await _clean();
  });

  Future<bool> delete() => _action(() async {
    final current = snapshot!;
    await store.delete(
      current.record.id,
      operationId: const Uuid().v4(),
      expectedRevision: current.record.revision,
    );
    closed = true;
    await _clean();
  });

  Future<void> _clean() async {
    try {
      await files.clean(store);
      cleanupWarning = null;
    } catch (_) {
      cleanupWarning = '记录已保留，已移除照片的本地清理将在重新打开时重试';
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_sharing?.cancel());
    super.dispose();
  }
}
