import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../shared/presentation.dart';
import 'reminder_coordinator.dart';

String reminderInstantLabel(DateTime at, String zone) {
  final local = tz.TZDateTime.from(at, tz.getLocation(zone));
  return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')} '
      '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
}

class ReminderCoverageText extends StatelessWidget {
  const ReminderCoverageText({
    required this.coverage,
    required this.zone,
    super.key,
  });

  final GoalReminderCoverage coverage;
  final String zone;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (coverage.status == 'disabled')
        const Text('提醒已关闭')
      else if (coverage.status == 'denied')
        const SizedBox.shrink()
      else if (coverage.status == 'noFuture')
        const Text('本次没有未来提醒，不补发已过时刻')
      else ...[
        Text('已预排 ${coverage.times.length} 次'),
        if (coverage.times.isNotEmpty) ...[
          Text('下次：${reminderInstantLabel(coverage.times.first, zone)}'),
          Text('已安排至：${reminderInstantLabel(coverage.times.last, zone)}'),
        ],
        if (coverage.firstUncovered case final at?)
          Text('尚未覆盖：${reminderInstantLabel(at, zone)} 起'),
      ],
    ],
  );
}

class ReminderOverview extends ConsumerWidget {
  const ReminderOverview({this.compact = false, super.key});

  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final report = ref.watch(reminderReportProvider);
    if (report.hasError) {
      return Padding(
        padding: EdgeInsets.only(bottom: compact ? 4 : 16),
        child: NoticeBanner(
          tone: NoticeTone.error,
          message: '提醒安排或取消未确认，记录已保存。',
          action: '重试',
          onAction: () => ref.read(reminderReportProvider.notifier).refresh(),
        ),
      );
    }
    final goals = ref.watch(goalsProvider).value;
    if (goals == null ||
        !goals.any(
          (goal) => goal.reminder.enabled || goal.reminder.needsReconcile,
        )) {
      return const SizedBox.shrink();
    }
    final data = report.value;
    if (data == null) {
      return compact ? const SizedBox.shrink() : const Text('正在核对系统提醒');
    }
    final unserved = data.goals.values
        .where((item) => item.firstUncovered != null && item.times.isEmpty)
        .length;
    final denied = data.goals.values.any((item) => item.status == 'denied');
    if (compact) {
      if (!denied && unserved == 0) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: NoticeBanner(
          tone: NoticeTone.warning,
          message: denied ? '通知未授权，已开启的提醒未生效' : '提醒容量不足：$unserved 个目标尚无已安排提醒',
        ),
      );
    }
    final count = data.goals.values.fold<int>(
      0,
      (total, item) => total + item.times.length,
    );
    final muted = Theme.of(context).textTheme.bodySmall
        ?.copyWith(color: context.xy.muted);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('系统已预排 $count 次提醒'),
                  if (unserved > 0)
                    Text(
                      '容量不足：$unserved 个目标尚未安排',
                      style: muted?.copyWith(color: context.xy.warning),
                    ),
                ],
              ),
            ),
            OutlinedButton(
              key: const ValueKey('reconcile-reminders'),
              onPressed: () =>
                  ref.read(reminderReportProvider.notifier).refresh(),
              child: const Text('核对'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text('关闭期间更换时区，提醒可能仍按原时区触发；重开后校正。', style: muted),
      ],
    );
  }
}
