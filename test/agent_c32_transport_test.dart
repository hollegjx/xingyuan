import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/assistant/data/assistant_service.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

import 'support/scripted_agent_service.dart';

AgentRequest _request() => AgentRequest.fromJson({
  'protocol': agentProtocol,
  'request_id': 'test_c32',
  'run_id': null,
  'turn': 1,
  'now': {
    'date': '2026-10-29',
    'time': '10:00',
    'weekday': 4,
    'time_zone': 'Asia/Shanghai',
  },
  'messages': [
    {'role': 'user', 'content': 'TEST synthetic timeout'},
  ],
});

void main() {
  test(
    'C32 openUrl TLS handshake stall is bounded without sending HTTP',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final connected = Completer<void>();
      final sockets = <Socket>[];
      var connections = 0;
      server.listen((socket) {
        sockets.add(socket);
        connections++;
        if (!connected.isCompleted) connected.complete();
        socket.listen((_) {}, onError: (Object _) {});
      });
      final service = HttpAssistantService(
        endpoint: Uri.parse('https://127.0.0.1:${server.port}'),
        readCredential: () async => 't' * 43,
        timeout: const Duration(milliseconds: 250),
      );
      final result = service
          .agentTurn(
            _request(),
            access: AssistantAccess(
              consentVersion: assistantConsentVersion,
              isCurrent: () async => true,
            ),
            cancellation: AssistantCancellation(),
          )
          .then<Object>((value) => value, onError: (Object error) => error);
      try {
        await connected.future.timeout(const Duration(seconds: 2));
        expect(
          await result.timeout(const Duration(seconds: 2)),
          isA<AssistantFailure>().having(
            (error) => error.kind,
            'kind',
            AssistantFailureKind.timeout,
          ),
        );
        expect(connections, 1);
      } finally {
        for (final socket in sockets) {
          socket.destroy();
        }
        await server.close();
      }
    },
  );

  for (final boundary in [
    'access_1',
    'credential',
    'access_2',
    'access_3',
    'headers',
    'body',
    'access_4',
  ]) {
    test('C32 HTTP $boundary timeout stops and rejects late work', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final entered = Completer<void>();
      final release = Completer<void>();
      var received = 0;
      var credentialReads = 0;
      var accessChecks = 0;
      Future<void> wait() async {
        if (!entered.isCompleted) entered.complete();
        await release.future;
      }

      server.listen((incoming) async {
        received++;
        await incoming.drain<void>();
        try {
          if (boundary == 'headers') await wait();
          if (boundary == 'body') {
            incoming.response.write(' ');
            await incoming.response.flush();
            await wait();
          }
          incoming.response.write(jsonEncode(agentResponse(_request())));
          await incoming.response.close();
        } catch (_) {
          // The real client closes its owned socket after timeout.
        }
      });
      final service = HttpAssistantService(
        endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
        allowInsecureLoopback: true,
        timeout: const Duration(milliseconds: 250),
        readCredential: () async {
          credentialReads++;
          if (boundary == 'credential') await wait();
          return 't' * 43;
        },
      );
      final access = AssistantAccess(
        consentVersion: assistantConsentVersion,
        isCurrent: () async {
          accessChecks++;
          if (boundary == 'access_$accessChecks') await wait();
          return true;
        },
      );
      final clock = Stopwatch()..start();
      final result = service
          .agentTurn(
            _request(),
            access: access,
            cancellation: AssistantCancellation(),
          )
          .then<Object>((value) => value, onError: (Object error) => error);
      try {
        await entered.future.timeout(const Duration(seconds: 2));
        expect(
          await result,
          isA<AssistantFailure>().having(
            (error) => error.kind,
            'kind',
            AssistantFailureKind.timeout,
          ),
        );
        expect(clock.elapsed, lessThan(const Duration(seconds: 2)));
        final requestsAtTimeout = received;
        release.complete();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(received, requestsAtTimeout);
        expect(
          received,
          boundary == 'headers' || boundary == 'body' || boundary == 'access_4'
              ? 1
              : 0,
        );
        expect(credentialReads, boundary == 'access_1' ? 0 : 1);
      } finally {
        if (!release.isCompleted) release.complete();
        await server.close(force: true);
      }
    });
  }
}
