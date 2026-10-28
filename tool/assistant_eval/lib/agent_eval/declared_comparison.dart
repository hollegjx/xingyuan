import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'fixtures.dart';

const c29CoverageCases = {'S04', 'S07', 'S08', 'S09', 'S15', 'S16', 'S20'};

Never _invalid() =>
    throw const FormatException('Invalid comparison declaration');
bool _hash(Object? v) => v is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(v);
String byteDigest(String s) => sha256.convert(utf8.encode(s)).toString();

class DeclaredComparison {
  DeclaredComparison(Json value, Json before, Json after) {
    final fields = {
      'schema',
      'before_report',
      'after_report',
      'review_id',
      'variables',
      'before_sources',
      'after_sources',
      'product_changes',
      'before_scorer',
      'after_scorer',
      'coverage_cases',
      'before_fixtures',
      'after_fixtures',
    };
    if (value.length != fields.length ||
        !value.keys.every(fields.contains) ||
        value['variables'] is! List ||
        value['product_changes'] is! List ||
        value['coverage_cases'] is! List ||
        !(value['variables'] as List).every((v) => v is String) ||
        !(value['coverage_cases'] as List).every((v) => v is String)) {
      _invalid();
    }
    if (value['schema'] != 'agent-treatment-declaration-v1' ||
        value['before_report'] != digest(before) ||
        value['after_report'] != digest(after) ||
        value['review_id'] is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{1,80}$')
            .hasMatch(value['review_id'] as String)) {
      _invalid();
    }
    reviewId = value['review_id'] as String;
    variables = (value['variables'] as List).cast<String>();
    if (variables.isEmpty ||
        variables.toSet().length != variables.length ||
        !variables.every({'prompt', 'tool_schema'}.contains)) {
      _invalid();
    }
    final a = object(before['metadata']), b = object(after['metadata']);
    for (final report in [before, after]) {
      final meta = object(report['metadata']);
      if (report['schema'] != 'agent-eval-report-v1' ||
          ![
            'product',
            'prompt',
            'tool_schema',
            'test',
            'model',
            'parameters',
          ].every((k) => _hash(meta[k])) ||
          meta['seed'] is! int ||
          !{
            'live',
            'app_offline',
            'scripted_trace',
          }.contains(meta['evidence_kind'])) {
        _invalid();
      }
      for (final row in (report['cases'] as List).map(object)) {
        if (!{
          'pass',
          'fail',
          'incomplete',
          'not_run',
        }.contains(row['status'])) {
          _invalid();
        }
        if (row['status'] != 'not_run' &&
            ![
              'model_calls',
              'extra_queries',
              'forbidden_requests',
              'denied_requests',
              'illegal_executions',
              'illegal_outbound',
              'canary_leaks',
            ].every((k) => row[k] is int && (row[k] as int) >= 0)) {
          _invalid();
        }
      }
    }
    final x = object(value['before_sources']),
        y = object(value['after_sources']);
    bool validPath(String p) =>
        !p.split('/').any((s) => s == '..' || s.isEmpty) &&
        p.endsWith('.dart') &&
        [
          'lib/',
          'server/lib/',
          'packages/xingyuan_core/lib/',
        ].any(p.startsWith);
    if (x.isEmpty ||
        y.isEmpty ||
        ![...x.keys, ...y.keys].every(validPath) ||
        ![...x.values, ...y.values].every(_hash) ||
        digest(x) != a['product'] ||
        digest(y) != b['product']) {
      _invalid();
    }
    final changed = {...x.keys, ...y.keys}.where((p) => x[p] != y[p]).toSet();
    final reviews = (value['product_changes'] as List).map(object).toList();
    if (reviews.length != changed.length ||
        reviews.map((r) => r['path']).toSet().length != reviews.length) {
      _invalid();
    }
    for (final r in reviews) {
      if (r.length != 4 ||
          !r.keys.every({'path', 'before', 'after', 'kind'}.contains)) {
        _invalid();
      }
      final p = r['path'], kind = r['kind'];
      if (p is! String ||
          !changed.contains(p) ||
          r['before'] != x[p] ||
          r['after'] != y[p] ||
          !{
            'prompt',
            'tool_schema',
            'prompt_tool_schema',
            'prompt_diagnostics',
            'prompt_tool_schema_diagnostics',
            'diagnostics',
          }.contains(kind)) {
        _invalid();
      }
      final promptFile = RegExp(
        r'^server/lib/src/prompts/agent_v[1-9][0-9]*\.dart$',
      ).hasMatch(p);
      final protocolFile = p == 'server/lib/src/agent_protocol.dart';
      if ((!promptFile && !protocolFile) || (promptFile && kind != 'prompt')) {
        _invalid();
      }
      if ((kind as String).contains('prompt') &&
          !variables.contains('prompt')) {
        _invalid();
      }
      if (kind.contains('tool_schema') && !variables.contains('tool_schema')) {
        _invalid();
      }
      if (kind.contains('diagnostics')) hasDiagnostics = true;
    }
    productChanges = reviews;
    if (!_hash(value['before_scorer']) ||
        value['before_scorer'] != value['after_scorer'] ||
        (a.containsKey('scorer') && a['scorer'] != value['before_scorer']) ||
        (b.containsKey('scorer') && b['scorer'] != value['after_scorer'])) {
      _invalid();
    }
    scorer = value['before_scorer'] as String;
    coverage = (value['coverage_cases'] as List).cast<String>().toSet();
    if (coverage.length != (value['coverage_cases'] as List).length) _invalid();
    final versionChange = a['fixture_version'] != b['fixture_version'];
    if (versionChange) {
      if (a['fixture_version'] != 'agent-c26-v2' ||
          b['fixture_version'] != 'agent-c26-v3' ||
          coverage.length != c29CoverageCases.length ||
          !coverage.containsAll(c29CoverageCases)) {
        _invalid();
      }
    } else if (coverage.isNotEmpty) {
      _invalid();
    }
    beforeFixtures = _fixtures(value['before_fixtures'], before);
    afterFixtures = _fixtures(value['after_fixtures'], after);
    for (final id in beforeFixtures.keys) {
      if (!coverage.contains(id) &&
          (beforeFixtures[id]!['content'] != afterFixtures[id]!['content'] ||
              beforeFixtures[id]!['raw'] != afterFixtures[id]!['raw'])) {
        _invalid();
      }
    }
  }

