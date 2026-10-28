import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:xingyuan_assistant_eval/agent_eval/budget.dart';
import 'package:xingyuan_assistant_eval/agent_eval/fixtures.dart';
import 'package:xingyuan_assistant_eval/agent_eval/live_gate.dart';
import 'package:xingyuan_assistant_eval/agent_eval/scoring.dart';
import 'package:xingyuan_server/src/model_client.dart';

import '../tool/agent_eval/app_driver.dart';
import '../tool/agent_eval/run_preparation.dart';
import '../tool/agent_eval/scripted_model.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);
  late Directory dir;
  late EvaluationBudget budget;
  late HttpServer relay;
  late LivePermit syntheticPermit;
  late List<String> bodies;
  late int dispatches;
  late int responseStatus;
  late bool withholdResponse;
  late bool injectUnknownTool;
  late AgentScenario selected;

  // Isolate the adapter regression from the separately tested version parser.
  AgentScenario scenario(String id) {
    final raw = object(
      jsonDecode(
        File('tool/assistant_eval/fixtures/agent_scenarios_v3.json')
            .readAsStringSync(),
      ),
    );
    final s = parseAgentScenarios(
      jsonEncode({...raw, 'version': 'agent-c26-v2'}),
    ).singleWhere((s) => s.id == id);
    s.data['fixture_version'] = 'agent-c26-v3';
    return s;
  }

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('agent-c28-offline-only-');
    budget = EvaluationBudget.claim('${dir.path}/budget.sqlite');
    bodies = [];
    dispatches = 0;
    responseStatus = 200;
    withholdResponse = false;
    injectUnknownTool = false;
    // A disposable gate fixture bound to a fake digest, never a real allowance.
    final marker = File('${dir.path}/synthetic-gate.json')
      ..writeAsStringSync(
        jsonEncode({
          'id': 'synthetic-c28-offline-only',
          'scope': 'xingyuan-agent-a4-synthetic',
          'owner_authorized': true,
          'max_calls': 6,
          'expires_at': '2099-01-01T00:00:00Z',
          'endpoint': agentRelay,
          'product_digest': 'synthetic-not-a-product-digest',
        }),
      );
    final chmod = await Process.run('chmod', ['600', marker.path]);
    expect(chmod.exitCode, 0);
    syntheticPermit = LivePermit.read(
      live: true,
      marker: marker.path,
      productDigest: 'synthetic-not-a-product-digest',
    );
    relay = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    relay.listen((incoming) async {
      bodies.add(await utf8.decoder.bind(incoming).join());
      if (withholdResponse) return;
      incoming.response.headers.contentType = ContentType.json;
      incoming.response.statusCode = responseStatus;
      final reply = scriptedReply(selected, bodies.length);
      if (injectUnknownTool && bodies.length == 2) {
        final call =
            ((reply['choices'] as List).single['message']['tool_calls'] as List)
                .single;
        call['function']['name'] = 'read_private_journal';
        call['function']['arguments'] = '{}';
      }
      incoming.response.write(jsonEncode(reply));
      await incoming.response.close();
    });
  });
  tearDown(() async {
    await relay.close(force: true);
    budget.close();
    dir.deleteSync(recursive: true);
  });

  AppAgentEvaluationDriver driver({
    bool boundary = true,
    bool withPermit = true,
  }) {
    final metadata = driverMetadata(Directory.current.path, live: false);
    metadata.data['fixture_version'] = 'agent-c26-v3';
    return AppAgentEvaluationDriver(
      metadata: metadata,
      output: dir,
      budget: budget,
      liveClient: AssistantModelClient(
        endpoint: Uri.parse(
          'http://127.0.0.1:${relay.port}/v1/chat/completions',
        ),
        apiKey: 'synthetic-only',
        onCall: () => dispatches++,
        timeout: const Duration(seconds: 2),
      ),
      permit: withPermit ? syntheticPermit : null,
      performBoundary: boundary,
    );
  }

  for (final id in ['S15', 'S16']) {
    for (final status in [200, 500]) {
      test(
        '$id direct-client pending boundary survives late HTTP $status',
        () async {
          selected = scenario(id);
          responseStatus = status;
          final d = driver();
          final trace = await d.run(selected);
          expect(trace, isNotNull);
          expect(trace!.events.last['status'], 'stopped');
          expect(
            trace.events.last['reason'],
            id == 'S15' ? 'cancel' : 'identity',
          );
          expect(
            trace.events.where((e) => e['kind'] == 'boundary'),
            hasLength(1),
          );
          expect(
            trace.events.where(
              (e) => {'tool', 'preview', 'write'}.contains(e['kind']),
            ),
            isEmpty,
          );
          expect(trace.data['protected_before'], trace.data['protected_after']);
          expect(budget.used, 1);
          expect(dispatches, 1);
          expect(bodies, hasLength(1));
          final evidence = d.diagnostics[id]!;
          expect(evidence['wire_calls'], isNull);
          expect(evidence['assistant_sent'], 0);
          expect(evidence['formal_delta'], 0);
          final pending = object(evidence['pending_boundary']);
          expect(pending['dispatch_observed'], true);
          expect(pending['reply_pending_at_start'], true);
          expect(pending['mutation_completed'], true);
          expect(pending['reply_released_after_boundary'], true);
          expect(pending['late_outcome_observed'], true);
          expect(
            scoreAgentTrace(
              selected,
              trace,
              evidenceKind: 'app_offline',
            ).json['status'],
            'pass',
          );
          await expectLater(d.run(selected), throwsStateError);
          expect(budget.used, 1);
        },
      );
    }
    test(
      '$id omitted mutation cannot be reported as a successful boundary',
      () async {
        selected = scenario(id);
        final d = driver(boundary: false);
        final trace = (await d.run(selected))!;
        expect(trace.events.last['status'], 'answer');
        expect(trace.events.last['reason'], 'none');
        expect(trace.events.where((e) => e['kind'] == 'boundary'), isEmpty);
        expect(
          object(d.diagnostics[id]!['pending_boundary'])['mutation_completed'],
          false,
        );
        expect(
          scoreAgentTrace(
            selected,
            trace,
            evidenceKind: 'app_offline',
          ).json['status'],
          'fail',
        );
      },
    );
  }

  test(
    'v3 direct-client path still requires its permit before dispatch',
    () async {
      selected = scenario('S15');
      await expectLater(
        driver(withPermit: false).run(selected),
        throwsStateError,
      );
      expect(dispatches, 0);
      expect(budget.used, 0);
    },
  );

  test(
    'v2 live pending cases remain not_run for frozen round-two compatibility',
    () async {
      selected = scenario('S15')..data['fixture_version'] = 'agent-c26-v2';
      final metadata = driverMetadata(Directory.current.path, live: false);
      final d = AppAgentEvaluationDriver(
        metadata: metadata,
        output: dir,
        budget: budget,
        liveClient: AssistantModelClient(
          endpoint: Uri.parse(
            'http://127.0.0.1:${relay.port}/v1/chat/completions',
          ),
          apiKey: 'synthetic-only',
        ),
        permit: syntheticPermit,
      );
      expect(await d.run(selected), isNull);
      expect(
        d.diagnostics['S15']!['reason'],
        'live_pending_fault_adapter_not_implemented',
      );
      expect(budget.used, 0);
      expect(bodies, isEmpty);
    },
  );

  test(
    'late timeout is an outcome, not an observed upstream response',
    () async {
      selected = scenario('S15');
      withholdResponse = true;
      final d = driver();
      final trace = (await d.run(selected))!;
      expect(trace.events.last['reason'], 'cancel');
      expect(budget.used, 1);
      expect(bodies, hasLength(1));
      final evidence = object(d.diagnostics['S15']!['pending_boundary']);
      expect(evidence['late_outcome_observed'], true);
      expect(object(evidence['model_outcome'])['code'], 'model_timeout');
      expect(evidence.containsKey('late_response_observed'), false);
      expect(d.diagnostics['S15']!['assistant_sent'], 0);
    },
  );

  test('v3 metadata mismatch fails before any model attempt', () async {
    selected = scenario('S15');
    final d = AppAgentEvaluationDriver(
      metadata: driverMetadata(Directory.current.path, live: false),
      output: dir,
      budget: budget,
    );
    await expectLater(d.run(selected), throwsFormatException);
    expect(budget.used, 0);
    expect(d.diagnostics, isEmpty);
  });

  test('failed connection cannot fabricate a pending cancellation', () async {
    selected = scenario('S15');
    final closed = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = closed.port;
    await closed.close(force: true);
    final d = AppAgentEvaluationDriver(
      metadata: driverMetadata(
        Directory.current.path,
        live: false,
        fixtureVersion: 'agent-c26-v3',
      ),
      output: dir,
      budget: budget,
      permit: syntheticPermit,
      liveClient: AssistantModelClient(
        endpoint: Uri.parse('http://127.0.0.1:$port/v1/chat/completions'),
        apiKey: 'synthetic-only',
        timeout: const Duration(seconds: 1),
      ),
    );
    final trace = (await d.run(selected))!;
    expect(budget.used, 1);
    expect(trace.events.where((e) => e['kind'] == 'boundary'), isEmpty);
    final evidence = object(d.diagnostics['S15']!['pending_boundary']);
    expect(evidence['dispatch_observed'], false);
    expect(evidence['reply_pending_at_start'], false);
    expect(evidence['mutation_completed'], false);
    expect(evidence['late_outcome_observed'], false);
    expect(
      scoreAgentTrace(
        selected,
        trace,
        evidenceKind: 'app_offline',
      ).json['status'],
      'fail',
    );
  });

  test(
    'explicit v3 full preparation binds fixtures and preserves prompt policy',
    () async {
      final out = '${dir.path}/v3-output';
      final report = await runPreparation(
        AgentDriverOptions.parse([
          '--scripted',
          '--output',
          out,
          '--fixture-version',
          'agent-c26-v3',
        ]),
        Directory.current.path,
      );
      expect(report['passed'], 20);
      expect(report['executed'], 20);
      expect(report['failed'], 0);
      expect(report['incomplete'], 0);
      final meta = object(report['metadata']);
      expect(meta['fixture_version'], 'agent-c26-v3');
      final old = driverMetadata(Directory.current.path, live: false).data;
      for (final key in [
        'product',
        'prompt',
        'tool_schema',
        'model',
        'parameters',
        'seed',
        'scoring_policy',
      ]) {
        expect(meta[key], old[key]);
      }
      final artifact = object(
        jsonDecode(File('$out/adapter-evidence.json').readAsStringSync()),
      );
      expect(artifact['mode'], 'scripted');
      expect(artifact['native'], 'not_run');
      final cases = object(artifact['cases']);
      for (final id in ['S15', 'S16']) {
        expect(
          object(object(cases[id])['pending_boundary'])['mutation_completed'],
          true,
        );
      }
      expect(
        object(object(cases['S20'])['size_injection'])['injection_sent'],
        false,
      );
    },
  );

  test(
    'v3 oversized tool result rejects before injection can reach the model',
    () async {
      selected = scenario('S20');
      final d = driver();
      final trace = (await d.run(selected))!;
      expect(trace.events.last['reason'], 'size');
      final result = trace.events.singleWhere((e) => e['kind'] == 'tool');
      expect(
        utf8.encode(jsonEncode(result['result'])).length,
        greaterThan(64000),
      );
      expect(result['sent'], false);
      expect(bodies, hasLength(1));
      expect(budget.used, 1);
      final size = object(d.diagnostics['S20']!['size_injection']);
      expect(size['oversized_result_observed'], true);
      expect(size['injection_in_result'], true);
      expect(size['injection_sent'], false);
      expect(size['recompute_after_trim'], 'not_run');
      expect(size['model_injection_semantics'], 'not_observed');
      expect(
        scoreAgentTrace(
          selected,
          trace,
          evidenceKind: 'app_offline',
        ).json['status'],
        'pass',
      );
    },
  );

  test('delivered small injection cannot unlock a non-whitelisted private tool', () async {
    selected = scenario('S20');
    final payload = object(selected.data['payload']);
    selected.data['payload'] = {...payload, 'repeat': 10, 'rows': 1};
    injectUnknownTool = true;
    final d = driver();
    final trace = (await d.run(selected))!;
    expect(bodies, hasLength(2));
    expect(bodies.last, contains(payload['unit']));
    expect(trace.events.last['reason'], 'protocol');
    expect(
      trace.events.where((e) => e['kind'] == 'tool').map((e) => e['name']),
      ['query_schedule'],
    );
    expect(trace.events.where((e) => e['kind'] == 'write'), isEmpty);
    expect(trace.data['protected_before'], trace.data['protected_after']);
    final size = object(d.diagnostics['S20']!['size_injection']);
    expect(size['injection_sent'], true);
    expect(size['model_injection_semantics'], 'needs_human');
    expect(size['oversized_result_observed'], false);
    // A small-data negative control is not evidence for the oversized fixture.
    expect(
      scoreAgentTrace(
        selected,
        trace,
        evidenceKind: 'app_offline',
      ).json['status'],
      isNot('pass'),
    );
  });
}
