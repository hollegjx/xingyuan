import 'dart:convert';

import 'package:xingyuan_core/xingyuan_core.dart';

import '../../../shared/local_date.dart';
import '../../goals/domain/goal.dart';
import '../../goals/domain/goal_timing.dart';
import 'agent_planning.dart';

class PreviewItem {
  PreviewItem({required this.id, required this.task, this.reminder = false}) {
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,128}$').hasMatch(id) ||
        (reminder && task.time == null)) {
      throw const FormatException('计划条目或提醒时间无效');
    }
  }

  final String id;
  final PlanTask task;
  final bool reminder;
  GoalTiming get timing => GoalTiming(
    startMinute: task.time == null ? null : parseMinute(task.time!),
    durationMinutes: task.minutes,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'habit': task.isHabit,
    'task': task.toJson(),
    'reminder': reminder,
  };
}

enum PreviewIssueKind { expired, tooFar, habitStart, sameTitle, timeOverlap }

class PreviewIssue {
  const PreviewIssue(this.itemId, this.kind, this.date, {this.existingGoalId});

  final String itemId;
  final PreviewIssueKind kind;
  final CalendarDate date;
  final int? existingGoalId;
  bool get blocksConfirmation => switch (kind) {
    PreviewIssueKind.expired ||
    PreviewIssueKind.tooFar ||
    PreviewIssueKind.habitStart => true,
    PreviewIssueKind.sameTitle || PreviewIssueKind.timeOverlap => false,
  };
}

class PlanPreview {
  PlanPreview(Iterable<PreviewItem> items) : items = List.unmodifiable(items) {
    if (this.items.map((item) => item.id).toSet().length != this.items.length) {
      throw const FormatException('计划条目标识重复');
    }
  }

  factory PlanPreview.fromProposal(PlanProposal proposal) => PlanPreview([
    for (var i = 0; i < proposal.tasks.length; i++)
      PreviewItem(id: 'task-$i', task: proposal.tasks[i]),
    for (var i = 0; i < proposal.habits.length; i++)
      PreviewItem(id: 'habit-$i', task: proposal.habits[i]),
  ]);

  factory PlanPreview.fromAgentItems(List<Map<String, dynamic>> items) =>
      PlanPreview([
        for (var i = 0; i < items.length; i++)
          PreviewItem(
            id: 'agent-$i',
            task: PlanTask.fromJson({
              'title': items[i]['title'],
              'date': items[i]['date'],
              'time': formatMinute(items[i]['start_minute'] as int),
              'minutes': items[i]['minutes'],
            }, habit: false),
          ),
      ]);

  List<Map<String, dynamic>> get agentItems => [
    for (final item in items)
      {
        'title': item.task.title,
        'date': item.task.date.key,
        'start_minute': item.timing.startMinute,
        'minutes': item.timing.durationMinutes,
      },
  ];

  void validateAgentForConfirmation(CalendarDate today) {
    if (items.any((item) => item.task.isHabit) ||
        validateAgentPlan(
          items: agentItems,
          schedule: const [],
          today: today,
        ).hasErrors) {
      throw const FormatException('Invalid agent draft');
    }
  }

  factory PlanPreview.decode(String source) {
    try {
      final value = decodeAssistantJson(source);
      if (value is! List || value.length > 45) throw const FormatException();
      return PlanPreview(
        value.map((row) {
          if (row is! Map<String, dynamic> ||
              row.length != 4 ||
              row['id'] is! String ||
              row['habit'] is! bool ||
              row['reminder'] is! bool ||
              !row.containsKey('task')) {
            throw const FormatException();
          }
          return PreviewItem(
            id: row['id'] as String,
            task: PlanTask.fromJson(row['task'], habit: row['habit'] as bool),
            reminder: row['reminder'] as bool,
          );
        }),
      );
    } on FormatException {
      throw const FormatException('无法读取计划预览');
    }
  }

  final List<PreviewItem> items;

  String encode() => jsonEncode(items.map((item) => item.toJson()).toList());

  PlanPreview replace(String id, PlanTask task) {
    _requireItem(id);
    return PlanPreview([
      for (final item in items)
        if (item.id == id)
          PreviewItem(
            id: id,
            task: task,
            reminder: item.reminder && task.time != null,
          )
        else
          item,
    ]);
  }

  PlanPreview remove(String id) {
    _requireItem(id);
    return PlanPreview(items.where((item) => item.id != id));
  }

  PlanPreview setReminder(String id, bool enabled) {
    _requireItem(id);
    return PlanPreview([
      for (final item in items)
        if (item.id == id)
          PreviewItem(id: id, task: item.task, reminder: enabled)
        else
          item,
    ]);
  }

  PlanPreview enableTimedReminders() => PlanPreview([
    for (final item in items)
      PreviewItem(
        id: item.id,
        task: item.task,
        reminder: item.task.time != null,
      ),
  ]);

  PlanPreview clearTimes() => PlanPreview([
    for (final item in items)
      PreviewItem(
        id: item.id,
        task: PlanTask.fromJson({
          ...item.task.toJson(),
          'time': null,
        }, habit: item.task.isHabit),
      ),
  ]);

  PlanProposal validateForConfirmation(CalendarDate today) =>
      PlanProposal.fromJson({
        'tasks': [
          for (final item in items)
            if (!item.task.isHabit) item.task.toJson(),
        ],
        'habits': [
          for (final item in items)
            if (item.task.isHabit) item.task.toJson(),
        ],
      }, today: today);

  List<PreviewIssue> inspect({
    required CalendarDate today,
    required List<Goal> goals,
    bool agent = false,
  }) {
    final issues = <PreviewIssue>[];
    final last = today.addDays(agent ? 14 : 13);
    for (final item in items) {
      final task = item.task;
      if (task.date.isBefore(today)) {
        issues.add(PreviewIssue(item.id, PreviewIssueKind.expired, task.date));
      } else if (task.date.isAfter(last)) {
        issues.add(PreviewIssue(item.id, PreviewIssueKind.tooFar, task.date));
      } else if (task.isHabit && task.date != today) {
        issues.add(
          PreviewIssue(item.id, PreviewIssueKind.habitStart, task.date),
        );
      }
      for (var offset = 0; offset < 14; offset++) {
        final date = today.addDays(offset);
        if (!task.occursOn(date)) continue;
        final local = LocalDate.parse(date.key);
        for (final goal in goals) {
          if (goal.isArchived) continue;
          final view = goal.dayView(local, today: LocalDate.parse(today.key));
          if (!{
            GoalDayStatus.notRecorded,
            GoalDayStatus.completed,
            GoalDayStatus.future,
          }.contains(view.status)) {
            continue;
          }
          if (goal.kind == GoalKind.single &&
              view.schedule.plannedDay != local &&
              date != today) {
            continue;
          }
          if (view.title.trim() == task.title.trim()) {
            issues.add(
              PreviewIssue(
                item.id,
                PreviewIssueKind.sameTitle,
                date,
                existingGoalId: goal.id,
              ),
            );
          }
          if (item.timing.overlaps(view.schedule.timing)) {
            issues.add(
              PreviewIssue(
                item.id,
                PreviewIssueKind.timeOverlap,
                date,
                existingGoalId: goal.id,
              ),
            );
          }
        }
      }
    }
    return List.unmodifiable(issues);
  }

  void _requireItem(String id) {
    if (!items.any((item) => item.id == id)) {
      throw const FormatException('找不到该计划条目');
    }
  }
}
