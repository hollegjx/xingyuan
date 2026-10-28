import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/assistant/data/assistant_service.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

import '../packages/xingyuan_core/test/day_analysis_fixture.dart'
    show analysisFixture;
import '../packages/xingyuan_core/test/journal_ai_fixture.dart'
    show polishFixture, diaryFixture;
import 'support/journal_request_size.dart';

TurnRequest request({String id = 'synthetic-request'}) => TurnRequest.fromJson({
  'protocol': assistantProtocol,
  'request_id': id,
  'now': {
    'date': '2026-10-20',
    'time': '21:00',
    'weekday': 2,
    'time_zone': 'Asia/Shanghai',
  },
  'summary': null,
  'messages': [
    {'role': 'user', 'text': '合成内容，不需要规划'},
  ],
  'settings': {'auto_memory': true},
});

Matcher fails(AssistantFailureKind kind) => throwsA(
  isA<AssistantFailure>().having((error) => error.kind, 'kind', kind),
);

void main() {
  late HttpServer server;
  late HttpAssistantService service;
  late AssistantAccess access;
  late String token;
  late List<Map<String, dynamic>> sent;
  late List<String> authHeaders;
  late List<String> routes;
  late bool current;
  late int status;
  late int credentialReads;
  Completer<void>? responseGate;
  String? raw;

  for (final unit in ['a', '中', '👩‍👩‍👧‍👦', '"', '\\', '\n']) {
    for (final byteCount in [63999, 64000, 64001, 65536]) {
      test('diary byte budget $byteCount unit ${jsonEncode(unit)}', () async {
        final payload = diaryPayloadOfSize(
          byteCount,
          unit: unit,
          entries: [
            {'title': '阅读"计划', 'completed': true, 'text': '第一行\n第二行'},
          ],
        );
        final request = GenerateDiaryRequest.fromJson(payload);
        expect(utf8.encode(jsonEncode(request.toJson())), hasLength(byteCount));
        raw = jsonEncode({
          'protocol': assistantProtocol,
          'request_id': request.requestId,
          'status': 'draft',
          'draft': '合成日记。',
        });
        if (byteCount <= 64000) {
          await service.generateDiary(request, access: access);
          expect(sent.single, payload);
          expect(routes, ['/v1/generate-diary']);
        } else {
          await expectLater(
            service.generateDiary(request, access: access),
            fails(AssistantFailureKind.tooLarge),
          );
          expect(routes, isEmpty);
          expect(sent, isEmpty);
          expect(authHeaders, isEmpty);
        }
      });
    }
  }

  for (final polish in [true, false]) {
    test(
      'journal ${polish ? 'polish' : 'diary'} uses guarded transport and exact text projection',
      () async {
        final fixture = polish ? polishFixture() : diaryFixture();
        raw = jsonEncode({
          'protocol': assistantProtocol,
          'request_id': fixture['request_id'],
          if (polish) ...{
            'rewrite': '我读完了一章。',
            'tips': ['保留了原意。'],
          } else ...{
            'status': 'draft',
            'draft': '我读完了一章。',
          },
        });
        Future<void> send(AssistantAccess grant) async {
          if (polish) {
            await service.polishNote(
              PolishNoteRequest.fromJson(fixture),
              access: grant,
            );
          } else {
            await service.generateDiary(
              GenerateDiaryRequest.fromJson(fixture),
              access: grant,
            );
          }
        }

        await expectLater(
          send(AssistantAccess(consentVersion: 1, isCurrent: () async => true)),
          fails(AssistantFailureKind.consent),
        );
        expect(sent, isEmpty);
        expect(credentialReads, 0);
        await send(access);
        expect(sent.single, fixture);
        expect(
          routes.single,
          polish ? '/v1/polish-note' : '/v1/generate-diary',
        );
        expect(credentialReads, 1);
        raw = jsonEncode({
          'protocol': assistantProtocol,
          'request_id': 'wrong',
        });
        await expectLater(
          send(access),
          fails(AssistantFailureKind.invalidResponse),
        );
      },
    );
  }

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    token = base64Url.encode(List.filled(32, 7)).replaceAll('=', '');
    current = true;
    credentialReads = 0;
    status = 200;
    raw = null;
    responseGate = null;
    sent = [];
    authHeaders = [];
    routes = [];
    access = AssistantAccess(
      consentVersion: assistantConsentVersion,
      isCurrent: () async => current,
    );
    service = HttpAssistantService(
      endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
      allowInsecureLoopback: true,
      readCredential: () async {
        credentialReads++;
        return token;
      },
    );
    server.listen((incoming) async {
      try {
        routes.add(incoming.uri.path);
        authHeaders.add(incoming.headers.value('authorization') ?? '');
        Map<String, dynamic>? body;
        if (incoming.method == 'POST') {
          body = jsonDecode(
            await utf8.decoder.bind(incoming).join(),
          ) as Map<String, dynamic>;
          sent.add(body);
        }
        if (responseGate != null) await responseGate!.future;
        incoming.response.statusCode = status;
        incoming.response.headers.contentType = ContentType.json;
        if (status == 302) {
          incoming.response.headers.set(
            'location',
            'http://127.0.0.1:${server.port}/credential-leak',
          );
        }
        incoming.response.write(
          raw ??
              jsonEncode(
                incoming.uri.path == '/v1/health'
                    ? {'protocol': assistantProtocol, 'status': 'ok'}
                    : incoming.uri.path == '/v1/summarize'
                    ? {
                        'protocol': assistantProtocol,
                        'request_id': body!['request_id'],
                        'summary': '合成摘要',
                      }
                    : incoming.uri.path == '/v1/analyze-day'
                    ? {
                        'protocol': assistantProtocol,
                        'request_id': body!['request_id'],
                        'summary': '合成当日分析',
                        'suggestions': ['可以记下一点感受。'],
                      }
                    : {
                        'protocol': assistantProtocol,
                        'request_id': body!['request_id'],
                        'reply': '合成回复',
                        'plan': null,
                        'memory_ops': [],
                      },
              ),
        );
        await incoming.response.close();
      } on SocketException {
        // Cancellation closes the synthetic connection.
      } on HttpException {
        // Cancellation closes the synthetic connection.
      }
    });
  });

  tearDown(() async {
    if (responseGate != null && !responseGate!.isCompleted) {
      responseGate!.complete();
    }
    await server.close(force: true);
  });

  Future<void> waitForRequest() async {
    final end = DateTime.now().add(const Duration(seconds: 2));
    while (sent.isEmpty && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(sent, hasLength(1));
  }

  test(
    'day analysis uses exact bounded payload and credential transport',
    () async {
      final input = DayAnalysisRequest.fromJson(analysisFixture());
      final result = await service.analyzeDay(input, access: access);
      expect(result.summary, '合成当日分析');
      expect(routes, ['/v1/analyze-day']);
      expect(sent.single, input.toJson());
      expect(authHeaders.single, 'Bearer $token');
    },
  );
  test(
    'analysis refuses missing consent and discards late identity response',
    () async {
      final input = DayAnalysisRequest.fromJson(analysisFixture());
      await expectLater(
        service.analyzeDay(
          input,
          access: AssistantAccess(
            consentVersion: 0,
            isCurrent: () async => true,
          ),
        ),
        fails(AssistantFailureKind.consent),
      );
      expect(sent, isEmpty);
      responseGate = Completer<void>();
      final running = service.analyzeDay(input, access: access);
      final check = expectLater(running, fails(AssistantFailureKind.discarded));
      await waitForRequest();
      current = false;
      responseGate!.complete();
      await check;
    },
  );
  test(
    'analysis rejects model plans or mismatched request without retry',
    () async {
      final input = DayAnalysisRequest.fromJson(analysisFixture());
      raw = jsonEncode({
        'protocol': assistantProtocol,
        'request_id': 'other',
        'summary': 'no',
        'suggestions': [],
      });
      await expectLater(
        service.analyzeDay(input, access: access),
        fails(AssistantFailureKind.invalidResponse),
      );
      expect(sent, hasLength(1));
    },
  );

  test(
    'no consent means zero network and no credential access, even health',
    () async {
      final denied = AssistantAccess(
        consentVersion: 0,
        isCurrent: () async => true,
      );
      await expectLater(
        service.turn(request(), access: denied),
        fails(AssistantFailureKind.consent),
      );
      await expectLater(
        service.health(access: denied),
        fails(AssistantFailureKind.consent),
      );
      expect(routes, isEmpty);
      expect(credentialReads, 0);
    },
  );

  test(
    'exact request body omits disabled categories and never contains token',
    () async {
      final turn = request();
      expect((await service.turn(turn, access: access)).reply, '合成回复');
      expect(sent.single, turn.toJson());
      expect(sent.single.keys, isNot(contains('memories')));
      expect(sent.single.keys, isNot(contains('schedule')));
      expect(sent.single.keys, isNot(contains('stats')));
      expect(jsonEncode(sent), isNot(contains(token)));
      expect(authHeaders.single, 'Bearer $token');
    },
  );

  test('health uses no credential and validates protocol', () async {
    await service.health(access: access);
    expect(credentialReads, 0);
    expect(authHeaders.single, '');
    raw = '{"protocol":"wrong","status":"ok"}';
    await expectLater(
      service.health(access: access),
      fails(AssistantFailureKind.invalidResponse),
    );
  });

  test('summary request is validated and correlated', () async {
    final summary = SummaryRequest.fromJson({
      'protocol': assistantProtocol,
      'request_id': 'summary-test',
      'summary': null,
      'messages': [
        {'role': 'user', 'text': '合成上下文'},
      ],
    });
    expect((await service.summarize(summary, access: access)).summary, '合成摘要');
    expect(sent.single, summary.toJson());
  });

  for (final entry in {
    400: AssistantFailureKind.request,
    401: AssistantFailureKind.credential,
    403: AssistantFailureKind.credential,
    413: AssistantFailureKind.tooLarge,
    422: AssistantFailureKind.invalidResponse,
    429: AssistantFailureKind.busy,
    500: AssistantFailureKind.unavailable,
    502: AssistantFailureKind.unavailable,
    504: AssistantFailureKind.timeout,
    302: AssistantFailureKind.unavailable,
  }.entries) {
    test(
      'HTTP ${entry.key} is explicit, sanitized and never auto-retried',
      () async {
        status = entry.key;
        raw = 'private-model-error $token';
        try {
          await service.turn(request(), access: access);
          fail('Request must fail');
        } on AssistantFailure catch (error) {
          expect(error.kind, entry.value);
          expect(error.message, contains('未创建任何内容'));
          expect(error.toString(), isNot(contains(token)));
          expect(error.toString(), isNot(contains('private-model-error')));
        }
        expect(routes, ['/v1/turn']);
        expect(sent, hasLength(1));
      },
    );
  }

  test(
    'invalid JSON and oversized response cannot expose private output',
    () async {
      for (final value in [
        '{"secret":"sensitive',
        'x' * (assistantBodyLimit + 1),
      ]) {
        raw = value;
        await expectLater(
          service.turn(request(), access: access),
          fails(AssistantFailureKind.invalidResponse),
        );
      }
      expect(sent, hasLength(2));
    },
  );

  test(
    'wrong response correlation and unrequested memories are rejected',
    () async {
      for (final response in [
        {
          'protocol': assistantProtocol,
          'request_id': 'wrong',
          'reply': '合成回复',
          'plan': null,
          'memory_ops': [],
        },
        {
          'protocol': assistantProtocol,
          'request_id': 'synthetic-request',
          'reply': '合成回复',
          'plan': null,
          'memory_ops': [
            {
              'op': 'delete',
              'id': 'unsent-memory',
              'category': null,
              'text': null,
              'expires_on': null,
            },
          ],
        },
      ]) {
        raw = jsonEncode(response);
        await expectLater(
          service.turn(request(), access: access),
          fails(AssistantFailureKind.invalidResponse),
        );
      }
    },
  );

  test(
    'late response is discarded after identity generation changes',
    () async {
      responseGate = Completer<void>();
      final result = service.turn(request(), access: access);
      final check = expectLater(result, fails(AssistantFailureKind.discarded));
      await waitForRequest();
      current = false;
      responseGate!.complete();
      await check;
    },
  );

  test(
    'already cancelled has zero network; waiting cancellation closes request',
    () async {
      final early = AssistantCancellation()..cancel();
      await expectLater(
        service.turn(request(), access: access, cancellation: early),
        fails(AssistantFailureKind.cancelled),
      );
      expect(routes, isEmpty);
      responseGate = Completer<void>();
      final cancellation = AssistantCancellation();
      final result = service.turn(
        request(),
        access: access,
        cancellation: cancellation,
      );
      final check = expectLater(result, fails(AssistantFailureKind.cancelled));
      await waitForRequest();
      cancellation.cancel();
      cancellation.cancel();
      await check;
      expect(sent, hasLength(1));
    },
  );

  test('timeout is bounded with no automatic retry', () async {
    responseGate = Completer<void>();
    final fast = HttpAssistantService(
      endpoint: service.endpoint,
      readCredential: () async => token,
      allowInsecureLoopback: true,
      timeout: const Duration(milliseconds: 40),
    );
    await expectLater(
      fast.turn(request(), access: access),
      fails(AssistantFailureKind.timeout),
    );
    expect(sent, hasLength(1));
  });

  test(
    'timeout while reading credential cannot start a late network request',
    () async {
      final credential = Completer<String?>();
      final slow = HttpAssistantService(
        endpoint: service.endpoint,
        readCredential: () => credential.future,
        allowInsecureLoopback: true,
        timeout: const Duration(milliseconds: 20),
      );
      await expectLater(
        slow.turn(request(), access: access),
        fails(AssistantFailureKind.timeout),
      );
      credential.complete(token);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(routes, isEmpty);
    },
  );

  test(
    'timeout during final access check cannot open a late connection',
    () async {
      final identity = Completer<bool>();
      var checks = 0;
      final slowAccess = AssistantAccess(
        consentVersion: assistantConsentVersion,
        isCurrent: () {
          checks++;
          return checks == 2 ? identity.future : Future.value(true);
        },
      );
      final fast = HttpAssistantService(
        endpoint: service.endpoint,
        readCredential: () async => token,
        allowInsecureLoopback: true,
        timeout: const Duration(milliseconds: 20),
      );
      await expectLater(
        fast.turn(request(), access: slowAccess),
        fails(AssistantFailureKind.timeout),
      );
      identity.complete(true);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(checks, 2);
      expect(routes, isEmpty);
    },
  );

  test(
    'missing credentials and unconfigured service do not send anything',
    () async {
      for (final value in [null, '', 'bad\r\nheader']) {
        final missing = HttpAssistantService(
          endpoint: service.endpoint,
          allowInsecureLoopback: true,
          readCredential: () async => value,
        );
        await expectLater(
          missing.turn(request(), access: access),
          fails(AssistantFailureKind.credential),
        );
      }
      final missing = HttpAssistantService(
        endpoint: null,
        readCredential: () async => token,
      );
      expect(missing.configured, false);
      await expectLater(
        missing.turn(request(), access: access),
        fails(AssistantFailureKind.unconfigured),
      );
      expect(routes, isEmpty);
    },
  );

  test(
    'plaintext non-loopback and credential-bearing endpoints are rejected',
    () {
      for (final value in [
        'http://example.test',
        'http://127.0.0.1.example.test',
        'https://user:password@example.test',
        'https://example.test?token=secret',
        'https://example.test#secret',
        'https://example.test/v1',
      ]) {
        expect(
          () => HttpAssistantService(
            endpoint: Uri.parse(value),
            allowInsecureLoopback: true,
            readCredential: () async => token,
          ),
          throwsA(isA<AssistantFailure>()),
        );
      }
      expect(
        () => HttpAssistantService(
          endpoint: service.endpoint,
          readCredential: () async => token,
        ),
        throwsA(isA<AssistantFailure>()),
      );
    },
  );
}
