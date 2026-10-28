import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/theme.dart';
import '../../../shared/presentation.dart';
import '../../../shared/ui/sparkle.dart';
import '../../records/presentation/day_record_preview.dart';
import '../../reminders/notification_permissions.dart';
import '../../reminders/reminder_status_view.dart';
import '../../review/review_view.dart';
import '../domain/goal.dart';
import 'goal_form_page.dart';

class GoalDetailPage extends ConsumerWidget {
  const GoalDetailPage({required this.goalId, super.key});

  final int goalId;

  Future<void> _archive(BuildContext context, WidgetRef ref) async {
    final approved = await confirmAction(
      context,
      title: '归档目标？',
      message: '归档后停止打卡并取消提醒，历史仍保留。本版本不可恢复归档。',
      confirm: '归档',
      confirmKey: const ValueKey('confirm-archive'),
      destructive: true,
    );
    if (approved != true || !context.mounted) return;
    try {
      await ref.read(goalCommandsProvider.notifier).archive(goalId);
    } catch (error) {
      if (context.mounted) showSaveError(context, error);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final today =
        ref.watch(environmentProvider).value?.day ??
        ref.read(clockProvider).read().day;
    return Scaffold(
      appBar: pageAppBar(context, '目标详情'),
      body: SafeArea(
        child: ref
            .watch(goalsProvider)
            .when(
              loading: () => const PageScroll(
                children: [StatusPanel(message: '正在读取目标', loading: true)],
              ),
              error: (error, stack) => PageScroll(
                children: [
                  StatusPanel(
                    message: '无法读取目标',
                    retry: () => retryLocalRecords(ref),
                  ),
                ],
              ),
              data: (goals) {
                final goal = findGoal(goals, goalId);
                if (goal == null) {
                  return const PageScroll(
                    children: [StatusPanel(message: '找不到这个目标')],
                  );
                }
                final busy = ref.watch(goalCommandsProvider).contains(goalId);
                final schedule = goal.scheduleOn(today);
                final next = goal.scheduleOn(today.addDays(1));
                final xy = context.xy;
                final theme = Theme.of(context);
                final todayView = goal.dayView(today, today: today);
                final small = theme.textTheme.bodySmall?.copyWith(
                  color: xy.muted,
                );
                final chevron = Icon(
                  CupertinoIcons.chevron_right,
                  size: 16,
                  color: xy.faint,
                );
                final lit =
                    todayView.status == GoalDayStatus.completed ||
                    goal.singleCompletion != null;
                Widget info(IconData icon, String text, {TextStyle? style}) =>
                    ListTile(
                      leading: Icon(icon, size: 22, color: xy.muted),
                      title: Text(text, style: style),
                    );
                return PageScroll(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: StarMark(
                              lit: lit,
                              size: 28,
                              outline: xy.faint,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              goal.titleOn(today),
                              style: theme.textTheme.headlineMedium,
                            ),
                          ),
                        ],
                      ),
                    ),
                    XyGroup(
                      margin: const EdgeInsets.only(top: 20),
                      dividerIndent: 54,
                      children: [
                        info(
                          CupertinoIcons.calendar,
                          scheduleLabel(goal.kind, schedule),
                        ),
                        if (goal.kind == GoalKind.habit &&
                            (schedule.weekdays != next.weekdays ||
                                schedule.startMinute != next.startMinute ||
                                schedule.durationMinutes !=
                                    next.durationMinutes))
                          info(
                            CupertinoIcons.arrow_branch,
                            '${dateLabel(next.effectiveDay)} 起：${scheduleLabel(goal.kind, next)}',
                          ),
                        info(
                          lit
                              ? CupertinoIcons.checkmark_circle_fill
                              : CupertinoIcons.circle,
                          goal.isArchived
                              ? '已归档，只读'
                              : goal.singleCompletion != null
                              ? '已完成于 ${dateLabel(goal.singleCompletion!.day)}'
                              : dayStatusLabel(todayView.status),
                        ),
                        info(
                          CupertinoIcons.clock,
                          '创建于 ${dateLabel(goal.createdDay)}',
                          style: small?.copyWith(fontSize: 15),
                        ),
                        if (goal.archivedDay != null)
                          info(
                            CupertinoIcons.archivebox,
                            '归档于 ${dateLabel(goal.archivedDay!)}',
                            style: small?.copyWith(fontSize: 15),
                          ),
                      ],
                    ),
                    XyGroup(
                      header: '今天的记录',
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                          child: DayRecordPreview(
                            goalId: goalId,
                            day: today,
                            title: goal.titleOn(today),
                            editable: !goal.isArchived,
                            showEmpty: !goal.isArchived,
                          ),
                        ),
                      ],
                    ),
                    XyGroup(
                      header: '提醒',
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: ReminderStatus(goal: goal),
                        ),
                      ],
                    ),
                    XyGroup(
                      children: [
                        ListTile(
                          key: const ValueKey('goal-history'),
                          leading: const Icon(CupertinoIcons.time),
                          title: const Text('查看历史'),
                          trailing: chevron,
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (context) => Scaffold(
                                appBar: pageAppBar(context, '目标历史'),
                                body: SafeArea(
                                  child: ReviewView(goalId: goalId),
                                ),
                              ),
                            ),
                          ),
                        ),
                        if (!goal.isArchived)
                          ListTile(
                            key: const ValueKey('edit-goal'),
                            enabled: !busy,
                            leading: const Icon(CupertinoIcons.pencil),
                            title: const Text('编辑目标'),
                            trailing: chevron,
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute<int>(
                                builder: (_) => GoalFormPage(goal: goal),
                              ),
                            ),
                          ),
                      ],
                    ),
                    if (!goal.isArchived)
                      XyGroup(
                        children: [
                          ListTile(
                            key: const ValueKey('archive-goal'),
                            enabled: !busy,
                            onTap: () => _archive(context, ref),
                            title: Center(
                              child: Text(
                                '归档目标',
                                style: TextStyle(
                                  color: busy
                                      ? xy.faint
                                      : theme.colorScheme.error,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                  ],
                );
              },
            ),
      ),
    );
  }
}

