import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:xingyuan_assistant_eval/agent_eval/fixtures.dart';
import 'package:xingyuan_assistant_eval/agent_eval/report.dart';
import 'package:xingyuan_assistant_eval/agent_eval/scoring.dart';
import 'package:xingyuan_assistant_eval/agent_eval/trace.dart';

import 'support/cli_process.dart';

final scenarios = parseAgentScenarios(
  File('fixtures/agent_scenarios.json').readAsStringSync(),
);
AgentScenario scenario(String id) => scenarios.singleWhere((s) => s.id == id);
final zeroHash = digest('synthetic-protected-baseline');
Json metadata({String prompt = 'before'}) => {
  for (final key in ['product', 'test', 'tool_schema', 'model', 'parameters'])
    key: digest(key),
  'prompt': digest(prompt),
  'fixture_version': 'agent-c16-v1',
  'seed': 1,
  'evidence_kind': 'scripted_trace',
};
Json event(String kind, Json values) => {'kind': kind, 'ms': 0, ...values};
Json model({
  int bytes = 1000,
  Object? usage = const {'prompt': 10, 'completion': 10, 'total': 20},
  bool dispatched = true,
}) => event('model', {
  'bytes': bytes,
  'reservation': (bytes + 1) ~/ 2 + 1500,
  'usage': usage,
  'dispatched': dispatched,
});
Json item({int start = 600, int minutes = 30, String day = '2026-10-27'}) => {
  'day': day,
  'start': start,
  'minutes': minutes,
  'title': '合成整理',
};
Json validation(
  List<Json> items, {
  String status = 'ok',
  String phase = 'final',
}) => event('validation', {
  'digest': digest(items),
  'status': status,
  'phase': phase,
  'data_revision': 'synthetic-r1',
  'issues': status == 'invalid' ? ['conflict'] : [],
});
Json draft(List<Json> items, {bool partial = false}) => event('draft', {
  'items': items,
  'warning_items': partial ? List.generate(items.length, (i) => i) : [],
  'confirm_enabled': !partial,
});
Json tool({
  String name = 'query_schedule',
  String id = 'c1',
  String status = 'ok',
  String? original,
  bool executed = true,
  bool sent = false,
  Json arguments = const {'from': '2026-10-27', 'to': '2026-10-27'},
  Object? result = const [],
  String necessity = 'necessary',
}) => event('tool', {
  'name': name,
  'call_id': id,
  'arguments': arguments,
  'status': status,
  'original_status': ?original,
  'executed': executed,
  'sent': sent,
  'result': result,
  'data_revision': 'synthetic-r1',
  'necessity': necessity,
});
Json terminal({
  String status = 'answer',
  String reason = 'none',
  String text = '合成回复',
}) => event('terminal', {'status': status, 'reason': reason, 'text': text});
Json banner(String status) => event('banner', {
  'status': status,
  'text': dataBanners[status],
  'above_response': true,
});
Json confirm(List<Json> items, {bool accepted = true, bool ack = false}) =>
    event('confirm', {
      'digest': digest(items),
      'accepted': accepted,
      'partial_ack': ack,
    });
