import 'package:test/test.dart';
import 'package:xingyuan_assistant_eval/agent_eval/fixtures.dart';
import 'package:xingyuan_assistant_eval/agent_eval/report.dart';
import 'package:xingyuan_assistant_eval/agent_eval/trace.dart';

import 'agent_eval_test.dart' as fixture;

void main() {
  test(
    'bounded stop categories survive scoring and appear in JSON and Markdown',
    () async {
      final raw = fixture.traceData('S01', [
        {...fixture.model(), 'rejection_category': 'multiple_tool_calls'},
        fixture.event('stop', {
          'category': 'protocol_other',
          'layer': 'backend_response',
        }),
        fixture.terminal(status: 'stopped', reason: 'protocol'),
      ]);
      final report = await evaluateAgentRun([
        fixture.scenario('S01'),
      ], fixture.driver(traces: [raw]));
      final row = object((report['cases'] as List).single);
      expect(
        (row['rejection_observations'] as List)
            .map(object)
            .map((r) => r['category']),
        ['multiple_tool_calls', 'protocol_other'],
      );
      expect(agentReportMarkdown(report), contains('multiple_tool_calls'));
    },
  );
  test('arbitrary diagnostic strings and body fields cannot enter a trace', () {
    for (final e in [
      {...fixture.model(), 'rejection_category': 'PRIVATE_CANARY'},
      fixture.event('stop', {
        'category': 'refusal',
        'layer': 'model_request',
        'body': 'PRIVATE_CANARY',
      }),
    ]) {
      expect(
        () => AgentTrace.fromJson(
          fixture.traceData('S01', [e, fixture.terminal()]),
        ),
        throwsFormatException,
      );
    }
  });
}
