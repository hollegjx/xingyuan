import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/theme.dart';
import '../../../shared/presentation.dart';
import '../domain/journal_entry.dart';
import '../domain/journal_suggestion.dart';

Future<bool> confirmDiscardDiaryEdits(
  BuildContext context,
  String prefix,
) async {
  const title = '放弃这次修改？';
  const message = '修改只保留在当前预览，离开或关闭应用后不会保留。原有日记不变。';
  final large =
      MediaQuery.textScalerOf(context).scale(17) * 4 >
      (MediaQuery.sizeOf(context).width - 32) / 2;
  if (!large) {
    return confirmAction(
      context,
      title: title,
      message: message,
      confirm: '放弃修改',
      cancel: '继续修改',
      destructive: true,
      confirmKey: ValueKey('$prefix-discard-confirm'),
      cancelKey: ValueKey('$prefix-discard-cancel'),
    );
  }
  FocusScope.of(context).unfocus();
  return await showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (context) => SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * .85,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Semantics(
                    header: true,
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(message),
                  const SizedBox(height: 20),
                  FilledButton(
                    key: ValueKey('$prefix-discard-cancel'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('继续修改'),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    key: ValueKey('$prefix-discard-confirm'),
                    style: TextButton.styleFrom(
                      foregroundColor: Theme.of(context).colorScheme.error,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('放弃修改'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ) ??
      false;
}

/// One reading surface for both diary entry points; no local writes here.
class DiaryPreviewBody extends StatefulWidget {
  const DiaryPreviewBody({
    required this.original,
    required this.suggestion,
    required this.append,
    required this.onChanged,
    required this.keyPrefix,
    this.enabled = true,
    this.editedText,
    super.key,
  });

  final String original;
  final String suggestion;
  final bool? append;
  final ValueChanged<bool> onChanged;
  final String keyPrefix;
  final bool enabled;
  final TextEditingController? editedText;

  @override
  State<DiaryPreviewBody> createState() => _DiaryPreviewBodyState();
}

class _DiaryPreviewBodyState extends State<DiaryPreviewBody> {
  bool _showOriginal = false;
  bool _editing = false;

  @override
  Widget build(BuildContext context) {
    final original = widget.original;
    final suggestion = widget.editedText?.text ?? widget.suggestion;
    final result = widget.append == true && original.isNotEmpty
        ? '$original\n\n$suggestion'
        : suggestion;
    final error = widget.editedText == null
        ? null
        : journalSuggestionError(
            suggestion,
            kind: JournalKind.diary,
            original: original,
            append: widget.append == true,
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.editedText != null)
          Align(
            alignment: Alignment.centerRight,
            child: IconButton(
              key: ValueKey('${widget.keyPrefix}-edit'),
              tooltip: _editing ? '完成修改' : '修改建议',
              onPressed: widget.enabled
                  ? () {
                      FocusScope.of(context).unfocus();
                      setState(() => _editing = !_editing);
                    }
                  : null,
              icon: Icon(
                _editing ? CupertinoIcons.check_mark : CupertinoIcons.pencil,
              ),
            ),
          ),
        if (_editing && widget.editedText != null) ...[
          if (widget.append == true && original.isNotEmpty) ...[
            SelectionArea(
              child: Text(
                original,
                key: ValueKey('${widget.keyPrefix}-protected-original'),
                style: Theme.of(context).textTheme.bodyLarge
                    ?.copyWith(height: 1.65),
              ),
            ),
            const SizedBox(height: 16),
          ],
          TextField(
            key: ValueKey('${widget.keyPrefix}-edited-text'),
            controller: widget.editedText,
            enabled: widget.enabled,
            autofocus: true,
            minLines: 4,
            maxLines: null,
            maxLength: JournalKind.diary.maxLength,
            maxLengthEnforcement: MaxLengthEnforcement.none,
            keyboardType: TextInputType.multiline,
            textCapitalization: TextCapitalization.sentences,
            onTapOutside: (_) => FocusScope.of(context).unfocus(),
            style: Theme.of(context).textTheme.bodyLarge
                ?.copyWith(height: 1.65),
            decoration: const InputDecoration(labelText: '新正文', filled: false),
          ),
        ] else
          SelectionArea(
            child: Text(
              result,
              key: ValueKey('${widget.keyPrefix}-suggestion'),
              style: Theme.of(context).textTheme.bodyLarge
                  ?.copyWith(height: 1.65),
            ),
          ),
        if (suggestion != widget.suggestion)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '修改未保存，关闭应用后不保留',
              key: ValueKey('${widget.keyPrefix}-local-edit-status'),
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: context.xy.muted),
            ),
          ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              error,
              key: ValueKey('${widget.keyPrefix}-edit-error'),
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (original.isNotEmpty) ...[
          const SizedBox(height: 20),
          IgnorePointer(
            ignoring: !widget.enabled,
            child: XySegmented<bool?>(
              key: ValueKey('${widget.keyPrefix}-mode'),
              segments: const [(true, '追加'), (false, '替换')],
              selected: widget.append,
              onChanged: (value) {
                if (value != null && widget.enabled) widget.onChanged(value);
              },
            ),
          ),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, box) {
              final label = Text(_showOriginal ? '收起原文' : '查看原文');
              final icon = Icon(
                _showOriginal
                    ? CupertinoIcons.chevron_up
                    : CupertinoIcons.chevron_down,
                size: 16,
              );
              final stacked =
                  MediaQuery.textScalerOf(context).scale(17) * 4 + 24 >
                  box.maxWidth;
              return TextButton(
                key: ValueKey('${widget.keyPrefix}-original-toggle'),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                ),
                onPressed: widget.enabled
                    ? () => setState(() => _showOriginal = !_showOriginal)
                    : null,
                child: stacked
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [label, icon],
                      )
                    : Row(
                        children: [
                          icon,
                          const SizedBox(width: 8),
                          Flexible(child: label),
                        ],
                      ),
              );
            },
          ),
          if (_showOriginal)
            SelectionArea(
              child: Text(
                original,
                key: ValueKey('${widget.keyPrefix}-original'),
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(height: 1.55, color: context.xy.muted),
              ),
            ),
        ],
      ],
    );
  }
}
