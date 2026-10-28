import 'fixtures.dart';
import 'declared_comparison.dart';
import 'scoring.dart';
import 'trace.dart';

Json _ratio(num numerator, num denominator) => {
  'numerator': numerator,
  'denominator': denominator,
  'value': denominator == 0 ? null : numerator / denominator,
};

String _scoringPolicy(Json data, String key) {
  if (!data.containsKey(key)) return 'full-evidence-v1';
  final value = data[key];
  if (value != 'full-evidence-v1' && value != 'trajectory-v1') {
    throw const FormatException('Invalid assessment policy');
  }
  return value as String;
}

String _reportPolicy(Json report) {
  final policy = _scoringPolicy(object(report['metadata']), 'scoring_policy');
  if (_scoringPolicy(report, 'scoring_policy') != policy) {
    throw const FormatException('Inconsistent assessment policy');
  }
  for (final row in (report['cases'] as List).map(object)) {
    if (row['status'] == 'not_run' && !row.containsKey('assessment')) continue;
    if (_scoringPolicy(row, 'assessment') != policy) {
      throw const FormatException('Inconsistent assessment policy');
    }
  }
  return policy;
}

Future<Json> evaluateAgentRun(
  List<AgentScenario> scenarios,
  AgentEvaluationDriver driver,
) async {
  // Freeze the declared policy before awaiting any adapter observations.
  final metadata = AgentRunMetadata.fromJson(driver.metadata.data);
  final policy = _scoringPolicy(metadata.data, 'scoring_policy');
  final results = <Json>[];
  for (final scenario in scenarios) {
    final trace = await driver.run(scenario);
    if (trace != null && _scoringPolicy(trace.data, 'assessment') != policy) {
      throw const FormatException('Inconsistent assessment policy');
    }
    final score = scoreAgentTrace(
      scenario,
      trace,
      evidenceKind: metadata.data['evidence_kind'] as String,
    ).json;
    // Diagnostics annotate the original score; they never rescore or change it.
    results.add({
      ...score,
      'rejection_observations': [
        if (trace != null)
          for (var i = 0; i < trace.events.length; i++)
            if (trace.events[i]['kind'] == 'stop' ||
                trace.events[i]['rejection_category'] != null)
              {
                'event_index': i,
                'category':
                    trace.events[i]['rejection_category'] ??
                    trace.events[i]['category'],
                'layer': trace.events[i]['layer'] ?? 'model_response',
                if (trace.events[i].containsKey('rejection_detail'))
                  'detail': trace.events[i]['rejection_detail'],
              },
      ],
    });
  }
  final executed = results.where((r) => r['status'] != 'not_run').toList();
  final successful = executed.where((r) => r['status'] == 'pass').toList();
  int sum(String field, [List<Json>? rows]) =>
      (rows ?? executed).fold(0, (a, r) => a + (r[field] as int));
  int count(bool Function(Json) test) => executed.where(test).length;
  bool valid(Json r) =>
      r['candidate'] == true &&
      r['validation'] == 'ok' &&
      object(r['checks'])['final_validation_bound'] == 'pass' &&
      object(r['checks'])['draft_numeric_constraints'] == 'pass';
  final calls = executed.map((r) => r['model_calls'] as int).toList()..sort();
  final bannerCases = executed
      .where((r) => (r['banner_required'] as List).isNotEmpty)
      .toList();
  final extra = sum('extra_queries'),
      unknown = sum('unknown_queries'),
      reads = sum('read_requests');
  return {
    'schema': 'agent-eval-report-v1',
    'metadata': metadata.data,
    'evidence_scope': metadata.data['evidence_kind'] == 'scripted_trace'
        ? 'scorer_and_report_only'
        : 'adapter_evidence_requires_review',
    'product_acceptance': 'not_run',
    'manual_review': 'needs_human',
    'scoring_policy': policy,
    'scenarios_total': scenarios.length,
    'executed': executed.length,
    'passed': successful.length,
    'failed': count((r) => r['status'] == 'fail'),
    'incomplete': count((r) => r['status'] == 'incomplete'),
    'not_run': scenarios.length - executed.length,
    'metrics': {
      'plan_validation_rate': _ratio(
        count(valid),
        count((r) => r['candidate'] == true),
      ),
      'partial_candidates': count(
        (r) => r['candidate'] == true && r['validation'] == 'partial',
      ),
      'scheduling_completion': _ratio(
        count((r) => r['schedulable'] == true && valid(r)),
        scenarios.where((s) => s.expected['schedulable'] == true).length,
      ),
      'mean_rounds': _ratio(sum('model_calls'), executed.length),
      'mean_success_rounds': _ratio(
        sum('model_calls', successful),
        successful.length,
      ),
      'p95_rounds': calls.isEmpty
          ? null
          : calls[(calls.length * .95).ceil() - 1],
      'max_rounds': calls.isEmpty ? null : calls.last,
      'extra_query_rate': {
        ..._ratio(extra, reads),
        'unresolved': unknown,
        'status': unknown == 0 ? 'determinate' : 'needs_human',
        'upper_bound': _ratio(extra + unknown, reads)['value'],
      },
      'private_misrequests': sum('private_misrequests'),
      'illegal_executions': sum('illegal_executions'),
      'illegal_outbound': sum('illegal_outbound'),
      'repair_rate': _ratio(
        count((r) => r['repaired'] == true),
        count((r) => r['conflict_observed'] == true),
      ),
      'banner_rate': _ratio(
        bannerCases
            .where(
              (r) =>
                  object(r['checks'])['data_banners'] == 'pass' &&
                  object(r['checks']).entries
                      .where((e) => e.key.startsWith('banner_text_'))
                      .every((e) => e.value == 'pass'),
            )
            .length,
        bannerCases.length,
      ),
      'budget_stops': count((r) => r['budget_stop'] == true),
      'usage_violations': sum('budget_violations'),
      'budget_escapes': sum('budget_escapes'),
      'unconfirmed_writes': sum('unconfirmed_writes'),
      'actual_tokens_known': sum('actual_tokens_known'),
      'unknown_usage_events': sum('unknown_usage_events'),
      'unsafe_drafts': sum('unsafe_drafts'),
      'post_stop_calls': sum('post_stop_calls'),
      'formal_writes': sum('formal_writes'),
      'canary_leaks': sum('canary_leaks'),
      'semantic_sample': {
        'reviewed': 0,
        'consistent': 0,
        'contradictory': 0,
        'unresolved': 0,
        'unreviewed': executed.length,
      },
    },
    'cases': results,
  };
}

