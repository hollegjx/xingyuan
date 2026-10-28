import 'package:xingyuan_core/xingyuan_core.dart';

import '../../../shared/local_date.dart';
import '../../../data/local/local_goal_repository.dart';
import '../../goals/domain/goal.dart';
import '../domain/agent_planning.dart';
import 'agent_tool_executor.dart';
import 'assistant_service.dart';
import 'local_conversation_store.dart';

class LocalAgentSource implements AgentDataSource {
  LocalAgentSource(this.store, this.turn);
  final LocalConversationStore store;
  final PendingAssistantTurn turn;

  @override
  Future<bool> authorize(String tool) async {
    if (!agentTools.contains(tool)) throw const FormatException('Invalid tool');
    if (!await store.isCurrent(turn)) {
      throw AssistantFailure(
        turn.cancellation.isCancelled
            ? AssistantFailureKind.cancelled
            : AssistantFailureKind.discarded,
      );
    }
    return tool == 'get_planning_preferences'
        ? turn.settings.sendMemories
        : turn.settings.sendSchedule;
  }

  @override
  Future<List<String>> preferences() => store.db.transaction(() async {
    if (!await authorize('get_planning_preferences')) {
      throw const AgentToolStop('not_authorized');
    }
    final rows = await store.memories.forRequest();
    await authorize('get_planning_preferences');
    return [
      for (final row in rows ?? <AssistantMemory>[])
        if (row.text.trim().isNotEmpty) row.text,
    ];
  });

  @override
  Future<List<AgentScheduleItem>> schedule(
    CalendarDate from,
    CalendarDate to,
  ) => store.db.transaction(() async {
    if (!await authorize('query_schedule')) {
      throw const AgentToolStop('not_authorized');
    }
    final result = await loadAgentSchedule(store.goals, from, to);
    await authorize('query_schedule');
    return result;
  });
}

Future<List<AgentScheduleItem>> loadAgentSchedule(
  LocalGoalRepository repository,
  CalendarDate from,
  CalendarDate to,
) async {
  await repository.requireActiveIdentity();
  final today = repository.clock.read().day;
  final goals = await repository.loadGoals();
  final result = <AgentScheduleItem>[];
  for (var date = from; !date.isAfter(to); date = date.addDays(1)) {
    final day = LocalDate.parse(date.key);
    for (final goal in goals) {
      if (goal.isArchived || day.isBefore(goal.createdDay)) continue;
      final schedule = goal.scheduleOn(day);
      var overdue = false;
      if (goal.kind == GoalKind.single) {
        if (goal.singleCompletion?.day.isBefore(day) ?? false) continue;
        final planned = schedule.plannedDay;
        overdue =
            planned != null &&
            planned.isBefore(today) &&
            day == today &&
            goal.singleCompletion == null;
        if (planned != day && !overdue) continue;
      } else if (!goal.isScheduledOn(day)) {
        continue;
      }
      // A past planned time is not evidence of availability today.
      result.add(
        AgentScheduleItem(
          title: goal.titleOn(day),
          date: date,
          startMinute: overdue ? null : schedule.startMinute,
          minutes: schedule.durationMinutes,
        ),
      );
    }
  }
  await repository.requireActiveIdentity();
  return result..sort(compareAgentSchedule);
}