  late final List<String> variables;
  late final String reviewId, scorer;
  late final List<Json> productChanges;
  late final Set<String> coverage;
  late final Map<String, Json> beforeFixtures, afterFixtures;
  bool hasDiagnostics = false;

  // These fixtures deliberately use one JSON object per line. Reject an unknown
  // layout instead of pretending canonical equality proves byte equality.
  Map<String, Json> _fixtures(Object? source, Json report) {
    if (source is! String) _invalid();
    final parsed = parseAgentScenarios(source);
    final raw = <String, String>{};
    for (final line in source.split('\n')) {
      final s = line.trim();
      if (!s.startsWith('{"id":')) continue;
      final row = object(
        jsonDecode(s.endsWith(',') ? s.substring(0, s.length - 1) : s),
      );
      if (raw.containsKey(row['id'])) _invalid();
      raw[row['id'] as String] = byteDigest('$line\n');
    }
    if (raw.length != 20 ||
        object(jsonDecode(source))['version'] !=
            object(report['metadata'])['fixture_version']) {
      _invalid();
    }
    final rows = <String, Json>{};
    for (final r in (report['cases'] as List).map(object)) {
      final id = r['case_id'];
      if (id is! String || rows.containsKey(id)) _invalid();
      rows[id] = r;
    }
    final fixtures = <String, Json>{};
    for (final s in parsed) {
      if (rows[s.id] != null &&
          rows[s.id]!['fixture_digest'] != s.fingerprint) {
        _invalid();
      }
      fixtures[s.id] = {
        'content': digest({...s.data}..remove('fixture_version')),
        'raw': raw[s.id],
      };
    }
    if (rows.keys.any((id) => !fixtures.containsKey(id))) _invalid();
    return fixtures;
  }
}
