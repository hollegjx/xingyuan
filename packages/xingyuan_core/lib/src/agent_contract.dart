import 'dart:convert';

import 'package:characters/characters.dart';

import 'calendar_date.dart';
import 'protocol.dart';

const agentProtocol = 'xingyuan.agent.v1';
const agentBodyLimit = 64000;
const agentOutputLimit = 1500;
const agentTokenLimit = 24000;
const agentCallLimit = 6;
const agentTools = [
  'get_planning_preferences',
  'query_schedule',
  'find_free_slots',
  'validate_plan',
  'submit_plan_draft',
];

Never _invalid() => throw const FormatException('Invalid agent protocol');

Map<String, dynamic> agentObject(Object? value, Set<String> keys) {
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

String agentCanonical(Object? value) => jsonEncode(_sorted(value));
Object? _sorted(Object? value) {
  if (value is Map<String, dynamic>) {
    final keys = value.keys.toList()..sort();
    return {for (final key in keys) key: _sorted(value[key])};
  }
  if (value is List) return value.map(_sorted).toList();
  return value;
}

class AgentRequest {
  AgentRequest._(
    this.requestId,
    this.runId,
    this.turn,
    this.now,
    this.messages,
    this.calls,
    this.results,
  );

  factory AgentRequest.fromJson(Object? value) {
    final map = agentObject(value, {
      'protocol',
      'request_id',
      'run_id',
      'turn',
      'now',
      'messages',
    });
    if (map['protocol'] != agentProtocol) _invalid();
    final requestId = _id(map['request_id']);
    final runId = map['run_id'] == null ? null : _id(map['run_id']);
    final turn = _int(map['turn'], 1, agentCallLimit + 1);
    if ((runId == null) != (turn == 1)) _invalid();
    final now = AssistantNow.fromJson(map['now']);
    now.date.addDays(14);
    final source = _list(map['messages'], 13, min: 1);
    if (source.length != 2 * turn - 1) _invalid();
    final user = agentObject(source.first, {'role', 'content'});
    if (user['role'] != 'user') _invalid();
    _text(user['content'], 24000);
    final messages = <Map<String, dynamic>>[user];
    final ids = <String>{};
    final calls = <AgentToolCall>[];
    final results = <Map<String, dynamic>>[];
    for (var i = 1; i < source.length; i += 2) {
      final assistant = agentObject(source[i], {
        'role',
        'content',
        'tool_calls',
      });
      if (assistant['role'] != 'assistant' || assistant['content'] != null) {
        _invalid();
      }
      final call = AgentToolCall.parse(
        _list(assistant['tool_calls'], 1, min: 1).single,
        now.date,
      );
      if (!ids.add(call.id) || call.id != agentCallId(runId!, (i + 1) ~/ 2)) {
        _invalid();
      }
      final tool = agentObject(source[i + 1], {
        'role',
        'tool_call_id',
        'content',
      });
      if (tool['role'] != 'tool' || tool['tool_call_id'] != call.id) _invalid();
      final result = validateAgentResult(
        decodeAssistantJson(_text(tool['content'], agentBodyLimit)),
        call.name,
        now.date,
      );
      calls.add(call);
      results.add(result);
      messages.add(call.message);
      messages.add({
        'role': 'tool',
        'tool_call_id': call.id,
        'content': agentCanonical(result),
      });
    }
    return AgentRequest._(
      requestId,
      runId,
      turn,
      now,
      List.unmodifiable(messages),
      List.unmodifiable(calls),
      List.unmodifiable(results),
    );
  }

  final String requestId;
  final String? runId;
  final int turn;
  final AssistantNow now;
  final List<Map<String, dynamic>> messages;
  final List<AgentToolCall> calls;
  final List<Map<String, dynamic>> results;

  Map<String, dynamic> toJson() => {
    'protocol': agentProtocol,
    'request_id': requestId,
    'run_id': runId,
    'turn': turn,
    'now': now.toJson(),
    'messages': messages,
  };
}

String agentCallId(String runId, int turn) => 'call_${runId}_$turn';

class AgentTurnResponse {
  AgentTurnResponse._(
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
  );

  factory AgentTurnResponse.fromJson(
    Object? value, {
    required AgentRequest request,
  }) {
    if (value is! Map<String, dynamic>) _invalid();
    final kind = value['kind'];
    if (!['text', 'question', 'tool_call', 'stopped'].contains(kind)) {
      _invalid();
    }
    final map = agentObject(value, {
      'protocol',
      'request_id',
      'run_id',
      'turn',
      'kind',
      'budget',
      if (kind == 'tool_call')
        'tool_call'
      else if (kind == 'stopped')
        'code'
      else
        'text',
    });
    final runId = _id(map['run_id']);
    if (map['protocol'] != agentProtocol ||
        map['request_id'] != request.requestId ||
        map['turn'] != request.turn ||
        (request.runId != null && runId != request.runId)) {
      _invalid();
    }
    final budget = agentObject(map['budget'], {
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
        ? AgentToolCall.parse(map['tool_call'], request.now.date)
        : null;
    if (call != null && call.id != agentCallId(runId, request.turn)) _invalid();
    return AgentTurnResponse._(
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
    );
  }
  final String requestId;
  final String runId;
  final int turn;
  final String kind;
  final String? text;
  final AgentToolCall? call;
  final String? code;
  final int tokens;
  final int remainingMs;
  final bool violation;
  Map<String, dynamic> toJson() => {
    'protocol': agentProtocol,
    'request_id': requestId,
    'run_id': runId,
    'turn': turn,
    'kind': kind,
    if (text != null) 'text': text,
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

class AgentToolCall {
  AgentToolCall._(this.id, this.name, this.arguments);
  factory AgentToolCall.parse(Object? value, CalendarDate today) {
    final map = agentObject(value, {'id', 'type', 'function'});
    if (map['type'] != 'function') _invalid();
    final function = agentObject(map['function'], {'name', 'arguments'});
    final name = _text(function['name'], 40);
    if (!agentTools.contains(name)) _invalid();
    final arguments = decodeAssistantJson(
      _text(function['arguments'], agentBodyLimit),
    );
    _validateArguments(name, arguments, today);
    return AgentToolCall._(
      _id(map['id']),
      name,
      Map<String, dynamic>.from(arguments as Map),
    );
  }
  final String id;
  final String name;
  final Map<String, dynamic> arguments;
  String get signature =>
      agentCanonical({'name': name, 'arguments': arguments});
  AgentToolCall scoped(String runId, int turn) =>
      AgentToolCall._(agentCallId(runId, turn), name, arguments);
  Map<String, dynamic> toJson() => {
    'id': id,
    'type': 'function',
    'function': {'name': name, 'arguments': agentCanonical(arguments)},
  };
  Map<String, dynamic> get message => {
    'role': 'assistant',
    'content': null,
    'tool_calls': [toJson()],
  };
}

CalendarDate _date(Object? value, CalendarDate today) {
  final date = CalendarDate.parse(_text(value, 10));
  if (date.isBefore(today) || date.isAfter(today.addDays(14))) _invalid();
  return date;
}

void _item(
  Object? value,
  CalendarDate today, {
  bool nullable = false,
  bool candidate = false,
}) {
  final item = agentObject(value, {'title', 'date', 'start_minute', 'minutes'});
  _text(item['title'], 60);
  // Candidates reach App business validation for D1 repair. Read results do not.
  if (candidate) {
    CalendarDate.parse(_text(item['date'], 10));
  } else {
    _date(item['date'], today);
  }
  final start = nullable && item['start_minute'] == null
      ? null
      : _int(item['start_minute'], 0, 1439);
  final minutes = nullable && item['minutes'] == null
      ? null
      : _int(item['minutes'], 5, 480);
  if (!candidate &&
      start != null &&
      minutes != null &&
      start + minutes > 1440) {
    _invalid();
  }
}

void _validateArguments(String name, Object? value, CalendarDate today) {
  final keys = switch (name) {
    'get_planning_preferences' => <String>{},
    'query_schedule' => {'from', 'to'},
    'find_free_slots' => {'from', 'to', 'minutes', 'window', 'daily_cap'},
    'validate_plan' => {'items'},
    'submit_plan_draft' => {'items', 'note'},
    _ => throw const FormatException('Invalid agent tool'),
  };
  final args = agentObject(value, keys);
  if (keys.contains('from')) {
    final from = _date(args['from'], today);
    if (_date(args['to'], today).isBefore(from)) _invalid();
  }
  if (name == 'find_free_slots') {
    _int(args['minutes'], 5, 480);
    if (args['daily_cap'] != null) _int(args['daily_cap'], 5, 1440);
    if (args['window'] != null) {
      final window = agentObject(args['window'], {
        'start_minute',
        'end_minute',
      });
      if (_int(window['start_minute'], 0, 1439) >=
          _int(window['end_minute'], 1, 1440)) {
        _invalid();
      }
    }
  }
  if (keys.contains('items')) {
    for (final item in _list(args['items'], 14, min: 1)) {
      _item(item, today, candidate: true);
    }
  }
  if (keys.contains('note')) _text(args['note'], 400, empty: true);
}

const _statuses = [
  'ok',
  'not_authorized',
  'failed',
  'truncated',
  'partial',
  'invalid',
];
const _issueCodes = [
  'conflict',
  'daily_cap',
  'date_range',
  'duplicate',
  'invalid_field',
  'unknown_schedule',
];

Map<String, dynamic> validateAgentResult(
  Object? value,
  String name,
  CalendarDate today, {
  bool allowDuplicate = true,
}) {
  if (value is Map && value['status'] == 'duplicate') {
    if (!allowDuplicate) _invalid();
    final map = agentObject(value, {'status', 'original_status', 'result'});
    final original = validateAgentResult(
      map['result'],
      name,
      today,
      allowDuplicate: false,
    );
    if (map['original_status'] != original['status']) _invalid();
    return map;
  }
  final map = agentObject(value, {'status', 'data'});
  final status = map['status'];
  if (!_statuses.contains(status)) _invalid();
  if (status == 'not_authorized' || status == 'failed') {
    if (map['data'] != null) _invalid();
    return map;
  }
  final validating = name == 'validate_plan' || name == 'submit_plan_draft';
  if (status == 'invalid' && !validating) _invalid();
  if (name == 'get_planning_preferences') {
    if (status == 'partial') _invalid();
    final data = agentObject(map['data'], {'preferences'});
    for (final item in _list(data['preferences'], 10)) {
      _text(agentObject(item, {'text'})['text'], 200);
    }
  } else if (name == 'query_schedule') {
    final data = agentObject(map['data'], {'items'});
    for (final item in _list(data['items'], 60)) {
      _item(item, today, nullable: true);
      if (status == 'ok' &&
          ((item as Map)['start_minute'] == null || item['minutes'] == null)) {
        _invalid();
      }
    }
  } else if (name == 'find_free_slots') {
    final data = agentObject(map['data'], {'slots', 'unknown_dates'});
    for (final item in _list(data['slots'], 20)) {
      final slot = agentObject(item, {'date', 'start_minute', 'minutes'});
      _date(slot['date'], today);
      if (_int(slot['start_minute'], 0, 1439) + _int(slot['minutes'], 5, 480) >
          1440) {
        _invalid();
      }
    }
    final unknown = _list(data['unknown_dates'], 15);
    for (final date in unknown) {
      _date(date, today);
    }
    if (status == 'ok' && unknown.isNotEmpty) _invalid();
  } else if (validating) {
    final data = agentObject(map['data'], {'issues'});
    final issues = _list(data['issues'], 20);
    for (final item in issues) {
      final issue = agentObject(item, {'index', 'code'});
      _int(issue['index'], 0, 13);
      if (!_issueCodes.contains(issue['code'])) _invalid();
    }
    if (status == 'ok' && issues.isNotEmpty) _invalid();
    if (status == 'partial' &&
        (issues.isEmpty ||
            issues.any((i) => i['code'] != 'unknown_schedule'))) {
      _invalid();
    }
    if (status == 'invalid' &&
        !issues.any((i) => i['code'] != 'unknown_schedule')) {
      _invalid();
    }
  } else {
    _invalid();
  }
  return map;
}
