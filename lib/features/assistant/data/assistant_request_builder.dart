import 'dart:convert';

import 'package:characters/characters.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

import '../../../shared/local_date.dart';
import '../../goals/domain/goal.dart';
import 'assistant_service.dart';
import 'local_conversation_store.dart';

class AssistantRequestBuilder {
  AssistantRequestBuilder(this.store);
  final LocalConversationStore store;

  Future<TurnRequest> build(PendingAssistantTurn turn) => store.db.transaction(
    () async {
      final input = await store.input(turn);
      if (input.needsSummary) {
        throw const AssistantFailure(AssistantFailureKind.summary);
      }
      final now = store.goals.clock.read();
      final settings = turn.settings;
      final goals = settings.sendSchedule || settings.sendStats
          ? (await store.goals.loadGoals())
                .where((goal) => !goal.isArchived)
                .toList()
          : <Goal>[];
      final memories = await store.memories.forRequest();
      final schedule = settings.sendSchedule ? _schedule(goals, now.day) : null;
      final json = <String, Object?>{
        'protocol': assistantProtocol,
        'request_id': turn.requestId,
        'now': {
          'date': now.day.key,
          'weekday': now.day.weekday,
          'time': formatMinute(now.localTime.hour * 60 + now.localTime.minute),
          'time_zone': now.zone,
        },
        'summary': input.summary,
        'messages': input.messages,
        if (memories != null)
          'memories': memories.map((row) => row.toJson()).toList(),
        if (schedule != null) 'schedule': schedule.days,
        if (schedule?.truncated ?? false) 'schedule_truncated': true,
        if (settings.sendStats) 'stats': _stats(goals, now.day),
        'settings': {'auto_memory': settings.autoMemory},
        'diary_proposals': true,
      };
      if (utf8.encode(jsonEncode(json)).length > assistantBodyLimit) {
        throw const AssistantFailure(AssistantFailureKind.tooLarge);
      }
      return TurnRequest.fromJson(json);
    },
  );

  ({List<Map<String, Object?>> days, bool truncated}) _schedule(
    List<Goal> goals,
    LocalDate today,
  ) {
    final days = <Map<String, Object?>>[];
    for (var offset = 0; offset < 14; offset++) {
      final day = today.addDays(offset);
      final views = <GoalDay>[];
      for (final goal in goals) {
        final view = goal.dayView(day, today: today);
        if (!{
          GoalDayStatus.notRecorded,
          GoalDayStatus.completed,
          GoalDayStatus.future,
        }.contains(view.status)) {
          continue;
        }
        if (goal.kind == GoalKind.single &&
            view.schedule.plannedDay != day &&
            day != today) {
          continue;
        }
        views.add(view);
      }
      views.sort((a, b) {
        final timing = (a.schedule.startMinute ?? 1440).compareTo(
          b.schedule.startMinute ?? 1440,
        );
        return timing != 0 ? timing : a.goal.id.compareTo(b.goal.id);
      });
      if (views.isEmpty) continue;
      final group = <String, Object?>{
        'date': day.key,
        'items': [
          for (final view in views)
            {
              'title': view.title,
              'kind': view.goal.kind.name,
              'time': view.schedule.startMinute == null
                  ? null
                  : formatMinute(view.schedule.startMinute!),
              'minutes': view.schedule.durationMinutes,
              'done': view.status == GoalDayStatus.completed,
            },
        ],
      };
      if (jsonEncode([...days, group]).characters.length > 3000) {
        return (days: days, truncated: true);
      }
      days.add(group);
    }
    return (days: days, truncated: false);
  }

  List<Map<String, Object?>> _stats(List<Goal> goals, LocalDate today) => [
    for (final goal in goals)
      {
        'title': goal.titleOn(today),
        'kind': goal.kind.name,
        'scheduled_14d':
            [for (var ago = 0; ago < 14; ago++) today.addDays(-ago)]
                .where(
                  (day) => goal.kind == GoalKind.single
                      ? !day.isBefore(goal.createdDay) &&
                            goal.scheduleOn(day).plannedDay == day
                      : goal.isScheduledOn(day),
                )
                .length,
        'done_14d': [for (var ago = 0; ago < 14; ago++) today.addDays(-ago)]
            .where((day) => goal.completionOn(day) != null)
            .length,
      },
  ];
}
