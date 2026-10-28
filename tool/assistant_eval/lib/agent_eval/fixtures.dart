import 'dart:convert';

import 'package:crypto/crypto.dart';

typedef Json = Map<String, Object?>;

const agentDriverFixtures = {
  'agent-c26-v2': 'agent_scenarios.json',
  'agent-c26-v3': 'agent_scenarios_v3.json',
};
const agentFixtureVersions = {'agent-c16-v1', 'agent-c26-v2', 'agent-c26-v3'};

Object? canonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: canonical(value[key])};
  }
  if (value is List) return value.map(canonical).toList();
  return value;
}

String digest(Object? value) =>
    sha256.convert(utf8.encode(jsonEncode(canonical(value)))).toString();

Json object(Object? value) {
  if (value is! Map<String, dynamic>) {
    throw const FormatException('Expected JSON object');
  }
  return value.cast<String, Object?>();
}

class AgentScenario {
  AgentScenario._(this.data);
  final Json data;
  String get id => data['id'] as String;
  String get fingerprint => digest(data);
  Json get expected => object(data['expected']);
  Json get grants => object(data['grants']);
  List<Json> get schedule => (data['schedule'] as List).map(object).toList();
}

List<AgentScenario> parseAgentScenarios(String source) {
  final root = object(jsonDecode(source));
  if (!agentFixtureVersions.contains(root['version'])) {
    throw const FormatException('Unknown fixture version');
  }
  final defaults = object(root['defaults']);
  final rows = (root['scenarios'] as List).map((raw) {
    final row = object(raw);
    final data = <String, Object?>{
      ...defaults,
      ...row,
      'fixture_version': root['version'],
      'expected': {...object(defaults['expected']), ...object(row['expected'])},
    };
    if (row['schedule_generator'] != null) {
      final generator = object(row['schedule_generator']);
      if (generator['count'] != 61 || generator['last_conflict'] != true) {
        throw const FormatException('Unsupported synthetic schedule generator');
      }
      final updated = root['version'] != 'agent-c16-v1';
      data['schedule'] = [
        for (var i = 0; i < 60; i++)
          {
            'id': 'synthetic-$i',
            'day': '2026-10-27',
            'start': updated ? i * 5 : 720 + i,
            'minutes': updated ? 5 : 1,
          },
        {
          'id': 'synthetic-hidden-conflict',
          'day': '2026-10-27',
          'start': 540,
          'minutes': 30,
        },
      ];
    }
    // JSON roundtrip isolates mutable input and nested defaults between cases.
    return AgentScenario._(object(jsonDecode(jsonEncode(data))));
  }).toList();
  final ids = rows.map((row) => row.id).toSet();
  if (rows.length != 20 ||
      ids.length != 20 ||
      !List.generate(
        20,
        (i) => 'S${(i + 1).toString().padLeft(2, '0')}',
      ).every(ids.contains)) {
    throw const FormatException('Exactly S01-S20 required');
  }
  return rows;
}
