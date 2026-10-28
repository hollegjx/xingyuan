import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../shared/local_date.dart';
import '../../../shared/presentation.dart';
import '../domain/journal_entry.dart';
import '../journal_providers.dart';
import 'journal_editor_page.dart';
import 'journal_list_page.dart';
import 'journal_style.dart';

/// The day's 随手记 and 日记, under the goals on 今天 and 回顾.
class JournalDaySections extends ConsumerWidget {
  const JournalDaySections({
    required this.day,
    this.canCreate = true,
    super.key,
  });
  final LocalDate day;
  final bool canCreate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notes = ref.watch(quickNotesOnProvider(day));
    final diary = ref.watch(diaryOnProvider(day));
    void write(JournalKind kind) =>
        openJournalEditor(context, kind: kind, day: day);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionLabel(
          '随手记',
          count: switch (notes.asData?.value.length) {
            final int n when n > 0 => n,
            _ => null,
          },
        ),
        notes.when(
          loading: () => const StatusPanel(message: '正在读取随手记', loading: true),
          error: (_, _) => StatusPanel(
            message: '无法读取随手记',
            retry: () => ref.invalidate(quickNotesOnProvider(day)),
          ),
          data: (rows) => XyGroup(
            margin: EdgeInsets.zero,
            dividerIndent: journalPreviewDividerIndent(
              context,
              JournalKind.quickNote,
              rows,
            ),
            children: [
              for (final row in rows)
                JournalPreviewTile(kind: JournalKind.quickNote, snapshot: row),
              if (canCreate)
                _WriteRow(
                  key: ValueKey('write-note-${day.key}'),
                  icon: CupertinoIcons.square_pencil_fill,
                  tint: journalNoteTint(context),
                  label: rows.isEmpty ? '写一条随手记' : '再记一条',
                  onTap: () => write(JournalKind.quickNote),
                )
              else if (rows.isEmpty)
                const _EmptyRow('这一天没有随手记'),
            ],
          ),
        ),
        const SectionLabel('日记'),
        diary.when(
          loading: () => const StatusPanel(message: '正在读取日记', loading: true),
          error: (_, _) => StatusPanel(
            message: '无法读取日记',
            retry: () => ref.invalidate(diaryOnProvider(day)),
          ),
          data: (row) => XyGroup(
            margin: EdgeInsets.zero,
            children: [
              if (row != null)
                JournalPreviewTile(kind: JournalKind.diary, snapshot: row)
              else if (canCreate)
                _WriteRow(
                  key: ValueKey('write-diary-${day.key}'),
                  icon: CupertinoIcons.book_fill,
                  tint: Theme.of(context).colorScheme.primary,
                  label: '写下这一天的日记',
                  onTap: () => write(JournalKind.diary),
                )
              else
                const _EmptyRow('这一天没有日记'),
            ],
          ),
        ),
      ],
    );
  }
}

/// A quiet "write something" row with a tinted icon tile.
class _WriteRow extends StatelessWidget {
  const _WriteRow({
    required this.icon,
    required this.tint,
    required this.label,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final Color tint;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    onTap: onTap,
    leading: XyIconTile(icon, color: tint),
    title: Text(
      label,
      style: TextStyle(color: Theme.of(context).colorScheme.primary),
    ),
    trailing: Icon(
      CupertinoIcons.plus,
      size: 18,
      color: Theme.of(context).colorScheme.primary,
    ),
  );
}

class _EmptyRow extends StatelessWidget {
  const _EmptyRow(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    child: Text(
      text,
      style: Theme.of(context).textTheme.bodyMedium
          ?.copyWith(color: context.xy.muted),
    ),
  );
}
