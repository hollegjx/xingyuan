import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:xingyuan_assistant_eval/cases.dart';
import 'package:xingyuan_server/src/model_client.dart';
import 'package:xingyuan_server/src/model_config.dart';

Future<void> main(List<String> args) async {
  String option(String name, String fallback) {
    final index = args.indexOf(name);
    return index < 0 ? fallback : args[index + 1];
  }

  if (!args.contains('--live')) {
    stdout.writeln(
      'NOT RUN: real model evaluation requires --live and synthetic cases.',
    );
    exitCode = 64;
    return;
  }
  final reasoning = option('--reasoning', 'none');
  final repeats = int.parse(option('--repeats', '3'));
  final selected = option('--only', '');
  final runId = DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
  final directory = Directory('../../build/assistant-eval/$runId-$reasoning')
    ..createSync(recursive: true);
  await Process.run('chmod', ['700', directory.path]);
  final report = File('${directory.path}/report.json');
  final results = <Map<String, Object?>>[];
  var calls = 0;
  final start = DateTime.now().toUtc();
  final git = await Process.run('git', ['rev-parse', 'HEAD']);
  final sourcePaths = [
    '../../server/lib/src/prompts.dart',
    '../../server/lib/src/model_client.dart',
    '../../server/lib/src/tool_schema.dart',
    '../../packages/xingyuan_core/lib/src/protocol.dart',
    'lib/cases.dart',
  ];
  final sourceDigest = sha256.convert([
    for (final path in sourcePaths) ...File(path).readAsBytesSync(),
  ]).toString();
  final cases = evaluationCases()
      .where((sample) => selected.isEmpty || sample.id == selected)
      .toList();
  if (cases.isEmpty || repeats < 1 || repeats > 3) {
    throw const FormatException('Invalid evaluation selection');
  }
  void save() {
    report.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'started_at': start.toIso8601String(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
        'model': 'gpt-6-luna',
        'git_commit': git.exitCode == 0 ? (git.stdout as String).trim() : null,
        'source_sha256': sourceDigest,
        'reasoning': reasoning,
        'max_completion_tokens': 4000,
        'calls': calls,
        'case_count': cases.length,
        'repeats': repeats,
        'results': results,
        'c02_calendar_confirmation_pending': false,
        'owner_decisions_date': '2026-10-20',
      }),
    );
  }

  final client = await loadModelConfig(
    option('--config', '../../config/planning-gateway.local.json'),
    reasoning: reasoning,
    onCall: () {
      calls++;
      save();
    },
  );
  save();
  var next = 0;
  final jobs = [
    for (final sample in cases)
      for (var repeat = 1; repeat <= repeats; repeat++) (sample, repeat),
  ];
  Future<void> worker() async {
    while (next < jobs.length) {
      final (sample, repeat) = jobs[next++];
      final watch = Stopwatch()..start();
      final row = <String, Object?>{'case': sample.id, 'repeat': repeat};
      try {
        final result = await client.turn(sample.request);
        row.addAll({
          'valid': true,
          'attempts': result.attempts,
          'usage': result.usage,
          'hard_failures': checkResult(sample, result.value, soft: false),
          'soft_failures': checkResult(sample, result.value, soft: true),
          'soft_checks': sample.soft.length,
          'output': result.value.toJson(),
        });
      } on ModelFailure catch (error) {
        row.addAll({
          'valid': false,
          'attempts': error.attempts,
          'error': error.code,
          'status': error.status,
        });
      } catch (_) {
        row.addAll({'valid': false, 'error': 'evaluation_error'});
      }
      row['elapsed_ms'] = watch.elapsedMilliseconds;
      results.add(row);
      save();
      stdout.writeln(
        jsonEncode({
          for (final key in [
            'case',
            'repeat',
            'valid',
            'hard_failures',
            'soft_failures',
            'error',
            'elapsed_ms',
          ])
            if (row.containsKey(key)) key: row[key],
        }),
      );
    }
  }

  // Two bounded workers match the service's per-device concurrency budget.
  final first = worker();
  await worker();
  await first;
  final valid = results.where((row) => row['valid'] == true).length;
  final hardPass = results
      .where(
        (row) => row['valid'] == true && (row['hard_failures'] as List).isEmpty,
      )
      .length;
  final softTotal = results.fold(
    0,
    (n, row) => n + ((row['soft_checks'] as int?) ?? 0),
  );
  final softFailed = results.fold(
    0,
    (n, row) => n + ((row['soft_failures'] as List?)?.length ?? 0),
  );
  final softRate = softTotal == 0 ? 1.0 : (softTotal - softFailed) / softTotal;
  stdout.writeln(
    jsonEncode({
      'runs': results.length,
      'calls': calls,
      'valid': valid,
      'hard_pass': hardPass,
      'soft_pass_rate': softRate,
      'report': report.absolute.path,
      'full_matrix': selected.isEmpty && repeats == 3,
      'calendar_confirmation_pending': false,
    }),
  );
  if (valid != jobs.length || hardPass != jobs.length || softRate < .85) {
    exitCode = 1;
  }
}
