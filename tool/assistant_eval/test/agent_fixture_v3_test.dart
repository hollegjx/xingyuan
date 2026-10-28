import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:xingyuan_assistant_eval/agent_eval/fixtures.dart';
import 'package:xingyuan_assistant_eval/agent_eval/live_gate.dart';
import 'package:xingyuan_assistant_eval/agent_eval/trace.dart';

void main() {
  Json raw(String name) =>
      object(jsonDecode(File('fixtures/$name').readAsStringSync()));
  final original = raw('agent_scenarios.json');
  final revised = raw('agent_scenarios_v3.json');
  Json row(Json root, String id) =>
      (root['scenarios'] as List).map(object).singleWhere((s) => s['id'] == id);

  test('R2 fixture bytes and every existing expectation stay immutable', () {
    expect(
      sha256
          .convert(File('fixtures/agent_scenarios.json').readAsBytesSync())
          .toString(),
      'e00196f478a1793aa9779762fea6d7aa82e12de2483e74f58d9a3e17a2c02a5c',
    );
    expect(revised['version'], 'agent-c26-v3');
    expect(revised['defaults'], original['defaults']);
    for (final item in (original['scenarios'] as List).map(object)) {
      expect(row(revised, item['id'] as String)['expected'], item['expected']);
    }
  });

  for (final id in ['S04', 'S07', 'S08', 'S09']) {
    test('$id has an explicit day task duration and query window', () {
      final input = row(revised, id)['input'] as String;
      expect(input, contains('今天'));
      expect(input, contains('整理'));
      expect(input, contains('30分钟'));
      expect(input, contains('9至11点'));
      expect(input, isNot(row(original, id)['input']));
    });
  }

  test(
    'S20 asks for actual schedule names so the large data path is reachable',
    () {
      final input = row(revised, 'S20')['input'] as String;
      expect(input, contains('查询'));
      expect(input, contains('目标名称'));
      expect(row(revised, 'S20')['payload'], row(original, 'S20')['payload']);
    },
  );

  test('v3 parser retains exactly twenty cases and legal S10 rows', () {
    final rows = parseAgentScenarios(jsonEncode(revised));
    expect(rows, hasLength(20));
    expect(
      rows.every((s) => s.data['fixture_version'] == 'agent-c26-v3'),
      true,
    );
    expect(
      rows
          .singleWhere((s) => s.id == 'S10')
          .schedule
          .every((r) => (r['minutes'] as int) >= 5),
      true,
    );
    expect(
      () => parseAgentScenarios(jsonEncode({...revised, 'version': 'unknown'})),
      throwsFormatException,
    );
  });

  test('v3 is allowed in metadata without loosening scoring policy', () {
    final metadata = <String, Object?>{
      for (final key in [
        'product',
        'test',
        'prompt',
        'tool_schema',
        'model',
        'parameters',
      ])
        key: digest(key),
      'fixture_version': 'agent-c26-v3',
      'seed': 20261028,
      'evidence_kind': 'app_offline',
      'scoring_policy': 'trajectory-v1',
    };
    expect(
      AgentRunMetadata.fromJson(metadata).data['fixture_version'],
      'agent-c26-v3',
    );
    expect(
      () => AgentRunMetadata.fromJson({
        ...metadata,
        'scoring_policy': 'anything',
      }),
      throwsFormatException,
    );
  });

  test('explicit v3 selection preserves mode gates and v2 default', () {
    expect(
      () => AgentDriverOptions.parse([
        '--scripted',
        '--output',
        '/tmp/unused',
        '--fixture-version',
        'agent-c26-v3',
      ]),
      returnsNormally,
    );
    expect(
      () => AgentDriverOptions.parse(['--scripted', '--output', '/tmp/unused']),
      returnsNormally,
    );
    for (final version in ['unknown', '../config', 'agent-c16-v1']) {
      expect(
        () => AgentDriverOptions.parse([
          '--scripted',
          '--output',
          '/tmp/unused',
          '--fixture-version',
          version,
        ]),
        throwsFormatException,
      );
    }
    expect(
      () => AgentDriverOptions.parse([
        '--live',
        '--output',
        '/tmp/unused',
        '--fixture-version',
        'agent-c26-v3',
      ]),
      throwsFormatException,
    );
    expect(
      AgentDriverOptions.parse(['--scripted', '--output', '/tmp/unused'])
          .fixtureVersion,
      'agent-c26-v2',
    );
    expect(
      AgentDriverOptions.parse([
        '--scripted',
        '--output',
        '/tmp/unused',
        '--fixture-version',
        'agent-c26-v3',
      ]).fixtureVersion,
      'agent-c26-v3',
    );
  });
}
