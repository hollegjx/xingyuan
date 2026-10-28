import 'package:timezone/timezone.dart' as tz;

import '../../../shared/app_clock.dart';
import '../../../shared/local_date.dart';
import '../../goals/domain/goal.dart';
import 'reminder_time.dart';

class ReminderCandidate {
  const ReminderCandidate(this.goalId, this.day, this.at);

  final int goalId;
  final LocalDate day;
  final tz.TZDateTime at;
  String get key => '$goalId/${day.key}';
}

class ReminderPlan {
  const ReminderPlan(this.selected, this.firstUncovered);

  final List<ReminderCandidate> selected;
  final Map<int, ReminderCandidate> firstUncovered;
}

LocalDate? _nextDay(LocalDate day) =>
    day == LocalDate(9999, 12, 31) ? null : day.addDays(1);

ReminderPlan planReminders({
  required List<Goal> goals,
  required ClockReading now,
  required Set<String> ended,
  required int capacity,
}) {
  ReminderCandidate? next(Goal goal, LocalDate? start) {
    if (start == null || goal.isArchived || !goal.reminder.enabled) return null;
    if (goal.kind == GoalKind.single) {
      if (goal.singleCompletion != null) return null;
      final day = goal.scheduleOn(now.day).plannedDay!;
      if (day.isBefore(start) || ended.contains('${goal.id}/${day.key}')) {
        return null;
      }
      final at = futureReminderTime(
        day: day,
        minuteOfDay: goal.reminder.minuteOfDay,
        location: now.localTime.location,
        now: now.instant,
      );
      return at == null ? null : ReminderCandidate(goal.id, day, at);
    }
    for (LocalDate? day = start; day != null; day = _nextDay(day)) {
      if (!goal.isScheduledOn(day) ||
          goal.completionOn(day) != null ||
          ended.contains('${goal.id}/${day.key}')) {
        continue;
      }
      final at = futureReminderTime(
        day: day,
        minuteOfDay: goal.reminder.minuteOfDay,
        location: now.localTime.location,
        now: now.instant,
      );
      if (at != null) return ReminderCandidate(goal.id, day, at);
    }
    return null;
  }

  final byId = {for (final goal in goals) goal.id: goal};
  final frontier = <int, ReminderCandidate>{};
  for (final goal in goals) {
    final candidate = next(goal, now.day);
    if (candidate != null) frontier[goal.id] = candidate;
  }
  final selected = <ReminderCandidate>[];
  while (selected.length < capacity && frontier.isNotEmpty) {
    final candidates = frontier.values.toList()
      ..sort((a, b) {
        final time = a.at.compareTo(b.at);
        return time == 0 ? a.goalId.compareTo(b.goalId) : time;
      });
    final candidate = candidates.first;
    selected.add(candidate);
    frontier.remove(candidate.goalId);
    final following = next(byId[candidate.goalId]!, _nextDay(candidate.day));
    if (following != null) frontier[candidate.goalId] = following;
  }
  return ReminderPlan(List.unmodifiable(selected), Map.unmodifiable(frontier));
}
