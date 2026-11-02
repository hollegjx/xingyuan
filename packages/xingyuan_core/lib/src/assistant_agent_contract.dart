import 'dart:convert';

import 'package:characters/characters.dart';

import 'calendar_date.dart';
import 'agent_contract.dart';
import 'protocol.dart';

const assistantAgentProtocol = 'xingyuan.agent.v2';
const assistantAgentTools = [
  ...agentTools,
  'get_day_summary',
  'get_journal_text',
  'create_diary_draft',
];
const assistantMemorySummaryLimit = 1200;

/// An opt-in inside the existing user payload keeps installed v2/v1 compatible.
/// Old servers can ignore it and return ordinary text without a summary.
bool assistantContextEnabled(AgentRequest request) {
  if (request is! AssistantAgentRequest) return false;
  try {
    final content = jsonDecode(request.messages.first['content'] as String);
    return content is Map && content['context_version'] == 1;
  } on FormatException {
    return false;
  }
}

const assistantToolByteLimit = 12000;
const assistantDiaryDraftLimit = 10000;

Never _invalid() => throw const FormatException('Invalid agent protocol');

Map<String, dynamic> _object(Object? value, Set<String> keys) {
  if (value is! Map<String, dynamic> ||
      value.length != keys.length ||
      !keys.every(value.containsKey)) {
    _invalid();
  }
  return value;
}

String _text(Object? value, int max, {bool empty = false}) {
  if (value is! String ||
      (!empty && value.trim().isEmpty) ||
      value.characters.length > max) {
    _invalid();
  }
  return value;
}

String _id(Object? value) {
  final id = _text(value, 128);
  if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id)) _invalid();
  return id;
}

int _int(Object? value, int min, int max) {
  if (value is! int || value < min || value > max) _invalid();
  return value;
}

List<dynamic> _list(Object? value, int max, {int min = 0}) {
  if (value is! List || value.length < min || value.length > max) _invalid();
  return value;
}

String _canonical(Object? value) => jsonEncode(_sorted(value));
Object? _sorted(Object? value) {
  if (value is Map<String, dynamic>) {
    final keys = value.keys.toList()..sort();
    return {for (final key in keys) key: _sorted(value[key])};
  }
  if (value is List) return value.map(_sorted).toList();
  return value;
}

class AssistantAgentRequest implements AgentRequest {
  AssistantAgentRequest._(
    this.requestId,
    this.runId,
    this.turn,
    this.now,
    this.messages,
    this.calls,
    this.results,
  );

  factory AssistantAgentRequest.fromJson(Object? value) {
    final map = _object(value, {
      'protocol',
      'request_id',
      'run_id',
      'turn',
      'now',
      'messages',
    });
    if (map['protocol'] != assistantAgentProtocol) _invalid();
    final requestId = _id(map['request_id']);
    final runId = map['run_id'] == null ? null : _id(map['run_id']);
    final turn = _int(map['turn'], 1, agentCallLimit + 1);
    if ((runId == null) != (turn == 1)) _invalid();
    final now = AssistantNow.fromJson(map['now']);
    now.date.addDays(14);
    final source = _list(map['messages'], 13, min: 1);
    if (source.length != 2 * turn - 1) _invalid();
    final user = _object(source.first, {'role', 'content'});
    if (user['role'] != 'user') _invalid();
    _text(user['content'], 24000);
    final messages = <Map<String, dynamic>>[user];
    final ids = <String>{};
    final calls = <AssistantAgentCall>[];
    final results = <Map<String, dynamic>>[];
    for (var i = 1; i < source.length; i += 2) {
      final assistant = _object(source[i], {'role', 'content', 'tool_calls'});
      if (assistant['role'] != 'assistant' || assistant['content'] != null) {
        _invalid();
      }
      final call = AssistantAgentCall.parse(
        _list(assistant['tool_calls'], 1, min: 1).single,
        now.date,
      );
      if (!ids.add(call.id) || call.id != _callId(runId!, (i + 1) ~/ 2)) {
        _invalid();
      }
      final tool = _object(source[i + 1], {'role', 'tool_call_id', 'content'});
      if (tool['role'] != 'tool' || tool['tool_call_id'] != call.id) _invalid();
      final result = validateAssistantAgentResult(
        decodeAssistantJson(_text(tool['content'], agentBodyLimit)),
        call.name,
        now.date,
      );
      final effective = result['status'] == 'duplicate'
          ? result['result'] as Map
          : result;
      final data = effective['data'];
      if (!agentTools.contains(call.name) && data is Map) {
        if (data['day'] != call.arguments['day'] ||
            (call.name == 'get_journal_text' &&
                _canonical(data['kinds']) !=
                    _canonical(call.arguments['kinds']))) {
          _invalid();
        }
      }
      calls.add(call);
      results.add(result);
      messages.add(call.message);
      messages.add({
        'role': 'tool',
        'tool_call_id': call.id,
        'content': _canonical(result),
      });
    }
    return AssistantAgentRequest._(
      requestId,
      runId,
      turn,
      now,
      List.unmodifiable(messages),
      List.unmodifiable(calls),
      List.unmodifiable(results),
    );
  }