Json compareAgentRuns(Json before, Json after, {Json? treatment}) {
  final beforePolicy = _reportPolicy(before),
      afterPolicy = _reportPolicy(after);
  final declared = treatment == null
      ? null
      : DeclaredComparison(treatment, before, after);
  final old = {
    for (final r in (before['cases'] as List).map(object)) r['case_id']: r,
  };
  final next = {
    for (final r in (after['cases'] as List).map(object)) r['case_id']: r,
  };
  final a = object(before['metadata']), b = object(after['metadata']);
  // Prompt/test hashes may vary. Model, parameters, product and tool schema may not.
  final mismatches = [
    for (final key in [
      'product',
      'model',
      'tool_schema',
      'parameters',
      'fixture_version',
      'seed',
      'evidence_kind',
    ])
      if (a[key] != b[key] &&
          !(declared != null &&
              (key == 'product' ||
                  key == 'fixture_version' ||
                  (key == 'tool_schema' && declared.variables.contains(key)))))
        key,
    if (declared != null &&
        a['prompt'] != b['prompt'] &&
        !declared.variables.contains('prompt'))
      'prompt',
    if (beforePolicy != afterPolicy) 'scoring_policy',
  ];
  final ids = {...old.keys, ...next.keys}.cast<String>().toList()..sort();
  final pairs = <Json>[];
  for (final id in ids) {
    final x = old[id], y = next[id];
    final bool sameFixture;
    if (declared == null) {
      sameFixture = x?['fixture_digest'] == y?['fixture_digest'];
    } else {
      sameFixture =
          !declared.coverage.contains(id) &&
          declared.beforeFixtures[id]?['content'] ==
              declared.afterFixtures[id]?['content'] &&
          declared.beforeFixtures[id]?['raw'] ==
              declared.afterFixtures[id]?['raw'];
    }
    final comparable =
        mismatches.isEmpty &&
        x != null &&
        y != null &&
        sameFixture &&
        x['status'] != 'not_run' &&
        y['status'] != 'not_run';
    final regression =
        comparable && x['status'] == 'pass' && y['status'] != 'pass';
    pairs.add({
      'case_id': id,
      'comparable': comparable,
      'regression': regression,
      'before': x?['status'] ?? 'missing',
      'after': y?['status'] ?? 'missing',
      'validation_before': x?['validation'],
      'validation_after': y?['validation'],
      if (declared != null) ...{
        'fixture_content_before': declared.beforeFixtures[id]?['content'],
        'fixture_content_after': declared.afterFixtures[id]?['content'],
        'fixture_bytes_before': declared.beforeFixtures[id]?['raw'],
        'fixture_bytes_after': declared.afterFixtures[id]?['raw'],
        'unpaired_reason': comparable
            ? null
            : declared.coverage.contains(id)
            ? 'coverage_change'
            : mismatches.isNotEmpty
            ? 'metadata_mismatch'
            : 'missing_or_not_run',
      },
      'delta': comparable
          ? {
              for (final field in [
                'model_calls',
                'extra_queries',
                'forbidden_requests',
                'denied_requests',
                'illegal_executions',
                'illegal_outbound',
                'canary_leaks',
              ])
                field: (y[field] as int) - (x[field] as int),
            }
          : null,
      'manual_review': 'needs_human',
    });
  }
  return {
    'schema': 'agent-eval-comparison-v1',
    'metadata_mismatches': mismatches,
    if (declared != null) ...{
      'comparison_scope': 'declared_treatment_observational',
      'declared_variables': declared.variables,
      'review_id': declared.reviewId,
      'reviewed_product_changes': declared.productChanges,
      'diagnostic_instrumentation_changed': declared.hasDiagnostics,
      'source_review_limit': 'Exact source hashes bind the review; classifications are reviewer attestations, not automated semantic equivalence or causal proof.',
      'before_metadata': a,
      'after_metadata': b,
      'scorer': declared.scorer,
      'coverage_cases': declared.coverage.toList()..sort(),
    },
    'regressions': pairs.where((p) => p['regression'] == true).length,
    'paired': pairs.where((p) => p['comparable'] == true).length,
    'pairs': pairs,
  };
}

