import '../../../shared/local_date.dart';
import 'goal_timing.dart';

enum GoalKind { habit, single }

enum GoalDayStatus {
  notCreated,
  notScheduled,
  notRecorded,
  completed,
  completedEarlier,
  archived,
  future,
}

class GoalDraft {
  const GoalDraft({
    required this.title,
    required this.kind,
    this.weekdays = 127,
    this.plannedDay,
    this.startMinute,
    this.durationMinutes,
    this.reminderEnabled = false,
    this.reminderMinute = 1200,
  });

  final String title;
  final GoalKind kind;
  final int weekdays;
  final LocalDate? plannedDay;
  final int? startMinute;
  final int? durationMinutes;
  final bool reminderEnabled;
  final int reminderMinute;
}

class TitleVersion {
  const TitleVersion(this.effectiveDay, this.title);

  final LocalDate effectiveDay;
  final String title;
}

class ScheduleVersion {
  const ScheduleVersion({
    required this.effectiveDay,
    required this.weekdays,
    this.plannedDay,
    this.startMinute,
    this.durationMinutes,
  });

  final LocalDate effectiveDay;
  final int weekdays;
  final LocalDate? plannedDay;
  final int? startMinute;
  final int? durationMinutes;

  GoalTiming get timing =>
      GoalTiming(startMinute: startMinute, durationMinutes: durationMinutes);

  bool includesWeekday(LocalDate day) =>
      (weekdays & (1 << (day.weekday - 1))) != 0;
}

class Completion {
  const Completion({
    required this.occurrenceKey,
    required this.completed,
    required this.day,
    required this.instant,
    required this.zone,
    required this.title,
    this.plannedDay,
  });

  final String occurrenceKey;
  final bool completed;
  final LocalDate day;
  final DateTime instant;
  final String zone;
  final String title;
  final LocalDate? plannedDay;
}

class ReminderState {
  const ReminderState({
    required this.enabled,
    required this.minuteOfDay,
    required this.revision,
    required this.needsReconcile,
    required this.status,
  });

  final bool enabled;
  final int minuteOfDay;
  final int revision;
  final bool needsReconcile;
  final String status;
}

class Goal {
  Goal({
    required this.id,
    required this.kind,
    required this.createdDay,
    required this.createdAt,
    required List<TitleVersion> titles,
    required List<ScheduleVersion> schedules,
    required List<Completion> completions,
    required this.reminder,
    this.archivedDay,
    this.archivedAt,
  }) : titles = List.unmodifiable(titles),
       schedules = List.unmodifiable(schedules),
       completions = List.unmodifiable(completions) {
    if (titles.isEmpty || schedules.isEmpty) {
      throw StateError('Goal is missing its title or schedule history');
    }
  }

  final int id;
  final GoalKind kind;
  final LocalDate createdDay;
  final DateTime createdAt;
  final LocalDate? archivedDay;
  final DateTime? archivedAt;
  final List<TitleVersion> titles;
  final List<ScheduleVersion> schedules;
  final List<Completion> completions;
  final ReminderState reminder;

  bool get isArchived => archivedDay != null;

  String titleOn(LocalDate day) {
    return titles
        .lastWhere(
          (entry) => !entry.effectiveDay.isAfter(day),
          orElse: () => titles.first,
        )
        .title;
  }

  ScheduleVersion scheduleOn(LocalDate day) {
    return schedules.lastWhere(
      (entry) => !entry.effectiveDay.isAfter(day),
      orElse: () => schedules.first,
    );
  }

  Completion? completionOn(LocalDate day) {
    for (final entry in completions) {
      if (entry.completed && entry.day == day) return entry;
    }
    return null;
  }

  Completion? get singleCompletion {
    if (kind != GoalKind.single) return null;
    for (final entry in completions) {
      if (entry.completed) return entry;
    }
    return null;
  }

  bool isScheduledOn(LocalDate day) {
    if (day.isBefore(createdDay)) return false;
    if (archivedDay case final archived? when day.isAfter(archived)) {
      return false;
    }
    final schedule = scheduleOn(day);
    if (kind == GoalKind.habit) return schedule.includesWeekday(day);
    final planned = schedule.plannedDay;
    if (planned == null) throw StateError('Single task has no planned day');
    return !day.isBefore(planned);
  }

  GoalDay dayView(LocalDate day, {required LocalDate today}) {
    final completion = completionOn(day);
    final schedule = scheduleOn(day);
    final String title;
    if (day.isBefore(today) && completion != null) {
      title = completion.title;
    } else {
      title = titleOn(day);
    }
    final GoalDayStatus status;
    if (completion != null) {
      status = GoalDayStatus.completed;
    } else if (day.isBefore(createdDay)) {
      status = GoalDayStatus.notCreated;
    } else if (archivedDay != null && day.isAfter(archivedDay!)) {
      status = GoalDayStatus.archived;
    } else if (singleCompletion case final completed?
        when completed.day.isBefore(day)) {
      status = GoalDayStatus.completedEarlier;
    } else if (!isScheduledOn(day)) {
      status = GoalDayStatus.notScheduled;
    } else if (day.isAfter(today)) {
      status = GoalDayStatus.future;
    } else {
      status = GoalDayStatus.notRecorded;
    }
    return GoalDay(
      goal: this,
      day: day,
      title: title,
      status: status,
      schedule: schedule,
      completion: completion,
    );
  }
}

class GoalDay {
  const GoalDay({
    required this.goal,
    required this.day,
    required this.title,
    required this.status,
    required this.schedule,
    this.completion,
  });

  final Goal goal;
  final LocalDate day;
  final String title;
  final GoalDayStatus status;
  final ScheduleVersion schedule;
  final Completion? completion;

  bool get isOverdue =>
      goal.kind == GoalKind.single &&
      schedule.plannedDay != null &&
      schedule.plannedDay!.isBefore(day) &&
      status == GoalDayStatus.notRecorded;
}

class TodayOverview {
  TodayOverview(List<Goal> goals, this.day) {
    final views = goals.map((goal) => goal.dayView(day, today: day)).toList();
    final order = {for (var i = 0; i < views.length; i++) views[i].goal.id: i};
    views.sort((a, b) {
      final byTime = (a.schedule.startMinute ?? 1440).compareTo(
        b.schedule.startMinute ?? 1440,
      );
      return byTime != 0
          ? byTime
          : order[a.goal.id]!.compareTo(order[b.goal.id]!);
    });
    pending = List.unmodifiable(
      views.where(
        (entry) =>
            !entry.goal.isArchived &&
            entry.goal.singleCompletion == null &&
            entry.status == GoalDayStatus.notRecorded,
      ),
    );
    completed = List.unmodifiable(
      views.where((entry) => entry.status == GoalDayStatus.completed),
    );
  }

  final LocalDate day;
  late final List<GoalDay> pending;
  late final List<GoalDay> completed;
}

class GoalRuleException implements Exception {
  const GoalRuleException(this.message);

  final String message;

  @override
  String toString() => message;
}
