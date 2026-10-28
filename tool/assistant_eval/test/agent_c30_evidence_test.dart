import 'package:test/test.dart';
import 'package:xingyuan_assistant_eval/agent_eval/fixtures.dart';
import 'package:xingyuan_assistant_eval/agent_eval/report.dart';
import 'package:xingyuan_assistant_eval/agent_eval/trace.dart';

import 'agent_eval_test.dart' as f;

void main() {
  test(
    'bounded detail annotates score without altering original verdict',
    () async {
      final raw = f.traceData('S01', [
        {
          ...f.model(),
          'rejection_category': 'protocol_other',
          'rejection_detail': 'content_json',
        },
        f.event('stop', {
          'category': 'protocol_other',
          'layer': 'app_loop',
          'rejection_detail': 'content_json',
        }),
        f.terminal(status: 'stopped', reason: 'protocol'),
      ]);
      final report = await evaluateAgentRun([
        f.scenario('S01'),
      ], f.driver(traces: [raw]));
      final row = object((report['cases'] as List).single);
      expect(
        (row['rejection_observations'] as List)
            .map(object)
            .map((e) => e['detail']),
        ['content_json', 'content_json'],
      );
      expect(agentReportMarkdown(report), contains('content_json'));
      final legacy = f.traceData('S01', [
        {...f.model(), 'rejection_category': 'protocol_other'},
        f.event('stop', {'category': 'protocol_other', 'layer': 'app_loop'}),
        f.terminal(status: 'stopped', reason: 'protocol'),
      ]);
      final old = await evaluateAgentRun([
        f.scenario('S01'),
      ], f.driver(traces: [legacy]));
      expect(row['status'], (old['cases'] as List).single['status']);
      expect(report['metrics'], old['metrics']);
    },
  );
  test('arbitrary detail and detail without stop are rejected', () {
    for (final event in [
      {
        ...f.model(),
        'rejection_category': 'protocol_other',
        'rejection_detail': 'PRIVATE_C30_CANARY',
      },
      {...f.model(), 'rejection_detail': 'content_json'},
    ]) {
      expect(
        () => AgentTrace.fromJson(f.traceData('S01', [event, f.terminal()])),
        throwsFormatException,
      );
    }
  });
}