Json write(List<Json> items, {String receipt = 'synthetic-receipt'}) => event(
  'write',
  {'digest': digest(items), 'count': items.length, 'receipt': receipt},
);
Json traceData(String id, List<Json> events) => {
  'case_id': id,
  'fixture_digest': scenario(id).fingerprint,
  'attempt': 1,
  'channels': traceChannels.toList(),
  'protected_before': zeroHash,
  'protected_after': zeroHash,
  'events': events,
};
Json score(String id, List<Json> events) => scoreAgentTrace(
  scenario(id),
  AgentTrace.fromJson(traceData(id, events)),
  evidenceKind: 'scripted_trace',
).json;
Json checks(Json score) => object(score['checks']);
List<Json> happy(String id) {
  final items = [item(start: id == 'S03' ? 540 : 600)];
  final events = <Json>[model()];
  var end = terminal();
  switch (id) {
    case 'S03':
      events.addAll([validation(items), draft(items)]);
      end = terminal(status: 'draft');
    case 'S04':
      events.addAll([
        validation([item(start: 540)], status: 'invalid', phase: 'candidate'),
        validation(items),
        draft(items),
      ]);
      end = terminal(status: 'draft');
    case 'S05' || 'S11':
      end = terminal(status: 'needs_input');
    case 'S06' || 'S07' || 'S08' || 'S09' || 'S10':
      final status = scenario(id).expected['banner'] as String;
      events.addAll([
        tool(status: status, executed: id != 'S08'),
        banner(status),
      ]);
    case 'S13':
      events.addAll([
        tool(),
        tool(id: 'c2', status: 'duplicate', original: 'ok', executed: false),
        tool(id: 'c3', status: 'invalid', executed: false),
      ]);
      end = terminal(status: 'stopped', reason: 'duplicate');
    case 'S14':
      events.addAll(List.generate(5, (_) => model()));
      end = terminal(status: 'stopped', reason: 'round_limit');
    case 'S15' || 'S16':
      final reason = scenario(id).expected['boundary'] as String;
      events.add(event('boundary', {'reason': reason}));
      end = terminal(status: 'stopped', reason: reason);
    case 'S17':
      final bad = [item(start: 540)];
      events.addAll([
        validation(bad, status: 'invalid'),
        tool(
          name: 'submit_plan_draft',
          status: 'invalid',
          arguments: {'items': bad},
        ),
        model(),
        validation(items),
        draft(items),
      ]);
      end = terminal(status: 'draft');
    case 'S18':
      events.addAll([
        validation(items),
        draft(items),
        confirm(items),
        validation(items, phase: 'save', status: 'invalid'),
      ]);
      end = terminal(status: 'stopped', reason: 'protocol');
    case 'S19':
      items.add(item(start: 660));
      events.addAll([
        validation(items),
        draft(items),
        confirm(items, accepted: false),
        confirm(items),
        validation(items, phase: 'save'),
        write(items),
        confirm(items),
      ]);
      end = terminal(status: 'saved');
    case 'S20':
      events.add(model(bytes: 63999, dispatched: false));
      end = terminal(status: 'stopped', reason: 'token_limit');
  }
  return [...events, end];
}

ScriptedTrajectoryDriver driver({
  List<Json>? traces,
  String prompt = 'before',
}) => ScriptedTrajectoryDriver.fromJson({
  'metadata': metadata(prompt: prompt),
  'traces': traces ?? [for (final s in scenarios) traceData(s.id, happy(s.id))],
});

class _PolicyDriver implements AgentEvaluationDriver {
  _PolicyDriver(Json input)
    : metadata = AgentRunMetadata.fromJson(object(input['metadata'])),
      traces = (input['traces'] as List)
          .map((value) => AgentTrace.fromJson(object(value)))
          .toList();

  @override
  final AgentRunMetadata metadata;
  final List<AgentTrace> traces;

  @override
  Future<AgentTrace?> run(AgentScenario scenario) async {
    for (final trace in traces) {
      if (trace.caseId == scenario.id) return trace;
    }
    return null;
  }
}

