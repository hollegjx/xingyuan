import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:xingyuan_server/src/model_client.dart';

import '../tool/agent_a0_relay_spike.dart';

Json answer(String text) => {
  'choices': [
    {
      'finish_reason': 'stop',
      'message': {'role': 'assistant', 'content': text},
    },
  ],
};

Json call(String name, Object args, {String id = 'synthetic_call'}) => {
  'choices': [
    {
      'finish_reason': 'tool_calls',
      'message': {
        'role': 'assistant',
        'tool_calls': [
          {
            'id': id,
            'type': 'function',
            'function': {
              'name': name,
              'arguments': args is String ? args : jsonEncode(args),
            },
          },
        ],
      },
    },
  ],
};

class ScriptedRelay extends Relay {
  ScriptedRelay(CallLedger ledger, this.replies)
    : super(
        AssistantModelClient(
          endpoint: Uri.parse(
            'https://model.example.invalid/v1/chat/completions',
          ),
          apiKey: 'synthetic-not-a-credential',
        ),
        ledger,
        () {},
      );

  final List<Json> replies;
  final List<Json> requests = [];

  @override
  Future<Json?> send(String caseId, Json body, Duration timeout) async {
    requests.add(jsonDecode(jsonEncode(body)) as Json);
    return replies.removeAt(0);
  }
}

