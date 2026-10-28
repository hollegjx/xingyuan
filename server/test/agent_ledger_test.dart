import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:xingyuan_server/src/agent_ledger.dart';
import 'package:xingyuan_server/src/agent_protocol.dart';
import 'package:xingyuan_server/src/agent_runner.dart';

import 'support/agent_fixtures.dart';

void main() {
  late Directory directory;
  late AgentLedger ledger;
  late DateTime now;
  late int elapsed;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('xingyuan-agent-ledger-');
    now = DateTime.utc(2026, 10, 27, 15);
    elapsed = 0;
    ledger = AgentLedger.open(
      '${directory.path}/agent.sqlite',
      now: () => now,
      elapsedMilliseconds: () => elapsed,
    );
  });
  tearDown(() async {
    ledger.close();
    await directory.delete(recursive: true);
  });
  test(
    'reservation work is deducted from the remaining transport deadline',
    () {
      ledger.close();
      var reads = 0;
      ledger = AgentLedger.open(
        '${directory.path}/agent.sqlite',
        now: () => now,
        elapsedMilliseconds: () => reads++ == 0 ? 0 : 5000,
      );
      final request = AgentRequest.fromJson(agentFixture());
      expect(
        ledger.reserve('device', request, 100).remaining.inMilliseconds,
        55000,
      );
    },
  );
  test(
    'deadline reached during reservation never dispatches a model request',
    () async {
      ledger.close();
      var reads = 0;
      ledger = AgentLedger.open(
        '${directory.path}/agent.sqlite',
        now: () => now,
        elapsedMilliseconds: () => reads++ == 0 ? 0 : 60000,
      );
      var calls = 0;
      final runner = AgentRunner(
        ledger: ledger,
        transport: (_, request, remaining) async {
          calls++;
          return AgentModelReply.parse(agentEnvelope(), request.now.date);
        },
      );
      final result = await runner.turn(
        'device',
        AgentRequest.fromJson(agentFixture()),
      );
      expect(calls, 0);
      expect(result.body['kind'], 'stopped');
      expect(result.body['code'], 'run_deadline');
      expect(result.settlement.tokens, greaterThan(0));
    },
  );
  for (final time in [59999, 60000, 60001, 599999, 600000, 600001]) {
    test('monotonic continuation boundary at ${time}ms', () {
      final source = agentFixture();
      final request = AgentRequest.fromJson(source);
      final reservation = ledger.reserve('device', request, 100);
      final settled = ledger.finish(
        reservation,
        request,
        AgentModelReply.parse(agentEnvelope(), request.now.date),
      );
      final next = AgentRequest.fromJson(
        agentContinue(source, {
          'run_id': reservation.runId,
          'tool_call': settled.outcome.call!.toJson(),
        }, agentOk()),
      );
      elapsed = time;
      if (time < 60000) {
        expect(ledger.reserve('device', next, 100).remaining.inMilliseconds, 1);
      } else {
        expect(
          () => ledger.reserve('device', next, 100),
          throwsA(
            isA<AgentFailure>().having(
              (e) => e.code,
              'code',
              time < 600000 ? 'run_deadline' : 'run_restart_required',
            ),
          ),
        );
      }
    });
  }
  for (final tokens in [23999, 24000, 24001]) {
    test('run reservation boundary $tokens', () {
      final request = AgentRequest.fromJson(agentFixture());
      final bytes = (tokens - 1500) * 2;
      if (tokens <= 24000) {
        expect(ledger.reserve('device', request, bytes).tokens, tokens);
      } else {
        expect(
          () => ledger.reserve('device', request, bytes),
          throwsA(
            isA<AgentFailure>().having(
              (e) => e.code,
              'code',
              'run_token_limit',
            ),
          ),
        );
      }
    });
  }
  for (final total in [399999, 400000, 400001]) {
    test('daily simultaneous reservation boundary $total', () {
      for (var i = 0; i < 16; i++) {
        ledger.reserve(
          'device',
          AgentRequest.fromJson(agentFixture(id: 'run_$i')),
          45000,
        );
      }
      final request = AgentRequest.fromJson(agentFixture(id: 'last'));
      final bytes = (total - 384000 - 1500) * 2;
      if (total <= 400000) {
        ledger.reserve('device', request, bytes);
        expect(ledger.dailyUsage('device', now)['tokens'], total);
      } else {
        expect(
          () => ledger.reserve('device', request, bytes),
          throwsA(
            isA<AgentFailure>().having(
              (e) => e.code,
              'code',
              'daily_token_limit',
            ),
          ),
        );
      }
    });
  }
  Matcher code(String value) =>
      throwsA(isA<AgentFailure>().having((e) => e.code, 'code', value));
  AgentModelReply reply(
    AgentRequest request, {
    int tokens = 120,
    Map<String, dynamic>? call,
    bool text = false,
  }) {
    final raw = agentEnvelope(call: call, text: text);
    raw['usage'] = {
      'prompt_tokens': tokens - 20,
      'completion_tokens': 20,
      'total_tokens': tokens,
    };
    return AgentModelReply.parse(raw, request.now.date);
  }

  Map<String, dynamic> continueWith(
    Map<String, dynamic> source,
    AgentReservation reservation,
    AgentSettlement settled, [
    Map<String, dynamic>? result,
  ]) => agentContinue(source, {
    'run_id': reservation.runId,
    'tool_call': settled.outcome.call!.toJson(),
  }, result ?? agentOk());

  test('reservation charges before dispatch; settlement refunds only verified usage', () {
    final request = AgentRequest.fromJson(agentFixture());
    final reservation = ledger.reserve('device', request, 101);
    expect(reservation.tokens, 1551);
    expect(ledger.dailyUsage('device', now), {'runs': 1, 'tokens': 1551});
    final settled = ledger.finish(reservation, request, reply(request));
    expect(settled.tokens, 120);
    expect(settled.violation, false);
    expect(ledger.dailyUsage('device', now), {'runs': 1, 'tokens': 120});
    expect(
      () => ledger.finish(reservation, request, reply(request)),
      code('ledger_unavailable'),
    );
    expect(ledger.dailyUsage('device', now)['tokens'], 120);
  });

  test('pre-reserve exact 24000 boundary and incoming/outgoing size guard', () {
    final request = AgentRequest.fromJson(agentFixture());
    expect(
      () => ledger.reserve('device', request, 64000),
      code('model_request_too_large'),
    );
    expect(
      () => ledger.reserve('device', request, 45001),
      code('run_token_limit'),
    );
    expect(ledger.dailyUsage('device', now)['runs'], 0);
    final reservation = ledger.reserve('device', request, 45000);
    expect(reservation.tokens, 24000);
    final settled = ledger.finish(
      reservation,
      request,
      reply(request, tokens: 24000),
    );
    expect(settled.tokens, 24000);
    final next = AgentRequest.fromJson(
      continueWith(agentFixture(), reservation, settled),
    );
    expect(() => ledger.reserve('device', next, 100), code('run_token_limit'));
  });

  test('missing, inconsistent, over-reservation and over-output usage stop and debit', () {
    for (final (index, usage) in [
      null,
      {'prompt_tokens': 100, 'completion_tokens': 20, 'total_tokens': 50},
      {'prompt_tokens': 2000, 'completion_tokens': 20, 'total_tokens': 2020},
      {'prompt_tokens': 1, 'completion_tokens': 1501, 'total_tokens': 1502},
      {'prompt_tokens': -1, 'completion_tokens': 1, 'total_tokens': 0},
    ].indexed) {
      final request = AgentRequest.fromJson(
        agentFixture(id: 'synthetic_$index'),
      );
      final reservation = ledger.reserve('device', request, 100);
      final raw = agentEnvelope()..['usage'] = usage;
      final settled = ledger.finish(
        reservation,
        request,
        AgentModelReply.parse(raw, request.now.date),
      );
      expect(settled.outcome.kind, 'stopped');
      expect(settled.violation, true);
      expect(settled.tokens, greaterThanOrEqualTo(1550));
      if (index == 2) expect(settled.tokens, 2020);
    }
  });

  test('six calls max; replayed round never recharges or dispatches', () {
    var source = agentFixture();
    for (var i = 1; i <= 6; i++) {
      final request = AgentRequest.fromJson(source);
      final reservation = ledger.reserve('device', request, 100);
      final settled = ledger.finish(
        reservation,
        request,
        reply(
          request,
          call: agentCall(
            id: 'upstream_$i',
            arguments: {'from': '2026-10-27', 'to': '2026-11-0$i'},
          ),
        ),
      );
      if (i > 1) {
        expect(
          () => ledger.reserve('device', request, 100),
          code('turn_replayed'),
        );
      }
      source = continueWith(source, reservation, settled);
    }
    expect(
      () => ledger.reserve('device', AgentRequest.fromJson(source), 100),
      code('run_call_limit'),
    );
    expect(ledger.dailyUsage('device', now), {'runs': 1, 'tokens': 720});
  });

  test('deadline is monotonic and late result cannot become a draft', () {
    final request = AgentRequest.fromJson(agentFixture());
    final reservation = ledger.reserve('device', request, 100);
    now = now.subtract(const Duration(days: 1));
    elapsed = 60000;
    final settled = ledger.finish(reservation, request, reply(request));
    expect(settled.outcome.code, 'run_deadline');
    expect(settled.remainingMs, 0);
    expect(settled.tokens, 120);
  });

  test(
    'concurrent turn and replayed start cannot reset budget; devices isolated',
    () {
      final request = AgentRequest.fromJson(agentFixture());
      final first = ledger.reserve('device', request, 100);
      expect(
        () => ledger.reserve('device', request, 100),
        code('start_replayed'),
      );
      final settled = ledger.finish(first, request, reply(request));
      final next = AgentRequest.fromJson(
        continueWith(agentFixture(), first, settled),
      );
      ledger.reserve('device', next, 100);
      expect(() => ledger.reserve('device', next, 100), code('run_busy'));
      expect(
        () => ledger.reserve('other', next, 100),
        code('run_restart_required'),
      );
      ledger.reserve('other', request, 100);
      expect(ledger.dailyUsage('device', now)['runs'], 1);
      expect(ledger.dailyUsage('other', now)['runs'], 1);
    },
  );

  test('restart rejects old run and initial replay, retaining crash reservation and daily caps', () {
    final request = AgentRequest.fromJson(agentFixture());
    final first = ledger.reserve('device', request, 100);
    final settled = ledger.finish(first, request, reply(request));
    final nextSource = continueWith(agentFixture(), first, settled);
    final next = AgentRequest.fromJson(nextSource);
    ledger.reserve('device', next, 100);
    final before = ledger.dailyUsage('device', now);
    ledger.close();
    ledger = AgentLedger.open(
      '${directory.path}/agent.sqlite',
      now: () => now,
      elapsedMilliseconds: () => elapsed,
    );
    expect(
      () => ledger.reserve('device', next, 100),
      code('run_restart_required'),
    );
    expect(
      () => ledger.reserve('device', request, 100),
      code('start_replayed'),
    );
    expect(ledger.dailyUsage('device', now), before);
    expect(before['tokens'], 1670);
  });

  test('40 starts per UTC day persists across connections; app clock cannot reset it', () {
    for (var i = 0; i < 40; i++) {
      final request = AgentRequest.fromJson(agentFixture(id: 'run_$i'));
      final reservation = ledger.reserve('device', request, 100);
      ledger.finish(reservation, request, reply(request, text: true));
    }
    final last = AgentRequest.fromJson(agentFixture(id: 'forty_one'));
    expect(() => ledger.reserve('device', last, 100), code('daily_run_limit'));
    final second = AgentLedger.open(
      '${directory.path}/agent.sqlite',
      now: () => now,
    );
    addTearDown(second.close);
    expect(() => second.reserve('device', last, 100), code('daily_run_limit'));
    now = now.add(const Duration(days: 1));
    elapsed += 86400000;
    final reservation = ledger.reserve('device', last, 100);
    expect(reservation.tokens, 1550);
    expect(ledger.dailyUsage('device', now)['runs'], 1);
  });

  test(
    '400000 daily tokens includes simultaneous reservations and crash debit',
    () {
      for (var i = 0; i < 16; i++) {
        ledger.reserve(
          'device',
          AgentRequest.fromJson(agentFixture(id: 'run_$i')),
          45000,
        );
      }
      expect(ledger.dailyUsage('device', now)['tokens'], 384000);
      ledger.reserve(
        'device',
        AgentRequest.fromJson(agentFixture(id: 'exact')),
        29000,
      );
      expect(ledger.dailyUsage('device', now)['tokens'], 400000);
      expect(
        () => ledger.reserve(
          'device',
          AgentRequest.fromJson(agentFixture(id: 'over')),
          1,
        ),
        code('daily_token_limit'),
      );
      expect(ledger.dailyUsage('device', now)['runs'], 17);
    },
  );

  test('history is bound to emitted call and immutable prior content', () {
    final source = agentFixture();
    final request = AgentRequest.fromJson(source);
    final reservation = ledger.reserve('device', request, 100);
    final settled = ledger.finish(reservation, request, reply(request));
    final next = continueWith(source, reservation, settled);
    final forged = agentCopy(next);
    forged['messages'][1]['tool_calls'][0]['function']['arguments'] =
        jsonEncode({'from': '2026-10-28', 'to': '2026-10-28'});
    expect(
      () => ledger.reserve('device', AgentRequest.fromJson(forged), 100),
      code('history_mismatch'),
    );
    final user = agentCopy(next);
    user['messages'][0]['content'] = 'changed';
    expect(
      () => ledger.reserve('device', AgentRequest.fromJson(user), 100),
      code('history_mismatch'),
    );
    expect(ledger.dailyUsage('device', now)['tokens'], 120);
    ledger.reserve('device', AgentRequest.fromJson(next), 100);
  });

  test(
    'second equivalent call requires cached original state; third stops',
    () {
      final source = agentFixture();
      var request = AgentRequest.fromJson(source);
      var reservation = ledger.reserve('device', request, 100);
      var settled = ledger.finish(reservation, request, reply(request));
      final denied = {'status': 'not_authorized', 'data': null};
      final secondSource = continueWith(source, reservation, settled, denied);
      request = AgentRequest.fromJson(secondSource);
      reservation = ledger.reserve('device', request, 100);
      settled = ledger.finish(
        reservation,
        request,
        reply(
          request,
          call: agentCall(
            id: 'upstream_2',
            arguments: {'to': '2026-10-27', 'from': '2026-10-27'},
          ),
        ),
      );
      final fake = continueWith(secondSource, reservation, settled, agentOk());
      expect(
        () => ledger.reserve('device', AgentRequest.fromJson(fake), 100),
        code('duplicate_result_mismatch'),
      );
      final third = continueWith(secondSource, reservation, settled, {
        'status': 'duplicate',
        'original_status': 'not_authorized',
        'result': denied,
      });
      request = AgentRequest.fromJson(third);
      reservation = ledger.reserve('device', request, 100);
      settled = ledger.finish(
        reservation,
        request,
        reply(request, call: agentCall(id: 'upstream_3')),
      );
      expect(settled.outcome.code, 'repeated_tool_call');
      expect(settled.calls, 3);
    },
  );

  test('reused upstream ID stops even with new arguments', () {
    final source = agentFixture();
    var request = AgentRequest.fromJson(source);
    var reservation = ledger.reserve('device', request, 100);
    var settled = ledger.finish(reservation, request, reply(request));
    request = AgentRequest.fromJson(continueWith(source, reservation, settled));
    reservation = ledger.reserve('device', request, 100);
    settled = ledger.finish(
      reservation,
      request,
      reply(
        request,
        call: agentCall(arguments: {'from': '2026-10-28', 'to': '2026-10-28'}),
      ),
    );
    expect(settled.outcome.code, 'reused_model_call_id');
  });

  test('submit invalid may repair, but ok/partial submit cannot continue', () {
    for (final status in ['invalid', 'ok', 'partial']) {
      final source = agentFixture(id: status);
      final request = AgentRequest.fromJson(source);
      final reservation = ledger.reserve('device', request, 100);
      final settled = ledger.finish(
        reservation,
        request,
        reply(
          request,
          call: agentCall(
            name: 'submit_plan_draft',
            arguments: {
              'items': [
                {
                  'title': 'synthetic',
                  'date': '2026-10-27',
                  'start_minute': 600,
                  'minutes': 30,
                },
              ],
              'note': '',
            },
          ),
        ),
      );
      final next = AgentRequest.fromJson(
        continueWith(source, reservation, settled, {
          'status': status,
          'data': {
            'issues': [
              if (status != 'ok')
                {
                  'index': 0,
                  'code': status == 'invalid' ? 'conflict' : 'unknown_schedule',
                },
            ],
          },
        }),
      );
      if (status == 'invalid') {
        ledger.reserve('device', next, 100);
      } else {
        expect(
          () => ledger.reserve('device', next, 100),
          code('draft_validation_terminal'),
        );
      }
    }
  });

  test('ten-minute run expiry never restores old run; persisted data is metadata only', () {
    final source = agentFixture();
    final request = AgentRequest.fromJson(source);
    final reservation = ledger.reserve('device', request, 100);
    final settled = ledger.finish(reservation, request, reply(request));
    final next = AgentRequest.fromJson(
      continueWith(source, reservation, settled),
    );
    now = now.add(const Duration(minutes: 10));
    elapsed = 600000;
    expect(
      () => ledger.reserve('device', next, 100),
      code('run_restart_required'),
    );
    ledger.reserve(
      'device',
      AgentRequest.fromJson(agentFixture(id: 'cleanup')),
      100,
    );
    final db = sqlite3.open('${directory.path}/agent.sqlite');
    try {
      expect(
        db.select('SELECT 1 FROM agent_runs WHERE id=?', [reservation.runId]),
        isEmpty,
      );
      final metadata = jsonEncode([
        for (final table in ['agent_runs', 'agent_daily', 'agent_starts'])
          db
              .select('SELECT * FROM $table')
              .map((r) => Map<String, Object?>.from(r))
              .toList(),
      ]);
      expect(metadata, isNot(contains('synthetic-private')));
      expect(metadata, isNot(contains('upstream_1')));
      expect(metadata, isNot(contains('messages')));
    } finally {
      db.close();
    }
  });
}
