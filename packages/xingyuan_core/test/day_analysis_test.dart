import 'dart:convert';

import 'package:test/test.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

import 'day_analysis_fixture.dart';

void main() {
  test('a day with saved text requires at least one suggestion', () {
    final request = DayAnalysisRequest.fromJson(analysisFixture());
    expect(
      () => DayAnalysisResponse.fromJson({
        'protocol': assistantProtocol,
        'request_id': request.requestId,
        'summary': '今天完成了阅读。',
        'suggestions': <String>[],
      }, request: request),
      throwsFormatException,
    );
  });
  test('own-day request and short response roundtrip', () {
    final request = DayAnalysisRequest.fromJson(analysisFixture());
    expect(request.toJson(), analysisFixture());
    final output = {
      'protocol': assistantProtocol,
      'request_id': request.requestId,
      'summary': '今天读完了一章。',
      'suggestions': ['可以记下一条印象最深的内容。'],
    };
    expect(
      DayAnalysisResponse.fromJson(output, request: request).toJson(),
      output,
    );
  });

  test('empty day and nullable timing do not invent completion', () {
    final input = analysisFixture();
    input['entries'] = [];
    expect(DayAnalysisRequest.fromJson(input).entries, isEmpty);
    final entry =
        (analysisFixture()['entries'] as List).single as Map<String, dynamic>;
    entry.addAll(<String, dynamic>{
      'completed': false,
      'completed_at': null,
      'planned_time': null,
      'planned_minutes': null,
      'text': '',
    });
    input['entries'] = [entry];
    expect(DayAnalysisRequest.fromJson(input).entries.single.completed, false);
  });

  for (final field in [
    'photos',
    'draft_text',
    'memories',
    'owner',
    'messages',
  ]) {
    test('reject private or unknown field $field rather than strip it', () {
      final input = analysisFixture()..[field] = 'private';
      expect(() => DayAnalysisRequest.fromJson(input), throwsFormatException);
      final entryInput = analysisFixture();
      (entryInput['entries'] as List).first[field] = 'private';
      expect(
        () => DayAnalysisRequest.fromJson(entryInput),
        throwsFormatException,
      );
    });
  }

  test('completion consistency, strict timestamps and IDs', () {
    for (final changes in <Map<String, dynamic>>[
      {'completed': false},
      {'completed_at': null},
      {'completed_at': '2026-13-40T12:25:00.000Z'},
      {'completed_at': '2026-10-21T12:25:00'},
      {'planned_time': '24:00'},
      {'planned_minutes': 4},
      {'id': '../../private'},
      {'text': 'x' * 501},
    ]) {
      final input = analysisFixture();
      (input['entries'] as List).first.addAll(changes);
      expect(() => DayAnalysisRequest.fromJson(input), throwsFormatException);
    }
    final duplicate = analysisFixture();
    (duplicate['entries'] as List).add((duplicate['entries'] as List).first);
    expect(() => DayAnalysisRequest.fromJson(duplicate), throwsFormatException);
  });

  test('body limit and result boundaries are explicit', () {
    final input = analysisFixture();
    input['entries'] = List.generate(
      150,
      (index) => {
        ...(analysisFixture()['entries'] as List).first as Map<String, dynamic>,
        'id': 'e${index + 1}',
        'text': '文' * 500,
      },
    );
    expect(
      utf8.encode(jsonEncode(input)).length,
      greaterThan(assistantBodyLimit),
    );
    expect(() => DayAnalysisRequest.fromJson(input), throwsFormatException);
    final request = DayAnalysisRequest.fromJson(analysisFixture());
    final output = {
      'protocol': assistantProtocol,
      'request_id': request.requestId,
      'summary': '内容',
      'suggestions': <String>[],
    };
    for (final changes in [
      {'summary': ''},
      {'summary': '文' * 181},
      {
        'suggestions': ['一', '二', '三'],
      },
      {
        'suggestions': ['文' * 101],
      },
      {
        'suggestions': ['重复', '重复'],
      },
      {'request_id': 'other'},
      {'plan': {}},
    ]) {
      expect(
        () => DayAnalysisResponse.fromJson({
          ...output,
          ...changes,
        }, request: request),
        throwsFormatException,
      );
    }
  });
}
