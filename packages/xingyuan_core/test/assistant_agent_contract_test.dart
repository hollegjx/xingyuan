import 'dart:convert';

import 'package:test/test.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

void main() {
  final today = CalendarDate.parse('2026-11-01');
  Map<String, dynamic> call(String name, Map<String, dynamic> args) => {
    'id': 'test',
    'type': 'function',
    'function': {'name': name, 'arguments': jsonEncode(args)},
  };
  test('all eight record dates accepted and adjacent dates rejected', () {
    for (var i = -8; i <= 1; i++) {
      final raw = call('get_journal_text', {
        'day': today.addDays(i).key,
        'kinds': ['quickNote'],
      });
      if (i < -7 || i > 0) {
        expect(
          () => AssistantAgentCall.parse(raw, today),
          throwsFormatException,
        );
      } else {
        expect(
          AssistantAgentCall.parse(raw, today).arguments['day'],
          today.addDays(i).key,
        );
      }
      expect(() => AgentToolCall.parse(raw, today), throwsFormatException);
    }
  });
  test('unknown keys, invalid kinds and injected owner are format errors', () {
    for (final args in [
      {
        'day': today.key,
        'kinds': ['quickNote'],
        'owner': 'other',
      },
      {
        'day': today.key,
        'kinds': ['quickNote', 'quickNote'],
      },
      {
        'day': today.key,
        'kinds': [1],
      },
      {
        'day': today.key,
        'kinds': ['photos'],
      },
    ]) {
      expect(
        () => AssistantAgentCall.parse(call('get_journal_text', args), today),
        throwsFormatException,
      );
    }
  });
  test(
    'v1 results stay strict and v2 does not accept extra private fields',
    () {
      final result = {
        'status': 'ok',
        'data': {
          'day': today.key,
          'kinds': ['diary'],
          'items': [
            {'kind': 'diary', 'text': 'TEST'},
          ],
        },
      };
      expect(
        validateAssistantAgentResult(result, 'get_journal_text', today),
        result,
      );
      expect(
        () => validateAgentResult(result, 'get_journal_text', today),
        throwsFormatException,
      );
      final private = {
        'status': 'ok',
        'data': {
          'day': today.key,
          'kinds': ['diary'],
          'items': [
            {'kind': 'diary', 'text': 'TEST', 'photo': 'TEST'},
          ],
        },
      };
      expect(
        () => validateAssistantAgentResult(private, 'get_journal_text', today),
        throwsFormatException,
      );
    },
  );
  test('12000 byte bound covers multibyte results and duplicate wrappers', () {
    final result = {
      'status': 'ok',
      'data': {
        'day': today.key,
        'kinds': ['quickNote'],
        'items': List.generate(
          20,
          (_) => {'kind': 'quickNote', 'text': '汉' * 2000},
        ),
      },
    };
    expect(
      () => validateAssistantAgentResult(result, 'get_journal_text', today),
      throwsFormatException,
    );
    expect(
      () => validateAssistantAgentResult(
        {
          'status': 'failed',
          'data': {'text': 'secret'},
        },
        'get_journal_text',
        today,
      ),
      throwsFormatException,
    );
  });
  test(
    'C76 summary timing validates actual UTC completion and nullable plans',
    () {
      final item = <String, dynamic>{
        'title': 'TEST task',
        'planned_time': '09:00',
        'planned_minutes': 30,
        'completed': true,
        'completed_at': '2026-11-01T02:30:00.000Z',
        'text': 'TEST saved',
      };
      Map<String, dynamic> result(Map<String, dynamic> row) => {
        'status': 'ok',
        'data': {
          'day': today.key,
          'items': [row],
        },
      };
      expect(
        validateAssistantAgentResult(result(item), 'get_day_summary', today),
        result(item),
      );
      expect(
        () => validateAssistantAgentResult(
          result({...item, 'completed_at': null}),
          'get_day_summary',
          today,
        ),
        throwsFormatException,
      );
      expect(
        () => validateAssistantAgentResult(
          result({...item, 'planned_time': '24:00'}),
          'get_day_summary',
          today,
        ),
        throwsFormatException,
      );
      expect(
        () => validateAssistantAgentResult(
          result({...item, 'planned_time': '23:50'}),
          'get_day_summary',
          today,
        ),
        throwsFormatException,
      );
      expect(
        () => validateAssistantAgentResult(
          result({...item, 'completed_at': '2026-11-01T02:30:00'}),
          'get_day_summary',
          today,
        ),
        throwsFormatException,
      );
      expect(
        validateAssistantAgentResult(
          result({
            ...item,
            'planned_time': null,
            'planned_minutes': null,
            'completed': false,
            'completed_at': null,
          }),
          'get_day_summary',
          today,
        )['status'],
        'ok',
      );
    },
  );
}
