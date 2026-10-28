import 'dart:convert';
import 'dart:io';

import 'package:xingyuan_assistant_eval/agent_eval/fixtures.dart';
import 'package:xingyuan_assistant_eval/agent_eval/report.dart';
import 'package:xingyuan_assistant_eval/agent_eval/trace.dart';

Future<void> main(List<String> args) async {
  try {
    final options = <String, String>{};
    if (args.isEmpty || args.length.isOdd) throw const FormatException();
    for (var i = 0; i < args.length; i += 2) {
      if (!{'--scripted', '--compare', '--output'}.contains(args[i]) ||
          options.containsKey(args[i]) ||
          args[i + 1].isEmpty) {
        throw const FormatException();
      }
      options[args[i]] = args[i + 1];
    }
    if (!options.containsKey('--scripted') ||
        !options.containsKey('--output')) {
      throw const FormatException();
    }
    final fixtures = File('fixtures/agent_scenarios.json');
    final scenarios = parseAgentScenarios(await fixtures.readAsString());
    Future<Json> run(String path) async => evaluateAgentRun(
      scenarios,
      ScriptedTrajectoryDriver.fromJson(
        object(jsonDecode(await File(path).readAsString())),
      ),
    );
    final report = await run(options['--scripted']!);
    final comparison = options['--compare'] == null
        ? null
        : compareAgentRuns(await run(options['--compare']!), report);
    final out = Directory(options['--output']!);
    // A fresh directory prevents accidental replacement of previous evidence.
    if (await out.exists()) throw const FormatException();
    await out.create(recursive: true);
    const encoder = JsonEncoder.withIndent('  ');
    await File('${out.path}/report.json')
        .writeAsString('${encoder.convert(report)}\n');
    await File('${out.path}/report.md')
        .writeAsString(agentReportMarkdown(report, comparison: comparison));
    if (comparison != null) {
      await File('${out.path}/comparison.json')
          .writeAsString('${encoder.convert(comparison)}\n');
    }
    stdout.writeln(
      'Synthetic scoring report written; product acceptance remains not_run.',
    );
    exitCode = report['failed'] != 0
        ? 1
        : report['not_run'] != 0 || report['incomplete'] != 0
        ? 3
        : 0;
  } catch (_) {
    // Never echo supplied trace text, paths, arguments or parser exceptions.
    stderr.writeln(
      'Invalid offline report input. Use --scripted FILE --output NEW_DIRECTORY [--compare BEFORE_FILE].',
    );
    exitCode = 64;
  }
}