  @override
  final String requestId;
  @override
  final String? runId;
  @override
  final int turn;
  @override
  final AssistantNow now;
  @override
  final List<Map<String, dynamic>> messages;
  @override
  final List<AssistantAgentCall> calls;
  @override
  final List<Map<String, dynamic>> results;

  @override
  Map<String, dynamic> toJson() => {
    'protocol': assistantAgentProtocol,
    'request_id': requestId,
    'run_id': runId,
    'turn': turn,
    'now': now.toJson(),
    'messages': messages,
  };
}

String _callId(String runId, int turn) => 'call_${runId}_$turn';

class AssistantAgentResponse implements AgentTurnResponse {
  AssistantAgentResponse._(
    this.requestId,
    this.runId,
    this.turn,
    this.kind,
    this.text,
    this.call,
    this.code,
    this.tokens,
    this.remainingMs,
    this.violation,
    this.memorySummary,
  );

  factory AssistantAgentResponse.fromJson(
    Object? value, {
    required AgentRequest request,
  }) {
    if (value is! Map<String, dynamic>) _invalid();
    final kind = value['kind'];
    if (!['text', 'question', 'tool_call', 'stopped'].contains(kind)) {
      _invalid();
    }
    final map = _object(value, {
      'protocol',
      'request_id',
      'run_id',
      'turn',
      'kind',
      'budget',
      if (value.containsKey('memory_summary') &&
          assistantContextEnabled(request) &&
          (kind == 'text' || kind == 'question'))
        'memory_summary',
      if (kind == 'tool_call')
        'tool_call'
      else if (kind == 'stopped')
        'code'
      else
        'text',
    });
    final runId = _id(map['run_id']);
    if (map['protocol'] != assistantAgentProtocol ||
        map['request_id'] != request.requestId ||
        map['turn'] != request.turn ||
        (request.runId != null && runId != request.runId)) {
      _invalid();
    }
    final budget = _object(map['budget'], {
      'calls',
      'charged_tokens',
      'remaining_ms',
      'violation',
    });
    if (budget['calls'] != request.turn || budget['violation'] is! bool) {
      _invalid();
    }
    final tokens = _int(budget['charged_tokens'], 0, 2000000000);
    final remaining = _int(budget['remaining_ms'], 0, 60000);
    final violation = budget['violation'] as bool;
    if (kind != 'stopped' &&
        (violation ||
            tokens == 0 ||
            tokens > agentTokenLimit ||
            remaining == 0)) {
      _invalid();
    }
    final call = kind == 'tool_call'
        ? AssistantAgentCall.parse(map['tool_call'], request.now.date)
        : null;
    if (call != null && call.id != _callId(runId, request.turn)) _invalid();
    return AssistantAgentResponse._(
      request.requestId,
      runId,
      request.turn,
      kind as String,
      kind == 'text' || kind == 'question' ? _text(map['text'], 4000) : null,
      call,
      kind == 'stopped' ? _id(map['code']) : null,
      tokens,
      remaining,
      violation,
      map.containsKey('memory_summary')
          ? _text(
              map['memory_summary'],
              assistantMemorySummaryLimit,
              empty: true,
            )
          : null,
    );
  }
  @override
  final String requestId;
  @override
  final String runId;
  @override
  final int turn;
  @override
  final String kind;
  @override
  final String? text;
  @override
  final AssistantAgentCall? call;
  @override
  final String? code;
  @override
  final int tokens;
  @override
  final int remainingMs;
  @override
  final bool violation;
  final String? memorySummary;
  @override
  Map<String, dynamic> toJson() => {
    'protocol': assistantAgentProtocol,
    'request_id': requestId,
    'run_id': runId,
    'turn': turn,
    'kind': kind,
    if (text != null) 'text': text,
    if (memorySummary != null) 'memory_summary': memorySummary,
    if (call != null) 'tool_call': call!.toJson(),
    if (code != null) 'code': code,
    'budget': {
      'calls': turn,
      'charged_tokens': tokens,
      'remaining_ms': remainingMs,
      'violation': violation,
    },
  };
}

class AssistantAgentCall implements AgentToolCall {
  AssistantAgentCall._(this.id, this.name, this.arguments);
  factory AssistantAgentCall.parse(Object? value, CalendarDate today) {
    final map = _object(value, {'id', 'type', 'function'});
    if (map['type'] != 'function') _invalid();
    final function = _object(map['function'], {'name', 'arguments'});
    final name = _text(function['name'], 40);
    if (!assistantAgentTools.contains(name)) _invalid();
    final arguments = decodeAssistantJson(
      _text(function['arguments'], agentBodyLimit),
    );
    if (agentTools.contains(name)) {
      AgentToolCall.parse(value, today);
    } else {
      _validateArguments(name, arguments, today);
    }
    return AssistantAgentCall._(
      _id(map['id']),
      name,
      Map<String, dynamic>.from(arguments as Map),
    );
  }
  @override
  final String id;
  @override
  final String name;
  @override
  final Map<String, dynamic> arguments;
  @override
  String get signature => _canonical({'name': name, 'arguments': arguments});
  @override
  AssistantAgentCall scoped(String runId, int turn) =>
      AssistantAgentCall._(_callId(runId, turn), name, arguments);
  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    'type': 'function',
    'function': {'name': name, 'arguments': _canonical(arguments)},
  };
  @override
  Map<String, dynamic> get message => {
    'role': 'assistant',
    'content': null,
    'tool_calls': [toJson()],
  };
}

