import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:xingyuan_core/xingyuan_core.dart';
import 'package:xingyuan_server/src/model_client.dart';
import 'package:xingyuan_server/src/prompts.dart';
import 'package:xingyuan_server/src/tool_schema.dart';

import '../../packages/xingyuan_core/test/fixture_contract.dart';
import '../../packages/xingyuan_core/test/day_analysis_fixture.dart'
    show analysisFixture;
import '../../packages/xingyuan_core/test/journal_ai_fixture.dart'
    show polishFixture, diaryFixture;

void main() {
  late HttpServer server;
  late TurnRequest request;
  late List<Map<String, dynamic>> calls;
  late Future<void> Function(HttpRequest, int) handle;
  setUp(() async {
    request = TurnRequest.fromJson(
      loadContractCases('../packages/xingyuan_core/test/fixtures')
          .first['request'],
    );
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    calls = [];
    handle = (incoming, index) async {
      incoming.response.write(jsonEncode(envelope()));
      await incoming.response.close();
    };
    server.listen((incoming) async {
      calls.add(
        jsonDecode(await utf8.decoder.bind(incoming).join())
            as Map<String, dynamic>,
      );
      await handle(incoming, calls.length);
    });
  });
  tearDown(() => server.close(force: true));
  AssistantModelClient client({
    Duration timeout = const Duration(seconds: 2),
  }) => AssistantModelClient(
    endpoint: Uri.parse('http://127.0.0.1:${server.port}/chat/completions'),
    apiKey: 'synthetic-key',
    timeout: timeout,
  );

  test('strict unique tool and only server system instructions', () async {
    final result = await client().turn(request);
    expect(result.value.plan, isNull);
    expect(result.attempts, 1);
    expect(calls.single['model'], 'gpt-6-luna');
    expect(calls.single['store'], false);
    expect(calls.single['parallel_tool_calls'], false);
    expect(calls.single['tools'][0]['function']['strict'], true);
    expect(
      calls.single['messages'][0]['content'],
      startsWith(assistantSystemPrompt),
    );
    expect(
      calls.single['messages'][0]['content'],
      contains('"minutes_until_midnight":180'),
    );
    expect(
      calls.single['messages'][1]['content'],
      jsonEncode(request.toJson()),
    );
  });
  test('only malformed model output receives one retry', () async {
    handle = (incoming, index) async {
      incoming.response.write(index == 1 ? '{invalid' : jsonEncode(envelope()));
      await incoming.response.close();
    };
    final result = await client().turn(request);
    expect(result.attempts, 2);
    expect(calls.length, 2);
  });
  test('diary capability gets a strict proposal tool but never a save operation', () async {
    request = TurnRequest.fromJson({
      ...request.toJson(),
      'diary_proposals': true,
    });
    handle = (incoming, index) async {
      final body = envelope();
      body['choices'][0]['message']['tool_calls'][0]['function']['arguments'] =
          jsonEncode({
            'reply': '待确认的合成日记建议',
            'plan': null,
            'memory_ops': <Object?>[],
            'diary': {'date': null, 'content': '合成素材：读了十页书。'},
          });
      incoming.response.write(jsonEncode(body));
      await incoming.response.close();
    };
    final result = await client().turn(request);
    expect(result.attempts, 1);
    expect(result.value.diary!.date, isNull);
    expect(result.value.diary!.content, '合成素材：读了十页书。');
    expect(
      calls.single['tools'][0]['function']['parameters'],
      assistantTurnSchemaFor(diaryProposals: true),
    );
    expect(
      calls.single['messages'][0]['content'],
      contains(chatDiarySystemPrompt),
    );
    expect(
      calls.single['messages'][1]['content'],
      jsonEncode(request.toJson()),
    );
    expect(assistantTurnSchema['properties'] as Map, isNot(contains('diary')));
  });
  test(
    'analysis has independent prompt, strict tool and no other context',
    () async {
      final analysis = DayAnalysisRequest.fromJson(analysisFixture());
      handle = (incoming, index) async {
        final body = envelope();
        body['choices'][0]['message']['tool_calls'][0]['function'] = {
          'name': 'analyze_day',
          'arguments': jsonEncode({
            'summary': '今天读完了一章。',
            'suggestions': ['可以记下一点感受。'],
          }),
        };
        incoming.response.write(jsonEncode(body));
        await incoming.response.close();
      };
      final result = await client().analyzeDay(analysis);
      expect(result.value.summary, '今天读完了一章。');
      expect(calls.single['messages'], [
        {'role': 'system', 'content': dayAnalysisSystemPrompt},
        {'role': 'user', 'content': jsonEncode(analysis.toJson())},
      ]);
      expect(calls.single['tools'][0]['function']['name'], 'analyze_day');
      expect(
        calls.single['tools'][0]['function']['parameters'],
        dayAnalysisSchema(withNotes: true),
      );
    },
  );
  test('two invalid responses become 422 without raw content', () async {
    handle = (incoming, index) async {
      incoming.response.write('synthetic-private-invalid');
      await incoming.response.close();
    };
    await expectLater(
      client().turn(request),
      throwsA(
        isA<ModelFailure>()
            .having((error) => error.status, 'status', 422)
            .having((error) => error.attempts, 'attempts', 2)
            .having(
              (error) => error.toString(),
              'safe',
              isNot(contains('private')),
            ),
      ),
    );
  });
  for (final polish in [true, false]) {
    test(
      'journal ${polish ? 'polish' : 'diary'} uses bounded strict tool and isolated text',
      () async {
        final tool = polish ? 'polish_note' : 'generate_diary';
        final source = polish ? polishFixture() : diaryFixture();
        handle = (incoming, index) async {
          final body = envelope();
          body['choices'][0]['message']['tool_calls'][0]['function'] = {
            'name': tool,
            'arguments': jsonEncode(
              polish
                  ? {
                      'rewrite': '我读完一章，想明天再读一点。',
                      'tips': ['保留了原本的打算。'],
                    }
                  : {'status': 'draft', 'draft': '我读完了一章，想晚上早点休息。'},
            ),
          };
          incoming.response.write(jsonEncode(body));
          await incoming.response.close();
        };
        if (polish) {
          await client().polishNote(PolishNoteRequest.fromJson(source));
        } else {
          await client().generateDiary(GenerateDiaryRequest.fromJson(source));
        }
        expect(calls.single['messages'], [
          {
            'role': 'system',
            'content': polish
                ? polishNoteSystemPrompt
                : generateDiarySystemPrompt,
          },
          {'role': 'user', 'content': jsonEncode(source)},
        ]);
        expect(calls.single['model'], 'gpt-6-luna');
        expect(calls.single['store'], false);
        expect(calls.single['parallel_tool_calls'], false);
        expect(calls.single['tools'][0]['function']['name'], tool);
        expect(calls.single['tools'][0]['function']['strict'], true);
        expect(
          calls.single['tools'][0]['function']['parameters'],
          polish ? polishNoteSchema : generateDiarySchema,
        );
      },
    );

    test(
      'journal ${polish ? 'polish' : 'diary'} invalid output retries once then returns safe error',
      () async {
        handle = (incoming, index) async {
          final body = envelope();
          body['choices'][0]['message']['tool_calls'][0]['function'] = {
            'name': polish ? 'polish_note' : 'generate_diary',
            'arguments': jsonEncode(
              polish
                  ? {'rewrite': 'private', 'tips': []}
                  : {'status': 'draft', 'draft': List.filled(1501, 'a').join()},
            ),
          };
          incoming.response.write(jsonEncode(body));
          await incoming.response.close();
        };
        await expectLater(
          polish
              ? client().polishNote(PolishNoteRequest.fromJson(polishFixture()))
              : client().generateDiary(
                  GenerateDiaryRequest.fromJson(diaryFixture()),
                ),
          throwsA(
            isA<ModelFailure>()
                .having((e) => e.status, 'status', 422)
                .having((e) => e.attempts, 'attempts', 2),
          ),
        );
        expect(calls.length, 2);
      },
    );
  }

  test(
    'empty diary never contacts model even with an invalid endpoint',
    () async {
      final result = await client().generateDiary(
        GenerateDiaryRequest.fromJson({
          ...diaryFixture(),
          'entries': [],
          'notes': [],
        }),
      );
      expect(result.value.insufficientMaterial, true);
      expect(result.attempts, 0);
      expect(calls, isEmpty);
    },
  );
  for (final status in [401, 429, 500, 302]) {
    test('upstream $status is not retried or redirected', () async {
      handle = (incoming, index) async {
        incoming.response.statusCode = status;
        incoming.response.headers.set(
          'location',
          'http://127.0.0.1:${server.port}/redirect',
        );
        await incoming.response.close();
      };
      await expectLater(
        client().turn(request),
        throwsA(
          isA<ModelFailure>().having((error) => error.status, 'status', 502),
        ),
      );
      expect(calls.length, 1);
    });
  }
  test('timeout is not retried', () async {
    handle = (incoming, index) async {};
    await expectLater(
      client(timeout: const Duration(milliseconds: 100)).turn(request),
      throwsA(
        isA<ModelFailure>().having((error) => error.status, 'status', 504),
      ),
    );
    expect(calls.length, 1);
  });
  test('truncation, refusal and wrong tool cannot be parsed', () {
    final truncated = envelope();
    truncated['choices'][0]['finish_reason'] = 'length';
    expect(
      () => parseToolArguments(truncated, 'assistant_turn'),
      throwsFormatException,
    );
    final refused = envelope();
    refused['choices'][0]['message']['refusal'] = 'no';
    expect(
      () => parseToolArguments(refused, 'assistant_turn'),
      throwsFormatException,
    );
    expect(
      () => parseToolArguments(envelope(), 'other'),
      throwsFormatException,
    );
  });
  test(
    'schema has strict objects recursively and prompt snapshot is stable',
    () async {
      void check(Object? node) {
        if (node is Map) {
          if (node['type'] == 'object') {
            expect(node['additionalProperties'], false);
            expect(
              (node['required'] as List).toSet(),
              (node['properties'] as Map).keys.toSet(),
            );
          }
          for (final value in node.values) {
            check(value);
          }
        } else if (node is List) {
          for (final value in node) {
            check(value);
          }
        }
      }

      check(assistantTurnSchema);
      check(assistantTurnSchemaFor(diaryProposals: true));
      check(assistantSummarySchema);
      check(dayAnalysisSchema());
      check(dayAnalysisSchema(withNotes: true));
      check(polishNoteSchema);
      check(generateDiarySchema);
      expect(
        assistantSystemPrompt,
        File('test/fixtures/assistant_prompt.txt').readAsStringSync(),
      );
      expect(
        summarySystemPrompt,
        File('test/fixtures/summary_prompt.txt').readAsStringSync(),
      );
    },
  );
}

Map<String, dynamic> envelope() => {
  'choices': [
    {
      'finish_reason': 'tool_calls',
      'message': <String, dynamic>{
        'tool_calls': [
          {
            'type': 'function',
            'function': {
              'name': 'assistant_turn',
              'arguments': jsonEncode({
                'reply': '先聊聊你的想法。',
                'plan': null,
                'memory_ops': [],
              }),
            },
          },
        ],
      },
    },
  ],
  'usage': {'prompt_tokens': 10, 'completion_tokens': 20, 'total_tokens': 30},
};
