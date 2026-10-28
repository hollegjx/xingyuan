import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:xingyuan_assistant_eval/journal_cases.dart';
import 'package:xingyuan_core/xingyuan_core.dart';
import 'package:xingyuan_server/src/model_client.dart';
import 'package:xingyuan_server/src/model_config.dart';

Future<void> main(List<String> args) async {
  if (args.length != 3 || args[0] != '--live' || args[1] != '--config') {
    stderr.writeln(
      'NOT RUN: requires --live --config PATH; synthetic cases only.',
    );
    exitCode = 64;
    return;
  }
  final run = DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
  final directory = Directory('../../build/journal-eval/$run')
    ..createSync(recursive: true);
  await Process.run('chmod', ['700', directory.path]);
  final digest = sha256.convert([
    for (final path in [
      '../../server/lib/src/prompts.dart',
      '../../server/lib/src/model_client.dart',
      '../../server/lib/src/tool_schema.dart',
      '../../packages/xingyuan_core/lib/src/journal_ai.dart',
      'lib/journal_cases.dart',
    ])
      ...File(path).readAsBytesSync(),
  ]).toString();
  var calls = 0;
  final rows = <Map<String, Object?>>[];
  void save() => File('${directory.path}/report.json').writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert({
      'synthetic_only': true,
      'model': 'gpt-6-luna',
      'source_sha256': digest,
      'calls': calls,
      'results': rows,
      'semantic_review':
          'pending; lexical checks do not prove factual grounding',
    }),
  );
  try {
    final model = await loadModelConfig(
      args[2],
      onCall: () {
        calls++;
        save();
      },
    );
    for (final sample in journalAiCases()) {
      for (var repeat = 1; repeat <= 3; repeat++) {
        final row = <String, Object?>{'case': sample.id, 'repeat': repeat};
        try {
          final Object result;
          final Map<String, Object?> output;
          if (sample.request case final PolishNoteRequest request) {
            final response = await model.polishNote(request);
            result = response.value;
            output = response.value.toJson();
          } else {
            final response = await model.generateDiary(
              sample.request as GenerateDiaryRequest,
            );
            result = response.value;
            output = response.value.toJson();
          }
          row.addAll({
            'output': output,
            'failures': checkJournalAi(sample, result),
          });
        } on ModelFailure catch (failure) {
          row['error'] = failure.code;
        } catch (_) {
          row['error'] = 'evaluation_error';
        }
        rows.add(row);
        save();
        stdout.writeln(
          jsonEncode({
            'case': sample.id,
            'repeat': repeat,
            'error': row['error'],
            'failures': row['failures'],
          }),
        );
      }
    }
    final passed = rows
        .where(
          (row) => row['error'] == null && (row['failures'] as List).isEmpty,
        )
        .length;
    stdout.writeln(
      jsonEncode({
        'passed': passed,
        'total': rows.length,
        'calls': calls,
        'report': '${directory.path}/report.json',
      }),
    );
    if (passed != journalAiCases().length * 3) exitCode = 1;
  } catch (_) {
    save();
    stderr.writeln('Evaluation could not start; check private configuration.');
    exitCode = 1;
  }
}
