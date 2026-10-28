import 'dart:convert';

import 'package:test/test.dart';
import 'package:xingyuan_server/src/agent_protocol.dart';
import 'package:xingyuan_server/src/prompts/agent_v2.dart' as v2;

import 'support/agent_fixtures.dart';

void main() {
  // Instruction contracts do not demonstrate live model quality.
  test('v3 preserves every v2 instruction and its immutable fingerprint', () {
    expect(agentPromptVersion, 'agent-v3');
    expect(agentSystemPrompt, startsWith(v2.agentSystemPrompt));
    expect(
      agentDigest({
        'version': v2.agentPromptVersion,
        'text': v2.agentSystemPrompt,
      }),
      'a171047709d68072e17db38df379d816ef35c865ea7a9ea47ce8af0306d07956',
    );
  });
  test('active body explicitly declares all five bounded capabilities', () {
    final body = jsonDecode(
      agentModelBody(AgentRequest.fromJson(agentFixture())),
    ) as Map;
    final text = body['messages'][0]['content'] as String;
    expect(
      text,
      contains(
        'read authorized preferences, query authorized schedules, compute free slots, validate plans and prepare reviewable drafts',
      ),
    );
    expect(text, contains('Never deny a provided capability'));
  });
  test('schedule or availability questions query before an answer', () {
    expect(
      agentSystemPrompt,
      contains('MUST call query_schedule before answering'),
    );
    expect(
      agentSystemPrompt,
      contains('existing arrangements or availability in a date/time range'),
    );
    expect(
      agentSystemPrompt,
      contains('Only not_authorized means the schedule grant is unavailable'),
    );
    expect(
      agentSystemPrompt,
      contains(
        'failed means the query failed, not that you lack the capability',
      ),
    );
  });
  test(
    'no slot offers a checked nearest alternative outside the empty window',
    () {
      expect(
        agentSystemPrompt,
        contains('Do not suggest moving within the same empty window'),
      );
      expect(
        agentSystemPrompt,
        contains('another time on the same day, then the next allowed day'),
      );
      expect(
        agentSystemPrompt,
        contains('query/check that alternative before a draft'),
      );
      expect(agentSystemPrompt, contains('ask one concise question'));
    },
  );
  test('query rule does not expand grants or override uncertainty and cap', () {
    expect(
      agentSystemPrompt,
      contains('Never expand grants or invent a reason from an empty result'),
    );
    expect(
      agentSystemPrompt,
      contains(
        'partial/truncated results cannot establish complete availability',
      ),
    );
    expect(
      agentSystemPrompt,
      contains('Respect the same daily cap and allowed dates'),
    );
    expect(
      agentSystemPrompt,
      contains('A scheduling request alone still uses find_free_slots'),
    );
  });
}
