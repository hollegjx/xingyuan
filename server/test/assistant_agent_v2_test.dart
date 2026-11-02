import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:xingyuan_core/xingyuan_core.dart';
import 'package:xingyuan_server/src/agent_ledger.dart';
import 'package:xingyuan_server/src/agent_protocol.dart';
import 'package:xingyuan_server/src/agent_runner.dart';
import 'package:xingyuan_server/src/device_registry.dart';
import 'package:xingyuan_server/src/service.dart';

import 'support/agent_fixtures.dart';

void main() {
  late Directory directory;
  late AgentLedger ledger;
  late HttpServer server;
  late HttpClient client;
  late String token;
  late List<String> bodies;
  late String responseTool;
  late List<Map<String, Object?>> logs;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'assistant-v2-synthetic-',
    );
    ledger = AgentLedger.open('${directory.path}/ledger.sqlite');
    final devices = DeviceRegistry('${directory.path}/devices.json');
    token = await devices.issue('synthetic');
    bodies = [];
    responseTool = 'get_journal_text';
    logs = [];
    final service = AssistantService(
      devices: devices,
      turn: (_) => throw StateError('unexpected legacy'),
      summarize: (_) => throw StateError('unexpected summary'),
      agent: AgentRunner(
        ledger: ledger,
        transport: (body, request, remaining) async {
          bodies.add(body);
          return AgentModelReply.parse(
            agentEnvelope(
              call: agentCall(
                name: responseTool,
                arguments: {
                  'day': '2026-10-27',
                  if (responseTool == 'get_journal_text')
                    'kinds': ['quickNote'],
                },
              ),
            ),
            request.now.date,
            extended: request is AssistantAgentRequest,
          );
        },
      ),
      log: logs.add,
    );
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(service.handle);
    client = HttpClient();
  });
  tearDown(() async {
    client.close(force: true);
    await server.close(force: true);
    ledger.close();
    await directory.delete(recursive: true);
  });
  Future<(int, Map<String, dynamic>)> send(
    String route, {
    Map<String, dynamic>? payload,
    bool authorized = true,
    String? raw,
  }) async {
    final req = await client.openUrl(
      payload == null && raw == null
          ? 'GET'
          : route.endsWith('capabilities')
          ? 'GET'
          : 'POST',
      Uri.parse('http://127.0.0.1:${server.port}$route'),
    );
    req.headers.contentType = ContentType.json;
    if (authorized) {
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    if (payload != null || raw != null) {
      final bytes = utf8.encode(raw ?? jsonEncode(payload));
      req.contentLength = bytes.length;
      req.add(bytes);
    }
    final response = await req.close();
    return (
      response.statusCode,
      jsonDecode(await utf8.decoder.bind(response).join())
          as Map<String, dynamic>,
    );
  }

  test('capability requires authentication, rejects a body, never invokes model or logs content', () async {
    expect((await send('/v2/agent/capabilities', authorized: false)).$1, 401);
    final response = await send('/v2/agent/capabilities');
    expect(response.$1, 200);
    expect(response.$2, {
      'protocol': assistantAgentProtocol,
      'tools': assistantAgentTools,
    });
    expect((await send('/v2/agent/capabilities', raw: 'TEST-private')).$1, 400);
    expect(bodies, isEmpty);
    expect(jsonEncode(logs), isNot(contains('TEST-private')));
  });
  test(
    'v2 routes eight tools and extended reply, v1 rejects new calls unchanged',
    () async {
      final request = {
        ...agentFixture(id: 'v2'),
        'protocol': assistantAgentProtocol,
      };
      final v2 = await send('/v2/agent/turn', payload: request);
      expect(v2.$1, 200);
      expect(v2.$2['tool_call']['function']['name'], 'get_journal_text');
      final parsed = AssistantAgentResponse.fromJson(
        v2.$2,
        request: AssistantAgentRequest.fromJson(request),
      );
      expect(parsed.call!.id, agentCallId(parsed.runId, 1));
      expect((jsonDecode(bodies.single)['tools'] as List), hasLength(8));
      final v1 = await send('/v1/agent/turn', payload: agentFixture(id: 'v1'));
      expect(v1.$1, 200);
      expect(v1.$2['kind'], 'stopped');
      expect(v1.$2['code'], 'invalid_model_output');
      expect((jsonDecode(bodies.last)['tools'] as List), hasLength(5));
      expect(
        jsonEncode(logs),
        isNot(contains('synthetic-private-planning-request')),
      );
    },
  );
  test(
    'C76 summary timing survives v2 HTTP continuation without body logs',
    () async {
      responseTool = 'get_day_summary';
      final request = {
        ...agentFixture(id: 'summary-time'),
        'protocol': assistantAgentProtocol,
      };
      final first = await send('/v2/agent/turn', payload: request);
      expect(first.$1, 200);
      final result = {
        'status': 'ok',
        'data': {
          'day': '2026-10-27',
          'items': [
            {
              'title': 'TEST private timed goal',
              'planned_time': '09:00',
              'planned_minutes': 30,
              'completed': true,
              'completed_at': '2026-10-27T01:30:00.000Z',
              'text': 'TEST private saved checkin',
            },
          ],
        },
      };
      final continued = agentContinue(request, first.$2, result);
      continued['protocol'] = assistantAgentProtocol;
      final second = await send('/v2/agent/turn', payload: continued);
      expect(second.$1, 200);
      final messages = (jsonDecode(bodies.last)['messages'] as List);
      final tool = messages.last as Map;
      expect(jsonDecode(tool['content'] as String), result);
      expect(jsonEncode(logs), isNot(contains('TEST private')));
    },
  );
  test('routes reject wrong or unknown protocol before model call', () async {
    expect((await send('/v2/agent/turn', payload: agentFixture())).$1, 400);
    expect(
      (await send(
        '/v1/agent/turn',
        payload: {...agentFixture(), 'protocol': assistantAgentProtocol},
      )).$1,
      400,
    );
    expect(
      (await send(
        '/v2/agent/turn',
        payload: {...agentFixture(), 'protocol': 'unknown'},
      )).$1,
      400,
    );
    expect(bodies, isEmpty);
  });
  test(
    'v2 run cannot switch to v1 after model call even with compatible history',
    () async {
      // Initial user-only envelope is valid in both versions, but the run is version-bound.
      final req = AssistantAgentRequest.fromJson({
        ...agentFixture(),
        'protocol': assistantAgentProtocol,
      });
      final reservation = ledger.reserve('synthetic', req, 1000);
      final reply = AgentModelReply.parse(agentEnvelope(), req.now.date);
      final settled = ledger.finish(reservation, req, reply);
      final switched = AgentRequest.fromJson({
        ...req.toJson(),
        'protocol': agentProtocol,
        'run_id': reservation.runId,
        'turn': 2,
        'messages': [
          ...req.messages,
          settled.outcome.call!.message,
          {
            'role': 'tool',
            'tool_call_id': settled.outcome.call!.id,
            'content': jsonEncode(agentOk()),
          },
        ],
      });
      expect(
        () => ledger.reserve('synthetic', switched, 1000),
        throwsA(
          isA<AgentFailure>().having((e) => e.code, 'code', 'history_mismatch'),
        ),
      );
    },
  );
}