void main() {
  late Directory directory;
  late File file;
  late CallLedger ledger;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('agent-a0-offline-');
    file = File('${directory.path}/ledger');
    ledger = await CallLedger.open(file);
  });
  tearDown(() async {
    await ledger.close();
    await directory.delete(recursive: true);
  });

  test('five strict schemas use auto and disallow parallel calls', () {
    final request = buildRequest([]);
    expect(request['tool_choice'], 'auto');
    expect(request['parallel_tool_calls'], false);
    expect(request['store'], false);
    expect(request['model'], 'gpt-6-luna');
    final definitions = request['tools'] as List;
    expect(definitions, hasLength(5));
    for (final definition in definitions) {
      final function = definition['function'];
      expect(function['strict'], true);
      final schema = function['parameters'];
      expect(schema['additionalProperties'], false);
      expect(schema['required'], (schema['properties'] as Map).keys.toList());
    }
    expect(samples.fold<int>(2, (n, s) => n + s.rounds), 28);
  });

  test('schema rejects unknown fields and wrong nested argument types', () {
    final schema = toolsSchema()[2]['function']['parameters'] as Json;
    final valid = <String, dynamic>{
      'from': fixtureDate,
      'to': fixtureDate,
      'minutes': 30,
      'window': null,
      'daily_cap': null,
    };
    expect(conforms(valid, schema), true);
    expect(conforms({...valid, 'minutes': '30'}, schema), false);
    expect(conforms({...valid, 'user_id': 7}, schema), false);
    expect(conforms({...valid}..remove('window'), schema), false);
    expect(
      conforms({
        ...valid,
        'window': {'start_minute': 1080, 'end_minute': '1320'},
      }, schema),
      false,
    );
  });

  test('only the exact existing HTTPS endpoint is allowed', () {
    expect(
      allowedEndpoint(
        Uri.parse('https://model.example.invalid/v1/chat/completions'),
      ),
      true,
    );
    for (final url in [
      'http://model.example.invalid/v1/chat/completions',
      'https://model.example.invalid.other/v1/chat/completions',
      'https://model.example.invalid:444/v1/chat/completions',
      'https://x@model.example.invalid/v1/chat/completions',
      'https://model.example.invalid/v1/chat/completions?x=1',
      'https://model.example.invalid/v1/chat/completions#x',
      'https://model.example.invalid/v1/responses',
    ]) {
      expect(allowedEndpoint(Uri.parse(url)), false);
    }
  });

  test('call 31 is refused and every reserved call survives reopen', () async {
    for (var i = 0; i < 30; i++) {
      await ledger.reserve('synthetic', 20);
    }
    expect(ledger.calls, 30);
    await expectLater(ledger.reserve('excess', 20), throwsA(isA<SpikeStop>()));
    await ledger.close();
    ledger = await CallLedger.open(file);
    expect(ledger.calls, 30);
    expect(ledger.chargedTokens, 30 * 1520);
    await expectLater(ledger.reserve('again', 20), throwsA(isA<SpikeStop>()));
  });

  test('UTF8 boundary rejects 64000 before reserving a call', () async {
    await expectLater(
      ledger.reserve('oversized', utf8.encode('x' * 64000).length),
      throwsA(isA<SpikeStop>()),
    );
    expect(ledger.calls, 0);
    await ledger.reserve('largest', 63999);
    expect(ledger.calls, 1);
    await expectLater(
      ledger.reserve('token_excess', 63999),
      throwsA(isA<SpikeStop>()),
    );
  });

  test(
    'failed reservation remains charged; completed usage releases bound',
    () async {
      await ledger.reserve('interrupted', 2000);
      final second = await ledger.reserve('finished', 2000);
      await ledger.complete(second, 70);
      expect(ledger.chargedTokens, 3570);
      expect(ledger.calls, 2);
    },
  );

  test('date normalization and out-of-range values are refused', () {
    expect(validDate('2026-10-27'), true);
    expect(validDate('2026-11-10'), true);
    for (final date in ['2026-10-26', '2026-11-11', '2026-10-32']) {
      expect(validDate(date), false);
    }
  });

  test('general reply makes no fixture tool call and logs no body', () async {
    final relay = ScriptedRelay(ledger, [answer('Synthetic answer sentinel')]);
    final row = await runSample(samples.first, relay);
    expect(row['outcome'], 'text');
    expect((row['rounds'] as List).single['kind'], 'text');
    expect(jsonEncode(row), isNot(contains('sentinel')));
  });

  test('tool response keeps exact call ID and non-ok status', () async {
    final relay = ScriptedRelay(ledger, [
      call('query_schedule', {
        'from': fixtureDate,
        'to': fixtureDate,
      }, id: 'c1'),
      answer('Availability is unknown; permission denied.'),
    ]);
    final row = await runSample(
      samples.firstWhere((s) => s.id == 'denied'),
      relay,
    );
    final toolMessage = (relay.requests.last['messages'] as List).last;
    expect(toolMessage['role'], 'tool');
    expect(toolMessage['tool_call_id'], 'c1');
    expect(jsonDecode(toolMessage['content'])['status'], 'not_authorized');
    expect(row['outcome'], 'text');
  });

  test('wrong arguments are not executed and return typed failure', () async {
    final relay = ScriptedRelay(ledger, [
      call('query_schedule', {
        'from': fixtureDate,
        'to': fixtureDate,
        'user': 1,
      }),
      answer('I need valid arguments.'),
    ]);
    final row = await runSample(samples[2], relay);
    expect((row['rounds'] as List).first['schema_valid'], false);
    final toolMessage = (relay.requests.last['messages'] as List).last;
    expect(jsonDecode(toolMessage['content'])['code'], 'invalid_arguments');
  });

  test('a repeated identical call stops before executing again', () async {
    final query = call('query_schedule', {
      'from': fixtureDate,
      'to': fixtureDate,
    });
    final relay = ScriptedRelay(ledger, [query, query]);
    final row = await runSample(samples[2], relay);
    expect(row['outcome'], 'repeat_stopped');
    expect(row['rounds'], hasLength(2));
  });

  test('equivalent reordered arguments count as the same call', () async {
    final relay = ScriptedRelay(ledger, [
      call('query_schedule', {'from': fixtureDate, 'to': fixtureDate}),
      call(
        'query_schedule',
        '{ "to": "2026-10-27", "from": "2026-10-27" }',
        id: 'second_id',
      ),
    ]);
    expect((await runSample(samples[2], relay))['outcome'], 'repeat_stopped');
  });

  test(
    'draft itself is validated even without an earlier validate call',
    () async {
      final item = {
        'title': 'Synthetic reading',
        'date': fixtureDate,
        'start_minute': 1140,
        'minutes': 30,
      };
      final relay = ScriptedRelay(ledger, [
        call('submit_plan_draft', {
          'items': [item],
          'note': '',
        }),
        call('submit_plan_draft', {
          'items': [
            {...item, 'start_minute': 1200},
          ],
          'note': '',
        }),
      ]);
      final row = await runSample(samples[3], relay);
      expect((row['rounds'] as List).first['plan_valid'], false);
      expect(row['outcome'], 'validated_draft');
    },
  );

  test('unknown or parallel tools fail closed', () async {
    final relay = ScriptedRelay(ledger, [call('delete_everything', {})]);
    expect(
      (await runSample(samples[2], relay))['outcome'],
      'invalid_tool_envelope',
    );
    final parallel = call('get_planning_preferences', {});
    final calls = parallel['choices'][0]['message']['tool_calls'] as List;
    calls.add(calls.single);
    final second = ScriptedRelay(ledger, [parallel]);
    expect(
      (await runSample(samples[2], second))['outcome'],
      'invalid_tool_envelope',
    );
  });

  test('four-round followup preserves each actual tool result', () async {
    final items = [
      {
        'title': 'Synthetic reading',
        'date': fixtureDate,
        'start_minute': 1200,
        'minutes': 30,
      },
    ];
    final relay = ScriptedRelay(ledger, [
      call('query_schedule', {
        'from': fixtureDate,
        'to': fixtureDate,
      }, id: 'c1'),
      call('find_free_slots', {
        'from': fixtureDate,
        'to': fixtureDate,
        'minutes': 30,
        'window': null,
        'daily_cap': null,
      }, id: 'c2'),
      call('validate_plan', {'items': items}, id: 'c3'),
      call('submit_plan_draft', {'items': items, 'note': ''}, id: 'c4'),
    ]);
    final result = await runSample(fourRoundSample, relay);
    expect(result['outcome'], 'validated_draft');
    expect(result['rounds'], hasLength(4));
    expect((relay.requests.last['messages'] as List), hasLength(8));
  });
}
