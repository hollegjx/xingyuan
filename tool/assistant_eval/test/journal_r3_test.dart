import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:xingyuan_assistant_eval/journal_cases.dart';
import 'package:xingyuan_assistant_eval/journal_r3_cases.dart';
import 'package:xingyuan_core/xingyuan_core.dart';
import 'package:xingyuan_server/src/model_client.dart';
import 'package:xingyuan_server/src/tool_schema.dart';

void main() {
  final cases = journalR3Cases();
  final corpus = jsonDecode(
    File('test/fixtures/journal_r3_responses.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final fixtures = (corpus['responses'] as List).cast<Map<String, dynamic>>();

  test('bounded R3 set leaves the old live matrix unchanged', () {
    expect(journalAiCases(), hasLength(10));
    expect(cases.map((item) => item.id), [
      'R3-MULTI',
      'R3-CORRECTION',
      'R3-NEGATIVE',
    ]);
    expect(corpus['provenance'], startsWith('Handwritten'));
    expect(fixtures, hasLength(19));
    expect(
      fixtures.map((f) => '${f['case']}/${f['id']}').toSet(),
      hasLength(19),
    );
    expect(
      fixtures.map((f) => f['case']).toSet(),
      cases.map((c) => c.id).toSet(),
    );
    for (final sample in cases) {
      final good = fixtures.where(
        (f) => f['case'] == sample.id && f['kind'] == 'valid',
      );
      expect(good, hasLength(2));
      expect(good.map((f) => jsonEncode(f['output'])).toSet(), hasLength(2));
    }
    final blindSpot = fixtures.singleWhere((f) => f['kind'] == 'blind_spot');
    expect(blindSpot['review'], startsWith('Reject:'));
    expect(blindSpot['failures'], isEmpty);
    final invalid = fixtures.where((f) => f['kind'] == 'invalid');
    expect(invalid, hasLength(12));
    expect(invalid.every((f) => (f['failures'] as List).isNotEmpty), true);
  });

  test('journal checker rejects unrelated operations and date deferral is opt-in', () {
    final original = cases[1];
    final source = original.request as TurnRequest;
    // Enable memory only to exercise this checker independently of the
    // protocol's disabled-auto-memory rejection. The R3 inputs stay unchanged.
    final request = TurnRequest.fromJson({
      ...source.toJson(),
      'settings': {'auto_memory': true},
    });
    final sample = JournalAiCase('checker-only', request, []);
    final result = TurnResponse.fromJson({
      'protocol': assistantProtocol,
      'request_id': request.requestId,
      'reply': '待确认。',
      'diary': {'date': '2026-10-26', 'content': '合成草稿。'},
      'plan': {
        'tasks': [
          {'title': '未请求任务', 'date': '2026-10-27', 'time': null, 'minutes': 10},
        ],
        'habits': [],
      },
      'memory_ops': [
        {
          'op': 'add',
          'id': null,
          'category': '其他',
          'text': '未请求记忆',
          'expires_on': null,
        },
      ],
    }, request: request);
    expect(checkJournalAi(sample, result), [
      'unexpected_plan',
      'unexpected_memory_ops',
    ]);
    expect(
      checkJournalAi(
        JournalAiCase('deferred', request, [], deferDiaryDate: true),
        result,
      ),
      ['unexpected_diary_date', 'unexpected_plan', 'unexpected_memory_ops'],
    );
  });

  for (final fixture in fixtures) {
    final sample = cases.singleWhere((item) => item.id == fixture['case']);
    test(
      '${sample.id}/${fixture['id']}: handwritten ${fixture['kind']}, not model quality',
      () async {
        // Only this ephemeral loopback server receives the synthetic request.
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final calls = <Map<String, dynamic>>[];
        final diary = sample.request is GenerateDiaryRequest;
        final tool = diary ? 'generate_diary' : 'assistant_turn';
        server.listen((incoming) async {
          calls.add(
            jsonDecode(await utf8.decoder.bind(incoming).join())
                as Map<String, dynamic>,
          );
          incoming.response.write(
            jsonEncode({
              'choices': [
                {
                  'finish_reason': 'tool_calls',
                  'message': {
                    'tool_calls': [
                      {
                        'type': 'function',
                        'function': {
                          'name': tool,
                          'arguments': jsonEncode(fixture['output']),
                        },
                      },
                    ],
                  },
                },
              ],
              'usage': {
                'prompt_tokens': 0,
                'completion_tokens': 0,
                'total_tokens': 0,
              },
            }),
          );
          await incoming.response.close();
        });
        final client = AssistantModelClient(
          endpoint: Uri.parse(
            'http://127.0.0.1:${server.port}/chat/completions',
          ),
          apiKey: 'synthetic-not-a-credential',
          timeout: const Duration(seconds: 2),
        );
        final Object response;
        final Map<String, Object?> payload;
        if (diary) {
          final request = sample.request as GenerateDiaryRequest;
          final result = await client.generateDiary(request);
          response = result.value;
          payload = request.toJson();
          expect(result.attempts, 1);
        } else {
          final request = sample.request as TurnRequest;
          final result = await client.turn(request);
          response = result.value;
          payload = request.toJson();
          expect(result.attempts, 1);
        }
        expect(calls, hasLength(1));
        expect(calls.single['messages'], hasLength(2));
        expect(calls.single['messages'][1], {
          'role': 'user',
          'content': jsonEncode(payload),
        });
        expect(calls.single['store'], false);
        expect(calls.single['parallel_tool_calls'], false);
        expect(calls.single['tools'], hasLength(1));
        expect(calls.single['tools'][0]['function'], {
          'name': tool,
          'description': 'Return validated data for local review.',
          'strict': true,
          'parameters': diary
              ? generateDiarySchema
              : assistantTurnSchemaFor(diaryProposals: true),
        });
        // Even the known bad prose is protocol-valid. This checker is NOT a
        // production semantic filter and cannot certify naturalness or truth.
        expect(checkJournalAi(sample, response), fixture['failures']);
      },
    );
  }
}
