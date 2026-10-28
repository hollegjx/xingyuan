import 'dart:io';

import 'package:test/test.dart';
import 'package:xingyuan_assistant_eval/agent_eval/fixtures.dart';
import 'package:xingyuan_assistant_eval/agent_eval/scoring.dart';
import 'package:xingyuan_assistant_eval/agent_eval/trace.dart';

void main() {
  test(
    'headless persisted preview is not evidence of rendered confirmation',
    () {
      final scenario = parseAgentScenarios(
        File('fixtures/agent_scenarios.json').readAsStringSync(),
      )[2];
      final items = [
        {
          'day': '2026-10-27',
          'start': 540,
          'minutes': 30,
          'title': 'synthetic',
        },
      ];
      final trace = AgentTrace.fromJson({
        'case_id': scenario.id,
        'fixture_digest': scenario.fingerprint,
        'attempt': 1,
        'channels': traceChannels.where((c) => c != 'presentation').toList(),
        'protected_before': digest([]),
        'protected_after': digest([]),
        'events': [
          {
            'kind': 'validation',
            'ms': 0,
            'digest': digest(items),
            'status': 'ok',
            'phase': 'final',
            'data_revision': 'r1',
            'issues': [],
          },
          {'kind': 'preview', 'ms': 0, 'items': items},
          {
            'kind': 'terminal',
            'ms': 0,
            'status': 'draft',
            'reason': 'none',
            'text': '',
          },
        ],
      });
      final score = scoreAgentTrace(
        scenario,
        trace,
        evidenceKind: 'app_offline',
      ).json;
      expect(score['status'], 'incomplete');
      expect((score['checks'] as Map)['data_banners'], 'not_observed');
      expect((score['checks'] as Map)['final_validation_bound'], 'pass');
      expect((score['checks'] as Map)['expected_draft'], 'pass');
    },
  );
}
