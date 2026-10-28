import 'dart:convert';

import 'package:test/test.dart';
import 'package:xingyuan_core/xingyuan_core.dart';
import 'package:xingyuan_server/src/agent_protocol.dart';

import 'support/agent_fixtures.dart';

void main() {
  final today = CalendarDate(2026, 10, 27);
  String? category(AgentModelReply r) =>
      (r as dynamic).rejectionCategory as String?;
  test('multiple calls remain rejected with only a safe category', () {
    final raw = agentEnvelope();
    raw['choices'][0]['message']['tool_calls'].add(agentCall(id: 'second'));
    final r = AgentModelReply.parse(raw, today);
    expect(r.outcome.code, 'invalid_model_output');
    expect(category(r), 'multiple_tool_calls');
    expect(
      jsonEncode(r.outcome.toJson()),
      isNot(contains('synthetic-private')),
    );
  });
  test(
    'invalid arguments keep the existing code and expose no argument text',
    () {
      final r = AgentModelReply.parse(
        agentEnvelope(
          call: agentCall(arguments: {'private': 'PRIVATE_C29_CANARY'}),
        ),
        today,
      );
      expect(r.outcome.code, 'invalid_model_output');
      expect(category(r), 'invalid_args');
    },
  );
  for (final entry in {
    'model_refusal': 'refusal',
    'model_length': 'length',
    'upstream_http': 'upstream_error',
    'model_connection': 'upstream_error',
    'model_timeout': 'deadline',
    'invalid_model_output': 'protocol_other',
    'PRIVATE_C29_CANARY': 'protocol_other',
  }.entries) {
    test('safe stop mapping ${entry.key}', () {
      expect(
        category(
          AgentModelReply(AgentOutcome.stop(entry.key), AgentUsage.parse(null)),
        ),
        entry.value,
      );
    });
  }
  test('valid text and tool outcomes have no rejection', () {
    expect(
      category(AgentModelReply.parse(agentEnvelope(text: true), today)),
      isNull,
    );
    expect(category(AgentModelReply.parse(agentEnvelope(), today)), isNull);
  });
  test('arbitrary category overrides never enter diagnostics', () {
    expect(
      category(
        AgentModelReply(
          const AgentOutcome.stop('invalid_model_output'),
          AgentUsage.parse(null),
          rejectionCategory: 'PRIVATE_C29_CANARY',
        ),
      ),
      'protocol_other',
    );
  });
}
