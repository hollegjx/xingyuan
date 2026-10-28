import 'package:flutter/material.dart';

import '../../../shared/presentation.dart';
import '../domain/journal_entry.dart';

Future<bool> confirmDeleteJournal(
  BuildContext context,
  JournalKind kind,
) async {
  final record = kind == JournalKind.diary ? '日记' : '随手记';
  final title = '删除$record？';
  const message = '文字、照片和草稿将被删除，目标和打卡不会改变。';
  final media = MediaQuery.of(context);
  final style = Theme.of(context).textTheme.titleMedium;
  final painter = TextPainter(
    text: TextSpan(
      text: title,
      style: DefaultTextStyle.of(context).style.merge(style),
    ),
    textDirection: Directionality.of(context),
    textScaler: media.textScaler,
    locale: Localizations.maybeLocaleOf(context),
  )..layout();
  final titleWidth = painter.width;
  painter.dispose();
  final dialogBudget = ((media.size.width - media.padding.horizontal - 32) / 2)
      .clamp(0.0, 230.0);
  final large = titleWidth > dialogBudget;
  if (!large) {
    return confirmAction(
      context,
      title: title,
      message: message,
      confirm: '删除',
      confirmKey: const ValueKey('confirm-delete-journal'),
      destructive: true,
    );
  }
  FocusScope.of(context).unfocus();
  return await showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: false,
        builder: (context) => SafeArea(
          child: SizedBox(
            key: const ValueKey('journal-delete-confirmation-panel'),
            width: double.infinity,
            height: MediaQuery.sizeOf(context).height * .85,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final fits = titleWidth <= constraints.maxWidth;
                      return Semantics(
                        header: true,
                        child: Text(
                          fits ? title : '删除\n$record？',
                          semanticsLabel: title,
                          style: style,
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 12),
                  const Text(message),
                  const SizedBox(height: 20),
                  FilledButton(
                    key: const ValueKey('cancel-delete-journal'),
                    autofocus: true,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('取消'),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    key: const ValueKey('confirm-delete-journal'),
                    style: TextButton.styleFrom(
                      foregroundColor: Theme.of(context).colorScheme.error,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('删除'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ) ??
      false;
}