class ReminderStatus extends ConsumerWidget {
  const ReminderStatus({required this.goal, super.key});

  final Goal goal;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final report = ref.watch(reminderReportProvider);
    if (report.hasError &&
        (goal.reminder.enabled || goal.reminder.needsReconcile)) {
      return StatusPanel(
        message: '提醒安排或取消未确认，记录已保存。',
        retry: () => ref.read(reminderReportProvider.notifier).refresh(),
      );
    }
    if (!goal.reminder.enabled) {
      return Text(
        goal.reminder.needsReconcile ? '提醒取消待确认' : '提醒已关闭',
        style: TextStyle(color: context.xy.muted),
      );
    }
    final minute = goal.reminder.minuteOfDay;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          TimeOfDay(hour: minute ~/ 60, minute: minute % 60).format(context),
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        ref
            .watch(notificationAccessProvider)
            .when(
              loading: () => const Text('正在读取通知权限，提醒未确认'),
              error: (error, stack) => const Text('无法读取通知权限，提醒未确认'),
              data: (access) => Text(switch (access) {
                NotificationAccess.off => '通知未授权，提醒未生效',
                NotificationAccess.alertsOff => '系统通知提示已关闭',
                NotificationAccess.allowed || NotificationAccess.quiet =>
                  access == NotificationAccess.quiet ? '系统已允许静默通知' : '系统已允许通知',
              }),
            ),
        const SizedBox(height: 8),
        if (goal.reminder.needsReconcile ||
            report.value?.goals[goal.id] == null)
          const Text('正在核对提醒安排')
        else
          ReminderCoverageText(
            coverage: report.value!.goals[goal.id]!,
            zone: report.value!.zone!,
          ),
        const SizedBox(height: 6),
        Text(
          '打开 App 时补排；超过已安排范围且未再打开，将不再提醒。',
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: context.xy.muted),
        ),
      ],
    );
  }
}
