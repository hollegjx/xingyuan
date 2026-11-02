import 'dart:convert';

import 'package:test/test.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

import 'package:xingyuan_assistant_eval/assistant_v5_scoring.dart';

void main() {
  final day = CalendarDate.parse('2026-11-01');
  Map<String, Object?> score({
    String material = 'present',
    String end = 'draft',
    bool reversed = false,
    bool earlyQuestion = false,
  }) {
    final requests = <AgentRequest>[];
    final responses = <AgentTurnResponse>[];
    final messages = <Map<String, dynamic>>[
      {
        'role': 'user',
        'content': jsonEncode({
          'context_version': 1,
          'summary': null,
          'messages': [
            {'role': 'user', 'text': 'TEST diary'},
          ],
        }),
      },
    ];
    final order = reversed
        ? ['get_journal_text', 'get_day_summary']
        : ['get_day_summary', 'get_journal_text'];
    for (var i = 0; i < 3; i++) {
      final request = AssistantAgentRequest.fromJson({
        'protocol': assistantAgentProtocol,
        'request_id': 'synthetic',
        'run_id': i == 0 ? null : 'run',
        'turn': i + 1,
        'now': {
          'date': day.key,
          'time': '12:00',
          'weekday': 7,
          'time_zone': 'Asia/Shanghai',
        },
        'messages': messages,
      });
      requests.add(request);
      final question = earlyQuestion || (i == 2 && end == 'question');
      final tool = question || (i == 2 && end == 'text')
          ? null
          : (i < 2 ? order[i] : 'create_diary_draft');
      final arguments = {
        'day': day.key,
        if (tool == 'get_journal_text') 'kinds': ['quickNote', 'diary'],
        if (tool == 'create_diary_draft') 'text': 'TEST 我记下今天的经历。',
      };
      final response = AssistantAgentResponse.fromJson({
        'protocol': assistantAgentProtocol,
        'request_id': 'synthetic',
        'run_id': 'run',
        'turn': i + 1,
        'kind': tool != null
            ? 'tool_call'
            : question
            ? 'question'
            : 'text',
        if (tool != null)
          'tool_call': {
            'id': agentCallId('run', i + 1),
            'type': 'function',
            'function': {'name': tool, 'arguments': jsonEncode(arguments)},
          }
        else
          'text': 'TEST response',
        'budget': {
          'calls': i + 1,
          'charged_tokens': 100,
          'remaining_ms': 59000,
          'violation': false,
        },
      }, request: request);
      responses.add(response);
      if (i == 2 || earlyQuestion) break;
      final result = {
        'status': material == 'blocked'
            ? 'not_authorized'
            : material == 'unknown'
            ? 'truncated'
            : 'ok',
        'data': material == 'blocked'
            ? null
            : {
                'day': day.key,
                if (tool == 'get_journal_text') 'kinds': ['quickNote', 'diary'],
                'items': [
                  if (material == 'present' && tool == 'get_journal_text')
                    {'kind': 'quickNote', 'text': 'TEST saved note'},
                ],
              },
      };
      messages.add(response.call!.message);
      messages.add({
        'role': 'tool',
        'tool_call_id': response.call!.id,
        'content': jsonEncode(result),
      });
    }
    return scoreContinuousDiaryTrajectory(
      day: day,
      requests: requests,
      responses: responses,
    );
  }

  test(
    'C80 nonempty diary must read both tools before draft with zero questions',
    () {
      expect(score()['passed'], true);
      expect(score(end: 'question')['passed'], false);
      expect(score(end: 'text')['passed'], false);
      expect(score(reversed: true)['passed'], false);
    },
  );
  test('C80 empty material still requires a draft without questions', () {
    expect(score(material: 'empty', end: 'question')['passed'], false);
    expect(score(material: 'empty')['passed'], true);
    expect(score(material: 'empty')['empty_material_exception'], false);
    expect(score(material: 'empty', earlyQuestion: true)['passed'], false);
    expect(score(material: 'unknown', end: 'question')['passed'], false);
    expect(score(material: 'blocked', end: 'question')['passed'], false);
    expect(score(material: 'blocked', end: 'text')['passed'], true);
  });
}
