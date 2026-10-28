import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../app/theme.dart';
import '../../../shared/local_date.dart';
import '../../../shared/local_identity_boundary.dart';
import '../../../shared/presentation.dart';
import '../../assistant/assistant_providers.dart';
import '../../assistant/data/assistant_service.dart';
import '../../assistant/presentation/assistant_settings_page.dart';
import '../../records/data/record_photo_picker.dart';
import '../../records/record_providers.dart';
import '../data/local_journal_store.dart';
import '../domain/journal_entry.dart';
import '../journal_providers.dart';
import '../ai/journal_ai_context.dart';
import '../ai/journal_ai_controller.dart';
import '../ai/journal_ai_providers.dart';
import 'journal_ai_preview.dart';
import 'journal_delete_confirmation.dart';
import 'journal_editor_controller.dart';
import 'journal_photo_view.dart';
import 'journal_style.dart';
import 'journal_viewport.dart';

Future<void> openJournalEditor(
  BuildContext context, {
  required JournalKind kind,
  required LocalDate day,
  String? id,
}) async {
  // Each editor owns its notices, including while the home route stays mounted.
  if (kind == JournalKind.diary) {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => JournalViewport(
          builder: (_) => ScaffoldMessenger(
            child: JournalEditorPage(kind: kind, day: day),
          ),
        ),
      ),
    );
    return;
  }
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    isDismissible: false,
    enableDrag: false,
    clipBehavior: Clip.antiAlias,
    builder: (_) => JournalViewport(
      builder: (context) {
        final media = MediaQuery.of(context);
        return Padding(
          padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
          child: SizedBox(
            height: math.max(
              0,
              (media.size.height -
                      media.viewPadding.top -
                      media.viewInsets.bottom) *
                  .9,
            ),
            child: ScaffoldMessenger(
              child: JournalEditorPage(
                kind: kind,
                day: day,
                id: id,
                sheet: true,
              ),
            ),
          ),
        );
      },
    ),
  );
}

class JournalEditorPage extends ConsumerStatefulWidget {
  const JournalEditorPage({
    required this.kind,
    required this.day,
    this.id,
    this.sheet = false,
    super.key,
  });

  final JournalKind kind;
  final LocalDate day;
  final String? id;
  final bool sheet;

  @override
  ConsumerState<JournalEditorPage> createState() => _JournalEditorPageState();
}

class _JournalEditorPageState extends ConsumerState<JournalEditorPage> {
  late final _id = widget.id ?? const Uuid().v4();
  late final Future<LocalJournalStore> _store = ref.read(
    journalStoreProvider(widget.kind).future,
  );
  late final _repository = _store.then((store) => store.goals);
  late Future<void> _opening = _open();
  final _text = TextEditingController();
  final _focus = FocusNode();
  JournalEditorController? _controller;
  JournalAiController? _ai;
  bool _previewOpen = false;
  bool _leaving = false;
  bool _allowLeave = false;
  bool _confirming = false;
  double? _lastTextSize;
  bool _caretRevealScheduled = false;

  String get _label => widget.kind == JournalKind.quickNote ? '随手记' : '日记';

