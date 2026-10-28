import 'package:test/test.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

import 'journal_ai_fixture.dart';

void main() {
  test('journal contracts round trip only explicit text fields', () {
    expect(
      PolishNoteRequest.fromJson(polishFixture()).toJson(),
      polishFixture(),
    );
    expect(
      GenerateDiaryRequest.fromJson(diaryFixture()).toJson(),
      diaryFixture(),
    );
  });

  test('reject photos, memory, history and unknown fields at every level', () {
    for (final key in ['photos', 'memory', 'history', 'owner', 'messages']) {
      expect(
        () => PolishNoteRequest.fromJson({...polishFixture(), key: []}),
        throwsFormatException,
      );
      expect(
        () => GenerateDiaryRequest.fromJson({...diaryFixture(), key: []}),
        throwsFormatException,
      );
      final nested = diaryFixture();
      (nested['entries'] as List).first[key] = [];
      expect(
        () => GenerateDiaryRequest.fromJson(nested),
        throwsFormatException,
      );
    }
    expect(
      () => GenerateDiaryRequest.fromJson({
        ...diaryFixture(),
        'notes': [
          {'text': 'x', 'photo': 'x'},
        ],
      }),
      throwsFormatException,
    );
  });

  test('length limits use graphemes and independently bound UTF-8 bytes', () {
    final emoji = List.filled(1000, '👩🏽‍💻').join();
    expect(
      PolishNoteRequest.fromJson({...polishFixture(), 'text': emoji}).text,
      emoji,
    );
    expect(
      () =>
          PolishNoteRequest.fromJson({...polishFixture(), 'text': '${emoji}x'}),
      throwsFormatException,
    );
    expect(
      () => PolishNoteRequest.fromJson({...polishFixture(), 'text': ' \n '}),
      throwsFormatException,
    );
    expect(
      () => PolishNoteRequest.fromJson({
        ...polishFixture(),
        'text': 'a${List.filled(40000, '\u0301').join()}',
      }),
      throwsFormatException,
    );
    expect(
      () => GenerateDiaryRequest.fromJson({
        ...diaryFixture(),
        'notes': List.filled(100, List.filled(1000, '字').join()),
      }),
      throwsFormatException,
    );
    expect(
      () => GenerateDiaryRequest.fromJson({
        ...diaryFixture(),
        'day': '2026-02-30',
      }),
      throwsFormatException,
    );
  });

  test('polish responses bind request and require bounded distinct tips', () {
    final request = PolishNoteRequest.fromJson(polishFixture());
    final response = {
      'protocol': assistantProtocol,
      'request_id': request.requestId,
      'rewrite': '我读完一章，想明天再读一点。',
      'tips': ['保留了原本的打算。'],
    };
    expect(
      PolishNoteResponse.fromJson(response, request: request).toJson(),
      response,
    );
    for (final invalid in [
      {...response, 'request_id': 'wrong'},
      {...response, 'rewrite': ''},
      {...response, 'rewrite': List.filled(1001, 'a').join()},
      {...response, 'tips': <String>[]},
      {
        ...response,
        'tips': ['a', 'a'],
      },
      {
        ...response,
        'tips': ['a', 'b', 'c'],
      },
      {...response, 'photos': []},
    ]) {
      expect(
        () => PolishNoteResponse.fromJson(invalid, request: request),
        throwsFormatException,
      );
    }
  });

  test('empty and unchecked-only sources cannot produce invented diary', () {
    final request = GenerateDiaryRequest.fromJson({
      ...diaryFixture(),
      'entries': [
        {'title': '跑步', 'completed': false, 'text': ''},
      ],
      'notes': [' '],
    });
    expect(request.hasMaterial, false);
    final empty = GenerateDiaryResponse.insufficient(request);
    expect(
      GenerateDiaryResponse.fromJson(
        empty.toJson(),
        request: request,
      ).insufficientMaterial,
      true,
    );
    expect(
      () => GenerateDiaryResponse.fromJson({
        ...empty.toJson(),
        'status': 'draft',
        'draft': '我跑了步',
      }, request: request),
      throwsFormatException,
    );
    expect(
      () => GenerateDiaryResponse.fromJson({
        ...empty.toJson(),
        'draft': '我很开心',
      }, request: request),
      throwsFormatException,
    );
  });

  test(
    'diary output is capped, bound to request and may decline unsafe material',
    () {
      final request = GenerateDiaryRequest.fromJson(diaryFixture());
      final response = {
        'protocol': assistantProtocol,
        'request_id': request.requestId,
        'status': 'draft',
        'draft': '我今天读完了一章。',
      };
      expect(
        GenerateDiaryResponse.fromJson(response, request: request).draft,
        response['draft'],
      );
      for (final invalid in [
        {...response, 'request_id': 'wrong'},
        {...response, 'status': 'other'},
        {...response, 'draft': ''},
        {...response, 'draft': List.filled(1501, 'a').join()},
        {...response, 'photos': []},
      ]) {
        expect(
          () => GenerateDiaryResponse.fromJson(invalid, request: request),
          throwsFormatException,
        );
      }
      expect(
        GenerateDiaryResponse.fromJson(
          GenerateDiaryResponse.insufficient(request).toJson(),
          request: request,
        ).insufficientMaterial,
        true,
      );
    },
  );
}
