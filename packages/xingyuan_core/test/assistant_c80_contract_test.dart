import 'dart:convert';

import 'package:test/test.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

void main() {
  AgentRequest request(bool optIn, {bool v1 = false}) =>
      parseAssistantAgentRequest({
        'protocol': v1 ? agentProtocol : assistantAgentProtocol,
        'request_id': 'synthetic',
        'run_id': null,
        'turn': 1,
        'now': {
          'date': '2026-11-02',
          'time': '12:00',
          'weekday': 1,
          'time_zone': 'Asia/Shanghai',
        },
        'messages': [
          {
            'role': 'user',
            'content': jsonEncode({
              if (optIn) 'context_version': 1,
              'summary': null,
              'messages': [
                {'role': 'user', 'text': 'Hi'},
              ],
            }),
          },
        ],
      });
  Map<String, dynamic> response(AgentRequest r) => {
    'protocol': r.toJson()['protocol'],
    'request_id': r.requestId,
    'run_id': 'synthetic-run',
    'turn': 1,
    'kind': 'text',
    'text': 'Hello',
    'budget': {
      'calls': 1,
      'charged_tokens': 120,
      'remaining_ms': 50000,
      'violation': false,
    },
  };
  test(
    'optional memory roundtrips only with explicit contextual v2 request',
    () {
      final r = request(true);
      final raw = response(r)..['memory_summary'] = '中' * 1200;
      final parsed = parseAssistantAgentResponse(
        raw,
        request: r,
      ) as AssistantAgentResponse;
      expect(parsed.toJson(), raw);
      expect(
        parseAssistantAgentResponse(response(r), request: r).text,
        'Hello',
      );
      raw['memory_summary'] = '中' * 1201;
      expect(
        () => parseAssistantAgentResponse(raw, request: r),
        throwsFormatException,
      );
      for (final legacy in [request(false), request(true, v1: true)]) {
        expect(assistantContextEnabled(legacy), false);
        expect(
          () => parseAssistantAgentResponse(
            response(legacy)..['memory_summary'] = 'private',
            request: legacy,
          ),
          throwsFormatException,
        );
      }
    },
  );
  test('unknown fields and non-text memory are rejected', () {
    final r = request(true);
    for (final value in [
      null,
      42,
      {'text': 'bad'},
    ]) {
      expect(
        () => parseAssistantAgentResponse(
          response(r)..['memory_summary'] = value,
          request: r,
        ),
        throwsFormatException,
      );
    }
    expect(
      () => parseAssistantAgentResponse(
        response(r)..['photo'] = 'SYNTHETIC_PHOTO',
        request: r,
      ),
      throwsFormatException,
    );
  });
}