  void _revealCaretAfterTextScaleChange(double textSize) {
    final changed = _lastTextSize != null && _lastTextSize != textSize;
    _lastTextSize = textSize;
    if (!changed || !_focus.hasFocus || _caretRevealScheduled) return;
    _caretRevealScheduled = true;
    // Font changes move the caret without an editing event. Reveal it after
    // layout without changing focus, selection, composing range or the draft.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _caretRevealScheduled = false;
      if (!mounted ||
          !_focus.hasFocus ||
          _leaving ||
          _previewOpen ||
          !_text.selection.isValid) {
        return;
      }
      _focus.context
          ?.findAncestorStateOfType<EditableTextState>()
          ?.bringIntoView(_text.selection.extent);
    });
  }

  Future<void> _open() async {
    final store = await _store;
    final files = await ref.read(journalPhotoFilesProvider(widget.kind).future);
    if (!mounted) return;
    final controller = JournalEditorController(
      store: store,
      files: files,
      picker: ref.read(recordPhotoPickerProvider),
    );
    try {
      await controller.initialize(day: widget.day, id: _id);
      if (!mounted) {
        controller.dispose();
        return;
      }
      _controller?.dispose();
      _ai?.dispose();
      _controller = controller;
      _ai = null;
      _text.text = controller.text;
      controller.addListener(_changed);
      setState(() {});
    } catch (_) {
      controller.dispose();
      rethrow;
    }
  }

  void _changed() {
    if (!mounted) return;
    final text = _controller?.text;
    if (text != null && text != _text.text) {
      _text.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    }
    setState(() {});
  }

  @override
  void dispose() {
    _ai?.dispose();
    _controller?.dispose();
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _leave() async {
    if (_leaving || _confirming || _controller?.busy == true) return;
    setState(() => _leaving = true);
    _ai?.cancel();
    try {
      await _controller?.flush();
      if (!mounted) return;
      _focus.unfocus();
      setState(() => _allowLeave = true);
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        _tell(journalErrorMessage(error));
      }
    } finally {
      if (mounted) setState(() => _leaving = false);
    }
  }

  Future<void> _onAiTap({required bool authorized}) async {
    if (!mounted ||
        _controller?.ready != true ||
        _controller!.busy ||
        _controller!.closed ||
        _leaving ||
        _confirming ||
        _previewOpen ||
        _ai?.busy == true) {
      return;
    }
    final ai = _ai;
    if (!authorized) {
      setState(() => _confirming = true);
      try {
        final open = await confirmAction(
          context,
          title: '开启 AI 功能',
          message: widget.kind == JournalKind.quickNote
              ? '润色需要先在 AI 设置里同意使用说明。只发送这一条的文字，不发照片。'
              : 'AI 写日记需要先在 AI 设置里同意使用说明。只发送今天的打卡和随手记文字，不发照片。',
          confirm: '去开启',
          confirmKey: const ValueKey('journal-ai-open-settings'),
        );
        if (open && mounted) {
          await Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const AssistantSettingsPage(),
            ),
          );
        }
      } finally {
        if (mounted) setState(() => _confirming = false);
      }
      return;
    }
    if (ai == null || ai.service.configured != true) {
      _tell('AI 暂时连接不上，可以在「我的 → AI 设置」里检查连接。');
      return;
    }
    if (widget.kind == JournalKind.diary &&
        _controller!.store.goals.clock.read().day != widget.day) {
      _tell('AI 只能为今天写日记。');
      return;
    }
    if (ai.busy) return;
    await _requestAi();
  }

  void _tell(String message) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        showCloseIcon: true,
        closeIconColor: Theme.of(context).snackBarTheme.contentTextStyle?.color,
        content: Builder(
          builder: (context) {
            final media = MediaQuery.of(context);
            final visibleHeight = math.max(
              0.0,
              media.size.height -
                  media.viewInsets.bottom -
                  media.viewPadding.vertical,
            );
            // Keep long, scaled notices readable above the keyboard and leave
            // room for the editor controls. Rebuild as keyboard metrics change.
            return ConstrainedBox(
              constraints: BoxConstraints(maxHeight: visibleHeight * .4),
              child: SingleChildScrollView(
                key: const ValueKey('journal-notice-scroll'),
                primary: false,
                child: Text(message),
              ),
            );
          },
        ),
      ),
    );

  Future<void> _requestAi() async {
    final ai = _ai;
    if (ai == null || _previewOpen || _leaving || _confirming) return;
    _focus.unfocus();
    if (!await ai.request() || !mounted || _leaving) return;
    setState(() => _previewOpen = true);
    try {
      await showJournalAiPreview(context, ai);
    } finally {
      if (mounted) {
        ai.discardPreview();
        setState(() => _previewOpen = false);
      }
    }
  }

  Future<void> _delete() async {
    if (_confirming || _leaving || _controller!.busy) return;
    setState(() => _confirming = true);
    final approved = await confirmDeleteJournal(context, widget.kind);
    if (!mounted) return;
    setState(() => _confirming = false);
    if (approved == true && await _controller!.delete()) {
      if (mounted) await _leave();
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final settings = ref.watch(assistantSettingsProvider).asData?.value;
    final aiAuthorized =
        settings?.consentVersion == assistantConsentVersion &&
        settings?.consentedAt != null;
    // Local editing without consent does not instantiate a network service.
    if (aiAuthorized && controller != null && _ai == null) {
      _ai = JournalAiController(
        editor: controller,
        context: JournalAiContext(
          controller.store.goals,
          credentialRevision: () =>
              ref.read(assistantCredentialRevisionProvider.notifier).changing
              ? -1
              : ref.read(assistantCredentialRevisionProvider),
        ),
        service: ref.read(journalAiServiceProvider),
      )..addListener(_changed);
    }
    ref.listen(
      assistantCredentialRevisionProvider,
      (_, _) => _ai?.cancel(configurationChanged: true),
    );
    ref.listen(assistantSettingsProvider, (before, after) {
      if (before?.asData != null &&
          before?.asData?.value != after.asData?.value) {
        _ai?.cancel(configurationChanged: true);
      }
    });
    final enabled =
        controller?.ready == true &&
        !controller!.busy &&
        !controller.closed &&
        !_leaving &&
        !_confirming;
    final lengthError = _text.text.characters.length > widget.kind.maxLength
        ? '正文最多 ${widget.kind.maxLength} 字'
        : null;
    return LocalIdentityBoundary(
      repository: _repository,
      child: PopScope<void>(
        canPop: _allowLeave,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _leave();
        },
        child: Scaffold(
          resizeToAvoidBottomInset: !widget.sheet,
          appBar: pageAppBar(
            context,
            _label,
            actions: [
              Tooltip(
                message: '保存$_label',
                child: TextButton(
                  key: const ValueKey('save-journal'),
                  onPressed: enabled
                      ? () async {
                          if (await controller.save() && mounted) {
                            await _leave();
                          }
                        }
                      : null,
                  child: const Text(
                    '完成',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],
          ),
          body: SafeArea(
            top: false,
            bottom: false,
            child: FutureBuilder<void>(
              future: _opening,
              builder: (context, opening) {
                if (opening.hasError) {
                  return PageScroll(
                    children: [
                      StatusPanel(
                        message: journalErrorMessage(opening.error!),
                        retry: () => setState(() => _opening = _open()),
                      ),
                    ],
                  );
                }
                if (controller == null || !controller.ready) {
                  return const StatusPanel(message: '正在读取内容', loading: true);
                }
                final photos = controller.snapshot!.draftPhotos;
                final aiUnavailable =
                    !aiAuthorized || _ai?.service.configured != true;
                final aiSettingsAction = IconButton(
                  key: const ValueKey('journal-ai-settings'),
                  tooltip: 'AI 设置',
                  onPressed: enabled
                      ? () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const AssistantSettingsPage(),
                          ),
                        )
                      : null,
                  icon: const Icon(CupertinoIcons.settings),
                );
                return LayoutBuilder(
                  builder: (context, box) {
                    _revealCaretAfterTextScaleChange(
                      MediaQuery.textScalerOf(context).scale(17),
                    );
                    final aiLabel = widget.kind == JournalKind.quickNote
                        ? '润色'
                        : 'AI 写日记';
                    final toolLayout = _toolbarLayout(
                      context,
                      box.maxWidth,
                      aiLabel,
                      photos.length,
                    );
                    final aiAction = _AiPill(
                      label: aiLabel,
                      icon: widget.kind == JournalKind.quickNote
                          ? CupertinoIcons.sparkles
                          : CupertinoIcons.wand_stars,
                      compact: toolLayout.compactAi,
                      ready:
                          !aiUnavailable &&
                          (widget.kind == JournalKind.quickNote ||
                              controller.store.goals.clock.read().day ==
                                  widget.day),
                      onPressed: enabled && _ai?.busy != true && !_previewOpen
                          ? () => _onAiTap(authorized: aiAuthorized)
                          : null,
                    );
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: PageScroll(
                            key: const ValueKey('journal-editor-scroll'),
                            children: [
                              _EditorHeader(
                                kind: widget.kind,
                                day: widget.day,
                                status: controller.closed
                                    ? '已保存'
                                    : controller.dirty
                                    ? controller.error != null
                                          ? '草稿未保存'
                                          : '正在保存草稿'
                                    : '草稿已保存在本机',
                                failed:
                                    controller.dirty &&
                                    controller.error != null,
                              ),
                              if (_ai?.busy == true)
                                _AiStatus(
                                  busy: true,
                                  text: widget.kind == JournalKind.diary
                                      ? '正在整理今天的记录'
                                      : '正在润色这段文字',
                                  action: IconButton(
                                    key: const ValueKey('journal-ai-cancel'),
                                    tooltip: '取消生成',
                                    onPressed: () => _ai?.cancel(),
                                    icon: const Icon(CupertinoIcons.xmark),
                                  ),
                                )
                              else if (_ai?.applied == true)
                                _AiStatus(
                                  text: '由星愿生成，可修改',
                                  textKey: const ValueKey('journal-ai-applied'),
                                  action: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton(
                                        key: const ValueKey('journal-ai-undo'),
                                        tooltip: '撤销 AI 修改',
                                        onPressed: _ai!.canUndo
                                            ? _ai!.undo
                                            : null,
                                        icon: const Icon(
                                          CupertinoIcons.arrow_uturn_left,
                                        ),
                                      ),
                                      if (aiUnavailable) aiSettingsAction,
                                    ],
                                  ),
                                )
                              else if (aiUnavailable)
                                _AiStatus(
                                  text: aiAuthorized ? 'AI 尚未连接' : 'AI 未开启',
                                  action: aiSettingsAction,
                                ),
                              if (_ai?.error case final error?)
                                NoticeBanner(
                                  tone: NoticeTone.error,
                                  message: error,
                                ),
                              _Paper(
                                builder: (context, paperBox) {
                                  final separateLengthError =
                                      lengthError != null &&
                                      _lengthFeedbackNeedsOwnLine(
                                        context,
                                        paperBox.maxWidth,
                                        lengthError,
                                        _text.text.characters.length,
                                        widget.kind.maxLength,
                                      );
                                  return Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      TextField(
                                        key: const ValueKey('journal-text'),
                                        controller: _text,
                                        focusNode: _focus,
                                        autofocus:
                                            widget.kind ==
                                            JournalKind.quickNote,
                                        enabled: enabled,
                                        minLines:
                                            widget.kind == JournalKind.quickNote
                                            ? 4
                                            : 12,
                                        maxLines: null,
                                        maxLength: widget.kind.maxLength,
                                        maxLengthEnforcement:
                                            MaxLengthEnforcement.none,
                                        buildCounter: _counter,
                                        textCapitalization:
                                            TextCapitalization.sentences,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodyLarge
                                            ?.copyWith(
                                              height:
                                                  widget.kind ==
                                                      JournalKind.diary
                                                  ? 1.7
                                                  : 1.5,
                                            ),
                                        decoration: InputDecoration(
                                          filled: false,
                                          border: InputBorder.none,
                                          enabledBorder: InputBorder.none,
                                          focusedBorder: InputBorder.none,
                                          disabledBorder: InputBorder.none,
                                          errorBorder: InputBorder.none,
                                          focusedErrorBorder: InputBorder.none,
                                          contentPadding: EdgeInsets.zero,
                                          hintText:
                                              widget.kind ==
                                                  JournalKind.quickNote
                                              ? '记下此刻的想法…'
                                              : '今天，想留下什么？',
                                          hintStyle: TextStyle(
                                            color: context.xy.faint,
                                          ),
                                          errorText: separateLengthError
                                              ? null
                                              : lengthError,
                                        ),
                                        onChanged: controller.setText,
                                      ),
                                      // The scaled counter must not consume the
                                      // inline error's entire available width.
                                      if (separateLengthError)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            top: 8,
                                          ),
                                          child: Semantics(
                                            liveRegion: true,
                                            child: Text(
                                              lengthError,
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .bodySmall
                                                  ?.copyWith(
                                                    color: Theme.of(context)
                                                        .colorScheme
                                                        .error,
                                                  ),
                                            ),
                                          ),
                                        ),
                                      if (box.maxWidth /
                                                  MediaQuery.textScalerOf(
                                                    context,
                                                  ).scale(17) >=
                                              12 &&
                                          widget.kind == JournalKind.diary &&
                                          _text.text.trim().isEmpty &&
                                          _ai?.busy != true &&
                                          controller.store.goals.clock
                                                  .read()
                                                  .day ==
                                              widget.day)
                                        _AiInvite(
                                          onTap: enabled && !_previewOpen
                                              ? () => _onAiTap(
                                                  authorized: aiAuthorized,
                                                )
                                              : null,
                                        ),
                                      if (toolLayout.counterInContent)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            top: 12,
                                          ),
                                          child: Text(
                                            '${photos.length}/3',
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodySmall
                                                ?.copyWith(
                                                  color: context.xy.muted,
                                                ),
                                          ),
                                        ),
                                      if (photos.isNotEmpty) ...[
                                        const SizedBox(height: 16),
                                        Wrap(
                                          spacing: 12,
                                          runSpacing: 12,
                                          children: [
                                            for (final photo in photos)
                                              _PhotoThumb(
                                                kind: widget.kind,
                                                photo: photo,
                                                onRemove: enabled
                                                    ? () => controller
                                                          .removePhoto(photo.id)
                                                    : null,
                                              ),
                                          ],
                                        ),
                                      ],
                                    ],
                                  );
                                },
                              ),
                              if (controller.error case final error?
                                  when error != lengthError || controller.dirty)
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    4,
                                    14,
                                    4,
                                    0,
                                  ),
                                  child: Wrap(
                                    spacing: 4,
                                    crossAxisAlignment:
                                        WrapCrossAlignment.center,
                                    children: [
                                      if (error != lengthError)
                                        Text(
                                          error,
                                          key: const ValueKey('journal-error'),
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall
                                              ?.copyWith(
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .error,
                                              ),
                                        ),
                                      if (controller.dirty)
                                        TextButton(
                                          key: const ValueKey(
                                            'retry-journal-draft',
                                          ),
                                          onPressed: enabled
                                              ? () => controller.setText(
                                                  controller.text,
                                                )
                                              : null,
                                          child: const Text('重试草稿保存'),
                                        ),
                                    ],
                                  ),
                                ),
                              if (controller.cleanupWarning case final warning?)
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    4,
                                    10,
                                    4,
                                    0,
                                  ),
                                  child: Text(
                                    warning,
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(color: context.xy.muted),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        // Leave room to edit at cramped heights; restore the bar
                        // when enough space returns, including during keyboard use.
                        if (box.maxHeight >= 160)
                          _Toolbar(
                            children: [
                              IconButton(
                                key: const ValueKey('journal-add-photo'),
                                tooltip: '从相册添加照片',
                                onPressed: enabled && photos.length < 3
                                    ? () => controller.addPhoto(
                                        RecordPhotoSource.library,
                                      )
                                    : null,
                                icon: const Icon(
                                  CupertinoIcons.photo,
                                  size: 24,
                                ),
                              ),
                              IconButton(
                                key: const ValueKey('journal-take-photo'),
                                tooltip: '拍照',
                                onPressed: enabled && photos.length < 3
                                    ? () => controller.addPhoto(
                                        RecordPhotoSource.camera,
                                      )
                                    : null,
                                icon: const Icon(
                                  CupertinoIcons.camera,
                                  size: 24,
                                ),
                              ),
                              if (!toolLayout.counterInContent)
                                Padding(
                                  padding: const EdgeInsets.only(left: 2),
                                  child: Text(
                                    '${photos.length}/3',
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(color: context.xy.muted),
                                  ),
                                ),
                              IconButton(
                                key: const ValueKey('delete-journal'),
                                tooltip: '删除$_label',
                                onPressed: enabled ? _delete : null,
                                icon: const Icon(
                                  CupertinoIcons.trash,
                                  size: 22,
                                ),
                              ),
                              aiAction,
                            ],
                          ),
                      ],
                    );
                  },
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// Character count shown only near the limit.
Widget? _counter(
  BuildContext context, {
  required int currentLength,
  required bool isFocused,
  required int? maxLength,
}) {
  if (maxLength == null || currentLength < maxLength * 0.8) return null;
  return Text(
    '$currentLength / $maxLength',
    style: Theme.of(context).textTheme.bodySmall?.copyWith(
      color: currentLength > maxLength
          ? Theme.of(context).colorScheme.error
          : context.xy.muted,
    ),
  );
}