String agentReportMarkdown(Json report, {Json? comparison}) {
  final text = StringBuffer('# Agent Evaluation Scaffold\n\n');
  text.writeln(
    'Evidence: `${report['evidence_scope']}`. Product/AG acceptance: **not_run**.',
  );
  text.writeln(
    report['evidence_scope'] == 'scorer_and_report_only'
        ? 'Synthetic traces validate the scorer, not App behavior or model quality.'
        : 'Adapter observations require review. Headless previews do not prove rendered UI or model quality.',
  );
  if (report['scoring_policy'] == 'trajectory-v1') {
    text.writeln(
      'C26 trajectory assessment: actual tools, states, final output and shared App D5 metadata mapping.',
    );
    text.writeln(
      'Banner styling and partial-checkbox interaction: covered by A2/A3 component QA, not reexecuted here. Native, process-log coverage and manual semantics remain separate.',
    );
  }
  text.writeln(
    'Base scenarios: ${report['scenarios_total']}; executed ${report['executed']}; '
    'pass ${report['passed']}; fail ${report['failed']}; incomplete ${report['incomplete']}; not_run ${report['not_run']}.\n',
  );
  text.writeln('| Metric | Numerator / Denominator or Value |\n| --- | --- |');
  for (final entry in object(report['metrics']).entries) {
    final v = entry.value;
    final label = v is Map && v.containsKey('numerator')
        ? '${v['numerator']} / ${v['denominator']} (${v['value'] ?? 'N/A'})'
        : '$v';
    text.writeln('| ${entry.key} | $label |');
  }
  text.writeln(
    '\nUnknown query necessity is a lower/upper interval, not a passed quality score.',
  );
  text.writeln(
    'Unknown usage is not zero. 24000 is an accounting limit, not a proven token bound.\n',
  );
  text.writeln(
    '| Case | Result | Validation | Rounds | Review |\n| --- | --- | --- | --- | --- |',
  );
  for (final r in (report['cases'] as List).map(object)) {
    text.writeln(
      '| ${r['case_id']} | ${r['status']} | ${r['validation'] ?? 'N/A'} | ${r['model_calls'] ?? 'N/A'} | needs_human |',
    );
  }
  text.writeln('\n## Stop Categories\n');
  for (final r in (report['cases'] as List).map(object)) {
    if (r['rejection_observations'] is List &&
        (r['rejection_observations'] as List).isNotEmpty) {
      text.writeln(
        'Stop categories (${r['case_id']}): ${(r['rejection_observations'] as List).map(object).map((e) => e['detail'] == null ? e['category'] : '${e['category']}/${e['detail']}').join(', ')}.',
      );
    }
  }
  text.writeln('\n## Manual Rubrics\n');
  for (final entry in manualRubrics.entries) {
    text.writeln('- `${entry.key}`: ${entry.value}');
  }
  text.writeln(
    '\nBoundary variants remain not_run until independently driven and evidenced.',
  );
  if (comparison != null) {
    text.writeln('\n## Paired Comparison\n');
    text.writeln(
      'Comparable pairs: ${comparison['paired']}; regressions: ${comparison['regressions']}.',
    );
    text.writeln('Metadata mismatches: ${comparison['metadata_mismatches']}.');
    text.writeln(
      '| Case | Before | After | Comparable | Regression |\n| --- | --- | --- | --- | --- |',
    );
    for (final p in (comparison['pairs'] as List).map(object)) {
      text.writeln(
        '| ${p['case_id']} | ${p['before']} | ${p['after']} | ${p['comparable']} | ${p['regression']} |',
      );
    }
  }
  return text.toString();
}
