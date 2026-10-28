import 'dart:convert';
import 'dart:io';

import 'package:xingyuan_assistant_eval/agent_eval/live_gate.dart';
import 'package:xingyuan_assistant_eval/agent_eval/source_fingerprint.dart';

Future<void> main(List<String> args) async {
  try {
    final options = AgentDriverOptions.parse(args);
    final root = Directory('../..').resolveSymbolicLinksSync();
    if (!File('$root/tool/agent_eval/headless_test.dart').existsSync()) {
      throw const FormatException('Run from tool/assistant_eval');
    }
    if (options.live) {
      LivePermit.read(
        live: true,
        marker: options.marker,
        productDigest: productFingerprint(root),
      );
    }
    // Worker rechecks all gates. No config/credential is read by the launcher.
    final output = Directory(options.output).absolute.path;
    if (FileSystemEntity.typeSync(output) != FileSystemEntityType.notFound) {
      throw const FormatException('Fresh output required');
    }
    final arguments = [
      args.first,
      '--output',
      output,
      '--fixture-version',
      options.fixtureVersion,
      if (options.live) ...[
        '--authorization',
        File(options.marker!).absolute.path,
        '--config',
        File(options.config!).absolute.path,
      ],
    ];
    final sdk = File(Platform.resolvedExecutable)
        .parent
        .parent
        .parent
        .parent
        .parent
        .path;
    final flutter = '$sdk/bin/flutter';
    final process = await Process.start(
      flutter,
      [
        'test',
        '--no-pub',
        '--concurrency=1',
        '--reporter=expanded',
        '--dart-define=AGENT_EVAL_OPTIONS=${base64Url.encode(utf8.encode(jsonEncode(arguments)))}',
        'tool/agent_eval/headless_test.dart',
      ],
      workingDirectory: root,
      includeParentEnvironment: false,
      environment: {
        for (final key in [
          'HOME',
          'PATH',
          'TMPDIR',
          'LANG',
          'FLUTTER_ROOT',
          'PUB_CACHE',
        ])
          if (Platform.environment[key] != null)
            key: Platform.environment[key]!,
      },
    );
    // Do not reflect arbitrary test/plugin exception text into a live report.
    final outDrain = process.stdout.drain<void>();
    final errDrain = process.stderr.drain<void>();
    int status;
    try {
      status = await process.exitCode.timeout(const Duration(minutes: 30));
    } on Object {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
      rethrow;
    }
    await outDrain;
    await errDrain;
    if (status != 0) {
      stderr.writeln(
        'Agent driver failed; retained artifacts are incomplete. No automatic retry.',
      );
      exitCode = 1;
      return;
    }
    final report =
        jsonDecode(File('$output/report.json').readAsStringSync()) as Map;
    stdout.writeln(
      'Agent report written. Native, semantic and owner acceptance remain unverified.',
    );
    exitCode = report['failed'] != 0
        ? 1
        : report['not_run'] != 0 || report['incomplete'] != 0
        ? 3
        : 0;
  } catch (_) {
    stderr.writeln(
      'NOT RUN: use --scripted --output NEW_DIR, or separately authorized --live --authorization MARKER --config CONFIG --output NEW_DIR. Optional --fixture-version agent-c26-v2|agent-c26-v3.',
    );
    exitCode = 64;
  }
}
