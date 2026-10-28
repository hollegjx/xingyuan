import 'dart:convert';
import 'dart:io';

import 'package:xingyuan_assistant_eval/agent_eval/budget.dart';
import 'package:xingyuan_assistant_eval/agent_eval/fixtures.dart';
import 'package:xingyuan_server/src/agent_ledger.dart';
import 'package:xingyuan_server/src/agent_protocol.dart';
import 'package:xingyuan_server/src/agent_runner.dart';

/// Isolated server guard probes, not additional turns of the App trajectory.
Future<List<Json>> probeAgentBodyBoundaries(
  Directory output,
  EvaluationBudget budget,
) async {
  final ledger = AgentLedger.open('${output.path}/size-probes.sqlite');
  final results = <Json>[];
  try {
    for (final bytes in [63999, 64000, 64001]) {
      final json = <String, dynamic>{
        'protocol': agentProtocol,
        'request_id': 'synthetic_size_$bytes',
        'run_id': null,
        'turn': 1,
        'now': {
          'date': '2026-10-27',
          'time': '08:00',
          'weekday': 2,
          'time_zone': 'Asia/Shanghai',
        },
        'messages': [
          {'role': 'user', 'content': '合成中文🌟'},
        ],
      };
      final base = AgentRequest.fromJson(json);
      final extra = bytes - utf8.encode(agentModelBody(base)).length;
      if (extra < 0) throw StateError('Boundary below protocol overhead');
      (json['messages'] as List).single['content'] =
          '合成中文🌟${'界' * (extra ~/ 3)}${'x' * (extra % 3)}';
      final request = AgentRequest.fromJson(json);
      final measured = utf8.encode(agentModelBody(request)).length;
      if (measured != bytes) throw StateError('Incorrect byte fixture');
      var calls = 0;
      var code = 'unexpected_acceptance';
      final runner = AgentRunner(
        ledger: ledger,
        transport: (body, request, remaining) async {
          // A regression can only reach this fake transport, never a live endpoint.
          final attempt = budget.reserve(
            'S20',
            request.turn,
            utf8.encode(body).length,
          );
          calls++;
          budget.settle(attempt, succeeded: false);
          return AgentModelReply(
            const AgentOutcome.stop('synthetic_probe'),
            AgentUsage.parse(null),
          );
        },
      );
      try {
        await runner.turn('synthetic-size-device', request);
      } on AgentFailure catch (error) {
        code = error.code;
      }
      results.add({
        'bytes': measured,
        'reservation': (measured + 1) ~/ 2 + agentOutputLimit,
        'code': code,
        'model_calls': calls,
        'layer': 'model_request',
      });
    }
    return results;
  } finally {
    ledger.close();
  }
}
