import 'dart:convert';

import 'package:xingyuan_core/xingyuan_core.dart';

import '../domain/agent_planning.dart';
import 'assistant_service.dart';

abstract interface class AgentDataSource {
  /// Checks the captured identity/consent even when this category is disabled.
  Future<bool> authorize(String tool);
  Future<List<String>> preferences();
  Future<List<AgentScheduleItem>> schedule(CalendarDate from, CalendarDate to);
}

class AgentToolStop implements Exception {
  const AgentToolStop(this.code);
  final String code;
  @override
  String toString() => 'AgentToolStop($code)';
}

class AgentToolExecutor {
  AgentToolExecutor({required this.source, required this.today});
  final AgentDataSource source;
  final CalendarDate today;
  final _cache = <String, String>{};
  final _counts = <String, int>{};
  final _dailyCaps = <String, int>{};
  Map<String, int> get dailyCaps => Map.unmodifiable(_dailyCaps);

  Future<Map<String, dynamic>> execute(AgentToolCall incoming) async {
    final call = AgentToolCall.parse(incoming.toJson(), today);
    final allowed = await source.authorize(call.name);
    final key = call.signature;
    final count = _counts.update(key, (value) => value + 1, ifAbsent: () => 1);
    if (count > 2) throw const AgentToolStop('repeated_tool_call');
    // No cached private result is consulted when the sending grant is absent.
    if (!allowed) {
      final denied = agentResult('not_authorized', null);
      if (count == 1) _cache[key] = agentCanonical(denied);
      return count == 1
          ? denied
          : {
              'status': 'duplicate',
              'original_status': 'not_authorized',
              'result': denied,
            };
    }
    if (count == 2) {
      final cached = _cache[key];
      if (cached == null) throw const AgentToolStop('missing_tool_result');
      final result = jsonDecode(cached) as Map<String, dynamic>;
      return {
        'status': 'duplicate',
        'original_status': result['status'],
        'result': result,
      };
    }
    Map<String, dynamic> result;
    try {
      result = await _perform(call);
    } on AssistantFailure {
      rethrow;
    } on AgentToolStop {
      rethrow;
    } catch (_) {
      result = agentResult('failed', null);
    }
    if (!await source.authorize(call.name)) {
      throw const AgentToolStop('authorization_changed');
    }
    final validated = validateAgentResult(
      result,
      call.name,
      today,
      allowDuplicate: false,
    );
    _cache[key] = agentCanonical(validated);
    return jsonDecode(_cache[key]!) as Map<String, dynamic>;
  }

  /// Never consults the call cache: a submit is checked again against local data.
  Future<AgentPlanValidation> validateDraft(
    List<Map<String, dynamic>> items,
  ) async {
    if (!await source.authorize('submit_plan_draft')) {
      throw const AgentToolStop('not_authorized');
    }
    final schedule = await source.schedule(today, today.addDays(14));
    if (!await source.authorize('submit_plan_draft')) {
      throw const AgentToolStop('authorization_changed');
    }
    return validateAgentPlan(
      items: items,
      schedule: schedule,
      today: today,
      dailyCaps: _dailyCaps,
    );
  }

  Future<Map<String, dynamic>> _perform(AgentToolCall call) async {
    final args = call.arguments;
    if (call.name == 'get_planning_preferences') {
      final rows = await source.preferences();
      return agentResult(rows.length > 10 ? 'truncated' : 'ok', {
        'preferences': [
          for (final text in rows.take(10)) {'text': text},
        ],
      });
    }
    if (call.name == 'validate_plan' || call.name == 'submit_plan_draft') {
      return (await validateDraft(
        (args['items'] as List).cast<Map<String, dynamic>>(),
      )).toJson();
    }
    final from = CalendarDate.parse(args['from'] as String);
    final to = CalendarDate.parse(args['to'] as String);
    final cap = args['daily_cap'] as int?;
    if (cap != null) {
      // A validated limit remains binding even if the following read fails.
      for (var date = from; !date.isAfter(to); date = date.addDays(1)) {
        final previous = _dailyCaps[date.key];
        _dailyCaps[date.key] = previous == null || cap < previous
            ? cap
            : previous;
      }
    }
    final rows = [...await source.schedule(from, to)]
      ..sort(compareAgentSchedule);
    if (call.name == 'query_schedule') {
      return agentResult(
        rows.length > 60
            ? 'truncated'
            : rows.any((row) => row.incomplete)
            ? 'partial'
            : 'ok',
        {'items': rows.take(60).map((row) => row.toJson()).toList()},
      );
    }
    final window = args['window'] as Map<String, dynamic>?;
    return findAgentFreeSlots(
      schedule: rows,
      from: from,
      to: to,
      minutes: args['minutes'] as int,
      startMinute: window?['start_minute'] as int? ?? 0,
      endMinute: window?['end_minute'] as int? ?? 1440,
      dailyCap: cap,
      dailyCaps: _dailyCaps,
    );
  }
}
