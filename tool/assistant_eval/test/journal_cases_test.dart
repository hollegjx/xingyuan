import 'dart:io';

import 'package:test/test.dart';
import 'package:xingyuan_assistant_eval/journal_cases.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

import 'support/cli_process.dart';

void main() {
  test('synthetic cases include both operations, empty day and injection', () {
    final cases = journalAiCases();
    expect(cases, hasLength(10));
    expect(cases.map((c) => c.id).toSet(), hasLength(10));
    expect(cases.where((c) => c.request is PolishNoteRequest), hasLength(3));
    expect(cases.where((c) => c.request is GenerateDiaryRequest), hasLength(7));
    for (final sample in cases.where(
      (c) => c.request is GenerateDiaryRequest,
    )) {
      final request = sample.request as GenerateDiaryRequest;
      final result = GenerateDiaryResponse.insufficient(request);
      expect(
        checkJournalAi(sample, result),
        request.hasMaterial ? ['unexpected_insufficient_material'] : isEmpty,
      );
    }
  });
  test('lexical guard detects synthetic invention, not semantic proof', () {
    final sample = journalAiCases().first;
    final request = sample.request as PolishNoteRequest;
    final response = PolishNoteResponse.fromJson({
      'protocol': assistantProtocol,
      'request_id': request.requestId,
      'rewrite': '我读了三章',
      'tips': ['保持表达。'],
    }, request: request);
    expect(checkJournalAi(sample, response), contains('forbidden:读了三章'));
  });
  test('experience guards flag stock endings but allow the supplied voice', () {
    for (final id in ['DIARY06-own-voice', 'DIARY07-brief']) {
      final sample = journalAiCases().singleWhere((item) => item.id == id);
      final request = sample.request as GenerateDiaryRequest;
      GenerateDiaryResponse response(String text) =>
          GenerateDiaryResponse.fromJson({
            'protocol': assistantProtocol,
            'request_id': request.requestId,
            'status': 'draft',
            'draft': text,
          }, request: request);
      expect(checkJournalAi(sample, response(request.notes.single)), isEmpty);
      expect(
        checkJournalAi(sample, response('今天很充实，明天继续加油。')),
        contains('forbidden:明天继续加油'),
      );
    }
  });
  test('live evaluation cannot start without both explicit flags', () async {
    for (final args in [
      <String>[],
      ['--live'],
      ['--config', '/nonexistent/synthetic.json'],
    ]) {
      final result = await runCli(Platform.resolvedExecutable, [
        'run',
        'bin/journal.dart',
        ...args,
      ]);
      expect(result.exitCode, 64, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stderr, contains('NOT RUN'));
    }
  });
}
