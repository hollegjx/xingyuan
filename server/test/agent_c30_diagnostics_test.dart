import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:xingyuan_core/xingyuan_core.dart';
import 'package:xingyuan_server/src/agent_ledger.dart';
import 'package:xingyuan_server/src/agent_protocol.dart';
import 'package:xingyuan_server/src/agent_runner.dart';
import 'package:xingyuan_server/src/model_client.dart';

import '../../test/support/agent_c30_replies.dart';
import 'support/agent_fixtures.dart';

void main() {
  final today = CalendarDate(2026, 10, 27);
  final mutations = <String, void Function(Map<String, dynamic>)>{
    'choices_shape': (v) => v['choices'] = [],
    'message_shape': (v) => v['choices'][0]['message'] = null,
    'message_role': (v) => v['choices'][0]['message']['role'] = 'user',
    'finish_reason': (v) => v['choices'][0]['finish_reason'] = 'unexpected',
    'stop_tool_calls': (v) =>
        v['choices'][0]['message']['tool_calls'] = [agentCall()],
    'content_shape': (v) => v['choices'][0]['message']['content'] = null,
    'content_json': (v) =>
        v['choices'][0]['message']['content'] = 'PRIVATE_C30_CANARY',
    'text_fields': (v) => v['choices'][0]['message']['content'] =
        '{"kind":"text","text":"PRIVATE_C30_CANARY","extra":true}',
    'text_kind': (v) => v['choices'][0]['message']['content'] =
        '{"kind":"draft","text":"PRIVATE_C30_CANARY"}',
    'text_value': (v) =>
        v['choices'][0]['message']['content'] = '{"kind":"text","text":null}',
  };
  for (final e in mutations.entries) {
    test('bounded detail ${e.key} retains original stop', () {
      final raw = agentEnvelope(text: true);
      e.value(raw);
      final reply = AgentModelReply.parse(raw, today);
      expect(reply.outcome.code, 'invalid_model_output');
      expect((reply as dynamic).rejectionDetail, e.key);
      expect(
        jsonEncode(reply.outcome.toJson()),
        isNot(contains('PRIVATE_C30_CANARY')),
      );
    });
  }
  for (final e in <String, void Function(Map<String, dynamic>)>{
    'call_fields': (v) => v['extra'] = 'PRIVATE_C30_CANARY',
    'call_type': (v) => v['type'] = 'other',
    'call_id': (v) => v['id'] = 'PRIVATE C30 CANARY',
    'function_fields': (v) => v['function']['extra'] = 'PRIVATE_C30_CANARY',
    'tool_name': (v) => v['function']['name'] = 'read_journal',
    'arguments_text': (v) => v['function']['arguments'] = null,
    'arguments_json': (v) => v['function']['arguments'] = '{PRIVATE_C30_CANARY',
    'arguments_schema': (v) =>
        v['function']['arguments'] = '{"private":"PRIVATE_C30_CANARY"}',
  }.entries) {
    test('tool diagnostic ${e.key} never accepts invalid input', () {
      final call = agentCopy(agentCall());
      e.value(call);
      final reply = AgentModelReply.parse(agentEnvelope(call: call), today);
      expect(reply.outcome.code, 'invalid_model_output');
      expect(reply.rejectionCategory, 'invalid_args');
      expect((reply as dynamic).rejectionDetail, e.key);
    });
  }
  test('valid mixed tool and envelope extras already accepted', () {
    final reply = AgentModelReply.parse(
      c30Reply('R3-S06', 3, 'mixed_submit'),
      today,
    );
    expect(reply.outcome.kind, 'tool_call');
    expect(reply.outcome.call!.message['content'], isNull);
  });
  test('arbitrary diagnostic override is never retained', () {
    final reply = AgentModelReply(
      const AgentOutcome.stop('invalid_model_output'),
      AgentUsage.parse(null),
      rejectionDetail: 'PRIVATE_C30_CANARY',
    );
    expect(reply.rejectionDetail, 'unspecified');
    final valid = AgentModelReply(
      AgentModelReply.parse(agentEnvelope(text: true), today).outcome,
      AgentUsage.parse(null),
      rejectionDetail: 'content_json',
    );
    expect(valid.rejectionDetail, isNull);
  });
  for (final entry in <String, List<int>>{
    'response_body_limit': List.filled(64000, 120),
    'response_encoding': [0xff],
    'response_json': utf8.encode('{PRIVATE_C30_CANARY'),
  }.entries) {
    test(
      '${entry.key} uses exactly one fake HTTP attempt and no raw body',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        var calls = 0;
        server.listen((request) async {
          await request.drain<void>();
          calls++;
          request.response.add(entry.value);
          await request.response.close();
        });
        final client = AssistantModelClient(
          endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
          apiKey: 'synthetic-only',
        );
        final request = AgentRequest.fromJson(agentFixture());
        final reply = await client.agentTurn(
          agentModelBody(request),
          request,
          const Duration(seconds: 5),
        );
        expect(reply.outcome.code, 'invalid_model_output');
        expect(reply.rejectionDetail, entry.key);
        expect(calls, 1);
        expect(
          jsonEncode(reply.outcome.toJson()),
          isNot(contains('PRIVATE_C30_CANARY')),
        );
      },
    );
  }
  for (final fault in [
    'history_mismatch',
    'draft_validation_terminal',
    'app_call_binding',
    'app_budget',
    'app_extra_fields',
  ]) {
    test('three-turn guard $fault remains fail closed', () async {
      final dir = Directory.systemTemp.createTempSync('c30-guard-');
      final ledger = AgentLedger.open('${dir.path}/ledger.sqlite');
      addTearDown(() {
        ledger.close();
        dir.deleteSync(recursive: true);
      });
      var attempts = 0;
      final runner = AgentRunner(
        ledger: ledger,
        transport: (_, request, _) async {
          attempts++;
          return AgentModelReply.parse(
            c30Reply('R2-S05', request.turn, 'mixed_submit'),
            today,
          );
        },
      );
      var raw = agentFixture();
      for (var turn = 1; turn <= 2; turn++) {
        final response = await runner.turn(
          'synthetic',
          AgentRequest.fromJson(raw),
        );
        raw = agentContinue(
          raw,
          Map<String, dynamic>.from(response.body),
          c30Result(c30Sequences['R2-S05']![turn - 1], 'R2-S05'),
        );
      }
      if (fault == 'history_mismatch') {
        raw['messages'][0]['content'] = 'altered synthetic history';
        await expectLater(
          runner.turn('synthetic', AgentRequest.fromJson(raw)),
          throwsA(isA<AgentFailure>().having((e) => e.code, 'code', fault)),
        );
        expect(attempts, 2);
        expect(agentRejectionDetailForCode(fault), fault);
        return;
      }
      final request = AgentRequest.fromJson(raw);
      final response = await runner.turn('synthetic', request);
      final body = Map<String, dynamic>.from(response.body);
      if (fault == 'draft_validation_terminal') {
        final next = agentContinue(
          raw,
          body,
          c30Result('submit_plan_draft', 'R2-S05'),
        );
        await expectLater(
          runner.turn('synthetic', AgentRequest.fromJson(next)),
          throwsA(isA<AgentFailure>().having((e) => e.code, 'code', fault)),
        );
        expect(agentRejectionDetailForCode(fault), fault);
      } else {
        if (fault == 'app_call_binding') {
          body['tool_call']['id'] = 'foreign_run';
        }
        if (fault == 'app_budget') body['budget']['calls'] = 2;
        if (fault == 'app_extra_fields') body['extra'] = 'PRIVATE_C30_CANARY';
        expect(
          () => AgentTurnResponse.fromJson(body, request: request),
          throwsFormatException,
        );
      }
      expect(attempts, 3);
    });
  }
  for (final sequence in c30Sequences.keys) {
    for (final variant in [
      'question',
      'mixed_submit',
      'plain_text',
      'bad_arguments',
    ]) {
      test(
        '$sequence three synthetic turns $variant through server and App contract',
        () async {
          final dir = Directory.systemTemp.createTempSync(
            'c30-synthetic-server-',
          );
          final ledger = AgentLedger.open('${dir.path}/ledger.sqlite');
          addTearDown(() {
            ledger.close();
            dir.deleteSync(recursive: true);
          });
          var attempts = 0;
          AgentModelReply? last;
          final runner = AgentRunner(
            ledger: ledger,
            transport: (_, request, _) async {
              attempts++;
              last = AgentModelReply.parse(
                c30Reply(sequence, request.turn, variant),
                today,
              );
              return last!;
            },
          );
          var raw = agentFixture(
            id: 'synthetic-${sequence.replaceAll('-', '_')}',
          );
          for (var turn = 1; turn <= 3; turn++) {
            final request = AgentRequest.fromJson(raw);
            final response = await runner.turn('synthetic-device', request);
            final app = AgentTurnResponse.fromJson(
              response.body,
              request: request,
            );
            expect(app.turn, turn);
            if (turn < 3) {
              expect(app.call!.name, c30Sequences[sequence]![turn - 1]);
              raw = agentContinue(
                raw,
                Map<String, dynamic>.from(response.body),
                c30Result(app.call!.name, sequence),
              );
            } else {
              expect(app.kind, switch (variant) {
                'question' => 'question',
                'mixed_submit' => 'tool_call',
                _ => 'stopped',
              });
              if (variant == 'plain_text' || variant == 'bad_arguments') {
                expect(app.code, 'invalid_model_output');
                expect(
                  (last as dynamic).rejectionDetail,
                  variant == 'plain_text' ? 'content_json' : 'arguments_json',
                );
              }
            }
          }
          expect(attempts, 3);
        },
      );
    }
  }
}
