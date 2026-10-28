import 'dart:convert';

import 'package:characters/characters.dart';
import 'package:crypto/crypto.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

import 'prompts/agent_v3.dart';
import 'agent_rejection.dart';
export 'prompts/agent_v3.dart';
export 'agent_rejection.dart';

export 'package:xingyuan_core/xingyuan_core.dart'
    show
        AgentRequest,
        AgentToolCall,
        agentProtocol,
        agentBodyLimit,
        agentOutputLimit,
        agentTokenLimit,
        agentCallLimit,
        agentTools,
        agentObject,
        agentCanonical,
        agentCallId,
        validateAgentResult;

class AgentFailure implements Exception {
  const AgentFailure(this.status, this.code);
  final int status;
  final String code;
  @override
  String toString() => 'AgentFailure($status, $code)';
}

Never _invalid() => throw const FormatException('Invalid agent protocol');

String _text(Object? value, int max, {bool empty = false}) {
  if (value is! String ||
      (!empty && value.trim().isEmpty) ||
      value.characters.length > max) {
    _invalid();
  }
  return value;
}

List<dynamic> _list(Object? value, int max, {int min = 0}) {
  if (value is! List || value.length < min || value.length > max) _invalid();
  return value;
}

String agentDigest(Object? value) =>
    sha256.convert(utf8.encode(agentCanonical(value))).toString();

extension AgentToolFingerprint on AgentToolCall {
  String get fingerprint => agentDigest({'name': name, 'arguments': arguments});
}

Map<String, Object?> _objectSchema(Map<String, Object?> fields) => {
  'type': 'object',
  'properties': fields,
  'required': fields.keys.toList(),
  'additionalProperties': false,
};
Map<String, Object?> _integerSchema(int min, int max) => {
  'type': 'integer',
  'minimum': min,
  'maximum': max,
};
Map<String, Object?> _stringSchema(int max, {int min = 0}) => {
  'type': 'string',
  'minLength': min,
  'description':
      'At most $max user-visible grapheme characters; checked locally.',
};

List<Map<String, Object?>> agentToolSchemas() {
  final date = {'type': 'string', 'pattern': r'^\d{4}-\d{2}-\d{2}$'};
  final item = _objectSchema({
    'title': _stringSchema(60, min: 1),
    'date': date,
    'start_minute': _integerSchema(0, 1439),
    'minutes': _integerSchema(5, 480),
  });
  final items = {'type': 'array', 'minItems': 1, 'maxItems': 14, 'items': item};
  final schemas = [
    _objectSchema({}),
    _objectSchema({'from': date, 'to': date}),
    _objectSchema({
      'from': date,
      'to': date,
      'minutes': _integerSchema(5, 480),
      'window': {
        'anyOf': [
          _objectSchema({
            'start_minute': _integerSchema(0, 1439),
            'end_minute': _integerSchema(1, 1440),
          }),
          {'type': 'null'},
        ],
      },
      'daily_cap': {
        'anyOf': [
          _integerSchema(5, 1440),
          {'type': 'null'},
        ],
      },
    }),
    _objectSchema({'items': items}),
    _objectSchema({'items': items, 'note': _stringSchema(400)}),
  ];
  const descriptions = [
    'Read authorized planning preferences when relevant preferences are needed '
        'and not already supplied. Never reads journals; not for general knowledge.',
    'Read authorized schedule details for the specified inclusive dates. This is '
        'not needed before every free-slot query. Non-ok does not establish availability.',
    'Find candidate slots for one item; already accounts for the local schedule. '
        'Pass the known daily_cap and user window; a slot is not a reservation for '
        'several items. Partial means unknown conflicts remain.',
    'Check the whole candidate batch locally for conflicts, dates, duplicates '
        'and daily limits, including existing load. Repair invalid issues; '
        'partial remains uncertain. This does not save tasks.',
    'Produce a reviewable draft, not a save, after candidate validation. App '
        'validates again: ok/partial ends this run, invalid permits repair within '
        'budget. Do not ask for final confirmation before this tool; the user '
        'confirms later in the App. Never claim saved tasks.',
  ];
  return [
    for (var i = 0; i < agentTools.length; i++)
      {
        'type': 'function',
        'function': {
          'name': agentTools[i],
          'description': descriptions[i],
          'strict': true,
          'parameters': schemas[i],
        },
      },
  ];
}

String agentModelBody(AgentRequest request) => jsonEncode({
  'model': 'gpt-6-luna',
  'reasoning_effort': 'none',
  'max_completion_tokens': agentOutputLimit,
  'store': false,
  'parallel_tool_calls': false,
  'tool_choice': 'auto',
  'tools': agentToolSchemas(),
  'messages': [
    {
      'role': 'system',
      'content':
          '$agentSystemPrompt\nLocal clock: ${jsonEncode(request.now.toJson())}\n'
          'Allowed local dates (inclusive): ${request.now.date.key} to '
          '${request.now.date.addDays(14).key}.',
    },
    ...request.messages,
  ],
});

