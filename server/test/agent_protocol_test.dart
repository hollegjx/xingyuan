import 'dart:convert';

import 'package:test/test.dart';
import 'package:xingyuan_core/xingyuan_core.dart';
import 'package:xingyuan_server/src/agent_protocol.dart';

import 'support/agent_fixtures.dart';

void main() {
  final today = CalendarDate(2026, 10, 27);
  test('user-visible text bounds count graphemes, not Unicode scalars', () {
    final title = 'e\u0301' * 60;
    final call = agentCall(
      name: 'submit_plan_draft',
      arguments: {
        'items': [
          {
            'title': title,
            'date': '2026-10-27',
            'start_minute': 600,
            'minutes': 30,
          },
        ],
        'note': '',
      },
    );
    expect(
      AgentModelReply.parse(agentEnvelope(call: call), today).outcome.kind,
      'tool_call',
    );
    final over = agentCopy(call);
    final args = jsonDecode(over['function']['arguments'] as String);
    args['items'][0]['title'] =
        '$title'
        'x';
    over['function']['arguments'] = jsonEncode(args);
    expect(
      AgentModelReply.parse(agentEnvelope(call: over), today).outcome.kind,
      'stopped',
    );
  });
  test('D1 business-invalid submit remains available for local invalid result repair', () {
    for (final item in [
      {
        'title': 'synthetic',
        'date': '2026-11-11',
        'start_minute': 600,
        'minutes': 30,
      },
      {
        'title': 'synthetic',
        'date': '2026-10-27',
        'start_minute': 1430,
        'minutes': 30,
      },
    ]) {
      final outcome = AgentModelReply.parse(
        agentEnvelope(
          call: agentCall(
            name: 'submit_plan_draft',
            arguments: {
              'items': [item],
              'note': '',
            },
          ),
        ),
        today,
      ).outcome;
      expect(outcome.kind, 'tool_call');
      expect(outcome.call!.name, 'submit_plan_draft');
    }
  });
  test('only server tools, prompt, model, auto and fixed output limit', () {
    final body = jsonDecode(
      agentModelBody(AgentRequest.fromJson(agentFixture())),
    );
    expect(body['tool_choice'], 'auto');
    expect(body['parallel_tool_calls'], false);
    expect(body['store'], false);
    expect(body['max_completion_tokens'], 1500);
    expect(body['tools'].length, 5);
    expect(body['messages'][0]['role'], 'system');
    void strict(Object? value) {
      if (value is Map) {
        if (value['type'] == 'object') {
          expect(value['additionalProperties'], false);
          expect(
            (value['required'] as List).toSet(),
            (value['properties'] as Map).keys.toSet(),
          );
        }
        value.values.forEach(strict);
      } else if (value is List) {
        value.forEach(strict);
      }
    }

    strict(body['tools']);
    for (final key in [
      'tools',
      'model',
      'system',
      'device',
      'budget',
      'endpoint',
    ]) {
      expect(
        () => AgentRequest.fromJson({...agentFixture(), key: 'override'}),
        throwsFormatException,
      );
    }
  });

  test(
    'typed text and question, never punctuation guessing or draft prose',
    () {
      for (final kind in ['text', 'question']) {
        expect(
          AgentModelReply.parse(
            agentEnvelope(text: true, kind: kind),
            today,
          ).outcome.kind,
          kind,
        );
      }
      expect(
        AgentModelReply.parse(
          agentEnvelope(text: true, kind: 'draft'),
          today,
        ).outcome.code,
        'invalid_model_output',
      );
      final plain = agentEnvelope(text: true);
      plain['choices'][0]['message']['content'] = 'untyped question?';
      expect(
        AgentModelReply.parse(plain, today).outcome.code,
        'invalid_model_output',
      );
    },
  );

  test(
    'mixed text and single valid tool follows tool; multiple calls stop',
    () {
      final mixed = agentEnvelope();
      mixed['choices'][0]['message']['content'] = 'do not treat this as saved';
      expect(AgentModelReply.parse(mixed, today).outcome.kind, 'tool_call');
      mixed['choices'][0]['message']['tool_calls'].add(agentCall(id: 'second'));
      expect(
        AgentModelReply.parse(mixed, today).outcome.code,
        'invalid_model_output',
      );
    },
  );

  test('refusal, length, invalid finish, schema and foreign fields stop', () {
    for (final finish in ['length', 'content_filter', 'function_call', null]) {
      final raw = agentEnvelope();
      raw['choices'][0]['finish_reason'] = finish;
      expect(AgentModelReply.parse(raw, today).outcome.kind, 'stopped');
    }
    final refused = agentEnvelope();
    refused['choices'][0]['message']['refusal'] = 'private refusal';
    expect(AgentModelReply.parse(refused, today).outcome.code, 'model_refusal');
    for (final call in [
      agentCall(name: 'read_file'),
      agentCall(
        arguments: {
          'from': '2026-10-27',
          'to': '2026-10-27',
          'user_id': 'other',
        },
      ),
      agentCall(arguments: {'from': '2026-10-26', 'to': '2026-10-27'}),
      agentCall(arguments: {'from': '2026-10-27', 'to': '2026-11-11'}),
      agentCall(arguments: {'from': '2026-10-31', 'to': '2026-11-31'}),
    ]) {
      expect(
        AgentModelReply.parse(agentEnvelope(call: call), today).outcome.code,
        'invalid_model_output',
      );
    }
    expect(
      AgentModelReply.parse(
        agentEnvelope(
          call: agentCall(
            arguments: {'from': '2026-10-27', 'to': '2026-11-10'},
          ),
        ),
        today,
      ).outcome.kind,
      'tool_call',
    );
  });

  test('draft 14 cap and structural duration bounds validated', () {
    Map<String, dynamic> item() => {
      'title': 'synthetic',
      'date': '2026-10-27',
      'start_minute': 100,
      'minutes': 30,
    };
    for (final count in [1, 14, 15]) {
      final call = agentCall(
        name: 'submit_plan_draft',
        arguments: {'items': List.generate(count, (_) => item()), 'note': ''},
      );
      expect(
        AgentModelReply.parse(agentEnvelope(call: call), today).outcome.kind,
        count <= 14 ? 'tool_call' : 'stopped',
      );
    }
    for (final invalid in [
      {...item(), 'minutes': '30'},
      {...item(), 'minutes': 481},
      {...item(), 'title': ' '},
    ]) {
      expect(
        () => AgentToolCall.parse(
          agentCall(
            name: 'validate_plan',
            arguments: {
              'items': [invalid],
            },
          ),
          today,
        ),
        throwsFormatException,
      );
    }
  });

  test('result caps and non-ok states cannot masquerade as empty success', () {
    for (final status in ['not_authorized', 'failed']) {
      expect(
        validateAgentResult(
          {'status': status, 'data': null},
          'query_schedule',
          today,
        )['status'],
        status,
      );
      expect(
        () => validateAgentResult(
          {
            'status': status,
            'data': {'items': []},
          },
          'query_schedule',
          today,
        ),
        throwsFormatException,
      );
    }
    final partial = {
      'status': 'partial',
      'data': {
        'items': [
          {
            'title': 'synthetic',
            'date': '2026-10-27',
            'start_minute': null,
            'minutes': null,
          },
        ],
      },
    };
    expect(
      validateAgentResult(partial, 'query_schedule', today)['status'],
      'partial',
    );
    expect(
      () => validateAgentResult(
        {...partial, 'status': 'ok'},
        'query_schedule',
        today,
      ),
      throwsFormatException,
    );
    final duplicate = {
      'status': 'duplicate',
      'original_status': 'partial',
      'result': partial,
    };
    expect(validateAgentResult(duplicate, 'query_schedule', today), duplicate);
    expect(
      () => validateAgentResult(
        {...duplicate, 'original_status': 'ok'},
        'query_schedule',
        today,
      ),
      throwsFormatException,
    );
    for (final (name, data) in [
      ('query_schedule', {'items': List.filled(61, partial['data'])}),
      (
        'get_planning_preferences',
        {
          'preferences': List.filled(11, {'text': 'x'}),
        },
      ),
      ('find_free_slots', {'slots': List.filled(21, {}), 'unknown_dates': []}),
      (
        'validate_plan',
        {
          'issues': List.filled(21, {'index': 0, 'code': 'conflict'}),
        },
      ),
    ]) {
      expect(
        () => validateAgentResult(
          {'status': 'truncated', 'data': data},
          name,
          today,
        ),
        throwsFormatException,
      );
    }
  });

  test('canonical keys recursive, but array order and values preserved', () {
    expect(
      agentCanonical({
        'b': [
          {'z': 1, 'a': 2},
        ],
        'a': 0,
      }),
      agentCanonical({
        'a': 0,
        'b': [
          {'a': 2, 'z': 1},
        ],
      }),
    );
    expect(agentDigest([1, 2]), isNot(agentDigest([2, 1])));
  });

  test('orphan, missing, foreign-run and mismatched history rejected', () {
    final response = {
      'run_id': 'run_one',
      'tool_call': agentCall(id: agentCallId('run_one', 1)),
    };
    final good = agentContinue(agentFixture(), response, agentOk());
    expect(AgentRequest.fromJson(good).calls.length, 1);
    final bad = <Map<String, dynamic>>[];
    bad.add(agentCopy(good)..['run_id'] = 'run_two');
    final missing = agentCopy(good);
    (missing['messages'] as List).removeLast();
    bad.add(missing);
    final mismatched = agentCopy(good);
    mismatched['messages'][2]['tool_call_id'] = 'orphan';
    bad.add(mismatched);
    final extra = agentCopy(good);
    extra['messages'][2]['credential'] = 'injected';
    bad.add(extra);
    final system = agentFixture();
    system['messages'][0]['role'] = 'system';
    bad.add(system);
    for (final value in bad) {
      expect(() => AgentRequest.fromJson(value), throwsFormatException);
    }
  });
}
