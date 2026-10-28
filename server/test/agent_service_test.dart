import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:xingyuan_server/src/agent_ledger.dart';
import 'package:xingyuan_server/src/agent_runner.dart';
import 'package:xingyuan_server/src/device_registry.dart';
import 'package:xingyuan_server/src/model_client.dart';
import 'package:xingyuan_server/src/service.dart';

import 'support/agent_fixtures.dart';

void main() {
  late Directory directory;
  late DeviceRegistry devices;
  late String token;
  late AgentLedger ledger;
  late HttpServer upstream;
  late HttpServer server;
  late HttpClient client;
  late List<Map<String, dynamic>> calls;
  late List<Map<String, Object?>> logs;
  late Future<void> Function(HttpRequest) handle;
  late int elapsed;
  Completer<void>? gate;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('xingyuan-agent-http-');
    devices = DeviceRegistry('${directory.path}/devices.json');
    token = await devices.issue('synthetic-device');
    elapsed = 0;
    ledger = AgentLedger.open(
      '${directory.path}/agent.sqlite',
      now: () => DateTime.utc(2026, 10, 27),
      elapsedMilliseconds: () => elapsed,
    );
    calls = [];
    logs = [];
    gate = null;
    upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    handle = (request) async {
      request.response.write(jsonEncode(agentEnvelope()));
      await request.response.close();
    };
    upstream.listen((request) async {
      try {
        calls.add(
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>,
        );
        if (gate != null) await gate!.future;
        await handle(request);
      } on HttpException {
        /* Synthetic timeout closes this socket. */
      } on SocketException {
        /* Synthetic timeout closes this socket. */
      }
    });
    final model = AssistantModelClient(
      endpoint: Uri.parse('http://127.0.0.1:${upstream.port}/chat/completions'),
      apiKey: 'synthetic-key',
      timeout: const Duration(milliseconds: 500),
    );
    final service = AssistantService(
      devices: devices,
      turn: (_) => throw StateError('legacy must not run'),
      summarize: (_) => throw StateError('legacy must not run'),
      agent: AgentRunner(ledger: ledger, transport: model.agentTurn),
      log: logs.add,
      readTimeout: const Duration(milliseconds: 150),
    );
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(service.handle);
    client = HttpClient();
  });
  tearDown(() async {
    if (gate != null && !gate!.isCompleted) gate!.complete();
    client.close(force: true);
    await server.close(force: true);
    await upstream.close(force: true);
    ledger.close();
    await directory.delete(recursive: true);
  });
  Future<(int, Map<String, dynamic>)> send({
    Object? body,
    String? raw,
    bool noAuth = false,
    String? credential,
    String? origin,
    bool fixed = false,
  }) async {
    final request = await client.postUrl(
      Uri.parse('http://127.0.0.1:${server.port}/v1/agent/turn'),
    );
    request.headers.contentType = ContentType.json;
    if (!noAuth) {
      request.headers.set('authorization', 'Bearer ${credential ?? token}');
    }
    if (origin != null) request.headers.set('origin', origin);
    final bytes = utf8.encode(raw ?? jsonEncode(body ?? agentFixture()));
    if (fixed) request.contentLength = bytes.length;
    request.add(bytes);
    final response = await request.close();
    expect(response.headers.value('cache-control'), 'no-store');
    return (
      response.statusCode,
      jsonDecode(await utf8.decoder.bind(response).join())
          as Map<String, dynamic>,
    );
  }

  test(
    'authenticated single tool, real result roundtrip, metadata-only logs',
    () async {
      final source = agentFixture();
      final (status, body) = await send(body: source);
      expect(status, 200);
      expect(body['kind'], 'tool_call');
      expect(body['budget']['calls'], 1);
      expect(calls.single['tool_choice'], 'auto');
      expect(calls.single['tools'].length, 5);
      final denied = {'status': 'not_authorized', 'data': null};
      handle = (incoming) async {
        incoming.response.write(
          jsonEncode(agentEnvelope(text: true, kind: 'question')),
        );
        await incoming.response.close();
      };
      final next = agentContinue(source, body, denied);
      final second = await send(body: next);
      expect(second.$2['kind'], 'question');
      expect(second.$2['budget']['calls'], 2);
      expect(
        jsonDecode(calls.last['messages'].last['content'] as String),
        denied,
      );
      expect(
        calls.last['messages'].last['tool_call_id'],
        body['tool_call']['id'],
      );
      expect(
        calls.last['messages'][2]['tool_calls'][0]['id'],
        body['tool_call']['id'],
      );
      expect((await send(body: next)).$2['code'], 'run_stopped');
      expect(calls.length, 2);
      final recorded = jsonEncode(logs);
      for (final forbidden in [
        token,
        'synthetic-key',
        'synthetic-private',
        'synthetic-device',
        source['request_id'] as String,
        body['run_id'] as String,
      ]) {
        expect(recorded, isNot(contains(forbidden)));
      }
      expect(logs.last['stop_code'], 'run_stopped');
    },
  );

  test(
    'authentication and origin block before any model or ledger reservation',
    () async {
      expect((await send(noAuth: true)).$1, 401);
      expect((await send(credential: 'wrong')).$1, 401);
      expect((await send(origin: 'null')).$1, 403);
      await devices.revoke('synthetic-device');
      expect((await send()).$1, 401);
      expect(calls, isEmpty);
      expect(
        ledger.dailyUsage(
          'synthetic-device',
          DateTime.utc(2026, 10, 27),
        )['runs'],
        0,
      );
    },
  );

  test('revocation between rounds blocks the result before relay', () async {
    final first = await send();
    final next = agentContinue(agentFixture(), first.$2, agentOk());
    await devices.revoke('synthetic-device');
    expect((await send(body: next)).$1, 401);
    expect(calls.length, 1);
  });

  for (final fixed in [true, false]) {
    test(
      '${fixed ? 'fixed' : 'chunked'} UTF-8 bodies must be strictly below 64000',
      () async {
        final source = jsonEncode(agentFixture());
        final boundary = '$source${' ' * (63999 - utf8.encode(source).length)}';
        final over = await send(raw: '$boundary ', fixed: fixed);
        expect(over.$1, 413);
        expect(over.$2['error'], 'request_too_large');
        expect(calls, isEmpty);
        expect((await send(raw: boundary, fixed: fixed)).$1, 200);
        expect(calls.length, 1);
      },
    );
  }

  test('declared 64000 rejects without waiting for withheld upload', () async {
    final socket = await Socket.connect('127.0.0.1', server.port);
    addTearDown(socket.destroy);
    socket.write(
      'POST /v1/agent/turn HTTP/1.1\r\nHost: localhost\r\n'
      'Authorization: Bearer $token\r\nContent-Type: application/json\r\n'
      'Content-Length: 64000\r\nConnection: close\r\n\r\n',
    );
    await socket.flush();
    final response = await utf8.decoder
        .bind(socket)
        .join()
        .timeout(const Duration(seconds: 2));
    expect(response, startsWith('HTTP/1.1 413'));
    expect(response, contains('{"error":"request_too_large"}'));
    expect(response, endsWith('\r\n0\r\n\r\n'));
    expect(calls, isEmpty);
  });

  test(
    'client overrides, broken JSON and history cannot trigger dispatch',
    () async {
      expect((await send(raw: '{private-invalid')).$1, 400);
      for (final key in ['tools', 'system', 'model', 'budget', 'device']) {
        expect(
          (await send(body: {...agentFixture(), key: 'override'})).$1,
          400,
        );
      }
      expect(calls, isEmpty);
      final first = await send();
      final next = agentContinue(agentFixture(), first.$2, agentOk());
      final forged = agentCopy(next);
      forged['messages'][0]['content'] = 'changed';
      expect((await send(body: forged)).$2['code'], 'history_mismatch');
      final orphan = agentCopy(next);
      orphan['messages'][2]['tool_call_id'] = 'other';
      expect((await send(body: orphan)).$1, 400);
      final foreign = agentCopy(next);
      foreign['run_id'] = 'other';
      expect((await send(body: foreign)).$1, 400);
      expect(calls.length, 1);
    },
  );

  test(
    'outgoing body and estimated token budget checked before model',
    () async {
      final tooLarge = agentFixture();
      tooLarge['messages'][0]['content'] = '语' * 20000;
      expect(utf8.encode(jsonEncode(tooLarge)).length, lessThan(64000));
      expect(
        (await send(body: tooLarge)).$2['code'],
        'model_request_too_large',
      );
      final tooManyTokens = agentFixture();
      tooManyTokens['messages'][0]['content'] = '语' * 15000;
      expect((await send(body: tooManyTokens)).$2['code'], 'run_token_limit');
      expect(calls, isEmpty);
    },
  );

  test(
    'simultaneous duplicate start dispatches only once; reservation is durable',
    () async {
      gate = Completer<void>();
      final first = send();
      while (calls.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      expect(
        ledger.dailyUsage(
          'synthetic-device',
          DateTime.utc(2026, 10, 27),
        )['tokens'],
        greaterThan(1500),
      );
      expect((await send()).$2['code'], 'start_replayed');
      gate!.complete();
      expect((await first).$2['kind'], 'tool_call');
      expect(calls.length, 1);
    },
  );

  for (final upstreamStatus in [302, 401, 429, 500]) {
    test('upstream $upstreamStatus stops without retry or redirect', () async {
      handle = (request) async {
        request.response.statusCode = upstreamStatus;
        request.response.headers.set(
          'location',
          'http://127.0.0.1:${upstream.port}/redirect',
        );
        request.response.write('private-upstream-error');
        await request.response.close();
      };
      final response = await send();
      expect(response.$2['kind'], 'stopped');
      expect(response.$2['code'], 'upstream_http');
      expect(response.$2['budget']['violation'], true);
      expect(response.$2['budget']['charged_tokens'], greaterThan(1500));
      expect(calls.length, 1);
      expect(jsonEncode(logs), isNot(contains('private-upstream-error')));
      expect((await send()).$2['code'], 'start_replayed');
    });
  }

  for (final malformed in [
    'invalid_json',
    'multiple',
    'length',
    'refusal',
    'unknown',
    'bad_args',
    'huge',
  ]) {
    test('$malformed output explicitly stops in one attempt', () async {
      handle = (request) async {
        final envelope = agentEnvelope();
        if (malformed == 'multiple') {
          envelope['choices'][0]['message']['tool_calls'].add(
            agentCall(id: 'two'),
          );
        }
        if (malformed == 'length') {
          envelope['choices'][0]['finish_reason'] = 'length';
        }
        if (malformed == 'refusal') {
          envelope['choices'][0]['message']['refusal'] = 'private';
        }
        if (malformed == 'unknown') {
          envelope['choices'][0]['message']['tool_calls'] = [
            agentCall(name: 'read_file'),
          ];
        }
        if (malformed == 'bad_args') {
          envelope['choices'][0]['message']['tool_calls'][0]['function']['arguments'] =
              '{broken';
        }
        request.response.write(switch (malformed) {
          'invalid_json' => 'private-invalid-json',
          'huge' => 'x' * 64000,
          _ => jsonEncode(envelope),
        });
        await request.response.close();
      };
      final response = await send();
      expect(response.$2['kind'], 'stopped');
      expect(response.$2.containsKey('tool_call'), false);
      expect(calls.length, 1);
    });
  }

  test(
    'missing usage never produces a tool or refunds the reservation',
    () async {
      handle = (request) async {
        request.response.write(jsonEncode(agentEnvelope()..remove('usage')));
        await request.response.close();
      };
      final response = await send();
      expect(response.$2['code'], 'invalid_usage');
      expect(response.$2['budget']['violation'], true);
      expect(
        response.$2['budget']['charged_tokens'],
        (utf8.encode(jsonEncode(calls.single)).length + 1) ~/ 2 + 1500,
      );
      expect(calls.length, 1);
    },
  );

  test(
    'model timeout closes transport, charges once, does not retry',
    () async {
      gate = Completer<void>();
      final response = await send();
      expect(response.$2['code'], 'model_timeout');
      expect(response.$2['budget']['calls'], 1);
      expect(response.$2['budget']['charged_tokens'], greaterThan(1500));
      expect(calls.length, 1);
      gate!.complete();
    },
  );

  test('late response after run deadline is discarded and charged', () async {
    handle = (request) async {
      elapsed = 60000;
      request.response.write(jsonEncode(agentEnvelope()));
      await request.response.close();
    };
    final response = await send();
    expect(response.$2['code'], 'run_deadline');
    expect(response.$2['budget']['charged_tokens'], 120);
  });
}