bool _lengthFeedbackNeedsOwnLine(
  BuildContext context,
  double width,
  String message,
  int length,
  int maxLength,
) {
  final theme = Theme.of(context);
  final painter = TextPainter(
    text: TextSpan(
      text: message,
      style: theme.inputDecorationTheme.errorStyle ?? theme.textTheme.bodySmall,
    ),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    locale: Localizations.maybeLocaleOf(context),
  )..layout();
  final errorWidth = painter.width;
  painter.text = TextSpan(
    text: '$length / $maxLength',
    style: theme.textTheme.bodySmall,
  );
  painter.layout();
  // InputDecorator reserves 16px between the error and counter.
  final needsOwnLine = errorWidth + 16 + painter.width > width;
  painter.dispose();
  return needsOwnLine;
}

/// Date, kind and draft state above the writing sheet.
class _EditorHeader extends StatelessWidget {
  const _EditorHeader({
    required this.kind,
    required this.day,
    required this.status,
    required this.failed,
  });

  final JournalKind kind;
  final LocalDate day;
  final String status;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final xy = context.xy;
    final statusColor = failed ? theme.colorScheme.error : xy.muted;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${weekdayLabels[day.weekday - 1]} · '
            '${kind == JournalKind.diary ? '日记' : '随手记'}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: kind == JournalKind.diary
                  ? theme.colorScheme.primary
                  : journalNoteTint(context),
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            journalDayLabel(day),
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Semantics(
            liveRegion: true,
            child: Row(
              children: [
                Icon(
                  failed
                      ? CupertinoIcons.exclamationmark_circle
                      : CupertinoIcons.checkmark_circle,
                  size: 14,
                  color: statusColor,
                ),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(
                    status,
                    key: const ValueKey('journal-draft-status'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: statusColor,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The white writing sheet.
class _Paper extends StatelessWidget {
  const _Paper({required this.builder});

  final LayoutWidgetBuilder builder;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
    decoration: BoxDecoration(
      color: context.xy.card,
      borderRadius: BorderRadius.circular(xyCardRadius),
    ),
    child: LayoutBuilder(builder: builder),
  );
}

/// A rounded photo with a small remove badge on its corner.
class _PhotoThumb extends StatelessWidget {
  const _PhotoThumb({
    required this.kind,
    required this.photo,
    required this.onRemove,
  });

  final JournalKind kind;
  final JournalPhoto photo;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) => Stack(
    clipBehavior: Clip.none,
    children: [
      JournalPhotoView(kind: kind, photo: photo, size: 92),
      Positioned(
        top: -12,
        right: -12,
        child: IconButton(
          key: ValueKey('remove-journal-photo-${photo.id}'),
          tooltip: '移除照片',
          onPressed: onRemove,
          visualDensity: VisualDensity.compact,
          icon: DecoratedBox(
            decoration: BoxDecoration(
              color: context.xy.card,
              shape: BoxShape.circle,
            ),
            child: Icon(
              CupertinoIcons.xmark_circle_fill,
              size: 22,
              color: context.xy.faint,
            ),
          ),
        ),
      ),
    ],
  );
}

/// Bottom bar pinned above the keyboard, like Notes.
class _Toolbar extends StatelessWidget {
  const _Toolbar({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: context.xy.bar,
      border: Border(top: BorderSide(color: context.xy.line, width: 0.5)),
    ),
    // Reserve the home-indicator gap remaining after keyboard avoidance.
    child: Padding(
      padding: EdgeInsets.only(
        left: MediaQuery.paddingOf(context).left,
        right: MediaQuery.paddingOf(context).right,
        bottom: math.max(
          0,
          MediaQuery.viewPaddingOf(context).bottom -
              MediaQuery.viewInsetsOf(context).bottom,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: IconTheme.merge(
          data: IconThemeData(color: Theme.of(context).colorScheme.primary),
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: children,
          ),
        ),
      ),
    ),
  );
}

/// A soft accent strip above the writing sheet for AI state: working,
/// applied (with undo) or not yet enabled.
class _AiStatus extends StatelessWidget {
  const _AiStatus({
    required this.text,
    this.textKey,
    this.action,
    this.busy = false,
  });

  final String text;
  final Key? textKey;
  final Widget? action;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final dark = theme.brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      constraints: const BoxConstraints(minHeight: 44),
      decoration: BoxDecoration(
        color: primary.withValues(alpha: dark ? 0.18 : 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          if (busy)
            XyActivity(radius: 8, color: primary)
          else
            Icon(CupertinoIcons.sparkles, size: 16, color: primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              key: textKey,
              style: theme.textTheme.bodySmall?.copyWith(
                color: primary,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}

({bool compactAi, bool counterInContent}) _toolbarLayout(
  BuildContext context,
  double width,
  String label,
  int photos,
) {
  final scaler = MediaQuery.textScalerOf(context);
  final theme = Theme.of(context);
  final painter = TextPainter(
    text: TextSpan(text: '$photos/3', style: theme.textTheme.bodySmall),
    textDirection: Directionality.of(context),
    textScaler: scaler,
    locale: Localizations.maybeLocaleOf(context),
  )..layout();
  final counterWidth = painter.width;
  painter.text = TextSpan(
    text: label,
    style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
  );
  painter.layout();
  // Bar padding, three 48px tool targets, counter padding, pill margin,
  // pill padding, icon and gap. Measure labels at the user's actual scale.
  final required =
      12 + 3 * 48 + 2 + counterWidth + 8 + 24 + 17 + 8 + painter.width;
  painter.dispose();
  final available = width - MediaQuery.paddingOf(context).horizontal;
  return (
    compactAi: scaler.scale(17) > 17 * 1.6 || required > available,
    // Keep the scaled count beside photos if even the icon-only row cannot
    // fit. Editing controls stay pinned without taking another body line.
    counterInContent: 12 + 4 * 48 + 8 + 2 + counterWidth > available,
  );
}

class _AiPill extends StatelessWidget {
  const _AiPill({
    required this.label,
    required this.icon,
    required this.ready,
    required this.onPressed,
    required this.compact,
  });

  final String label;
  final IconData icon;
  final bool ready;
  final VoidCallback? onPressed;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final dark = theme.brightness == Brightness.dark;
    return Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: TextButton(
          key: const ValueKey('journal-ai-request'),
          onPressed: onPressed,
          style: TextButton.styleFrom(
            foregroundColor: ready ? primary : context.xy.muted,
            backgroundColor: ready
                ? primary.withValues(alpha: dark ? 0.2 : 0.1)
                : context.xy.fill,
            shape: const StadiumBorder(),
            textStyle: theme.textTheme.bodyLarge?.copyWith(
              fontWeight: FontWeight.w600,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            visualDensity: VisualDensity.standard,
          ),
          child: compact
              ? Icon(icon, size: 17, semanticLabel: label)
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 17),
                    const SizedBox(width: 8),
                    Text(label, maxLines: 1, softWrap: false),
                  ],
                ),
        ),
      ),
    );
  }
}

class _AiInvite extends StatelessWidget {
  const _AiInvite({required this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: SizedBox(
        width: double.infinity,
        child: TextButton.icon(
          key: const ValueKey('journal-ai-invite'),
          onPressed: onTap,
          style: TextButton.styleFrom(
            alignment: Alignment.centerLeft,
            foregroundColor: primary,
            minimumSize: const Size(0, 48),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          icon: const Icon(CupertinoIcons.wand_stars, size: 20),
          label: Text(
            '让星愿先写一版',
            style: theme.textTheme.bodyLarge?.copyWith(
              color: primary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}
