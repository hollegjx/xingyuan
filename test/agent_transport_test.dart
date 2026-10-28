import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/assistant/data/assistant_service.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

import 'support/scripted_agent_service.dart';

AgentRequest request([String content = 'TEST synthetic']) =>
    AgentRequest.fromJson({
      'protocol': agentProtocol,
      'request_id': 'test_request',
      'run_id': null,
      'turn': 1,
      'now': {
        'date': '2026-10-28',
        'time': '12:00',
        'weekday': 3,
        'time_zone': 'Asia/Shanghai',
      },
      'messages': [
        {'role': 'user', 'content': content},
      ],
    });
AgentRequest sized(int bytes) {
  final base = utf8.encode(jsonEncode(request('x').toJson())).length - 1;
  final count = bytes - base;
  return request('测' * (count ~/ 3) + 'x' * (count % 3));
}

void main() {
  late HttpServer server;
  late HttpAssistantService service;
  late int credentialReads;
  late int received;
  late Future<void> Function(HttpRequest) respond;
  final access = AssistantAccess(
    consentVersion: assistantConsentVersion,
    isCurrent: () async => true,
  );
  setUp(() async {
    credentialReads = 0;
    received = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    respond = (incoming) async {
      final parsed = AgentRequest.fromJson(
        jsonDecode(await utf8.decoder.bind(incoming).join()),
      );
      incoming.response.write(jsonEncode(agentResponse(parsed)));
      await incoming.response.close();
    };
    server.listen((incoming) async {
      received++;
      await respond(incoming);
    });
    service = HttpAssistantService(
      endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
      allowInsecureLoopback: true,
      readCredential: () async {
        credentialReads++;
        return 't' * 43;
      },
    );
  });
  tearDown(() => server.close(force: true));

  test('63999 multibyte body sent exactly; this transport check is not server token-budget proof', () async {
    final value = sized(63999);
    respond = (incoming) async {
      final bytes = await incoming.fold(
        <int>[],
        (all, chunk) => all..addAll(chunk),
      );
      expect(bytes, utf8.encode(jsonEncode(value.toJson())));
      expect(bytes, hasLength(63999));
      expect(incoming.uri.path, '/v1/agent/turn');
      incoming.response.write(jsonEncode(agentResponse(value)));
      await incoming.response.close();
    };
    expect(
      (await service.agentTurn(
        value,
        access: access,
        cancellation: AssistantCancellation(),
      )).text,
      'TEST answer',
    );
    expect(received, 1);
    expect(credentialReads, 1);
  });
  for (final bytes in [64000, 64001]) {
    test('$bytes bytes rejected before credential read or network', () async {
      final value = sized(bytes);
      expect(utf8.encode(jsonEncode(value.toJson())), hasLength(bytes));
      await expectLater(
        service.agentTurn(
          value,
          access: access,
          cancellation: AssistantCancellation(),
        ),
        throwsA(
          isA<AssistantFailure>().having(
            (e) => e.kind,
            'kind',
            AssistantFailureKind.tooLarge,
          ),
        ),
      );
      expect(received, 0);
      expect(credentialReads, 0);
    });
  }
  test(
    'cancel closes owned connection and ignores its late response',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      respond = (incoming) async {
        await incoming.drain<void>();
        entered.complete();
        await release.future;
        try {
          incoming.response.write(jsonEncode(agentResponse(request())));
          await incoming.response.close();
        } catch (_) {}
      };
      final cancellation = AssistantCancellation();
      final result = service.agentTurn(
        request(),
        access: access,
        cancellation: cancellation,
      );
      final checked = expectLater(result, throwsA(isA<AssistantFailure>()));
      await entered.future;
      cancellation.cancel();
      await checked;
      release.complete();
      expect(received, 1);
    },
  );
  test('restart and quota rejection expose only a typed stop code', () async {
    for (final code in ['run_restart_required', 'daily_run_limit']) {
      respond = (incoming) async {
        await incoming.drain<void>();
        incoming.response.statusCode = 409;
        incoming.response.write(
          jsonEncode({
            'protocol': agentProtocol,
            'kind': 'stopped',
            'code': code,
          }),
        );
        await incoming.response.close();
      };
      await expectLater(
        service.agentTurn(
          request(),
          access: access,
          cancellation: AssistantCancellation(),
        ),
        throwsA(isA<AgentServiceStopped>().having((e) => e.code, 'code', code)),
      );
    }
    expect(received, 2);
  });
  test('response64000 is rejected and redirects are not followed', () async {
    respond = (incoming) async {
      await incoming.drain<void>();
      final encoded = jsonEncode(agentResponse(request()));
      incoming.response.write(
        encoded + ' ' * (64000 - utf8.encode(encoded).length),
      );
      await incoming.response.close();
    };
    await expectLater(
      service.agentTurn(
        request(),
        access: access,
        cancellation: AssistantCancellation(),
      ),
      throwsA(isA<AssistantFailure>()),
    );
    respond = (incoming) async {
      await incoming.drain<void>();
      incoming.response.statusCode = 302;
      incoming.response.headers.set(
        'location',
        'http://127.0.0.1:${server.port}/elsewhere',
      );
      await incoming.response.close();
    };
    await expectLater(
      service.agentTurn(
        request(),
        access: access,
        cancellation: AssistantCancellation(),
      ),
      throwsA(isA<AssistantFailure>()),
    );
    expect(received, 2);
  });
}
