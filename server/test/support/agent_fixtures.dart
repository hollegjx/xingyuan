import 'dart:convert';

import 'package:xingyuan_server/src/agent_protocol.dart';

Map<String, dynamic> agentFixture({String id = 'synthetic-run'}) => {
  'protocol': agentProtocol,
  'request_id': id,
  'run_id': null,
  'turn': 1,
  'now': {
    'date': '2026-10-27',
    'time': '19:00',
    'weekday': 2,
    'time_zone': 'Asia/Shanghai',
  },
  'messages': [
    {'role': 'user', 'content': 'synthetic-private-planning-request'},
  ],
};

Map<String, dynamic> agentCall({
  String id = 'upstream_1',
  String name = 'query_schedule',
  Map<String, dynamic>? arguments,
}) => {
  'id': id,
  'type': 'function',
  'function': {
    'name': name,
    'arguments': jsonEncode(
      arguments ?? {'from': '2026-10-27', 'to': '2026-10-27'},
    ),
  },
};

Map<String, dynamic> agentEnvelope({
  Map<String, dynamic>? call,
  bool text = false,
  String kind = 'text',
}) => {
  'choices': [
    <String, dynamic>{
      'finish_reason': text ? 'stop' : 'tool_calls',
      'message': {
        'role': 'assistant',
        'content': text
            ? jsonEncode({'kind': kind, 'text': 'synthetic-private-response'})
            : null,
        if (!text) 'tool_calls': [call ?? agentCall()],
      },
    },
  ],
  'usage': {'prompt_tokens': 100, 'completion_tokens': 20, 'total_tokens': 120},
};

Map<String, dynamic> agentOk() => {
  'status': 'ok',
  'data': {'items': <Object?>[]},
};

Map<String, dynamic> agentContinue(
  Map<String, dynamic> previous,
  Map<String, dynamic> response,
  Map<String, dynamic> result,
) => {
  ...previous,
  'run_id': response['run_id'],
  'turn': (previous['turn'] as int) + 1,
  'messages': [
    ...previous['messages'] as List,
    {
      'role': 'assistant',
      'content': null,
      'tool_calls': [response['tool_call']],
    },
    {
      'role': 'tool',
      'tool_call_id': response['tool_call']['id'],
      'content': jsonEncode(result),
    },
  ],
};

Map<String, dynamic> agentCopy(Object value) =>
    jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
