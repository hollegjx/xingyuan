import 'dart:convert';

import 'package:test/test.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

import 'fixture_contract.dart';

void main() {
  for (final fixture in loadContractCases('test/fixtures')) {
    test('shared fixture ${fixture['id']}', () {
      expect(acceptsContractCase(fixture), fixture['accept']);
    });
  }

  test('calendar weeks use Mondays, including month and year boundaries', () {
    expect(
      CalendarDate.parse('2026-10-20').remainingWeek.last.key,
      '2026-10-25',
    );
    expect(CalendarDate.parse('2026-10-20').nextWeek.first.key, '2026-10-26');
    expect(CalendarDate.parse('2026-10-25').remainingWeek.length, 1);
    expect(CalendarDate.parse('2028-02-28').addDays(1).key, '2028-02-29');
    expect(CalendarDate.parse('2026-12-31').addDays(1).key, '2027-01-01');
  });

  test('decode failures never expose source and enforce UTF-8 size', () {
    try {
      decodeAssistantJson('{"secret":"synthetic-private');
      fail('expected failure');
    } on FormatException catch (error) {
      expect(error.toString(), isNot(contains('synthetic-private')));
      expect(error.source, isNull);
    }
    expect(
      () => decodeAssistantJson(jsonEncode('字' * 22000)),
      throwsFormatException,
    );
  });

  test('summary protocol bounds and correlation', () {
    final request = {
      'protocol': assistantProtocol,
      'request_id': 'summary-1',
      'summary': null,
      'messages': [
        {'role': 'user', 'text': '周三要加班'},
      ],
    };
    expect(SummaryRequest.fromJson(request).toJson(), request);
    final response = {
      'protocol': assistantProtocol,
      'request_id': 'summary-1',
      'summary': '周三需要加班，其他晚上可以读书。',
    };
    expect(
      SummaryResponse.fromJson(response, requestId: 'summary-1').toJson(),
      response,
    );
    expect(
      () => SummaryResponse.fromJson(response, requestId: 'other'),
      throwsFormatException,
    );
    expect(
      () => SummaryResponse.fromJson({
        ...response,
        'summary': '字' * 1501,
      }, requestId: 'summary-1'),
      throwsFormatException,
    );
    expect(
      () => SummaryRequest.fromJson({...request, 'messages': []}),
      throwsFormatException,
    );
  });

  test('unicode title length uses graphemes, not UTF-16 code units', () {
    expect(
      PlanTask.fromJson({
        'title': '📚' * 60,
        'date': '2026-10-20',
        'time': null,
        'minutes': 5,
      }, habit: false).title,
      '📚' * 60,
    );
  });

  test('opt-out fields stay absent after serialization', () {
    final fixture = loadContractCases('test/fixtures')
        .singleWhere((testCase) => testCase['id'] == 'valid-category-opt-out');
    final json = TurnRequest.fromJson(fixture['request']).toJson();
    for (final key in ['memories', 'schedule', 'stats']) {
      expect(json.containsKey(key), isFalse);
    }
  });
}
