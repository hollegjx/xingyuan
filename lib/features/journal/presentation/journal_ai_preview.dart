import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../../../shared/presentation.dart';
import '../ai/journal_ai_controller.dart';
import '../domain/journal_entry.dart';
import '../domain/journal_suggestion.dart';
import 'diary_preview_body.dart';
import 'journal_viewport.dart';

Future<void> showJournalAiPreview(
  BuildContext context,
  JournalAiController controller,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  isDismissible: false,
  enableDrag: false,
  builder: (_) =>
      JournalViewport(builder: (_) => _PreviewSheet(controller: controller)),
);

class _PreviewSheet extends StatefulWidget {
  const _PreviewSheet({required this.controller});
  final JournalAiController controller;
  @override
  State<_PreviewSheet> createState() => _PreviewSheetState();
}

class _PreviewSheetState extends State<_PreviewSheet> {
  bool? _append;
  late final String _initialSuggestion;
  late final TextEditingController _editedText;
  bool _closing = false;
  bool get _hasEdits =>
      widget.controller.editor.store.kind == JournalKind.diary &&
      _editedText.text != _initialSuggestion;

  @override
  void initState() {
    super.initState();
    _initialSuggestion = widget.controller.preview?.suggestion ?? '';
    _editedText = TextEditingController(text: _initialSuggestion)
      ..addListener(_textChanged);
  }

  void _textChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _editedText.dispose();
    super.dispose();
  }

  Future<void> _close() async {
    if (_closing || widget.controller.busy) return;
    setState(() => _closing = true);
    FocusScope.of(context).unfocus();
    final discard =
        !_hasEdits || await confirmDiscardDiaryEdits(context, 'journal-ai');
    if (!mounted) return;
    setState(() => _closing = false);
    if (discard) Navigator.pop(context);
  }

  Future<void> _use() async {
    final c = widget.controller;
    final preview = c.preview;
    if (_closing || c.busy || preview == null) return;
    final diary = c.editor.store.kind == JournalKind.diary;
    if (diary && preview.original.isNotEmpty && _append == null) return;
    FocusScope.of(context).unfocus();
    if (await c.use(
          append: diary && _append == true,
          editedText: diary ? _editedText.text : null,
        ) &&
        mounted) {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final c = widget.controller;
      final preview = c.preview;
      final theme = Theme.of(context);
      final xy = context.xy;
      final note = c.editor.store.kind == JournalKind.quickNote;
      final editError = note || preview == null
          ? null
          : journalSuggestionError(
              _editedText.text,
              kind: JournalKind.diary,
              original: preview.original,
              append: _append == true,
            );
      Widget keep() => TextButton(
        key: const ValueKey('journal-ai-keep'),
        style: note
            ? null
            : TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 8),
              ),
        onPressed: c.busy || _closing ? null : _close,
        child: Text(note ? '保留原文' : '暂不使用'),
      );
      Widget use() => FilledButton(
        key: const ValueKey('journal-ai-use'),
        style: note
            ? null
            : FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
        onPressed:
            preview == null ||
                c.busy ||
                _closing ||
                editError != null ||
                (!note && preview.original.isNotEmpty && _append == null)
            ? null
            : _use,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Opacity(
              opacity: c.busy ? 0 : 1,
              alwaysIncludeSemantics: true,
              child: Text(note ? '使用' : '放入草稿'),
            ),
            if (c.busy) XyActivity(radius: 8, color: theme.colorScheme.primary),
          ],
        ),
      );
      return PopScope(
        canPop: !c.busy && !_closing && !_hasEdits,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _close();
        },
        child: SafeArea(
          child: Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: SizedBox(
              height: MediaQuery.sizeOf(context).height * .85,
              child: LayoutBuilder(
                builder: (context, box) {
                  // At accessibility sizes two side-by-side buttons would break
                  // their labels a character per line and eat the screen: the
                  // actions then follow the text, stacked full width.
                  final scale = MediaQuery.textScalerOf(context).scale(17) / 17;
                  final stacked = 4 * 17 * scale + 40 > (box.maxWidth - 44) / 2;
                  final scroll = SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            if (note || !stacked) ...[
                              Container(
                                width: 34,
                                height: 34,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: theme.colorScheme.primary.withValues(
                                    alpha: 0.12,
                                  ),
                                ),
                                child: Icon(
                                  CupertinoIcons.sparkles,
                                  size: 18,
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                              const SizedBox(width: 12),
                            ],
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    note ? '润色建议' : '日记草稿',
                                    style: theme.textTheme.titleMedium
                                        ?.copyWith(fontWeight: FontWeight.w700),
                                  ),
                                  Text(
                                    note
                                        ? '由星愿生成，可修改'
                                        : stacked
                                        ? '由星愿整理\n尚未保存'
                                        : '由星愿整理 · 尚未保存',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: xy.muted,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        if (preview != null) ...[
                          const SizedBox(height: 18),
                          if (!note)
                            DiaryPreviewBody(
                              original: preview.original,
                              suggestion: preview.suggestion,
                              editedText: _editedText,
                              append: _append,
                              onChanged: (value) =>
                                  setState(() => _append = value),
                              enabled: !c.busy && !_closing,
                              keyPrefix: 'journal-ai',
                            ),
                          if (note) ...[
                            _Block(
                              label: '原文',
                              child: Text(
                                preview.original.isEmpty
                                    ? '空白草稿'
                                    : preview.original,
                                key: const ValueKey('journal-ai-original'),
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: xy.muted,
                                  height: 1.55,
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            _Block(
                              label: '建议',
                              highlight: true,
                              child: Text(
                                preview.suggestion,
                                key: const ValueKey('journal-ai-suggestion'),
                                style: theme.textTheme.bodyLarge?.copyWith(
                                  height: 1.65,
                                ),
                              ),
                            ),
                          ],
                          for (final tip in preview.tips)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(4, 14, 4, 0),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.only(top: 1),
                                    child: Icon(
                                      CupertinoIcons.lightbulb,
                                      size: 16,
                                      color: xy.star,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      tip,
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(color: xy.muted),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                        if (c.error != null) ...[
                          const SizedBox(height: 12),
                          NoticeBanner(
                            tone: NoticeTone.error,
                            message: c.error!,
                          ),
                        ],
                        if (stacked) ...[
                          const SizedBox(height: 24),
                          use(),
                          const SizedBox(height: 8),
                          keep(),
                        ],
                      ],
                    ),
                  );
                  if (stacked) return scroll;
                  return Column(
                    children: [
                      Expanded(child: scroll),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border(
                            top: BorderSide(color: xy.line, width: 0.5),
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                          child: Row(
                            children: [
                              Expanded(child: keep()),
                              const SizedBox(width: 12),
                              Expanded(child: use()),
                            ],
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// One labelled text block: grey for the original, outlined for the
/// suggestion.
class _Block extends StatelessWidget {
  const _Block({
    required this.label,
    required this.child,
    this.highlight = false,
  });

  final String label;
  final Widget child;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final xy = context.xy;
    final primary = theme.colorScheme.primary;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: highlight ? xy.card : xy.fill,
        borderRadius: BorderRadius.circular(xyCardRadius),
        border: highlight
            ? Border.all(color: primary.withValues(alpha: 0.35))
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: highlight ? primary : xy.muted,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          child,
        ],
      ),
    );
  }
}
