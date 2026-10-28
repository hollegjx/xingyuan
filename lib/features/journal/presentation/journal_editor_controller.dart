import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../../data/sync/identity_store.dart';
import '../../../shared/local_date.dart';
import '../../records/data/record_photo.dart';
import '../../records/data/record_photo_picker.dart';
import '../data/journal_photo_files.dart';
import '../data/local_journal_store.dart';
import '../domain/journal_entry.dart';

const _saveFailureMessage = '未能保存，请重试。原有内容未被清空。';

String journalErrorMessage(
  Object error, {
  String fallback = _saveFailureMessage,
}) => switch (error) {
  JournalRuleException() => error.message,
  RecordPhotoException() => error.message,
  StaleIdentity() => '身份已变化，请返回后重新打开',
  _ => fallback,
};

class JournalEditorController extends ChangeNotifier {
  JournalEditorController({
    required this.store,
    required this.files,
    required this.picker,
  });

  final LocalJournalStore store;
  final JournalPhotoFiles files;
  final RecordPhotoPicker picker;
  JournalSnapshot? snapshot;
  String text = '';
  String? error;
  String? cleanupWarning;
  bool ready = false;
  bool busy = false;
  bool dirty = false;
  bool closed = false;
  bool _disposed = false;
  int _inputVersion = 0;
  Object? _draftFailure;
  String? _saveOperation;
  String? _deleteOperation;
  Future<void> _tail = Future.value();

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize({required LocalDate day, String? id}) async {
    snapshot = switch (store) {
      LocalQuickNoteStore notes => await notes.beginDraft(id: id, day: day),
      LocalDiaryStore diary => await diary.beginDraft(day),
      _ => throw StateError('Unsupported journal store'),
    };
    text = snapshot!.entry.draftText!;
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
    if (!ready || busy || closed || _disposed) return Future.value();
    text = value;
    dirty = true;
    error = null;
    _saveOperation = null;
    _deleteOperation = null;
    final version = ++_inputVersion;
    _notify();
    // Accepted keystrokes finish in order even if the widget is disposed.
    return _enqueue(() async {
      try {
        final entry = snapshot!.entry;
        snapshot = await store.writeDraft(
          entry.id,
          content: value,
          expectedDraftRevision: entry.draftRevision,
        );
        if (version == _inputVersion) {
          dirty = false;
          _draftFailure = null;
          error = null;
        }
      } catch (failure) {
        _draftFailure = failure;
        error = journalErrorMessage(failure);
      }
      _notify();
    });
  }

  Future<void> flush() async {
    await _tail;
    if (_draftFailure case final failure?) throw failure;
  }

  Future<void> _requireOpen() async {
    if (_disposed || closed) throw const JournalRuleException('编辑已关闭');
    await store.goals.requireActiveIdentity();
    if (_disposed || closed) throw const JournalRuleException('编辑已关闭');
  }

  Future<bool> _action(
    Future<void> Function() work, {
    String fallback = _saveFailureMessage,
  }) async {
    if (!ready || busy || closed || _disposed) return false;
    busy = true;
    error = null;
    _notify();
    var started = false;
    try {
      await flush();
      await _requireOpen();
      started = true;
      await work();
      return true;
    } catch (failure) {
      // A failed pending draft is still a save failure, not a failed delete.
      error = journalErrorMessage(
        failure,
        fallback: started ? fallback : _saveFailureMessage,
      );
      return false;
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<bool> save() => _action(() async {
    final entry = snapshot!.entry;
    snapshot = await store.save(
      entry.id,
      operationId: _saveOperation ??= const Uuid().v4(),
      expectedRevision: entry.revision,
      expectedDraftRevision: entry.draftRevision,
    );
    closed = true;
    await _clean();
  });

  // Explicit replacements become visible only after the draft write succeeds.
  Future<bool> replaceText(String value, {required String expectedText}) =>
      _action(() async {
        if (text != expectedText) {
          throw const JournalRuleException('草稿已变化，请重新生成');
        }
        final entry = snapshot!.entry;
        snapshot = await store.writeDraft(
          entry.id,
          content: value,
          expectedDraftRevision: entry.draftRevision,
        );
        text = value;
        dirty = false;
        _draftFailure = null;
        _saveOperation = null;
        _deleteOperation = null;
        _inputVersion++;
      });

  Future<bool> addPhoto(RecordPhotoSource source) => _action(() async {
    if (snapshot!.draftPhotos.length >= 3) {
      throw const JournalRuleException('每条内容最多 3 张照片');
    }
    final bytes = await picker.pick(source);
    if (bytes == null) return;
    await _requireOpen();
    final sanitized = await sanitizeRecordPhoto(bytes);
    await _requireOpen();
    final photo = await files.write(sanitized);
    try {
      await _requireOpen();
      final entry = snapshot!.entry;
      snapshot = await store.addPhoto(
        entry.id,
        photo: photo,
        expectedDraftRevision: entry.draftRevision,
      );
      _saveOperation = null;
      _deleteOperation = null;
    } catch (_) {
      // This file was created by this import and is not a saved attachment.
      try {
        await files.remove(photo.id);
      } catch (_) {}
      rethrow;
    }
  });

  Future<bool> removePhoto(String id) => _action(() async {
    final entry = snapshot!.entry;
    snapshot = await store.removePhoto(
      entry.id,
      id,
      expectedDraftRevision: entry.draftRevision,
    );
    _saveOperation = null;
    _deleteOperation = null;
    await _clean();
  });

  Future<bool> delete() => _action(() async {
    final entry = snapshot!.entry;
    await store.delete(
      entry.id,
      operationId: _deleteOperation ??= const Uuid().v4(),
      expectedRevision: entry.revision,
      expectedDraftRevision: entry.draftRevision,
    );
    closed = true;
    await _clean();
  }, fallback: '未能删除，请重试。原有内容未被清空。');

  Future<void> _clean() async {
    try {
      await files.clean(store);
      cleanupWarning = null;
    } catch (_) {
      cleanupWarning = '内容已保留，已移除照片的本地清理将在重新打开时重试';
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
