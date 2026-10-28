import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../../app/providers.dart';
import '../../../app/theme.dart';
import '../../../shared/presentation.dart';
import '../../../shared/ui/sparkle.dart';
import '../../records/presentation/day_record_preview.dart';
import '../domain/goal.dart';

String? _completedAt(Completion? completion) {
  if (completion == null || !completion.completed) return null;
  try {
    final local = tz.TZDateTime.from(
      completion.instant,
      tz.getLocation(completion.zone),
    );
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(local.hour)}:${two(local.minute)} 完成';
  } catch (_) {
    return null;
  }
}

class GoalTile extends ConsumerWidget {
  const GoalTile({
    required this.view,
    required this.onOpen,
    this.interactive = false,
    this.status,
    super.key,
  });

  final GoalDay view;
  final VoidCallback onOpen;
  final bool interactive;
  final String? status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final done = view.status == GoalDayStatus.completed;
    final busy = ref.watch(goalCommandsProvider).contains(view.goal.id);
    final canAct =
        interactive &&
        !view.goal.isArchived &&
        (done || view.status == GoalDayStatus.notRecorded);
    final theme = Theme.of(context);
    final xy = context.xy;
    final completedAt = done ? _completedAt(view.completion) : null;
    // "07:52 完成" already says it; skip the plain "已完成" label then.
    final statusText =
        status ??
        (interactive || completedAt != null
            ? null
            : dayStatusLabel(view.status));
    final small = theme.textTheme.bodySmall?.copyWith(color: xy.muted);
    return InkWell(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 6, 0, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (canAct)
              StarCheckButton(
                key: ValueKey('${done ? 'undo' : 'complete'}-${view.goal.id}'),
                lit: done,
                busy: busy,
                onPressed: () async {
                  try {
                    await ref
                        .read(goalCommandsProvider.notifier)
                        .setCompleted(view.goal.id, !done, view.day);
                  } catch (error) {
                    if (context.mounted) showSaveError(context, error);
                  }
                },
              )
            else
              SizedBox.square(
                dimension: 48,
                child: Center(
                  child: StarMark(
                    lit: done || view.status == GoalDayStatus.completedEarlier,
                    size: 24,
                    outline: xy.faint,
                    glow: false,
                  ),
                ),
              ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 12, left: 2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    AnimatedDefaultTextStyle(
                      duration: const Duration(milliseconds: 200),
                      style: theme.textTheme.bodyLarge!.copyWith(
                        color: done ? xy.muted : theme.colorScheme.onSurface,
                      ),
                      child: Text(view.title),
                    ),
                    const SizedBox(height: 2),
                    Wrap(
                      spacing: 8,
                      children: [
                        Text(
                          scheduleLabel(view.goal.kind, view.schedule),
                          style: small,
                        ),
                        if (completedAt != null)
                          Text(
                            completedAt,
                            style: small?.copyWith(color: xy.success),
                          ),
                      ],
                    ),
                    if (view.isOverdue)
                      Text(
                        '已逾期，仍可完成',
                        style: small?.copyWith(color: xy.warning),
                      ),
                    if (statusText != null) Text(statusText, style: small),
                    if (view.goal.isArchived) Text('已归档，只读', style: small),
                    DayRecordPreview(
                      goalId: view.goal.id,
                      day: view.day,
                      title: view.title,
                      editable: !view.goal.isArchived,
                      showEmpty: interactive && !view.goal.isArchived,
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: IconButton(
                key: ValueKey('detail-${view.goal.id}'),
                tooltip: '查看目标详情',
                onPressed: onOpen,
                color: xy.faint,
                icon: const Icon(CupertinoIcons.chevron_right, size: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
