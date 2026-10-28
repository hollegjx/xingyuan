import 'dart:convert';

import 'package:test/test.dart';
import 'package:xingyuan_server/src/agent_protocol.dart';
import 'package:xingyuan_server/src/prompts.dart';

import 'support/agent_fixtures.dart';

void main() {
  test('versioned Agent prompt is used only by the Agent body', () {
    expect(agentPromptVersion, 'agent-v3');
    final body = jsonDecode(
      agentModelBody(AgentRequest.fromJson(agentFixture())),
    ) as Map;
    expect(
      body['messages'][0]['content'],
      startsWith('$agentSystemPrompt\nLocal clock:'),
    );
    expect(body['tools'], agentToolSchemas());
    expect(body['tool_choice'], 'auto');
    expect(body['parallel_tool_calls'], false);
    expect(body['max_completion_tokens'], 1500);
    expect(
      agentSystemPrompt,
      contains('General knowledge needs no private tools'),
    );
    expect(agentSystemPrompt, contains('never prove the user is free'));
    expect(agentSystemPrompt, contains('Never invent existing arrangements'));
    expect(agentSystemPrompt, contains('Only locally validated candidates'));
    expect(assistantSystemPrompt, isNot(contains(agentSystemPrompt)));
  });
}
