import 'dart:convert';

import 'package:test/test.dart';
import 'package:xingyuan_core/xingyuan_core.dart';
import 'package:xingyuan_server/src/agent_protocol.dart';
import 'package:xingyuan_server/src/prompts/agent_v5.dart' as v5;

void main() {
  test('continuous prompt supports chat, seven dates, receipts and explicit writes', () {
    final request = AssistantAgentRequest.fromJson({
      'protocol': assistantAgentProtocol,
      'request_id': 'synthetic',
      'run_id': null,
      'turn': 1,
      'now': {
        'date': '2026-11-02',
        'time': '12:00',
        'weekday': 1,
        'time_zone': 'Asia/Shanghai',
      },
      'messages': [
        {
          'role': 'user',
          'content': jsonEncode({
            'context_version': 1,
            'summary': null,
            'messages': [
              {'role': 'user', 'text': 'Hello'},
            ],
          }),
        },
      ],
    });
    final body = jsonDecode(agentModelBody(request));
    final prompt = body['messages'][0]['content'] as String;
    expect(v5.agentPromptVersion, 'agent-v5');
    expect(prompt, contains('No tool or planning workflow is required'));
    expect(prompt, contains('2026-10-27 to 2026-11-02 inclusive'));
    expect(prompt, contains('the App shows receipts'));
    expect(prompt, contains('Questions before the draft MUST be zero.'));
    expect(prompt, isNot(contains('may you ask one short question')));
    expect(prompt, contains('never saves a formal diary'));
    expect(prompt, contains('memory_summary'));
    expect(prompt, contains('No photos, attachments, locations'));
    expect(body['tools'].length, 8);
  });
}