class AgentUsage {
  AgentUsage._(this.counts, this.valid);
  factory AgentUsage.parse(Object? value) {
    final counts = <String, int>{};
    if (value is Map) {
      for (final key in [
        'prompt_tokens',
        'completion_tokens',
        'total_tokens',
      ]) {
        if (value[key] case final int count
            when count >= 0 && count <= 1000000000) {
          counts[key] = count;
        }
      }
    }
    return AgentUsage._(
      Map.unmodifiable(counts),
      counts.length == 3 &&
          counts['prompt_tokens']! > 0 &&
          counts['prompt_tokens']! + counts['completion_tokens']! ==
              counts['total_tokens'],
    );
  }
  final Map<String, int> counts;
  final bool valid;
  int get reported => [
    counts['total_tokens'] ?? 0,
    (counts['prompt_tokens'] ?? 0) + (counts['completion_tokens'] ?? 0),
  ].reduce((a, b) => a > b ? a : b);
}

class AgentOutcome {
  const AgentOutcome._(this.kind, {this.text, this.call, this.code});
  const AgentOutcome.stop(String code) : this._('stopped', code: code);
  const AgentOutcome.tool(AgentToolCall call) : this._('tool_call', call: call);
  final String kind;
  final String? text;
  final AgentToolCall? call;
  final String? code;
  Map<String, Object?> toJson() => {
    'kind': kind,
    if (text != null) 'text': text,
    if (call != null) 'tool_call': call!.toJson(),
    if (code != null) 'code': code,
  };
}

String agentRejectionCategory(String? code) => switch (code) {
  'model_refusal' => 'refusal',
  'model_length' => 'length',
  'upstream_http' || 'model_connection' => 'upstream_error',
  'model_timeout' || 'run_deadline' => 'deadline',
  'model_request_too_large' || 'model_request_limit' => 'size',
  'token_budget' ||
  'run_token_limit' ||
  'run_calls' ||
  'run_call_limit' ||
  'invalid_usage' ||
  'usage_exceeds_reservation' => 'budget',
  'repeated_tool_call' => 'duplicate',
  _ => 'protocol_other',
};

class AgentModelReply {
  AgentModelReply(
    this.outcome,
    this.usage, {
    String? rejectionCategory,
    String? rejectionDetail,
  }) : rejectionCategory = outcome.kind == 'stopped'
           ? {'multiple_tool_calls', 'invalid_args'}.contains(rejectionCategory)
                 ? rejectionCategory
                 : agentRejectionCategory(outcome.code)
           : null,
       rejectionDetail = outcome.kind == 'stopped'
           ? agentRejectionDetails.contains(rejectionDetail)
                 ? rejectionDetail
                 : agentRejectionDetailForCode(outcome.code)
           : null;
  factory AgentModelReply.parse(Object? value, CalendarDate today) {
    final usage = AgentUsage.parse(value is Map ? value['usage'] : null);
    var category = 'protocol_other';
    var detail = 'envelope_shape';
    Object? rejectedCall;
    var parsingCall = false;
    try {
      if (value is! Map) _invalid();
      detail = 'choices_shape';
      final choice = _list(value['choices'], 1, min: 1).single;
      detail = 'message_shape';
      if (choice is! Map || choice['message'] is! Map) _invalid();
      final message = choice['message'] as Map;
      final finish = choice['finish_reason'];
      if (message['refusal'] != null || finish == 'content_filter') {
        return AgentModelReply(const AgentOutcome.stop('model_refusal'), usage);
      }
      if (finish == 'length') {
        return AgentModelReply(const AgentOutcome.stop('model_length'), usage);
      }
      detail = 'message_role';
      if (message['role'] != 'assistant') _invalid();
      if (finish == 'tool_calls') {
        detail = 'tool_calls_shape';
        if (message['tool_calls'] is List &&
            (message['tool_calls'] as List).length > 1) {
          category = 'multiple_tool_calls';
        }
        final rawCall = _list(message['tool_calls'], 1, min: 1).single;
        category = 'invalid_args';
        rejectedCall = rawCall;
        parsingCall = true;
        final call = AgentToolCall.parse(rawCall, today);
        return AgentModelReply(AgentOutcome.tool(call), usage);
      }
      detail = 'finish_reason';
      if (finish != 'stop') _invalid();
      detail = 'stop_tool_calls';
      if (message['tool_calls'] != null &&
          _list(message['tool_calls'], 0).isNotEmpty) {
        _invalid();
      }
      detail = 'content_shape';
      final content = _text(message['content'], 6000);
      detail = 'content_json';
      final decoded = decodeAssistantJson(content);
      detail = 'text_fields';
      final text = agentObject(decoded, {'kind', 'text'});
      detail = 'text_kind';
      if (text['kind'] != 'text' && text['kind'] != 'question') _invalid();
      detail = 'text_value';
      return AgentModelReply(
        AgentOutcome._(text['kind'] as String, text: _text(text['text'], 4000)),
        usage,
      );
    } on FormatException {
      return AgentModelReply(
        const AgentOutcome.stop('invalid_model_output'),
        usage,
        rejectionCategory: category,
        rejectionDetail: parsingCall
            ? agentRejectedToolDetail(rejectedCall)
            : detail,
      );
    }
  }
  final AgentOutcome outcome;
  final AgentUsage usage;
  // Diagnostic-only; never serializes upstream content or changes API outcomes.
  final String? rejectionCategory;
  final String? rejectionDetail;
}
