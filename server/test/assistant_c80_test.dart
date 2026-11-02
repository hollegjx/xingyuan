import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:xingyuan_core/xingyuan_core.dart';
import 'package:xingyuan_server/src/agent_protocol.dart';
import 'package:xingyuan_server/src/agent_ledger.dart';
import 'package:xingyuan_server/src/agent_runner.dart';

import 'support/agent_fixtures.dart';

void main() {
  AgentRequest request({bool contextual = true, bool v1 = false}) =>
      parseAssistantAgentRequest({
        ...agentFixture(),
        'protocol': v1 ? agentProtocol : assistantAgentProtocol,
        'messages': [
          {
            'role': 'user',
            'content': jsonEncode({
              if (contextual) 'context_version': 1,
              'summary': 'SYNTHETIC_OLD_MEMORY',
              'messages': [
                {'role': 'user', 'text': 'Hello'},
              ],
            }),
          },
        ],
      });
  Map<String, dynamic> output({Object summary = 'SYNTHETIC_NEW_MEMORY'}) {
    final result = agentEnvelope(text: true);
    result['choices'][0]['message']['content'] = jsonEncode({
      'kind': 'text',
      'text': 'Hello back',
      'memory_summary': summary,
    });
    return result;
  }

  test(
    'opt-in v5 body keeps model configuration and installed v2/v1 baselines',
    () {
      final body = jsonDecode(agentModelBody(request()));
      final old = jsonDecode(agentModelBody(request(contextual: false)));
      final v1 = jsonDecode(agentModelBody(request(v1: true)));
      expect(
        body['messages'][0]['content'],
        contains('Maintain memory_summary'),
      );
      expect(
        body['messages'][0]['content'],
        contains('2026-10-21 to 2026-10-27 inclusive'),
      );
      expect(
        old['messages'][0]['content'],
        isNot(contains('Maintain memory_summary')),
      );
      expect(
        v1['messages'][0]['content'],
        isNot(contains('Maintain memory_summary')),
      );
      expect(
        old['messages'][0]['content'],
        contains('past-day reads require App confirmation'),
      );
      expect(body['tools'].length, 8);
      expect(v1['tools'].length, 5);
      for (final key in [
        'model',
        'reasoning_effort',
        'max_completion_tokens',
        'store',
        'parallel_tool_calls',
        'tool_choice',
      ]) {
        expect(body[key], old[key]);
        expect(body[key], v1[key]);
      }
    },
  );
  test(
    'memory response strictly bounded and forbidden for unnegotiated clients',
    () {
      final day = request().now.date;
      expect(
        AgentModelReply.parse(
          output(),
          day,
          extended: true,
          contextual: true,
        ).outcome.memorySummary,
        'SYNTHETIC_NEW_MEMORY',
      );
      expect(
        AgentModelReply.parse(output(), day, extended: true).outcome.code,
        'invalid_model_output',
      );
      expect(
        AgentModelReply.parse(output(), day, contextual: true).outcome.code,
        'invalid_model_output',
      );
      for (final invalid in [
        'x' * 1201,
        1,
        null,
        {'text': 'bad'},
      ]) {
        final raw = output();
        raw['choices'][0]['message']['content'] = jsonEncode({
          'kind': 'text',
          'text': 'hello',
          'memory_summary': invalid,
        });
        expect(
          AgentModelReply.parse(
            raw,
            day,
            extended: true,
            contextual: true,
          ).outcome.code,
          'invalid_model_output',
        );
      }
      expect(
        AgentModelReply.parse(
          agentEnvelope(text: true),
          day,
          extended: true,
          contextual: true,
        ).outcome.kind,
        'text',
      );
    },
  );
  test(
    'metered runner carries memory through existing ledger and response parser',
    () async {
      final dir = await Directory.systemTemp.createTemp('c80-synthetic-');
      final ledger = AgentLedger.open('${dir.path}/ledger.sqlite');
      addTearDown(() async {
        ledger.close();
        await dir.delete(recursive: true);
      });
      final r = request();
      var calls = 0;
      final runner = AgentRunner(
        ledger: ledger,
        transport: (body, r, remaining) async {
          calls++;
          return AgentModelReply.parse(
            output(),
            r.now.date,
            extended: r is AssistantAgentRequest,
            contextual: assistantContextEnabled(r),
          );
        },
      );
      final response = (await runner.turn('synthetic-device', r)).body;
      expect(calls, 1);
      final parsed = parseAssistantAgentResponse(
        response,
        request: r,
      ) as AssistantAgentResponse;
      expect(parsed.memorySummary, 'SYNTHETIC_NEW_MEMORY');
      expect(parsed.tokens, 120);
      expect(parsed.turn, 1);
    },
  );
}
