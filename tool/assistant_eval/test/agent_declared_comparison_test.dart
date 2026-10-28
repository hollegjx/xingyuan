import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:xingyuan_assistant_eval/agent_eval/fixtures.dart';
import 'package:xingyuan_assistant_eval/agent_eval/report.dart';

void main() {
  final v2 = File('fixtures/agent_scenarios.json').readAsStringSync();
  final v3 = File('fixtures/agent_scenarios_v3.json').readAsStringSync();
  const coverage = ['S04', 'S07', 'S08', 'S09', 'S15', 'S16', 'S20'];
  Json product(String version) => {
    'lib/stable.dart': digest('stable'),
    'server/lib/src/prompts/agent_v2.dart': digest(version),
  };
  Json report(String version, String fixtures) => {
    'schema': 'agent-eval-report-v1',
    'scoring_policy': 'trajectory-v1',
    'metadata': {
      'product': digest(product(version)),
      'prompt': digest(version),
      'tool_schema': digest('schema-$version'),
      'test': digest('tests-$version'),
      'model': digest('model'),
      'parameters': digest('parameters'),
      'fixture_version': object(jsonDecode(fixtures))['version'],
      'seed': 20261028,
      'evidence_kind': 'live',
      'scoring_policy': 'trajectory-v1',
    },
    'cases': [
      for (final s in parseAgentScenarios(fixtures))
        {
          'case_id': s.id,
          'fixture_digest': s.fingerprint,
          'assessment': 'trajectory-v1',
          'status': 'pass',
          'validation': 'ok',
          for (final k in [
            'model_calls',
            'extra_queries',
            'forbidden_requests',
            'denied_requests',
            'illegal_executions',
            'illegal_outbound',
            'canary_leaks',
          ])
            k: 0,
        },
    ],
  };
  Json declaration(Json a, Json b, {bool changedFixture = false}) => {
    'schema': 'agent-treatment-declaration-v1',
    'before_report': digest(a),
    'after_report': digest(b),
    'variables': ['prompt', 'tool_schema'],
    'review_id': 'C29-synthetic-test',
    'before_sources': product('a'),
    'after_sources': product('b'),
    'product_changes': [
      {
        'path': 'server/lib/src/prompts/agent_v2.dart',
        'before': digest('a'),
        'after': digest('b'),
        'kind': 'prompt',
      },
    ],
    'before_scorer': digest('same-scorer'),
    'after_scorer': digest('same-scorer'),
    'before_fixtures': v2,
    'after_fixtures': changedFixture ? v3 : v2,
    'coverage_cases': changedFixture ? coverage : <String>[],
  };
  Json compare(Json a, Json b, Json d) =>
      Function.apply(compareAgentRuns, [a, b], {#treatment: d}) as Json;
  test('explicit treatment pairs matching cases without rewriting reports', () {
    final a = report('a', v2), b = report('b', v2), old = jsonEncode([a, b]);
    final c = compare(a, b, declaration(a, b));
    expect(c['paired'], 20);
    expect(c['comparison_scope'], 'declared_treatment_observational');
    expect(c['declared_variables'], ['prompt', 'tool_schema']);
    expect(jsonEncode([a, b]), old);
    expect(compareAgentRuns(a, b)['paired'], 0);
  });
  test(
    'v3 pairs only thirteen unchanged cases and lists seven coverage cases',
    () {
      final a = report('a', v2), b = report('b', v3);
      final c = compare(a, b, declaration(a, b, changedFixture: true));
      expect(c['paired'], 13);
      expect(c['coverage_cases'], coverage);
      for (final p in (c['pairs'] as List).map(object)) {
        expect(p['comparable'], !coverage.contains(p['case_id']));
        if (p['comparable'] == true) {
          expect(p['fixture_content_before'], p['fixture_content_after']);
        }
      }
    },
  );
  for (final field in ['model', 'parameters', 'seed', 'evidence_kind']) {
    test('$field is not a treatment variable', () {
      final a = report('a', v2), b = report('b', v2);
      object(b['metadata'])[field] = field == 'seed'
          ? 9
          : field == 'evidence_kind'
          ? 'app_offline'
          : digest('changed');
      expect(compare(a, b, declaration(a, b))['paired'], 0);
    });
  }
  for (final mutation in [
    'unreviewed_product',
    'invalid_review',
    'report_binding',
    'scorer',
    'variables',
    'fixture_binding',
    'duplicate_cases',
    'policy',
    'unknown_field',
    'raw_bytes',
    'defaults',
    'coverage',
    'missing_metadata',
  ]) {
    test('rejects $mutation without weakening defaults', () {
      final a = report('a', v2), b = report('b', v2);
      final d = declaration(a, b);
      switch (mutation) {
        case 'unreviewed_product':
          object(d['after_sources'])['lib/stable.dart'] = digest('changed');
          object(b['metadata'])['product'] = digest(d['after_sources']);
        case 'invalid_review':
          object((d['product_changes'] as List).single)['after'] = digest(
            'wrong',
          );
        case 'report_binding':
          d['after_report'] = digest('wrong');
        case 'scorer':
          d['after_scorer'] = digest('different');
        case 'variables':
          d['variables'] = ['prompt', 'model'];
        case 'fixture_binding':
          object((b['cases'] as List).first)['fixture_digest'] = digest(
            'wrong',
          );
        case 'duplicate_cases':
          (b['cases'] as List).add((b['cases'] as List).first);
        case 'policy':
          object((b['cases'] as List).first)['assessment'] = 'full-evidence-v1';
        case 'unknown_field':
          d['ignored'] = 'PRIVATE_C29_CANARY';
        case 'raw_bytes':
          d['after_fixtures'] = v2.replaceFirst(
            '    {"id": "S01"',
            '     {"id": "S01"',
          );
        case 'defaults':
          d['after_fixtures'] = v2.replaceFirst(
            '"minute": 480',
            '"minute": 481',
          );
        case 'coverage':
          d['coverage_cases'] = ['S01'];
        case 'missing_metadata':
          object(a['metadata']).remove('model');
          object(b['metadata']).remove('model');
          d['before_report'] = digest(a);
      }
      if (mutation != 'report_binding') d['after_report'] = digest(b);
      expect(() => compare(a, b, d), throwsFormatException);
    });
  }
  test('not-run and missing cases are never filled in by declarations', () {
    final a = report('a', v2), b = report('b', v2);
    object((b['cases'] as List).first)['status'] = 'not_run';
    (b['cases'] as List).removeLast();
    expect(compare(a, b, declaration(a, b))['paired'], 18);
  });
}
