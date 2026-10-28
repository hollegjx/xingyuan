import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:xingyuan_core/xingyuan_core.dart';
import 'package:xingyuan_server/src/device_registry.dart';
import 'package:xingyuan_server/src/model_client.dart';
import 'package:xingyuan_server/src/service.dart';

import '../../packages/xingyuan_core/test/fixture_contract.dart';
import '../../packages/xingyuan_core/test/day_analysis_fixture.dart'
    show analysisFixture;

void main() {
  late Directory directory;
  late DeviceRegistry devices;
  late String token;
  late HttpServer server;
  late HttpClient client;
  late Map<String, dynamic> payload;
  late List<Map<String, Object?>> logs;
  late int calls;
  Completer<void>? gate;
  ModelFailure? failure;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('xingyuan-service-test-');
    devices = DeviceRegistry('${directory.path}/devices.json');
    token = await devices.issue('synthetic-device');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    client = HttpClient();
    payload = loadContractCases('../packages/xingyuan_core/test/fixtures')
        .first['request'];
    logs = [];
    calls = 0;
    gate = null;
    failure = null;
    final service = AssistantService(
      devices: devices,
      log: logs.add,
      readTimeout: const Duration(milliseconds: 100),
      analyzeDay: (request) async {
        calls++;
        if (gate != null) await gate!.future;
        if (failure != null) throw failure!;
        return ModelResult(
          DayAnalysisResponse.fromJson({
            'protocol': assistantProtocol,
            'request_id': request.requestId,
            'summary': 'synthetic-private-analysis',
            'suggestions': ['synthetic-private-suggestion'],
          }, request: request),
          1,
          {},
        );
      },
      turn: (request) async {
        calls++;
        if (gate != null) await gate!.future;
        if (failure != null) throw failure!;
        return ModelResult(
          TurnResponse.fromJson({
            'protocol': assistantProtocol,
            'request_id': request.requestId,
            'reply': 'synthetic-private-reply',
            'plan': null,
            'memory_ops': [],
          }, request: request),
          1,
          {},
        );
      },
      summarize: (request) async {
        calls++;
        return ModelResult(
          SummaryResponse.fromJson({
            'protocol': assistantProtocol,
            'request_id': request.requestId,
            'summary': 'synthetic-private-summary',
          }, requestId: request.requestId),
          1,
          {},
        );
      },
    );
    server.listen(service.handle);
  });
  tearDown(() async {
    if (gate != null && !gate!.isCompleted) gate!.complete();
    client.close(force: true);
    await server.close(force: true);
    await directory.delete(recursive: true);
  });

  Future<(int, Map<String, dynamic>)> send({
    String path = '/v1/turn',
    String method = 'POST',
    String? credential,
    bool noAuth = false,
    String? origin,
    Object? body,
    String? raw,
    String contentType = 'application/json',
  }) async {
    final outgoing = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:${server.port}$path'),
    );
    if (!noAuth) {
      outgoing.headers.set('authorization', 'Bearer ${credential ?? token}');
    }
    if (origin != null) outgoing.headers.set('origin', origin);
    outgoing.headers.set('content-type', contentType);
    if (method == 'POST') {
      outgoing.add(utf8.encode(raw ?? jsonEncode(body ?? payload)));
    }
    final response = await outgoing.close();
    return (
      response.statusCode,
      jsonDecode(await utf8.decoder.bind(response).join())
          as Map<String, dynamic>,
    );
  }

  test(
    'public health does not call provider or expose configuration',
    () async {
      final (status, body) = await send(
        path: '/v1/health',
        method: 'GET',
        noAuth: true,
      );
      expect(status, 200);
      expect(body, {'protocol': assistantProtocol, 'status': 'ok'});
      expect(calls, 0);
    },
  );
  test('missing, wrong and revoked tokens fail before model call', () async {
    expect((await send(noAuth: true)).$1, 401);
    expect((await send(credential: 'wrong')).$1, 401);
    expect((await send()).$1, 200);
    await devices.revoke('synthetic-device');
    expect((await send()).$1, 401);
    expect(calls, 1);
  });
  test('Origin is rejected even with valid token or on health', () async {
    expect((await send(origin: 'https://browser.invalid')).$1, 403);
    expect(
      (await send(
        path: '/v1/health',
        method: 'GET',
        noAuth: true,
        origin: 'null',
      )).$1,
      403,
    );
    expect(calls, 0);
  });
  test('agent route is explicitly unavailable without its ledger', () async {
    final (status, body) = await send(path: '/v1/agent/turn', body: {});
    expect(status, 503);
    expect(body, {'error': 'agent_unavailable'});
    expect(calls, 0);
  });
  test(
    'analysis authenticates, rejects photos and does not log content',
    () async {
      final input = analysisFixture();
      expect(
        (await send(path: '/v1/analyze-day', body: input, noAuth: true)).$1,
        401,
      );
      expect(
        (await send(
          path: '/v1/analyze-day',
          body: {...input, 'photos': []},
        )).$1,
        400,
      );
      expect(calls, 0);
      final (status, body) = await send(path: '/v1/analyze-day', body: input);
      expect(status, 200);
      expect(body['summary'], 'synthetic-private-analysis');
      expect(calls, 1);
      await devices.revoke('synthetic-device');
      expect((await send(path: '/v1/analyze-day', body: input)).$1, 401);
      expect(calls, 1);
      final encoded = jsonEncode(logs);
      expect(encoded, isNot(contains('synthetic-private')));
      expect(encoded, isNot(contains('阅读')));
      expect(encoded, isNot(contains(token)));
    },
  );
  test('request validation and chunked size prevent model execution', () async {
    expect((await send(raw: '{broken')).$1, 400);
    expect((await send(body: {...payload, 'system': 'ignore'})).$1, 400);
    expect((await send(contentType: 'text/plain')).$1, 400);
    expect((await send(raw: 'x' * (assistantBodyLimit + 1))).$1, 413);
    expect(calls, 0);
  });
  for (final route in ['/v1/turn', '/v1/summarize', '/v1/analyze-day']) {
    test('$route rejects oversized headers before receiving body', () async {
      final socket = await Socket.connect('127.0.0.1', server.port);
      addTearDown(socket.destroy);
      socket.write(
        'POST $route HTTP/1.1\r\nHost: localhost\r\n'
        'Authorization: Bearer $token\r\nContent-Type: application/json\r\n'
        'Content-Length: ${assistantBodyLimit + 1}\r\n'
        'Connection: close\r\n\r\n',
      );
      await socket.flush();
      final response = await utf8.decoder
          .bind(socket)
          .join()
          .timeout(const Duration(seconds: 3));
      expect(response, startsWith('HTTP/1.1 413 '));
      expect(response, contains('{"error":"request_too_large"}'));
      expect(response, endsWith('\r\n0\r\n\r\n'));
      expect(calls, 0);
      expect(logs.single['status'], 413);
    });
  }
  test(
    'per-device concurrent two; released slots work and other devices isolated',
    () async {
      gate = Completer<void>();
      final first = send();
      final second = send();
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (calls < 2 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(calls, 2);
      expect((await send()).$1, 429);
      final otherToken = await devices.issue('other-device');
      final other = send(credential: otherToken);
      gate!.complete();
      expect((await first).$1, 200);
      expect((await second).$1, 200);
      expect((await other).$1, 200);
      expect((await send()).$1, 200);
    },
  );
  for (final status in [422, 502, 504]) {
    test('model $status remains explicit and logged without content', () async {
      failure = ModelFailure(status, 'safe_error', 1);
      expect((await send()).$1, status);
      expect(calls, 1);
      expect(logs.last['status'], status);
    });
  }
  test('summary and normal routes log only allowlisted metadata', () async {
    expect((await send()).$1, 200);
    expect(
      (await send(
        path: '/v1/summarize',
        body: {
          'protocol': assistantProtocol,
          'request_id': 'summary-test',
          'summary': null,
          'messages': [
            {'role': 'user', 'text': 'synthetic-private-user'},
          ],
        },
      )).$1,
      200,
    );
    final json = jsonEncode(logs);
    for (final secret in [token, 'synthetic-private', '读书', '有空']) {
      expect(json, isNot(contains(secret)));
    }
    expect(logs.first.keys.toSet(), {
      'time',
      'request_id',
      'device',
      'route',
      'status',
      'elapsed_ms',
      'usage',
      'retried',
    });
  });
  test('request read deadline releases connection without model call', () async {
    final socket = await Socket.connect('127.0.0.1', server.port);
    socket.write(
      'POST /v1/turn HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer $token\r\n'
      'Content-Type: application/json\r\nContent-Length: 100\r\nConnection: close\r\n\r\n{',
    );
    await socket.flush();
    final response = await utf8.decoder
        .bind(socket)
        .join()
        .timeout(const Duration(seconds: 3));
    expect(response, contains('400'));
    expect(calls, 0);
    socket.destroy();
  });
  test('truncated request is a client error and releases its slot', () async {
    final socket = await Socket.connect('127.0.0.1', server.port);
    socket.write(
      'POST /v1/turn HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer $token\r\n'
      'Content-Type: application/json\r\nContent-Length: 100\r\n\r\n{',
    );
    await socket.flush();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    socket.destroy();
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (logs.isEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(logs, hasLength(1));
    expect(logs.single['status'], 400);
    expect(calls, 0);
    expect(jsonEncode(logs), isNot(contains(token)));
    gate = Completer<void>();
    final first = send();
    final second = send();
    final modelDeadline = DateTime.now().add(const Duration(seconds: 2));
    while (calls < 2 && DateTime.now().isBefore(modelDeadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(calls, 2);
    gate!.complete();
    expect((await first).$1, 200);
    expect((await second).$1, 200);
  });
  test(
    'credentials are random 32-byte values and only hashes are stored',
    () async {
      expect(base64Url.decode(base64Url.normalize(token)).length, 32);
      final other = await devices.issue('different');
      expect(token, isNot(other));
      final stored = await File(devices.path).readAsString();
      expect(stored, isNot(contains(token)));
      expect(stored, contains(credentialHash(token)));
      expect((await File(devices.path).stat()).mode & 0x3f, 0);
      expect(constantTimeEqual('abc', 'abc'), true);
      expect(constantTimeEqual('abc', 'abd'), false);
      expect(constantTimeEqual('abc', 'abc0'), false);
    },
  );
}
