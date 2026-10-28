import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:xingyuan_core/xingyuan_core.dart';
import 'package:xingyuan_server/src/device_registry.dart';
import 'package:xingyuan_server/src/journal_rate_limit.dart';
import 'package:xingyuan_server/src/model_client.dart';
import 'package:xingyuan_server/src/service.dart';

import '../../packages/xingyuan_core/test/journal_ai_fixture.dart'
    show polishFixture, diaryFixture;

void main() {
  late Directory root;
  late DeviceRegistry devices;
  late String token;
  late HttpServer server;
  late HttpClient client;
  late List<Map<String, Object?>> logs;
  late int calls;
  late int elapsed;
  Completer<void>? gate;
  ModelFailure? failure;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('journal-service-synthetic-');
    devices = DeviceRegistry('${root.path}/devices.json');
    token = await devices.issue('qa-journal-synthetic');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    client = HttpClient();
    logs = [];
    calls = 0;
    elapsed = 0;
    gate = null;
    failure = null;
    Future<void> model() async {
      calls++;
      await gate?.future;
      if (failure != null) throw failure!;
    }

    final service = AssistantService(
      devices: devices,
      log: logs.add,
      readTimeout: const Duration(milliseconds: 100),
      journalRateLimit: JournalRateLimit(elapsedMilliseconds: () => elapsed),
      turn: (_) => throw StateError('unexpected turn'),
      summarize: (_) => throw StateError('unexpected summary'),
      polishNote: (request) async {
        await model();
        return ModelResult(
          PolishNoteResponse.fromJson({
            'protocol': assistantProtocol,
            'request_id': request.requestId,
            'rewrite': 'synthetic-private-rewrite',
            'tips': ['synthetic-private-tip'],
          }, request: request),
          1,
          {},
        );
      },
      generateDiary: (request) async {
        await model();
        return ModelResult(
          GenerateDiaryResponse.fromJson({
            'protocol': assistantProtocol,
            'request_id': request.requestId,
            'status': 'draft',
            'draft': 'synthetic-private-diary',
          }, request: request),
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
    await root.delete(recursive: true);
  });

  Future<(int, Map<String, dynamic>)> send(
    String route,
    Object body, {
    bool auth = true,
    bool origin = false,
    bool fixedLength = false,
    String? raw,
  }) async {
    final request = await client.postUrl(
      Uri.parse('http://127.0.0.1:${server.port}$route'),
    );
    request.headers.contentType = ContentType.json;
    if (auth) request.headers.set('authorization', 'Bearer $token');
    if (origin) request.headers.set('origin', 'https://browser.invalid');
    final bytes = utf8.encode(raw ?? jsonEncode(body));
    if (fixedLength) request.contentLength = bytes.length;
    request.add(bytes);
    final response = await request.close();
    return (
      response.statusCode,
      jsonDecode(await utf8.decoder.bind(response).join())
          as Map<String, dynamic>,
    );
  }

  for (final route in ['/v1/polish-note', '/v1/generate-diary']) {
    Map<String, dynamic> fixture() =>
        route.endsWith('polish-note') ? polishFixture() : diaryFixture();
    test('$route authenticates and rejects photos before model', () async {
      expect((await send(route, fixture(), auth: false)).$1, 401);
      expect((await send(route, fixture(), origin: true)).$1, 403);
      expect((await send(route, {...fixture(), 'photos': []})).$1, 400);
      expect(calls, 0);
      expect((await send(route, fixture())).$1, 200);
      await devices.revoke('qa-journal-synthetic');
      expect((await send(route, fixture())).$1, 401);
      expect(calls, 1);
      final encoded = jsonEncode(logs);
      for (final secret in [
        token,
        'synthetic-private',
        '我今天',
        '读完一章',
        '我想晚上',
      ]) {
        expect(encoded, isNot(contains(secret)));
      }
      expect(logs.any((log) => (log['input_bytes'] as int? ?? 0) > 0), true);
    });
    test('$route chunked body is bounded without model', () async {
      final large = {
        ...fixture(),
        'padding': List.filled(assistantBodyLimit + 1, 'x').join(),
      };
      expect((await send(route, large)).$1, 413);
      expect(calls, 0);
    });
    test('$route fixed Content-Length preserves the complete 413', () async {
      final large = {...fixture(), 'padding': 'x' * (assistantBodyLimit + 1)};
      final (status, body) = await send(route, large, fixedLength: true);
      expect(status, 413);
      expect(body, {'error': 'request_too_large'});
      expect(calls, 0);
      expect((await send(route, fixture(), fixedLength: true)).$1, 200);
      expect(calls, 1);
      expect(jsonEncode(logs), isNot(contains(token)));
      expect(jsonEncode(logs), isNot(contains('padding')));
    });
    test(
      '$route fixed length keeps the exact byte limit and capacity',
      () async {
        final raw = jsonEncode(fixture());
        final padding = assistantBodyLimit - utf8.encode(raw).length;
        for (var i = 0; i < 13; i++) {
          final (status, body) = await send(
            route,
            fixture(),
            fixedLength: true,
            raw: '$raw${' ' * (padding + 1)}',
          );
          expect(status, 413);
          expect(body, {'error': 'request_too_large'});
        }
        expect(calls, 0);
        expect(logs, hasLength(13));
        expect(logs.every((log) => log['input_bytes'] == 0), true);
        for (final size in [assistantBodyLimit - 1, assistantBodyLimit]) {
          expect(
            (await send(
              route,
              fixture(),
              fixedLength: true,
              raw: '$raw${' ' * (size - utf8.encode(raw).length)}',
            )).$1,
            200,
          );
          expect(logs.last['input_bytes'], size);
        }
        expect(calls, 2);
      },
    );
    for (final (name, prefix) in [
      ('no body', ''),
      ('partial body', '{'),
      ('proxy-limited body', 'x' * 64000),
    ]) {
      test('$route rejects oversized headers with $name', () async {
        final socket = await Socket.connect('127.0.0.1', server.port);
        addTearDown(socket.destroy);
        socket.write(
          'POST $route HTTP/1.1\r\nHost: localhost\r\n'
          'Authorization: Bearer $token\r\nContent-Type: application/json\r\n'
          'Content-Length: ${assistantBodyLimit + 1}\r\n'
          'Connection: close\r\n\r\n$prefix',
        );
        await socket.flush();
        final response = await utf8.decoder
            .bind(socket)
            .join()
            .timeout(const Duration(seconds: 3));
        expect(response, startsWith('HTTP/1.1 413 '));
        expect(response, contains('{"error":"request_too_large"}'));
        expect(response, endsWith('\r\n0\r\n\r\n'));
        expect(response, contains('cache-control: no-store'));
        expect(response, contains('connection: close'));
        expect(calls, 0);
        expect(logs.single['status'], 413);
        expect(logs.single['input_bytes'], 0);
      });
    }
    test('$route releases reservation after model failure', () async {
      failure = const ModelFailure(504, 'model_timeout', 1);
      expect((await send(route, fixture())).$1, 504);
      failure = null;
      expect((await send(route, fixture())).$1, 200);
      expect(calls, 2);
    });
  }

  test('rate windows are independent for route and device and reset', () async {
    final originalToken = token;
    for (var i = 0; i < 12; i++) {
      expect((await send('/v1/polish-note', polishFixture())).$1, 200);
    }
    expect((await send('/v1/polish-note', polishFixture())).$1, 429);
    expect((await send('/v1/generate-diary', diaryFixture())).$1, 200);
    token = await devices.issue('qa-journal-other');
    expect((await send('/v1/polish-note', polishFixture())).$1, 200);
    elapsed = 60000;
    token = originalToken;
    expect((await send('/v1/polish-note', polishFixture())).$1, 200);
  });

  test(
    'one pending request per journal endpoint; completion frees capacity',
    () async {
      gate = Completer<void>();
      final first = send('/v1/polish-note', polishFixture());
      while (calls == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect((await send('/v1/polish-note', polishFixture())).$1, 429);
      final second = send('/v1/generate-diary', diaryFixture());
      while (calls < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      gate!.complete();
      expect((await first).$1, 200);
      expect((await second).$1, 200);
      expect((await send('/v1/polish-note', polishFixture())).$1, 200);
    },
  );

  test(
    'empty diary returns insufficient material without a model call',
    () async {
      final (status, body) = await send('/v1/generate-diary', {
        ...diaryFixture(),
        'entries': [],
        'notes': [],
      });
      expect(status, 200);
      expect(body['status'], 'insufficient_material');
      expect(body['draft'], '');
      expect(calls, 0);
    },
  );
}
