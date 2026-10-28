import 'package:test/test.dart';
import 'package:xingyuan_assistant_eval/analysis_cases.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

void main() {
  test(
    'reviewed failures cannot invent atmosphere or turn wishes into actions',
    () {
      for (final (id, summary, rejected) in [
        ('DAY04-no-notes', '阅读完成，为今天留了一段安静投入的时间。', '安静'),
        ('DAY05-adjustment', '泡茶完成，疲惫时你没有勉强去运动。', '没有勉强去运动'),
        ('DAY05-adjustment', '泡茶完成，你选择休息了。', '选择休息'),
        ('DAY06-untrusted-note', '阅读完成，文字与目标无关。', '文字与目标无关'),
      ]) {
        final sample = analysisCases().singleWhere((item) => item.id == id);
        final response = DayAnalysisResponse.fromJson({
          'protocol': assistantProtocol,
          'request_id': sample.request.requestId,
          'summary': summary,
          'suggestions': ['可以试试写下一句真实感受。'],
        }, request: sample.request);
        expect(
          checkAnalysis(sample, response),
          contains('forbidden:$rejected'),
        );
      }
    },
  );
  test('explicitly denying an inference is not the inference itself', () {
    final sample = analysisCases()[1];
    final result = DayAnalysisResponse.fromJson({
      'protocol': assistantProtocol,
      'request_id': sample.request.requestId,
      'summary': '今天调整安排先休息；阅读和整理未标记完成，这不代表实际没有进行。',
      'suggestions': ['可以给休息留出空档。'],
    }, request: sample.request);
    expect(checkAnalysis(sample, result), isEmpty);
  });
  test('unchecked is not evidence that an activity did not happen', () {
    final sample = analysisCases().singleWhere(
      (item) => item.id == 'DAY05-adjustment',
    );
    final result = DayAnalysisResponse.fromJson({
      'protocol': assistantProtocol,
      'request_id': sample.request.requestId,
      'summary': '完成了泡茶。运动今天没有进行。',
      'suggestions': ['可以给休息留出空档。'],
    }, request: sample.request);
    expect(checkAnalysis(sample, result), contains('forbidden:没有进行'));
  });
  test('meaningful adjustment notes require a concrete suggestion', () {
    for (final sample in analysisCases().where(
      (item) => ['DAY02-not-completed', 'DAY05-adjustment'].contains(item.id),
    )) {
      expect(
        () => DayAnalysisResponse.fromJson({
          'protocol': assistantProtocol,
          'request_id': sample.request.requestId,
          'summary': sample.id == 'DAY02-not-completed'
              ? '今天调整了阅读安排，并选择先休息；整理条目没有保存文字。'
              : '今天完成了泡茶，并在喝茶时安静坐了一会。你记录午后很疲惫、今天想休息。',
          'suggestions': <String>[],
        }, request: sample.request),
        throwsFormatException,
      );
    }
  });
  test('eight synthetic days cover data absence, injection and LA', () {
    final cases = analysisCases();
    expect(cases, hasLength(8));
    expect(cases.map((item) => item.id).toSet(), hasLength(8));
    expect(cases.last.request.now.timeZone, 'America/Los_Angeles');
    expect(cases[2].request.entries, isEmpty);
  });
  test('checks reject invented/private context and patronizing language', () {
    final sample = analysisCases().first;
    final result = DayAnalysisResponse.fromJson({
      'protocol': assistantProtocol,
      'request_id': sample.request.requestId,
      'summary': '阅读完成，根据照片你跑了30分钟。',
      'suggestions': ['你必须继续跑。'],
    }, request: sample.request);
    expect(
      checkAnalysis(sample, result),
      containsAll([
        'forbidden:照片',
        'forbidden:必须',
        'forbidden:跑了30分钟',
        'forbidden:继续跑',
      ]),
    );
  });
}
