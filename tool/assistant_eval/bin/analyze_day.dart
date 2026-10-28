import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:xingyuan_assistant_eval/analysis_cases.dart';
import 'package:xingyuan_server/src/model_client.dart';
import 'package:xingyuan_server/src/model_config.dart';

Future<void> main(List<String> args) async {
  if (!args.contains('--live')) {
    stderr.writeln(
      'NOT RUN: requires --live; only committed synthetic cases are used.',
    );
    exitCode = 64;
    return;
  }
  final configIndex = args.indexOf('--config');
  if (configIndex >= 0 && configIndex + 1 >= args.length) {
    exitCode = 64;
    return;
  }
  final config = configIndex < 0
      ? '../../config/assistant-server.local.json'
      : args[configIndex + 1];
  final run = DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
  final directory = Directory('../../build/analysis-eval/$run')
    ..createSync(recursive: true);
  await Process.run('chmod', ['700', directory.path]);
  final results = <Map<String, Object?>>[];
  var calls = 0;
  final sourceDigest = sha256.convert([
    for (final path in [
      '../../server/lib/src/prompts.dart',
      '../../server/lib/src/model_client.dart',
      '../../server/lib/src/tool_schema.dart',
      '../../packages/xingyuan_core/lib/src/day_analysis.dart',
      'lib/analysis_cases.dart',
    ])
      ...File(path).readAsBytesSync(),
  ]).toString();
  void save() => File('${directory.path}/report.json').writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert({
      'synthetic_only': true,
      'model': 'gpt-6-luna',
      'reasoning': 'none',
      'source_sha256': sourceDigest,
      'calls': calls,
      'results': results,
      'semantic_review':
          'pending; automated checks do not prove absence of invented facts',
    }),
  );
  try {
    final model = await loadModelConfig(
      config,
      onCall: () {
        calls++;
        save();
      },
    );
    for (final sample in analysisCases()) {
      for (var repeat = 1; repeat <= 3; repeat++) {
        final row = <String, Object?>{'case': sample.id, 'repeat': repeat};
        try {
          final result = await model.analyzeDay(sample.request);
          row.addAll({
            'output': result.value.toJson(),
            'attempts': result.attempts,
            'usage': result.usage,
            'failures': checkAnalysis(sample, result.value),
          });
        } on ModelFailure catch (error) {
          row.addAll({'error': error.code, 'attempts': error.attempts});
        } catch (_) {
          row['error'] = 'evaluation_error';
        }
        results.add(row);
        save();
        stdout.writeln(
          jsonEncode({
            'case': sample.id,
            'repeat': repeat,
            'failures': row['failures'],
            'error': row['error'],
          }),
        );
      }
    }
    final passed = results
        .where(
          (row) => row['error'] == null && (row['failures'] as List).isEmpty,
        )
        .length;
    stdout.writeln(
      jsonEncode({
        'passed': passed,
        'total': results.length,
        'calls': calls,
        'report': '${directory.path}/report.json',
      }),
    );
    if (passed != 24) exitCode = 1;
  } catch (_) {
    save();
    stderr.writeln('Evaluation could not start; check private configuration.');
    exitCode = 1;
  }
}
