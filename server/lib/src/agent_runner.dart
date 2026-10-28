import 'dart:async';
import 'dart:convert';

import 'agent_ledger.dart';
import 'agent_protocol.dart';

typedef AgentTransport = Future<AgentModelReply> Function(
  String body,
  AgentRequest request,
  Duration remaining,
);

class AgentTurnResult {
  AgentTurnResult(this.body, this.usage, this.settlement);
  final Map<String, Object?> body;
  final Map<String, int> usage;
  final AgentSettlement settlement;
}

class AgentRunner {
  AgentRunner({required this.ledger, required this.transport});
  final AgentLedger ledger;
  final AgentTransport transport;

  Future<AgentTurnResult> turn(String device, AgentRequest request) async {
    final body = agentModelBody(request);
    final reservation = ledger.reserve(
      device,
      request,
      utf8.encode(body).length,
    );
    AgentModelReply reply;
    try {
      if (reservation.remaining <= Duration.zero) {
        reply = AgentModelReply(
          const AgentOutcome.stop('run_deadline'),
          AgentUsage.parse(null),
        );
      } else {
        reply = await transport(
          body,
          request,
          reservation.remaining,
        ).timeout(reservation.remaining);
      }
    } on TimeoutException {
      reply = AgentModelReply(
        const AgentOutcome.stop('model_timeout'),
        AgentUsage.parse(null),
      );
    } catch (_) {
      // No exception text from upstream or a transport can reach logs/clients.
      reply = AgentModelReply(
        const AgentOutcome.stop('model_connection'),
        AgentUsage.parse(null),
      );
    }
    final settled = ledger.finish(reservation, request, reply);
    return AgentTurnResult(
      {
        'protocol': agentProtocol,
        'request_id': request.requestId,
        'run_id': reservation.runId,
        'turn': settled.calls,
        ...settled.outcome.toJson(),
        'budget': {
          'calls': settled.calls,
          'charged_tokens': settled.tokens,
          'remaining_ms': settled.remainingMs,
          'violation': settled.violation,
        },
      },
      reply.usage.counts,
      settled,
    );
  }
}