CalendarDate assistantRecordDay(Object? value, CalendarDate today) {
  final day = CalendarDate.parse(_text(value, 10));
  if (day.isBefore(today.addDays(-7)) || day.isAfter(today)) _invalid();
  return day;
}

List<String> _kinds(Object? value) {
  final values = _list(value, 2, min: 1);
  if (values.any((v) => v is! String)) _invalid();
  final kinds = values.cast<String>();
  if (kinds.toSet().length != kinds.length ||
      kinds.any((kind) => !['quickNote', 'diary'].contains(kind))) {
    _invalid();
  }
  return kinds;
}

void _validateArguments(String name, Object? value, CalendarDate today) {
  final args = _object(value, switch (name) {
    'get_day_summary' => {'day'},
    'get_journal_text' => {'day', 'kinds'},
    'create_diary_draft' => {'day', 'text'},
    _ => throw const FormatException('Invalid assistant tool'),
  });
  assistantRecordDay(args['day'], today);
  if (name == 'get_journal_text') _kinds(args['kinds']);
  if (name == 'create_diary_draft') {
    _text(args['text'], assistantDiaryDraftLimit);
  }
}

Map<String, dynamic> validateAssistantAgentResult(
  Object? value,
  String name,
  CalendarDate today, {
  bool allowDuplicate = true,
}) {
  if (agentTools.contains(name)) {
    return validateAgentResult(
      value,
      name,
      today,
      allowDuplicate: allowDuplicate,
    );
  }
  if (!assistantAgentTools.contains(name) ||
      utf8.encode(jsonEncode(value)).length > assistantToolByteLimit) {
    _invalid();
  }
  if (value is Map && value['status'] == 'duplicate') {
    if (!allowDuplicate) _invalid();
    final map = _object(value, {'status', 'original_status', 'result'});
    final original = validateAssistantAgentResult(
      map['result'],
      name,
      today,
      allowDuplicate: false,
    );
    if (map['original_status'] != original['status']) _invalid();
    return map;
  }
  final map = _object(value, {'status', 'data'});
  final status = map['status'];
  if (status == 'not_authorized' || status == 'failed') {
    if (map['data'] != null) _invalid();
    return map;
  }
  if (!['ok', 'truncated'].contains(status)) _invalid();
  if (name == 'create_diary_draft') {
    final data = _object(map['data'], {'day', 'pending_confirmation'});
    assistantRecordDay(data['day'], today);
    if (status != 'ok' || data['pending_confirmation'] != true) _invalid();
    return map;
  }
  final journal = name == 'get_journal_text';
  final data = _object(map['data'], {'day', 'items', if (journal) 'kinds'});
  assistantRecordDay(data['day'], today);
  final kinds = journal ? _kinds(data['kinds']) : const <String>[];
  final rows = _list(data['items'], journal ? 20 : 60);
  var diaries = 0;
  for (final row in rows) {
    final item = _object(
      row,
      journal
          ? {'kind', 'text'}
          : {
              'title',
              'planned_time',
              'planned_minutes',
              'completed',
              'completed_at',
              'text',
            },
    );
    _text(item['text'], journal ? 2000 : 1000, empty: true);
    if (journal) {
      if (!kinds.contains(item['kind'])) _invalid();
      if (item['kind'] == 'diary' && ++diaries > 1) _invalid();
    } else {
      _text(item['title'], 60);
      if (item['completed'] is! bool) _invalid();
      final time = item['planned_time'];
      final start = time == null ? null : parseMinute(_text(time, 5));
      final duration = item['planned_minutes'] == null
          ? null
          : _int(item['planned_minutes'], 5, 480);
      if (start != null && duration != null && start + duration > 1440) {
        _invalid();
      }
      final completedAt = item['completed_at'];
      if (item['completed'] != (completedAt != null)) _invalid();
      if (completedAt != null) {
        final text = _text(completedAt, 32);
        final instant = DateTime.tryParse(text);
        if (instant == null ||
            !instant.isUtc ||
            instant.toIso8601String() != text) {
          _invalid();
        }
      }
    }
  }
  return map;
}

/// Route selection stays explicit: v1 never accepts an extended result.
AgentRequest parseAssistantAgentRequest(Object? value) =>
    value is Map && value['protocol'] == assistantAgentProtocol
    ? AssistantAgentRequest.fromJson(value)
    : AgentRequest.fromJson(value);

AgentTurnResponse parseAssistantAgentResponse(
  Object? value, {
  required AgentRequest request,
}) => request is AssistantAgentRequest
    ? AssistantAgentResponse.fromJson(value, request: request)
    : AgentTurnResponse.fromJson(value, request: request);
