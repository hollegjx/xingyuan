import 'package:test/test.dart';
import 'package:xingyuan_assistant_eval/cases.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

void main() {
  test('matrix has at least thirty fixed synthetic cases spanning C01-C15', () {
    final cases = evaluationCases();
    expect(cases.length, greaterThanOrEqualTo(30));
    expect(cases.map((sample) => sample.id).toSet().length, cases.length);
    expect(
      cases.map((sample) => sample.id.split('-').first).toSet().length,
      15,
    );
    for (final sample in cases) {
      expect(
        TurnRequest.fromJson(sample.request.toJson()).requestId,
        sample.id,
      );
    }
  });
  test('checker rejects fabricated creation and missing required plan', () {
    final sample = evaluationCases().first;
    final result = TurnResponse.fromJson({
      'protocol': assistantProtocol,
      'request_id': sample.id,
      'reply': '已创建所有目标',
      'plan': null,
      'memory_ops': [],
    }, request: sample.request);
    expect(
      checkResult(sample, result, soft: false),
      containsAll(['no_creation_claim', 'plan', 'count', 'dates']),
    );
  });
  test('approved C02 uses October 25 and C08 distinguishes clarification from planning', () {
    final cases = evaluationCases();
    final week = cases.singleWhere((row) => row.id == 'C02-01');
    expect(week.hard['dates'], [
      '2026-10-20',
      '2026-10-21',
      '2026-10-22',
      '2026-10-23',
      '2026-10-24',
      '2026-10-25',
    ]);
    final clarification = cases.singleWhere((row) => row.id == 'C08-03');
    expect(clarification.request.messages.last.text, '明天帮我排一下');
    expect(clarification.hard['plan'], false);
    expect(clarification.soft['question'], true);
    final plan = cases.singleWhere((row) => row.id == 'C08-04');
    expect(plan.request.messages, hasLength(3));
    expect(plan.request.memories!.single.text, '不喜欢早起');
    expect(plan.hard['plan'], true);
    expect(plan.hard['earliest'], 600);
    final nativeRegression = cases.singleWhere((row) => row.id == 'C08-05');
    expect(nativeRegression.request.messages, hasLength(3));
    expect(nativeRegression.request.memories!.single.text, '不喜欢早起。');
    expect(nativeRegression.hard['earliest'], 600);
  });
  test('original C07 requires a multi-day plan without extra prompting', () {
    final sample = evaluationCases().singleWhere((row) => row.id == 'C07-03');
    expect(sample.request.messages.last.text, '这周把《原则》读完');
    TurnResponse response(List<Map<String, Object?>> tasks) =>
        TurnResponse.fromJson({
          'protocol': assistantProtocol,
          'request_id': sample.id,
          'reply': '建议按天阅读，请在预览确认。',
          'plan': tasks.isEmpty ? null : {'tasks': tasks, 'habits': []},
          'memory_ops': [],
        }, request: sample.request);
    Map<String, Object?> task(String date) => {
      'title': '阅读',
      'date': date,
      'time': null,
      'minutes': null,
    };
    expect(
      checkResult(sample, response([]), soft: false),
      containsAll(['plan', 'min_dates']),
    );
    expect(
      checkResult(sample, response([task('2026-10-20')]), soft: false),
      contains('min_dates'),
    );
    expect(
      checkResult(
        sample,
        response([task('2026-10-20'), task('2026-10-21')]),
        soft: false,
      ),
      isEmpty,
    );
  });
}
