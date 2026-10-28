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

void main() {
  setUpAll(tzdata.initializeTimeZones);
  const canary = 'PRIVATE_C29_REJECTED_RESPONSE';
  for (final category in [
    'multiple_tool_calls',
    'invalid_args',
    'refusal',
    'length',
    'upstream_error',
    'protocol_other',
  ]) {
    test(
      'fake rejected $category survives App to report without body',
      () async {
        final dir = Directory.systemTemp.createTempSync('c29-fake-rejection-');
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
          final call = {
            'id': 'synthetic-call',
            'type': 'function',
            'function': {
              'name': 'query_schedule',
              'arguments': '{"private":"$canary"}',
            },
          };
          final body = {
            'choices': [
              {
                'finish_reason': switch (category) {
                  'multiple_tool_calls' || 'invalid_args' => 'tool_calls',
                  'length' => 'length',
                  _ => 'stop',
                },
                'message': {
                  'role': 'assistant',
                  'content': canary,
                  if (category == 'refusal') 'refusal': canary,
                  if (category == 'multiple_tool_calls' ||
                      category == 'invalid_args')
                    'tool_calls': [
                      call,
                      if (category == 'multiple_tool_calls')
                        {...call, 'id': 'synthetic-second'},
                    ],
                },
              },
            ],
            'usage': {
              'prompt_tokens': 10,
              'completion_tokens': 10,
              'total_tokens': 20,
            },
          };
          request.response.statusCode = category == 'upstream_error'
              ? 503
              : 200;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode(body));
          await request.response.close();
        });
        final marker = File('${dir.path}/fake-gate.json')
          ..writeAsStringSync(
            jsonEncode({
              'id': 'synthetic-c29-offline-only',
              'scope': 'xingyuan-agent-a4-synthetic',
              'owner_authorized': true,
              'max_calls': 6,
              'expires_at': '2099-01-01T00:00:00Z',
              'endpoint': agentRelay,
              'product_digest': 'synthetic-not-a-product-digest',
            }),
          );
        expect((await Process.run('chmod', ['600', marker.path])).exitCode, 0);
        final d = AppAgentEvaluationDriver(
          metadata: driverMetadata(Directory.current.path, live: false),
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
          File('tool/assistant_eval/fixtures/agent_scenarios.json')
              .readAsStringSync(),
        ).first;
        final report = await evaluateAgentRun([scenario], d);
        final row = object((report['cases'] as List).single);
        expect(
          (row['rejection_observations'] as List)
              .map(object)
              .map((e) => e['category']),
          contains(category),
        );
        expect(agentReportMarkdown(report), contains(category));
        expect(jsonEncode(report), isNot(contains(canary)));
        expect(
          jsonEncode(d.traces.map((t) => t.data).toList()),
          isNot(contains(canary)),
        );
        expect(jsonEncode(d.diagnostics), isNot(contains(canary)));
        expect(requests, 1);
        expect(budget.used, 1);
        expect(row['formal_writes'], 0);
        expect(row['status'], isNot('pass'));
      },
    );
  }
}
