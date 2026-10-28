import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:xingyuan_assistant_eval/agent_eval/budget.dart';
import 'package:xingyuan_assistant_eval/agent_eval/fixtures.dart';
import 'package:xingyuan_assistant_eval/agent_eval/scoring.dart';
import 'package:xingyuan_assistant_eval/agent_eval/trace.dart';

import '../tool/agent_eval/app_driver.dart';
import '../tool/agent_eval/run_preparation.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);
  late Directory dir;
  late EvaluationBudget budget;
  late AppAgentEvaluationDriver driver;
  final scenarios = parseAgentScenarios(
    File('tool/assistant_eval/fixtures/agent_scenarios.json')
        .readAsStringSync(),
  );
  setUp(() {
    dir = Directory.systemTemp.createTempSync('agent-c26-test-');
    budget = EvaluationBudget.claim('${dir.path}/budget.sqlite');
    driver = AppAgentEvaluationDriver(
      metadata: driverMetadata(Directory.current.path, live: false),
      output: dir,
      budget: budget,
    );
  });
  tearDown(() {
    budget.close();
    dir.deleteSync(recursive: true);
  });
  AgentScenario scenario(String id) => scenarios.singleWhere((s) => s.id == id);
  Json score(String id, AgentTrace trace) =>
      scoreAgentTrace(scenario(id), trace, evidenceKind: 'app_offline').json;

  for (final id in ['S06', 'S08']) {
    test(
      '$id trajectory uses actual App data state without claiming UI',
      () async {
        final trace = (await driver.run(scenario(id)))!;
        final result = score(id, trace);
        expect(result['status'], 'pass');
        expect((result['checks'] as Map)['data_banners'], 'pass');
        expect(trace.data['channels'], isNot(contains('presentation')));
        expect(
          trace.events.where((e) => e['kind'] == 'data_state'),
          hasLength(1),
        );
        expect(result['product_acceptance'], 'not_run');
        expect(
          (result['manual'] as List).every((r) => r['status'] == 'needs_human'),
          true,
        );

        for (final mutation in ['missing', 'text', 'status']) {
          final data = object(jsonDecode(jsonEncode(trace.data)));
          final events = (data['events'] as List).cast<Map>();
          if (mutation == 'missing') {
            events.removeWhere((e) => e['kind'] == 'data_state');
          } else {
            final state = events.singleWhere((e) => e['kind'] == 'data_state');
            state[mutation == 'text' ? 'messages' : 'statuses'] = ['wrong'];
          }
          expect(score(id, AgentTrace.fromJson(data))['status'], isNot('pass'));
        }
      },
    );
  }

  test(
    'S10 seeds legal rows and actually omits a later conflicting row',
    () async {
      final s = scenario('S10');
      expect(s.schedule.every((r) => (r['minutes'] as int) >= 5), true);
      final trace = await driver.run(s);
      expect(trace, isNotNull);
      final query = trace!.events.singleWhere(
        (e) => e['kind'] == 'tool' && e['name'] == 'query_schedule',
      );
      expect(query['status'], 'truncated');
      final items = (query['result'] as Map)['data']['items'] as List;
      expect(items, hasLength(60));
      expect(items.any((r) => r['start_minute'] == 540), false);
      expect(
        trace.events
            .where((e) => e['kind'] == 'validation')
            .any((e) => (e['issues'] as List).contains('conflict')),
        true,
      );
      expect(score('S10', trace)['status'], 'pass');
      final missing = object(jsonDecode(jsonEncode(trace.data)));
      (missing['events'] as List).removeWhere((e) => e['kind'] == 'validation');
      expect(
        score('S10', AgentTrace.fromJson(missing))['status'],
        isNot('pass'),
      );
      final exposed = object(jsonDecode(jsonEncode(trace.data)));
      final shown = (exposed['events'] as List).singleWhere(
        (e) => e['kind'] == 'tool' && e['name'] == 'query_schedule',
      );
      shown['result']['data']['items'][0]['start_minute'] = 540;
      expect(
        score('S10', AgentTrace.fromJson(exposed))['status'],
        isNot('pass'),
      );
    },
  );

  test(
    'S20 real oversized tool result stops and exact server boundaries reject',
    () async {
      final trace = await driver.run(scenario('S20'));
      expect(trace, isNotNull);
      expect(trace!.events.last['reason'], 'size');
      expect(
        score('S20', trace)['status'],
        'pass',
        reason: jsonEncode({
          'score': score('S20', trace),
          'diagnostics': driver.diagnostics['S20'],
          'events': trace.events
              .map(
                (e) => {
                  'kind': e['kind'],
                  'bytes': e['bytes'],
                  'reason': e['reason'],
                },
              )
              .toList(),
        }),
      );
      final tool = trace.events.singleWhere((e) => e['kind'] == 'tool');
      expect(tool['sent'], false);
      expect(
        utf8.encode(jsonEncode(tool['result'])).length,
        greaterThan(64000),
      );
      final rejected = trace.events.singleWhere(
        (e) => e['kind'] == 'model' && e['dispatched'] == false,
      );
      expect(rejected['bytes'], greaterThan(64000));
      final probes = trace.events
          .where((e) => e['kind'] == 'size_probe')
          .toList();
      expect(probes.map((e) => e['bytes']), [63999, 64000, 64001]);
      expect(probes.map((e) => e['code']), [
        'run_token_limit',
        'model_request_too_large',
        'model_request_too_large',
      ]);
      expect(probes.every((e) => e['model_calls'] == 0), true);
      expect(driver.diagnostics['S20']!['wire_calls'], 1);
      expect(trace.events.where((e) => e['kind'] == 'write'), isEmpty);
      expect(trace.events.last['reason'], 'size');
      final mutated = object(jsonDecode(jsonEncode(trace.data)));
      final events = (mutated['events'] as List).cast<Map>();
      events.singleWhere(
        (e) => e['kind'] == 'size_probe' && e['bytes'] == 64000,
      )['code'] = 'run_token_limit';
      expect(score('S20', AgentTrace.fromJson(mutated))['status'], 'fail');
    },
  );
}
