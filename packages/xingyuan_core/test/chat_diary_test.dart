import 'package:test/test.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

Map<String, Object?> diaryTurn({bool enabled = true}) => {
  'protocol': assistantProtocol,
  'request_id': 'synthetic-diary-1',
  'now': {
    'date': '2026-10-25',
    'weekday': 7,
    'time': '13:00',
    'time_zone': 'Asia/Shanghai',
  },
  'summary': null,
  'messages': [
    {'role': 'user', 'text': '合成素材：今天读了十页书。把上面这段放入今天日记'},
  ],
  'settings': {'auto_memory': false},
  if (enabled) 'diary_proposals': true,
};

Map<String, Object?> diaryResponse({
  String? date = '2026-10-25',
  String? text,
}) => {
  'protocol': assistantProtocol,
  'request_id': 'synthetic-diary-1',
  'reply': '日记建议待你确认，尚未保存。',
  'plan': null,
  'memory_ops': <Object?>[],
  'diary': {'date': date, 'content': text ?? '今天读了十页书。'},
};

void main() {
  test(
    'chat diary proposal is a bounded suggestion, with explicit capability',
    () {
      final request = TurnRequest.fromJson(diaryTurn());
      final response = diaryResponse();
      expect(
        TurnResponse.fromJson(response, request: request).toJson(),
        response,
      );
      expect(request.toJson(), diaryTurn());
    },
  );

  test(
    'ambiguous destination remains null rather than defaulting to today',
    () {
      final response = diaryResponse(date: null);
      expect(
        TurnResponse.fromJson(
          response,
          request: TurnRequest.fromJson(diaryTurn()),
        ).toJson(),
        response,
      );
    },
  );

  test(
    'old clients cannot receive diary actions and old response stays unchanged',
    () {
      final request = TurnRequest.fromJson(diaryTurn(enabled: false));
      expect(
        () => TurnResponse.fromJson(diaryResponse(), request: request),
        throwsFormatException,
      );
      final old = diaryResponse()..remove('diary');
      expect(TurnResponse.fromJson(old, request: request).toJson(), old);
    },
  );

  test(
    'future dates, overflow and model save claims in fields are rejected',
    () {
      final request = TurnRequest.fromJson(diaryTurn());
      for (final response in [
        diaryResponse(date: '2026-10-26'),
        diaryResponse(date: '2026-02-30'),
        diaryResponse(text: '字' * 5001),
        diaryResponse(text: '   '),
        {
          ...diaryResponse(),
          'diary': {'date': null, 'content': '合成', 'saved': true},
        },
      ]) {
        expect(
          () => TurnResponse.fromJson(response, request: request),
          throwsFormatException,
        );
      }
      final boundary = diaryResponse(text: 'e\u0301' * 5000);
      expect(
        TurnResponse.fromJson(boundary, request: request).toJson(),
        boundary,
      );
    },
  );
}
