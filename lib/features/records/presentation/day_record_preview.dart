import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../shared/local_date.dart';
import '../../companion/presentation/publication_status.dart';
import '../record_providers.dart';
import 'day_record_page.dart';
import 'record_photo_view.dart';

/// The note and photos under a goal card, or a quiet "写记录" entry.
class DayRecordPreview extends ConsumerWidget {
  const DayRecordPreview({
    required this.goalId,
    required this.day,
    required this.title,
    required this.editable,
    this.showEmpty = false,
    super.key,
  });

  final int goalId;
  final LocalDate day;
  final String title;
  final bool editable;
  final bool showEmpty;

  void _open(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => DayRecordPage(
        goalId: goalId,
        day: day,
        title: title,
        editable: editable,
      ),
    ),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final xy = context.xy;
    final theme = Theme.of(context);
    // Keep the last known records while a refresh is in flight.
    final records = ref.watch(dayRecordsProvider(day));
    if (records.hasError && !records.hasValue) {
      return Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: () => ref.invalidate(dayRecordsProvider(day)),
          icon: const Icon(CupertinoIcons.arrow_clockwise),
          label: const Text('记录读取失败，重试'),
        ),
      );
    }
    final list = records.value;
    if (list == null) return const SizedBox.shrink();
    final snapshot = list
        .where((item) => item.record.goalId == goalId)
        .firstOrNull;
    final saved =
        snapshot?.record.savedAt != null && snapshot?.record.deletedAt == null;
    final draft = snapshot?.hasDraftChanges ?? false;
    if (!showEmpty && !saved && !draft) return const SizedBox.shrink();
    final key = ValueKey('record-$goalId-${day.key}');
    if (!saved && !draft) {
      return Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          key: key,
          onPressed: () => _open(context),
          style: TextButton.styleFrom(
            padding: const EdgeInsets.only(right: 8),
            minimumSize: const Size(44, 36),
            tapTargetSize: MaterialTapTargetSize.padded,
            textStyle: theme.textTheme.bodyMedium,
          ),
          icon: const Icon(CupertinoIcons.square_pencil, size: 17),
          label: const Text('写记录'),
        ),
      );
    }
    final record = snapshot!.record;
    final shared = saved && record.syncState != 'local';
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Material(
        color: xy.cardSoft,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          key: key,
          borderRadius: BorderRadius.circular(10),
          onTap: () => _open(context),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 9, 12, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (draft)
                  Text(
                    '有未保存草稿',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: xy.warning,
                    ),
                  ),
                if (saved && record.content.isNotEmpty)
                  if (MediaQuery.textScalerOf(context).scale(1) > 1.3)
                    // Large text shows the whole note rather than cutting it.
                    Text(record.content, style: theme.textTheme.bodyMedium)
                  else
                    Text(
                      record.content,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium,
                    ),
                if (saved && snapshot.savedPhotos.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final photo in snapshot.savedPhotos)
                        RecordPhotoView(photo: photo),
                    ],
                  ),
                ],
                if (saved &&
                    !draft &&
                    record.content.isEmpty &&
                    snapshot.savedPhotos.isEmpty)
                  Text(
                    '查看记录',
                    style: theme.textTheme.bodySmall?.copyWith(color: xy.muted),
                  ),
                if (shared) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Icon(
                        record.syncState == 'confirmed'
                            ? CupertinoIcons.heart_fill
                            : CupertinoIcons.clock,
                        size: 14,
                        color: record.syncState == 'failed'
                            ? theme.colorScheme.error
                            : xy.partner,
                      ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          publicationStatus(record.syncState),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: xy.muted,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (record.syncState != 'confirmed')
                    PublicationQueueView(goalId: goalId, day: day.key),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
