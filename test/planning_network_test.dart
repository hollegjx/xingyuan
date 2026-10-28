import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/planning/domain/daily_plan.dart';
import 'package:habit_checkin/shared/local_date.dart';

import 'support/legacy_planning/planning_service.dart';
import 'support/legacy_planning/dev_gateway.dart';
import 'support/legacy_planning/model_planner.dart';

final input = PlanningRequest(
  day: LocalDate(2026, 10, 19),
  zone: 'Asia/Shanghai',
  intent: 'TEST 阅读',
  preferences: '',
  availableMinutes: 30,
);
final tasks = [PlanTask(title: 'TEST 阅读一章', minutes: 20)];
const token = 'test-only-local-bridge-token-not-a-real-credential';

Map<String, Object?> responseFor({
  String name = ModelPlanner.toolName,
  String? arguments,
  String finish = 'tool_calls',
}) => {
  'choices': [
    {
      'finish_reason': finish,
      'message': {
        'role': 'assistant',
        'tool_calls': [
          {
            'id': 'test-call',
            'type': 'function',
            'function': {
              'name': name,
              'arguments': arguments ?? encodePlanTasks(tasks),
            },
          },
        ],
      },
    },
  ],
};

void main() {
  test('model adapter forces only the draft tool and does not embed the API key in messages', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    Map<String, dynamic>? sent;
    String? authorization;
    server.listen((request) async {
      authorization = request.headers.value('Authorization');
      sent =
          jsonDecode(await readPlanningBody(request)) as Map<String, dynamic>;
      request.response.write(jsonEncode(responseFor()));
      await request.response.close();
    });
    final model = ModelPlanner(
      endpoint: Uri.parse(
        'http://127.0.0.1:${server.port}/v1/chat/completions',
      ),
      apiKey: 'test-only-secret',
      model: 'gpt-6-luna',
    );
    expect(await model.generate(input), hasLength(1));
    expect(authorization, 'Bearer test-only-secret');
    expect(sent!['model'], 'gpt-6-luna');
    expect(sent!['reasoning_effort'], 'none');
    expect(sent!['max_completion_tokens'], 1200);
    expect(sent!['store'], isFalse);
    expect(sent!['parallel_tool_calls'], isFalse);
    expect(jsonEncode(sent), isNot(contains('test-only-secret')));
    expect(sent!['tool_choice'], {
      'type': 'function',
      'function': {'name': ModelPlanner.toolName},
    });
    expect(sent!['tools'], hasLength(1));
  });

  test('adapter rejects arbitrary tools, truncation, extra arguments and malformed outputs', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    Object? output;
    server.listen((request) async {
      await request.drain<void>();
      request.response.write(jsonEncode(output));
      await request.response.close();
    });
    final model = ModelPlanner(
      endpoint: Uri.parse('http://127.0.0.1:${server.port}/chat/completions'),
      apiKey: 'test-only',
      model: 'gpt-6-luna',
    );
    for (final invalid in [
      responseFor(name: 'delete_goals'),
      responseFor(finish: 'length'),
      responseFor(arguments: '{"tasks":[],"owner":"someone-else"}'),
      responseFor(arguments: '{"tasks":[{"title":"TEST","minutes":100}]}'),
      responseFor(arguments: 'not json'),
      {'choices': []},
      {'tasks': []},
    ]) {
      output = invalid;
      await expectLater(
        model.generate(input),
        throwsA(isA<PlanningException>()),
      );
    }
  });

  test(
    'model adapter does not follow redirects carrying credentials',
    () async {
      final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
        await target.close(force: true);
      });
      var targetRequests = 0;
      target.listen((request) async {
        targetRequests++;
        await request.response.close();
      });
      server.listen((request) async {
        await request.drain<void>();
        request.response.statusCode = 307;
        request.response.headers.set(
          'Location',
          'http://127.0.0.1:${target.port}/leak',
        );
        await request.response.close();
      });
      final model = ModelPlanner(
        endpoint: Uri.parse('http://127.0.0.1:${server.port}/chat/completions'),
        apiKey: 'test-only',
        model: 'gpt-6-luna',
      );
      await expectLater(
        model.generate(input),
        throwsA(isA<PlanningException>()),
      );
      expect(targetRequests, 0);
    },
  );

  test('gateway rejects unauthenticated, browser-origin and malformed requests before billing', () async {
    var generated = 0;
    final gateway = PlanningDevGateway(
      token: token,
      maxCalls: 3,
      generate: (_) async {
        generated++;
        return tasks;
      },
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(gateway.handle);
    final client = HttpClient();
    addTearDown(() async {
      client.close(force: true);
      await server.close(force: true);
    });
    Future<int> post({String? auth, String? origin, Object? body}) async {
      final request = await client.postUrl(
        Uri.parse('http://127.0.0.1:${server.port}/plan'),
      );
      request.headers.contentType = ContentType.json;
      if (auth != null) request.headers.set('Authorization', auth);
      if (origin != null) request.headers.set('Origin', origin);
      request.write(jsonEncode(body ?? input.toJson()));
      final response = await request.close();
      await response.drain<void>();
      return response.statusCode;
    }

    expect(await post(), 401);
    expect(await post(auth: 'Bearer wrong'), 401);
    expect(
      await post(auth: 'Bearer $token', origin: 'https://untrusted.example'),
      401,
    );
    expect(
      await post(auth: 'Bearer $token', body: {'private_notes': 'TEST'}),
      422,
    );
    expect(generated, 0);
    expect(gateway.calls, 0);
    for (var i = 0; i < 3; i++) {
      expect(await post(auth: 'Bearer $token'), 200);
    }
    expect(await post(auth: 'Bearer $token'), 429);
    expect(generated, 3);
  });

  test(
    'client works through the gateway and never automatically retries',
    () async {
      final gateway = PlanningDevGateway(
        token: token,
        maxCalls: 1,
        generate: (_) async => tasks,
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen(gateway.handle);
      addTearDown(() => server.close(force: true));
      final client = HttpPlanningService(
        endpoint: Uri.parse('http://127.0.0.1:${server.port}/plan'),
        token: token,
        destination: 'TEST only',
      );
      expect(await client.generate(input), hasLength(1));
      await expectLater(
        client.generate(input),
        throwsA(isA<PlanningException>()),
      );
      expect(gateway.calls, 1);
    },
  );

  test('client bounds response size without retrying', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var count = 0;
    server.listen((request) async {
      count++;
      await request.drain<void>();
      request.response.write('x' * 33000);
      await request.response.close();
    });
    final client = HttpPlanningService(
      endpoint: Uri.parse('http://127.0.0.1:${server.port}/plan'),
      token: token,
      destination: 'TEST only',
    );
    await expectLater(
      client.generate(input),
      throwsA(isA<PlanningException>()),
    );
    expect(count, 1);
  });
}
