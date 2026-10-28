import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../../app/providers.dart';
import '../../../app/theme.dart';
import '../../../shared/local_date.dart';
import '../../../shared/local_identity_boundary.dart';
import '../../../shared/presentation.dart';
import '../domain/journal_entry.dart';
import '../journal_providers.dart';
import 'journal_editor_page.dart';
import 'journal_style.dart';

String _timeLabel(JournalEntry entry) {
  final instant = DateTime.fromMicrosecondsSinceEpoch(
    entry.createdAt,
    isUtc: true,
  );
  DateTime time;
  try {
    time = tz.TZDateTime.from(instant, tz.getLocation(entry.zone));
  } catch (_) {
    time = instant;
  }
  return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
}

double _leadWidth(JournalKind kind) => kind == JournalKind.diary ? 40 : 44;

List<Text> _metadata(
  BuildContext context,
  JournalKind kind,
  JournalEntry entry,
) {
  final theme = Theme.of(context);
  final day = LocalDate.parse(entry.day);
  return [
    if (kind == JournalKind.diary) ...[
      Text(
        '${day.day}',
        softWrap: false,
        overflow: TextOverflow.visible,
        style: theme.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
          height: 1.1,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
      Text(
        weekdayLabels[day.weekday - 1],
        softWrap: false,
        overflow: TextOverflow.visible,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    ] else
      Text(
        _timeLabel(entry),
        softWrap: false,
        overflow: TextOverflow.visible,
        style: theme.textTheme.bodySmall?.copyWith(
          color: context.xy.muted,
          fontWeight: FontWeight.w600,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
  ];
}

bool _metadataFits(BuildContext context, List<Text> labels, double width) {
  for (final label in labels) {
    final painter = TextPainter(
      text: TextSpan(
        text: label.data,
        style: DefaultTextStyle.of(context).style.merge(label.style),
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      locale: Localizations.maybeLocaleOf(context),
    )..layout();
    final fits = painter.width <= width;
    painter.dispose();
    if (!fits) return false;
  }
  return true;
}

double journalPreviewDividerIndent(
  BuildContext context,
  JournalKind kind,
  List<JournalSnapshot> rows,
) =>
    rows.any(
      (row) => !_metadataFits(
        context,
        _metadata(context, kind, row.entry),
        _leadWidth(kind),
      ),
    )
    ? 16
    : 16 + _leadWidth(kind) + 10;

/// Keeps complete date/time fields above the summary when the lead is too narrow.
class JournalPreviewTile extends StatelessWidget {
  const JournalPreviewTile({
    required this.kind,
    required this.snapshot,
    super.key,
  });

  final JournalKind kind;
  final JournalSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final xy = context.xy;
    final entry = snapshot.entry;
    final text = entry.isSaved ? entry.content : entry.draftText ?? '';
    final photos = entry.isSaved ? snapshot.savedPhotos : snapshot.draftPhotos;
    final draft = !entry.isSaved || snapshot.hasDraftChanges;
    final day = LocalDate.parse(entry.day);
    final diary = kind == JournalKind.diary;
    final blank = text.trim().isEmpty;
    final labels = _metadata(context, kind, entry);
    final summary = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          blank
              ? photos.isEmpty
                    ? '空白草稿'
                    : '${photos.length} 张照片'
              : text.trim(),
          maxLines: diary ? 3 : 4,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyLarge?.copyWith(
            height: 1.45,
            color: blank ? xy.muted : null,
          ),
        ),
        if (draft || (photos.isNotEmpty && !blank)) ...[
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (draft) const JournalDraftBadge(),
              if (photos.isNotEmpty && !blank)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(CupertinoIcons.photo, size: 14, color: xy.muted),
                    const SizedBox(width: 3),
                    Text(
                      '${photos.length}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: xy.muted,
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ],
      ],
    );
    final chevron = Padding(
      padding: const EdgeInsets.only(left: 4, top: 3),
      child: Icon(CupertinoIcons.chevron_right, color: xy.faint, size: 15),
    );
    return InkWell(
      key: ValueKey('journal-entry-${entry.id}'),
      onTap: () =>
          openJournalEditor(context, kind: kind, day: day, id: entry.id),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 10, 12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = _leadWidth(kind);
            final inline =
                constraints.maxWidth > width + 10 + 19 &&
                _metadataFits(context, labels, width);
            if (!inline) {
              final metadata = Wrap(
                spacing: 12,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: labels,
              );
              // The navigation indicator must not take width from a full field.
              final sharesChevron = _metadataFits(
                context,
                labels,
                constraints.maxWidth - 19,
              );
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (sharesChevron)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: metadata),
                        chevron,
                      ],
                    )
                  else ...[
                    Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: chevron,
                    ),
                    metadata,
                  ],
                  const SizedBox(height: 8),
                  summary,
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: EdgeInsets.only(top: diary ? 0 : 2),
                  child: SizedBox(
                    width: width,
                    child: diary ? Column(children: labels) : labels.single,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(child: summary),
                chevron,
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Splits rows into inset groups: 随手记 by day, 日记 by month.
List<Widget> journalGroups(
  BuildContext context,
  JournalKind kind,
  List<JournalSnapshot> rows, {
  required LocalDate today,
}) {
  final groups = <String, List<JournalSnapshot>>{};
  for (final row in rows) {
    final key = kind == JournalKind.diary
        ? row.entry.day.substring(0, 7)
        : row.entry.day;
    groups.putIfAbsent(key, () => []).add(row);
  }
  String header(String key) {
    if (kind == JournalKind.diary) {
      final year = int.parse(key.substring(0, 4));
      final month = int.parse(key.substring(5, 7));
      return year == today.year ? '$month月' : '$year年$month月';
    }
    final day = LocalDate.parse(key);
    if (day == today) return '今天';
    if (day == today.addDays(-1)) return '昨天';
    return '${journalDayLabel(day, today: today)} '
        '${weekdayLabels[day.weekday - 1]}';
  }

  final keys = groups.keys.toList();
  return [
    for (var i = 0; i < keys.length; i++)
      XyGroup(
        header: header(keys[i]),
        margin: EdgeInsets.only(top: i == 0 ? 4 : 20),
        dividerIndent: journalPreviewDividerIndent(
          context,
          kind,
          groups[keys[i]]!,
        ),
        children: [
          for (final row in groups[keys[i]]!)
            JournalPreviewTile(kind: kind, snapshot: row),
        ],
      ),
  ];
}

class JournalListPage extends ConsumerStatefulWidget {
  const JournalListPage({required this.kind, super.key});
  final JournalKind kind;

  @override
  ConsumerState<JournalListPage> createState() => _JournalListPageState();
}

class _JournalListPageState extends ConsumerState<JournalListPage> {
  late final _repository = ref.read(journalRepositoryProvider.future);
  final _scroll = ScrollController();
  int _page = 0;
  static const _pageSize = 50;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _go(int page) {
    setState(() => _page = page);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  @override
  Widget build(BuildContext context) {
    final query = (
      kind: widget.kind,
      limit: _pageSize,
      offset: _page * _pageSize,
    );
    final entries = ref.watch(journalListProvider(query));
    return LocalIdentityBoundary(
      repository: _repository,
      child: Scaffold(
        appBar: pageAppBar(
          context,
          widget.kind == JournalKind.diary ? '日记本' : '随手记',
          actions: [
            IconButton(
              key: const ValueKey('journal-new'),
              tooltip: widget.kind == JournalKind.diary ? '写今天的日记' : '新建随手记',
              icon: const Icon(CupertinoIcons.square_pencil),
              onPressed: () => openJournalEditor(
                context,
                kind: widget.kind,
                day: ref.read(clockProvider).read().day,
              ),
            ),
          ],
        ),
        body: SafeArea(
          child: PageScroll(
            controller: _scroll,
            children: [
              ...entries.when(
                loading: () => [
                  const StatusPanel(message: '正在读取内容', loading: true),
                ],
                error: (_, _) => [
                  StatusPanel(
                    message: '无法读取本地内容，原有数据未被清空。',
                    retry: () => ref.invalidate(journalListProvider(query)),
                  ),
                ],
                data: (rows) => [
                  if (rows.isEmpty)
                    const StatusPanel(message: '还没有内容')
                  else
                    ...journalGroups(
                      context,
                      widget.kind,
                      rows,
                      today: ref.read(clockProvider).read().day,
                    ),
                ],
              ),
              if (_page > 0 || (entries.asData?.value.length ?? 0) == _pageSize)
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      key: const ValueKey('journal-previous-page'),
                      tooltip: '上一页',
                      onPressed: _page > 0 ? () => _go(_page - 1) : null,
                      icon: const Icon(CupertinoIcons.chevron_left),
                    ),
                    Text('${_page + 1}'),
                    IconButton(
                      key: const ValueKey('journal-next-page'),
                      tooltip: '下一页',
                      onPressed:
                          (entries.asData?.value.length ?? 0) == _pageSize
                          ? () => _go(_page + 1)
                          : null,
                      icon: const Icon(CupertinoIcons.chevron_right),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
