import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:xingyuan_assistant_eval/agent_eval/budget.dart';
import 'package:xingyuan_assistant_eval/agent_eval/fixtures.dart';
import 'package:xingyuan_assistant_eval/agent_eval/live_gate.dart';
import 'package:xingyuan_assistant_eval/agent_eval/report.dart';
import 'package:xingyuan_server/src/model_client.dart';

import '../tool/agent_eval/app_driver.dart';
import '../tool/agent_eval/run_preparation.dart';
import 'support/agent_c30_replies.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);
  for (final sequence in c30Sequences.keys) {
    for (final variant in [
      'question',
      'mixed_submit',
      'plain_text',
      'bad_arguments',
    ]) {
      test('$sequence fake three-turn App path $variant', () async {
        final dir = Directory.systemTemp.createTempSync('c30-app-synthetic-');
        final budget = EvaluationBudget.claim('${dir.path}/budget.sqlite');
        final relay = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() async {
          await relay.close(force: true);
          budget.close();
          dir.deleteSync(recursive: true);
        });
        var requests = 0;
        relay.listen((request) async {
          await request.drain<void>();
          requests++;
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode(c30Reply(sequence, requests, variant)),
          );
          await request.response.close();
        });
        // This disposable fake-digest gate cannot authorize any real product.
        final marker = File('${dir.path}/fake-gate.json')
          ..writeAsStringSync(
            jsonEncode({
              'id': 'synthetic-c30-offline-only',
              'scope': 'xingyuan-agent-a4-synthetic',
              'owner_authorized': true,
              'max_calls': 6,
              'expires_at': '2099-01-01T00:00:00Z',
              'endpoint': agentRelay,
              'product_digest': 'synthetic-not-a-product-digest',
            }),
          );
        expect((await Process.run('chmod', ['600', marker.path])).exitCode, 0);
        final driver = AppAgentEvaluationDriver(
          metadata: driverMetadata(
            Directory.current.path,
            live: false,
            fixtureVersion: sequence == 'R2-S05'
                ? 'agent-c26-v2'
                : 'agent-c26-v3',
          ),
          output: dir,
          budget: budget,
          permit: LivePermit.read(
            live: true,
            marker: marker.path,
            productDigest: 'synthetic-not-a-product-digest',
          ),
          liveClient: AssistantModelClient(
            endpoint: Uri.parse(
              'http://127.0.0.1:${relay.port}/v1/chat/completions',
            ),
            apiKey: 'synthetic-only',
          ),
        );
        final scenario = parseAgentScenarios(
          File(
            'tool/assistant_eval/fixtures/${sequence == 'R2-S05' ? 'agent_scenarios.json' : 'agent_scenarios_v3.json'}',
          ).readAsStringSync(),
        ).singleWhere((s) => s.id == sequence.split('-')[1]);
        final report = await evaluateAgentRun([scenario], driver);
        final trace = driver.traces.single;
        final row = object((report['cases'] as List).single);
        final tools = trace.events.where((e) => e['kind'] == 'tool').toList();
        expect(tools.take(2).map((e) => e['name']), c30Sequences[sequence]);
        expect(
          tools.take(2).map((e) => e['status']),
          sequence == 'R3-S06' ? ['partial', 'ok'] : ['ok', 'ok'],
        );
        expect(requests, 3);
        expect(budget.used, 3);
        expect(row['formal_writes'], 0);
        expect(trace.data['protected_before'], trace.data['protected_after']);
        if (variant == 'plain_text' || variant == 'bad_arguments') {
          final detail = variant == 'plain_text'
              ? 'content_json'
              : 'arguments_json';
          final stops = (row['rejection_observations'] as List)
              .map(object)
              .toList();
          expect(stops.map((e) => e['detail']), [detail, detail, detail]);
          expect(stops.map((e) => e['layer']), [
            'model_response',
            'backend_response',
            'app_loop',
          ]);
          expect(agentReportMarkdown(report), contains(detail));
          expect(
            trace.events.lastWhere((e) => e['kind'] == 'terminal')['status'],
            'stopped',
          );
        } else {
          expect(row['rejection_observations'], isEmpty);
          expect(
            trace.events.lastWhere((e) => e['kind'] == 'terminal')['status'],
            variant == 'mixed_submit' ? 'draft' : 'needs_input',
          );
        }
        for (final value in [report, trace.data, driver.diagnostics]) {
          expect(
            jsonEncode(value),
            isNot(contains('PRIVATE_C30_REJECTED_BODY')),
          );
          expect(
            jsonEncode(value),
            isNot(contains('SYNTHETIC_IGNORED_TOOL_COMMENTARY')),
          );
          expect(jsonEncode(value), isNot(contains('SYNTHETIC_IGNORED_EXTRA')));
        }
      });
    }
  }
}
