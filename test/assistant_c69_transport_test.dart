import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/assistant/data/assistant_service.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

import 'support/scripted_agent_service.dart';

void main() {
  late HttpServer server;
  late HttpAssistantService service;
  late Future<void> Function(HttpRequest) handle;
  final access = AssistantAccess(
    consentVersion: assistantConsentVersion,
    isCurrent: () async => true,
  );
  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    handle = (r) async {
      r.response.statusCode = 404;
      await r.response.close();
    };
    server.listen((r) => handle(r));
    service = HttpAssistantService(
      endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
      allowInsecureLoopback: true,
      readCredential: () async => 't' * 43,
    );
  });
  tearDown(() => server.close(force: true));
  test('probe is authenticated GET with exactly zero body, then v2 response validated', () async {
    final seen = <String>[];
    handle = (r) async {
      seen.add(r.uri.path);
      expect(
        r.headers.value(HttpHeaders.authorizationHeader),
        'Bearer ${'t' * 43}',
      );
      final body = await utf8.decoder.bind(r).join();
      if (r.uri.path.endsWith('capabilities')) {
        expect(r.method, 'GET');
        expect(body, isEmpty);
        r.response.write(
          jsonEncode({
            'protocol': assistantAgentProtocol,
            'tools': assistantAgentTools,
          }),
        );
      } else {
        expect(r.uri.path, '/v2/agent/turn');
        final request = AssistantAgentRequest.fromJson(jsonDecode(body));
        r.response.write(
          jsonEncode({
            ...agentResponse(request),
            'protocol': assistantAgentProtocol,
          }),
        );
      }
      await r.response.close();
    };
    expect(
      await service.supportsAssistantTools(
        access: access,
        cancellation: AssistantCancellation(),
      ),
      isTrue,
    );
    final request = AssistantAgentRequest.fromJson({
      'protocol': assistantAgentProtocol,
      'request_id': 'synthetic',
      'run_id': null,
      'turn': 1,
      'now': {
        'date': '2026-11-01',
        'weekday': 7,
        'time': '12:00',
        'time_zone': 'Asia/Shanghai',
      },
      'messages': [
        {'role': 'user', 'content': 'TEST synthetic'},
      ],
    });
    expect(
      (await service.agentTurn(
        request,
        access: access,
        cancellation: AssistantCancellation(),
      )).text,
      'TEST answer',
    );
    expect(seen, ['/v2/agent/capabilities', '/v2/agent/turn']);
  });
  test(
    '404 and malformed capability both return unsupported, with no cache',
    () async {
      expect(
        await service.supportsAssistantTools(
          access: access,
          cancellation: AssistantCancellation(),
        ),
        isFalse,
      );
      handle = (r) async {
        expect(await utf8.decoder.bind(r).join(), isEmpty);
        r.response.write(
          jsonEncode({
            'protocol': assistantAgentProtocol,
            'tools': ['get_journal_text'],
          }),
        );
        await r.response.close();
      };
      expect(
        await service.supportsAssistantTools(
          access: access,
          cancellation: AssistantCancellation(),
        ),
        isFalse,
      );
    },
  );
  test(
    'revoked access and cancellation do not become silent fallback',
    () async {
      await expectLater(
        service.supportsAssistantTools(
          access: AssistantAccess(
            consentVersion: assistantConsentVersion,
            isCurrent: () async => false,
          ),
          cancellation: AssistantCancellation(),
        ),
        throwsA(
          isA<AssistantFailure>().having(
            (e) => e.kind,
            'kind',
            AssistantFailureKind.discarded,
          ),
        ),
      );
      final cancellation = AssistantCancellation()..cancel();
      await expectLater(
        service.supportsAssistantTools(
          access: access,
          cancellation: cancellation,
        ),
        throwsA(
          isA<AssistantFailure>().having(
            (e) => e.kind,
            'kind',
            AssistantFailureKind.cancelled,
          ),
        ),
      );
    },
  );
  test(
    'capability timeout falls back and closes the no-body request',
    () async {
      service = HttpAssistantService(
        endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
        allowInsecureLoopback: true,
        readCredential: () async => 't' * 43,
        timeout: const Duration(milliseconds: 40),
      );
      handle = (r) async {
        expect(await utf8.decoder.bind(r).join(), isEmpty);
      };
      expect(
        await service.supportsAssistantTools(
          access: access,
          cancellation: AssistantCancellation(),
        ),
        isFalse,
      );
    },
  );
}
