import 'package:flutter/foundation.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

import '../../../shared/local_date.dart';
import '../../assistant/data/assistant_service.dart';
import '../data/local_journal_store.dart';
import '../domain/journal_entry.dart';
import '../domain/journal_suggestion.dart';
import '../presentation/journal_editor_controller.dart';
import 'journal_ai_context.dart';

class JournalAiPreview {
  const JournalAiPreview({
    required this.original,
    required this.suggestion,
    required this.tips,
    required this.access,
  });
  final String original;
  final String suggestion;
  final List<String> tips;
  final AssistantAccess access;
}

class JournalAiController extends ChangeNotifier {
  JournalAiController({
    required this.editor,
    required this.context,
    required this.service,
  });
  final JournalEditorController editor;
  final JournalAiContext context;
  final JournalAiService service;
  JournalAiPreview? preview;
  String? error;
  bool busy = false;
  bool applied = false;
  String? _undoText;
  String? _appliedText;
  int _epoch = 0;
  bool _disposed = false;
  AssistantCancellation? _cancellation;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  bool get canUndo =>
      !_disposed &&
      !busy &&
      _undoText != null &&
      editor.text == _appliedText &&
      !editor.closed;

  Future<bool> request() async {
    if (_disposed || busy || !editor.ready || editor.busy || editor.closed) {
      return false;
    }
    final epoch = ++_epoch;
    busy = true;
    error = null;
    preview = null;
    final cancellation = AssistantCancellation();
    _cancellation = cancellation;
    _notify();
    bool current() =>
        !_disposed &&
        epoch == _epoch &&
        !editor.closed &&
        !cancellation.isCancelled;
    try {
      final access = await context.authorize();
      if (!service.configured) {
        throw const AssistantFailure(AssistantFailureKind.unconfigured);
      }
      await editor.flush();
      if (!current()) return false;
      final original = editor.text;
      final String suggestion;
      final List<String> tips;
      if (editor.store.kind == JournalKind.quickNote) {
        final request = await context.polish(original);
        if (!current() || !await access.isCurrent() || !current()) {
          throw const AssistantFailure(AssistantFailureKind.discarded);
        }
        final response = await service.polishNote(
          request,
          access: access,
          cancellation: cancellation,
        );
        final valid = PolishNoteResponse.fromJson(
          response.toJson(),
          request: request,
        );
        suggestion = valid.rewrite;
        tips = valid.tips;
      } else {
        final day = LocalDate.parse(editor.snapshot!.entry.day);
        final request = await context.diary(day);
        if (!current() || !await access.isCurrent() || !current()) {
          throw const AssistantFailure(AssistantFailureKind.discarded);
        }
        final response = await service.generateDiary(
          request,
          access: access,
          cancellation: cancellation,
        );
        final valid = GenerateDiaryResponse.fromJson(
          response.toJson(),
          request: request,
        );
        if (valid.insufficientMaterial) {
          throw const JournalRuleException('今天的素材不足，可以先写一点随手记');
        }
        suggestion = valid.draft;
        tips = const [];
      }
      if (!current() || !await access.isCurrent() || !current()) {
        throw const AssistantFailure(AssistantFailureKind.discarded);
      }
      if (editor.text != original || editor.busy || editor.closed) {
        throw const JournalRuleException('内容已变化，请重新生成；当前草稿未被替换');
      }
      preview = JournalAiPreview(
        original: original,
        suggestion: suggestion,
        tips: tips,
        access: access,
      );
      return true;
    } catch (failure) {
      if (current()) {
        error = switch (failure) {
          AssistantFailure(kind: AssistantFailureKind.tooLarge)
              when editor.store.kind == JournalKind.diary =>
            '今天的素材太多，请精简当天的随手记或打卡记录后重试。原文未被修改。',
          AssistantFailure() => failure.message,
          FormatException() => '内容超过发送上限或结果无效，原文未被修改',
          _ => journalErrorMessage(failure),
        };
      }
      return false;
    } finally {
      if (epoch == _epoch) {
        busy = false;
        _cancellation = null;
        _notify();
      }
    }
  }

  Future<bool> use({bool append = false, String? editedText}) async {
    final result = preview;
    if (_disposed || busy || result == null || editor.busy || editor.closed) {
      return false;
    }
    final epoch = _epoch;
    busy = true;
    error = null;
    _notify();
    try {
      if (!await result.access.isCurrent() ||
          _disposed ||
          editor.closed ||
          epoch != _epoch) {
        throw const AssistantFailure(AssistantFailureKind.discarded);
      }
      if (editor.text != result.original || editor.busy) {
        throw const JournalRuleException('草稿已变化，请重新生成');
      }
      final suggestion = editedText ?? result.suggestion;
      final problem = journalSuggestionError(
        suggestion,
        kind: editor.store.kind,
        original: result.original,
        append: append,
      );
      if (problem != null) {
        throw JournalRuleException(problem);
      }
      final replacement = append && result.original.isNotEmpty
          ? '${result.original}\n\n$suggestion'
          : suggestion;
      if (!await editor.replaceText(
        replacement,
        expectedText: result.original,
      )) {
        throw JournalRuleException(editor.error ?? '草稿未写入，请重试');
      }
      _undoText = result.original;
      _appliedText = replacement;
      applied = true;
      if (_disposed || epoch != _epoch) return false;
      preview = null;
      return true;
    } catch (failure) {
      if (!_disposed && epoch == _epoch) {
        error = failure is AssistantFailure
            ? failure.message
            : journalErrorMessage(failure);
      }
      return false;
    } finally {
      if (epoch == _epoch) {
        busy = false;
        _notify();
      }
    }
  }

  Future<bool> undo() async {
    if (_disposed || !canUndo || editor.busy) return false;
    final epoch = _epoch;
    busy = true;
    _notify();
    try {
      await editor.store.goals.requireActiveIdentity();
      if (_disposed ||
          epoch != _epoch ||
          editor.closed ||
          editor.busy ||
          editor.text != _appliedText) {
        return false;
      }
      if (!await editor.replaceText(_undoText!, expectedText: _appliedText!)) {
        throw JournalRuleException(editor.error ?? '撤销未完成，请重试');
      }
      if (_disposed || epoch != _epoch) return false;
      _undoText = null;
      _appliedText = null;
      applied = false;
      error = null;
      return true;
    } catch (failure) {
      if (!_disposed && epoch == _epoch) error = journalErrorMessage(failure);
      return false;
    } finally {
      if (epoch == _epoch) {
        busy = false;
        _notify();
      }
    }
  }

  void discardPreview() {
    preview = null;
    _notify();
  }

  void cancel({bool configurationChanged = false}) {
    _epoch++;
    _cancellation?.cancel();
    _cancellation = null;
    busy = false;
    preview = null;
    error = configurationChanged ? '授权或凭证已变化，结果已丢弃' : '已取消等待；模型调用可能已经发生';
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    _cancellation?.cancel();
    super.dispose();
  }
}