void main() {
  test(
    'exactly twenty isolated data fixtures preserve required edge cases',
    () {
      expect(scenarios.map((s) => s.id).toSet(), hasLength(20));
      expect(scenario('S10').schedule, hasLength(61));
      expect(scenario('S10').schedule.last['start'], 540);
      expect(scenario('S06').schedule.single['start'], isNull);
      expect(scenario('S07').schedule.single['minutes'], isNull);
      expect(scenario('S08').grants['schedule'], false);
      expect(object(scenario('S11').data['preferences'])['minutes'], isNull);
      final copy = parseAgentScenarios(
        File('fixtures/agent_scenarios.json').readAsStringSync(),
      );
      object(copy.first.data['preferences'])['minutes'] = 42;
      expect(object(copy[1].data['preferences'])['minutes'], 30);
      expect(
        scenario('S20').data['variants'],
        contains('reservation_33500_rejects_63999'),
      );
    },
  );
  for (final s in scenarios) {
    test('${s.id} scripted scoring example, not product execution', () {
      final result = score(s.id, happy(s.id));
      expect(result['status'], 'pass', reason: '${result['checks']}');
      expect(result['product_acceptance'], 'not_run');
      expect(
        (result['manual'] as List).every((r) => r['status'] == 'needs_human'),
        true,
      );
      expect(
        object(result['variants']).values.every((v) => v == 'not_run'),
        true,
      );
    });
  }
  test('absent traces and incomplete instrumentation are not green', () {
    expect(
      scoreAgentTrace(
        scenario('S01'),
        null,
        evidenceKind: 'scripted_trace',
      ).json['status'],
      'not_run',
    );
    final data = traceData('S01', happy('S01'))..['channels'] = ['model'];
    expect(
      scoreAgentTrace(
        scenario('S01'),
        AgentTrace.fromJson(data),
        evidenceKind: 'scripted_trace',
      ).json['status'],
      'incomplete',
    );
    expect(score('S01', [model()])['status'], 'fail');
  });
  test(
    'duplicate case, wrong fixture, unknown fields and live driver are refused',
    () {
      final t = traceData('S01', happy('S01'));
      expect(() => driver(traces: [t, t]), throwsFormatException);
      expect(
        () => scoreAgentTrace(
          scenario('S02'),
          AgentTrace.fromJson(t),
          evidenceKind: 'scripted_trace',
        ),
        throwsFormatException,
      );
      expect(
        () => AgentTrace.fromJson({...t, 'secret': 'not-allowed'}),
        throwsFormatException,
      );
      expect(
        () => ScriptedTrajectoryDriver.fromJson({
          'metadata': {...metadata(), 'evidence_kind': 'live'},
          'traces': [],
        }),
        throwsFormatException,
      );
      expect(
        () => AgentTrace.fromJson(traceData('S01', [event('invented', {})])),
        throwsFormatException,
      );
    },
  );
  test('scenario ID is checked independently of the fixture digest', () {
    final mixed = traceData('S01', happy('S01'))..['case_id'] = 'S02';
    expect(
      () => scoreAgentTrace(
        scenario('S01'),
        AgentTrace.fromJson(mixed),
        evidenceKind: 'scripted_trace',
      ),
      throwsFormatException,
    );
  });
  test('canonical hashes sort nested keys but preserve array order', () {
    expect(
      digest({
        'b': {'y': 2, 'x': 1},
        'a': 0,
      }),
      digest({
        'a': 0,
        'b': {'x': 1, 'y': 2},
      }),
    );
    expect(digest([1, 2]), isNot(digest([2, 1])));
  });
  test('general answers count blocked requests separately from execution', () {
    final r = score('S01', [
      model(),
      tool(executed: false, status: 'not_authorized'),
      banner('not_authorized'),
      terminal(),
    ]);
    expect(r['forbidden_requests'], 1);
    expect(r['illegal_executions'], 0);
    expect(r['status'], 'fail');
  });
  test('denial, forbidden tool and canary leak cannot be averaged away', () {
    final r = score('S08', [
      model(),
      tool(status: 'not_authorized', sent: true),
      tool(name: 'read_diary', id: 'c2'),
      banner('not_authorized'),
      terminal(text: 'SYNTHETIC_DIARY'),
    ]);
    expect(r['illegal_executions'], 2);
    expect(r['illegal_outbound'], 1);
    expect(r['canary_leaks'], 1);
    expect(r['status'], 'fail');
  });
  test('D5 banner is state-based, exact, persistent and above response', () {
    final r = score('S09', [
      model(),
      tool(status: 'failed'),
      tool(id: 'c2', arguments: {'narrow': true}),
      {...banner('failed'), 'text': 'wrong'},
      terminal(text: '不能说你很空闲'),
    ]);
    expect(checks(r)['banner_text_failed'], 'fail');
    expect(
      score('S09', [model(), tool(status: 'failed'), terminal()])['status'],
      'fail',
    );
    final good = score('S09', [
      model(),
      tool(status: 'failed'),
      banner('failed'),
      tool(id: 'c2', arguments: {'narrow': true}),
      terminal(text: '你很空闲'),
    ]);
    expect(good['status'], 'pass');
    expect((good['manual'] as List).first['status'], 'needs_human');
  });
  test(
    'final validation must bind actual candidate, not an earlier digest',
    () {
      final r = score('S03', [
        model(),
        validation([item(start: 540)]),
        draft([item(start: 541)]),
        terminal(status: 'draft'),
      ]);
      expect(r['unsafe_drafts'], 1);
      expect(checks(r)['final_validation_bound'], 'fail');
    },
  );
  test('independent numeric oracle rejects overlap and daily overflow', () {
    final bad = [item(start: 540)];
    expect(
      checks(
        score('S04', [
          model(),
          validation(bad),
          draft(bad),
          terminal(status: 'draft'),
        ]),
      )['draft_numeric_constraints'],
      'fail',
    );
    final over = [item(start: 660), item(start: 690)];
    expect(
      checks(
        score('S05', [
          model(),
          validation(over),
          draft(over),
          terminal(status: 'draft'),
        ]),
      )['draft_numeric_constraints'],
      'fail',
    );
  });
  test(
    'partial candidates never count as ok and require per-item warnings',
    () {
      final items = [item(start: 540)];
      final r = score('S06', [
        model(),
        tool(status: 'partial'),
        banner('partial'),
        validation(items, status: 'partial'),
        draft(items, partial: true),
        terminal(status: 'draft'),
      ]);
      expect(r['status'], 'pass');
      expect(r['validation'], 'partial');
      final bad = score('S06', [
        model(),
        tool(status: 'partial'),
        banner('partial'),
        validation(items, status: 'partial'),
        draft(items),
        terminal(status: 'draft'),
      ]);
      expect(checks(bad)['partial_guard'], 'fail');
    },
  );
  test('duplicate caches preserve original status/result, identity wins', () {
    final sequence = [
      model(),
      tool(status: 'partial', result: {'unknown': 1}),
      tool(
        id: 'c2',
        status: 'duplicate',
        original: 'ok',
        result: {},
        executed: false,
      ),
      banner('partial'),
      tool(id: 'c3', status: 'invalid', executed: false),
      terminal(status: 'stopped', reason: 'duplicate'),
    ];
    expect(checks(score('S13', sequence))['duplicate_cache'], 'fail');
    final identity = [
      model(),
      tool(),
      event('boundary', {'reason': 'identity'}),
      tool(id: 'c2', status: 'duplicate', original: 'ok', executed: false),
      terminal(status: 'stopped', reason: 'identity'),
    ];
    expect(score('S16', identity)['post_stop_calls'], 1);
  });
  for (final usage in [
    null,
    {'prompt': 1, 'completion': 2, 'total': 4},
    {'prompt': -1, 'completion': 1, 'total': 0},
    {'prompt': 1.5, 'completion': 1, 'total': 2.5},
    {'prompt': 2000, 'completion': 1, 'total': 2001},
  ]) {
    test('invalid usage $usage stays unknown and stops', () {
      final r = score('S20', [
        model(usage: usage),
        model(bytes: 64000, dispatched: false),
        terminal(status: 'stopped', reason: 'usage_invalid'),
      ]);
      final knownOver = usage?['total'] == 2001;
      expect(r['unknown_usage_events'], knownOver ? 0 : 1);
      expect(r['actual_tokens_known'], knownOver ? 2001 : 0);
      expect(r['budget_violations'], 1);
      expect(r['post_stop_calls'], 0);
      final late = score('S20', [
        model(usage: usage),
        model(),
        terminal(status: 'stopped', reason: 'usage_invalid'),
      ]);
      expect(late['post_stop_calls'], 1);
    });
  }
  test('six calls, exact deadline and reservation checked before dispatch', () {
    expect(
      checks(
        score('S14', [
          ...List.generate(7, (_) => model()),
          terminal(status: 'stopped', reason: 'round_limit'),
        ]),
      )['model_dispatch_budget'],
      'fail',
    );
    final t = model()..['ms'] = 60000;
    expect(
      checks(
        score('S14', [
          t,
          {...terminal(status: 'stopped', reason: 'deadline'), 'ms': 60000},
        ]),
      )['model_dispatch_budget'],
      'fail',
    );
    expect(
      checks(
        score('S20', [model(bytes: 63999), terminal()]),
      )['model_dispatch_budget'],
      'fail',
    );
    expect(
      checks(score('S20', [model(bytes: 64000), terminal()]))['request_bytes'],
      'fail',
    );
    expect(score('S20', happy('S20'))['status'], 'pass');
  });
  test('cancellation prevents new model request, presentation and writes', () {
    final r = score('S15', [
      model(),
      event('boundary', {'reason': 'cancel'}),
      model(),
      draft([item()]),
      write([item()]),
      terminal(status: 'stopped', reason: 'cancel'),
    ]);
    expect(r['post_stop_calls'], 3);
    expect(checks(r)['write_confirmed'], 'fail');
  });
  test(
    'confirmation requires fresh validation and idempotent write events',
    () {
      final items = [item(), item(start: 660)];
      final r = score('S19', [
        model(),
        validation(items),
        draft(items),
        confirm(items, accepted: false),
        confirm(items),
        write(items),
        write(items),
        terminal(status: 'saved'),
      ]);
      expect(checks(r)['write_confirmed'], 'fail');
      expect(checks(r)['idempotent_write'], 'fail');
      expect(r['formal_writes'], 4);
    },
  );
  test(
    'schema rejects negative counters, nonmonotonic events and unknown status',
    () {
      for (final events in [
        [
          event('privacy', {'channel': 'log', 'leaks': -1}),
        ],
        [
          {...model(), 'ms': 2},
          terminal(),
        ],
        [tool(status: 'empty_success')],
      ]) {
        expect(
          () => AgentTrace.fromJson(traceData('S01', events)),
          throwsFormatException,
        );
      }
    },
  );
  test(
    'twenty case report uses real denominators and keeps product not_run',
    () async {
      final report = await evaluateAgentRun(scenarios, driver());
      expect(report['passed'], 20);
      expect(report['product_acceptance'], 'not_run');
      final metrics = object(report['metrics']);
      expect(object(metrics['mean_rounds'])['denominator'], 20);
      expect(object(metrics['plan_validation_rate'])['denominator'], 5);
      expect(object(metrics['semantic_sample'])['reviewed'], 0);
      expect(report['evidence_scope'], 'scorer_and_report_only');
    },
  );
  test('zero denominator is null and failed runs remain in average', () async {
    final empty = await evaluateAgentRun(scenarios, driver(traces: []));
    expect(object(object(empty['metrics'])['mean_rounds'])['value'], isNull);
    final r = await evaluateAgentRun(
      scenarios,
      driver(
        traces: [
          traceData('S01', [model(), model(), tool(), terminal()]),
        ],
      ),
    );
    expect(r['failed'], 1);
    expect(object(object(r['metrics'])['mean_rounds'])['value'], 2);
  });
  test(
    'unknown query necessity stays manual; necessary narrowing is not extra',
    () async {
      final trace = traceData('S09', [
        model(),
        tool(status: 'failed'),
        banner('failed'),
        tool(id: 'c2', arguments: {'narrow': true}, necessity: 'unknown'),
        terminal(),
      ]);
      final r = await evaluateAgentRun(scenarios, driver(traces: [trace]));
      final rate = object(object(r['metrics'])['extra_query_rate']);
      expect(rate['numerator'], 0);
      expect(rate['denominator'], 2);
      expect(rate['unresolved'], 1);
      expect(rate['status'], 'needs_human');
    },
  );
  test(
    'paired reports retain regressions and refuse incompatible comparisons',
    () async {
      final before = await evaluateAgentRun(scenarios, driver());
      final after = await evaluateAgentRun(
        scenarios,
        driver(
          prompt: 'after',
          traces: [
            for (final s in scenarios)
              traceData(
                s.id,
                s.id == 'S01' ? [model(), tool(), terminal()] : happy(s.id),
              ),
          ],
        ),
      );
      final c = compareAgentRuns(before, after);
      expect(c['paired'], 20);
      expect(c['regressions'], 1);
      object(after['metadata'])['model'] = digest('different-model');
      expect(compareAgentRuns(before, after)['paired'], 0);
      expect(compareAgentRuns(before, after)['metadata_mismatches'], ['model']);
    },
  );
  group('assessment policy binding', () {
    Json trajectory(String id) => {
      ...traceData(id, [
        ...happy(id)
            .where((e) => e['kind'] != 'banner' && e['kind'] != 'terminal'),
        event('data_state', {
          'statuses': ['not_authorized'],
          'messages': [dataBanners['not_authorized']],
          'source': 'committed',
        }),
        for (final channel in ['outbound', 'log'])
          event('privacy', {'channel': channel, 'leaks': 0}),
        terminal(),
      ]),
      'assessment': 'trajectory-v1',
      'channels': trajectoryChannels.toList(),
    };
    Json input({bool declared = true, bool observed = true}) => {
      'metadata': {
        ...metadata(),
        if (declared) 'scoring_policy': 'trajectory-v1',
      },
      'traces': [observed ? trajectory('S08') : traceData('S08', happy('S08'))],
    };
    Future<Json> report(Json input) =>
        evaluateAgentRun([scenario('S08')], _PolicyDriver(input));

    test(
      'matching policies pass and historical full reports still pair',
      () async {
        final full = await report(input(declared: false, observed: false));
        final current = await report(input());
        expect(full['passed'], 1);
        expect(current['passed'], 1);
        expect(compareAgentRuns(current, current)['paired'], 1);
        final legacy = object(jsonDecode(jsonEncode(full)));
        legacy.remove('scoring_policy');
        object((legacy['cases'] as List).single).remove('assessment');
        expect(compareAgentRuns(full, legacy)['paired'], 1);
        final different = compareAgentRuns(full, current);
        expect(different['paired'], 0);
        expect(different['metadata_mismatches'], ['scoring_policy']);
        expect(object((different['pairs'] as List).single)['delta'], isNull);
      },
    );

    for (final declared in [false, true]) {
      test('ingestion rejects all mismatched traces declared=$declared', () {
        final mixed = input(declared: declared, observed: !declared);
        (mixed['traces'] as List).insert(0, traceData('S01', happy('S01')));
        expect(
          () => ScriptedTrajectoryDriver.fromJson(mixed),
          throwsFormatException,
        );
      });
      test('rejects run/trace mismatch declared=$declared', () async {
        await expectLater(
          report(input(declared: declared, observed: !declared)),
          throwsFormatException,
        );
      });
    }
    test('rejects mixed case policies in a declared run', () async {
      final mixed = input();
      (mixed['traces'] as List).add(traceData('S01', happy('S01')));
      await expectLater(
        evaluateAgentRun([
          scenario('S08'),
          scenario('S01'),
        ], _PolicyDriver(mixed)),
        throwsFormatException,
      );
    });

    for (final target in ['top', 'case', 'metadata']) {
      for (final mutation in ['missing', 'different', 'null', 'unknown']) {
        test('comparison rejects $target policy $mutation', () async {
          final changed = await report(input());
          final row = switch (target) {
            'top' => changed,
            'metadata' => object(changed['metadata']),
            _ => object((changed['cases'] as List).single),
          };
          final key = target == 'case' ? 'assessment' : 'scoring_policy';
          if (mutation == 'missing') {
            row.remove(key);
          } else {
            row[key] = switch (mutation) {
              'different' => 'full-evidence-v1',
              'null' => null,
              _ => 'unknown-policy',
            };
          }
          // Equal outer metadata must not make inconsistent cases comparable.
          expect(
            () => compareAgentRuns(changed, changed),
            throwsFormatException,
          );
        });
      }
    }
    test('not-run rows may omit assessment but cannot contradict it', () async {
      final empty = input()..['traces'] = <Json>[];
      final r = await report(empty);
      expect(r['not_run'], 1);
      expect(compareAgentRuns(r, r)['paired'], 0);
      object((r['cases'] as List).single)['assessment'] = 'full-evidence-v1';
      expect(() => compareAgentRuns(r, r), throwsFormatException);
    });

    for (final option in ['--scripted', '--compare']) {
      test('CLI rejects inconsistent $option before creating output', () async {
        final dir = Directory.systemTemp.createTempSync('agent-policy-cli-');
        addTearDown(() => dir.deleteSync(recursive: true));
        final good = File('${dir.path}/good.json')
          ..writeAsStringSync(jsonEncode(input()));
        final invalid = input(declared: false);
        (object((invalid['traces'] as List).single)['events'] as List)
                .last['text'] =
            'PRIVATE_POLICY_CANARY';
        final bad = File('${dir.path}/bad.json')
          ..writeAsStringSync(jsonEncode(invalid));
        final out = '${dir.path}/out';
        final result = await runCli(Platform.resolvedExecutable, [
          'run',
          'bin/agent_report.dart',
          '--scripted',
          option == '--scripted' ? bad.path : good.path,
          if (option == '--compare') ...['--compare', bad.path],
          '--output',
          out,
        ]);
        expect(result.exitCode, 64);
        expect(Directory(out).existsSync(), false);
        expect(
          '${result.stdout}${result.stderr}',
          isNot(contains('PRIVATE_POLICY_CANARY')),
        );
      });
    }
  });
  test(
    'JSON and Markdown omit source text, tool args, results and identifiers',
    () async {
      final source = traceData('S01', [
        model(),
        terminal(text: 'PRIVATE_SYNTHETIC_TEXT|\n# header'),
      ]);
      final r = await evaluateAgentRun(scenarios, driver(traces: [source]));
      final json = jsonEncode(r), md = agentReportMarkdown(r);
      for (final exported in [json, md]) {
        expect(exported, isNot(contains('PRIVATE_SYNTHETIC_TEXT')));
        expect(exported, isNot(contains('synthetic-protected-baseline')));
        expect(exported, contains('not_run'));
      }
    },
  );
  test('partial and unreviewed output do not inflate quality rates', () async {
    final items = [item(start: 540)];
    final r = await evaluateAgentRun(
      scenarios,
      driver(
        traces: [
          traceData('S06', [
            model(),
            tool(status: 'partial'),
            banner('partial'),
            validation(items, status: 'partial'),
            draft(items, partial: true),
            terminal(status: 'draft'),
          ]),
        ],
      ),
    );
    expect(object(object(r['metrics'])['plan_validation_rate'])['value'], 0);
    expect(object(r['metrics'])['partial_candidates'], 1);
    expect(r['not_run'], 19);
  });
  test(
    'last model validation cannot replace validation of displayed items',
    () {
      final items = [item(start: 540)];
      final r = score('S03', [
        model(),
        validation(items, status: 'invalid'),
        draft(items),
        validation([item(start: 541)]),
        terminal(status: 'draft'),
      ]);
      expect(r['validation'], 'invalid');
      expect(checks(r)['final_validation_bound'], 'fail');
    },
  );
  test('unknown schedule cannot be upgraded to ok, even if model says so', () {
    final items = [item(start: 540)];
    final r = score('S06', [
      model(),
      tool(status: 'partial'),
      banner('partial'),
      validation(items),
      draft(items),
      terminal(status: 'draft'),
    ]);
    expect(checks(r)['unknown_schedule_not_ok'], 'fail');
  });
  test('banner alone does not prove the scenario data status occurred', () {
    final r = score('S06', [model(), banner('partial'), terminal()]);
    expect(r['status'], 'incomplete');
  });
  test('failed query followed by complete narrowed query may validate, banner persists', () {
    final items = [item(start: 540)];
    final r = score('S03', [
      model(),
      tool(status: 'failed'),
      banner('failed'),
      tool(id: 'c2', arguments: {'narrow': true}),
      validation(items),
      draft(items),
      terminal(status: 'draft'),
    ]);
    expect(r['status'], 'pass');
    expect(r['extra_queries'], 0);
  });
  test('misrequest is counted once when both general and unauthorized', () {
    final r = score('S02', [
      model(),
      tool(status: 'not_authorized', executed: false),
      banner('not_authorized'),
      terminal(),
    ]);
    expect(r['private_misrequests'], 1);
    expect(r['denied_requests'], 1);
    expect(r['forbidden_requests'], 1);
  });
  test(
    'out of range, one-minute overlap, end1441 and duplicate items fail',
    () {
      for (final items in [
        [item(day: '2026-11-11')],
        [item(start: 1410, minutes: 31)],
        [item(), item(start: 629)],
        [item(), item()],
      ]) {
        final r = score('S05', [
          model(),
          validation(items),
          draft(items),
          terminal(status: 'draft'),
        ]);
        expect(checks(r)['draft_numeric_constraints'], 'fail');
      }
    },
  );
  test('size and budget refusal remain separate at 63999,64000,64001', () {
    for (final bytes in [63999, 64000, 64001]) {
      final r = score('S20', [
        model(bytes: bytes, dispatched: false),
        terminal(
          status: 'stopped',
          reason: bytes == 63999 ? 'token_limit' : 'size',
        ),
      ]);
      expect(r['status'], 'pass');
      expect(r['model_calls'], 0);
      expect(r['actual_tokens_known'], 0);
    }
  });
  test(
    'CLI exports JSON, Markdown and paired comparison without overwriting',
    () async {
      final dir = Directory.systemTemp.createTempSync('agent-eval-cli-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final input = File('${dir.path}/trace.json')
        ..writeAsStringSync(
          jsonEncode({
            'metadata': metadata(),
            'traces': [for (final s in scenarios) traceData(s.id, happy(s.id))],
          }),
        );
      final out = '${dir.path}/report';
      final result = await runCli(Platform.resolvedExecutable, [
        'run',
        'bin/agent_report.dart',
        '--scripted',
        input.path,
        '--compare',
        input.path,
        '--output',
        out,
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(
        object(
          jsonDecode(File('$out/report.json').readAsStringSync()),
        )['passed'],
        20,
      );
      expect(
        object(
          jsonDecode(File('$out/comparison.json').readAsStringSync()),
        )['paired'],
        20,
      );
      expect(
        File('$out/report.md').readAsStringSync(),
        contains('Paired Comparison'),
      );
      final again = await runCli(Platform.resolvedExecutable, [
        'run',
        'bin/agent_report.dart',
        '--scripted',
        input.path,
        '--output',
        out,
      ]);
      expect(again.exitCode, 64);
      final evidence = Platform.environment['AGENT_EVAL_EVIDENCE_DIR'];
      if (evidence != null) {
        final folder = Directory(evidence);
        expect(folder.existsSync(), false);
        folder.createSync(recursive: true);
        input.copySync('$evidence/scripted-traces.json');
        for (final name in ['report.json', 'report.md', 'comparison.json']) {
          File('$out/$name').copySync('$evidence/$name');
        }
      }
    },
  );
  test(
    'CLI distinguishes incomplete, failed, malformed and rejects live switches',
    () async {
      final dir = Directory.systemTemp.createTempSync('agent-eval-status-');
      addTearDown(() => dir.deleteSync(recursive: true));
      for (final entry in {
        'incomplete': 3,
        'failed': 1,
        'malformed': 64,
      }.entries) {
        final input = File('${dir.path}/${entry.key}.json');
        input.writeAsStringSync(
          entry.key == 'malformed'
              ? 'PRIVATE_PARSE_CANARY'
              : jsonEncode({
                  'metadata': metadata(),
                  'traces': entry.key == 'incomplete'
                      ? []
                      : [
                          traceData('S01', [model(), tool(), terminal()]),
                        ],
                }),
        );
        final r = await runCli(Platform.resolvedExecutable, [
          'run',
          'bin/agent_report.dart',
          '--scripted',
          input.path,
          '--output',
          '${dir.path}/${entry.key}-out',
        ]);
        expect(r.exitCode, entry.value);
        expect(
          '${r.stdout}${r.stderr}',
          isNot(contains('PRIVATE_PARSE_CANARY')),
        );
      }
      final live = await runCli(Platform.resolvedExecutable, [
        'run',
        'bin/agent_report.dart',
        '--live',
        'true',
      ]);
      expect(live.exitCode, 64);
      expect(Directory('${dir.path}/malformed-out').existsSync(), false);
    },
  );
}
