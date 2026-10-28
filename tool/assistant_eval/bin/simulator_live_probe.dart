import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:xingyuan_server/src/device_registry.dart';
import 'package:xingyuan_server/src/model_config.dart';
import 'package:xingyuan_server/src/service.dart';

// This runner only targets an already booted simulator, never a physical phone.
Future<void> main(List<String> args) async {
  final options = <String, String>{};
  var live = false;
  for (var index = 0; index < args.length; index++) {
    final arg = args[index];
    if (arg == '--live' && !live) {
      live = true;
    } else if ([
          '--simulator',
          '--run',
          '--flutter',
          '--config',
          '--suite',
        ].contains(arg) &&
        !options.containsKey(arg) &&
        index + 1 < args.length &&
        !args[index + 1].startsWith('--')) {
      options[arg] = args[++index];
    } else {
      exitCode = 64;
      stderr.writeln('Invalid simulator probe arguments.');
      return;
    }
  }
  final simulator = options['--simulator'];
  final run = options['--run'];
  final suite = options['--suite'] ?? 'long';
  if (!live ||
      !Platform.isMacOS ||
      simulator == null ||
      run == null ||
      !['long', 'scenarios'].contains(suite) ||
      !RegExp(r'^[A-Za-z0-9-]{8,60}$').hasMatch(run) ||
      options['--flutter'] == null) {
    stderr.writeln(
      'Usage: simulator_live_probe --live --simulator ID --run UNIQUE --flutter /path/to/flutter [--config /private/config.json] [--suite long|scenarios]',
    );
    exitCode = 64;
    return;
  }
  final root = File.fromUri(Platform.script).parent.parent.parent.parent.path;
  final git = await Process.run('git', [
    'rev-parse',
    'HEAD',
  ], workingDirectory: root);
  String digest(List<String> paths) => sha256.convert([
    for (final path in paths) ...File('$root/$path').readAsBytesSync(),
  ]).toString();
  // Match run.dart's digest so native and model-only evidence can be correlated.
  final sourceDigest = digest([
    'server/lib/src/prompts.dart',
    'server/lib/src/model_client.dart',
    'server/lib/src/tool_schema.dart',
    'packages/xingyuan_core/lib/src/protocol.dart',
    'tool/assistant_eval/lib/cases.dart',
  ]);
  final probeDigest = digest([
    'integration_test/assistant_live_gate_test.dart',
    'integration_test/support/live_assistant_scenarios.dart',
    'tool/assistant_eval/bin/simulator_live_probe.dart',
  ]);
  final directory = Directory('$root/build/assistant-eval/simulator-$run');
  if (await directory.exists()) {
    stderr.writeln('Probe run already exists; choose a fresh run ID.');
    exitCode = 64;
    return;
  }
  final devices = await Process.run('xcrun', [
    'simctl',
    'list',
    'devices',
    'available',
    '--json',
  ]);
  if (devices.exitCode != 0) {
    throw StateError('Cannot inspect simulator inventory');
  }
  final inventory =
      (jsonDecode(devices.stdout as String) as Map)['devices'] as Map;
  final selected = inventory.values
      .expand((rows) => rows as List)
      .where(
        (row) =>
            row['udid'] == simulator &&
            row['state'] == 'Booted' &&
            row['isAvailable'] == true,
      );
  if (selected.length != 1) {
    throw StateError('Target must be one booted test simulator');
  }
  final container = await Process.run('xcrun', [
    'simctl',
    'get_app_container',
    simulator,
    'org.example.xingyuan',
    'data',
  ]);
  if (container.exitCode != 0) {
    throw StateError('Install the ordinary simulator app first');
  }
  final containerPath = (container.stdout as String).trim();
  final bootstrap = File(
    '$containerPath/Documents/assistant-live-$run.credential',
  );
  if (await bootstrap.exists()) {
    throw StateError('Credential bootstrap already exists');
  }
  await directory.create(recursive: true);
  await Process.run('chmod', ['700', directory.path]);
  final privateDirectory = await Directory.systemTemp.createTemp(
    'xingyuan-live-',
  );
  final registry = DeviceRegistry('${privateDirectory.path}/devices.json');
  final token = await registry.issue('sim-$run');
  var calls = 0;
  final events = <Map<String, Object?>>[];
  final stages = <String, int>{};
  final cases = <String, String>{};
  final report = File('${directory.path}/report.json');
  void save() => report.writeAsStringSync(
    jsonEncode({
      'run': run,
      'suite': suite,
      'git_commit': git.exitCode == 0 ? (git.stdout as String).trim() : null,
      'source_sha256': sourceDigest,
      'probe_sha256': probeDigest,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
      'calls': calls,
      'stages': stages,
      'cases': cases,
      'events': events,
    }),
    flush: true,
  );
  save();
  HttpServer? server;
  var appTouched = false;
  String? modelKey;
  Future<void> audit(String stage) async {
    var files = 0;
    for (final target in [
      Directory('$root/build/ios/iphonesimulator/Runner.app'),
      directory,
    ]) {
      await for (final file in target.list(
        recursive: true,
        followLinks: false,
      )) {
        if (file is! File) continue;
        final content = latin1.decode(await file.readAsBytes());
        if (content.contains(token) ||
            (modelKey != null && content.contains(modelKey))) {
          throw StateError('Sensitive output detected');
        }
        files++;
      }
    }
    stages[stage] = 0;
    stages['${stage}_files'] = files;
    save();
  }

  Future<void> command(
    String stage,
    String executable,
    List<String> arguments,
  ) async {
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: root,
    );
    final log = File('${directory.path}/$stage.log');
    await log.writeAsString('');
    Future<void> capture(Stream<List<int>> source) async {
      await for (final line
          in source.transform(utf8.decoder).transform(const LineSplitter())) {
        var safe = line.replaceAll(token, '[REDACTED]');
        if (modelKey != null) safe = safe.replaceAll(modelKey, '[REDACTED]');
        await log.writeAsString('$safe\n', mode: FileMode.append);
        final progress = RegExp(r'ASSISTANT_LIVE stage=[a-z-]+ turn=\d+')
            .firstMatch(safe);
        if (progress != null) {
          stdout.writeln(
            '${DateTime.now().toUtc().toIso8601String()} ${progress.group(0)}',
          );
        }
        final scenario = RegExp(
          r'ASSISTANT_CASE id=([A-Za-z0-9-]+) result=([a-z-]+)',
        ).firstMatch(safe);
        if (scenario != null) {
          cases[scenario.group(1)!] = scenario.group(2)!;
          save();
          stdout.writeln(scenario.group(0));
        }
      }
    }

    final output = capture(process.stdout);
    final errors = capture(process.stderr);
    int code;
    try {
      code = await process.exitCode.timeout(const Duration(minutes: 15));
    } on TimeoutException {
      process.kill(ProcessSignal.sigterm);
      await process.exitCode.timeout(
        const Duration(seconds: 20),
        onTimeout: () {
          process.kill(ProcessSignal.sigkill);
          return -9;
        },
      );
      code = 124;
    }
    await output;
    await errors;
    stages[stage] = code;
    save();
    stdout.writeln('$stage: exit $code; actual model calls $calls');
    if (code != 0) throw StateError('Simulator stage failed: $stage');
  }

  try {
    final model = await loadModelConfig(
      options['--config'] ?? '$root/config/assistant-server.local.json',
      onCall: () {
        calls++;
        save();
      },
    );
    modelKey = model.apiKey;
    final service = AssistantService(
      devices: registry,
      turn: model.turn,
      summarize: model.summarize,
      log: (event) {
        events.add(event);
        save();
      },
    );
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(service.handle);
    await bootstrap.parent.create(recursive: true);
    await bootstrap.writeAsString(token, flush: true);
    final mode = await Process.run('chmod', ['600', bootstrap.path]);
    if (mode.exitCode != 0) throw StateError('Private bootstrap mode failed');
    for (final phase in ['write', 'reopen']) {
      appTouched = true;
      await command(phase, options['--flutter']!, [
        'test',
        'integration_test/assistant_live_gate_test.dart',
        '-d',
        simulator,
        '--no-uninstall',
        '--reporter',
        'expanded',
        '--dart-define=ASSISTANT_LIVE_RUN=$run',
        '--dart-define=ASSISTANT_LIVE_PHASE=$phase',
        '--dart-define=ASSISTANT_LIVE_SUITE=$suite',
        '--dart-define=ASSISTANT_BASE_URL=http://127.0.0.1:${server.port}',
      ]);
      await audit('${phase}_secret_audit');
    }
  } catch (_) {
    exitCode = 1;
    stderr.writeln('Live probe failed; inspect its redacted stage log.');
  } finally {
    await registry.revoke('sim-$run');
    if (await registry.authenticate('Bearer $token') != null) {
      throw StateError('Test credential revocation failed');
    }
    if (await bootstrap.exists()) await bootstrap.delete();
    final currentContainer = await Process.run('xcrun', [
      'simctl',
      'get_app_container',
      simulator,
      'org.example.xingyuan',
      'data',
    ]);
    if (currentContainer.exitCode == 0) {
      final movedBootstrap = File(
        '${(currentContainer.stdout as String).trim()}/Documents/assistant-live-$run.credential',
      );
      if (await movedBootstrap.exists()) await movedBootstrap.delete();
    }
    await server?.close(force: true);
    await privateDirectory.delete(recursive: true);
    stages['credential_revoked'] = 0;
    save();
    if (appTouched) {
      if (stages['reopen'] != 0) {
        try {
          await command('cleanup_keychain', options['--flutter']!, [
            'test',
            'integration_test/assistant_live_gate_test.dart',
            '-d',
            simulator,
            '--no-uninstall',
            '--reporter',
            'expanded',
            '--dart-define=ASSISTANT_LIVE_RUN=$run',
            '--dart-define=ASSISTANT_LIVE_PHASE=cleanup',
            '--dart-define=ASSISTANT_BASE_URL=http://127.0.0.1:1',
          ]);
        } catch (_) {
          exitCode = 1;
          stderr.writeln(
            'Revoked test Keychain cleanup failed; ordinary app restoration will still run.',
          );
        }
      }
      try {
        await command('restore_build', options['--flutter']!, [
          'build',
          'ios',
          '--simulator',
          '--debug',
          '-t',
          'lib/main.dart',
          '--dart-define-from-file=config/assistant-client.example.json',
        ]);
        await command('restore_install', 'xcrun', [
          'simctl',
          'install',
          simulator,
          '$root/build/ios/iphonesimulator/Runner.app',
        ]);
        await command('restore_launch', 'xcrun', [
          'simctl',
          'launch',
          simulator,
          'org.example.xingyuan',
        ]);
        await audit('ordinary_secret_audit');
      } catch (_) {
        exitCode = 1;
        stderr.writeln(
          'Ordinary app restoration failed; inspect the stage log.',
        );
      }
    }
    stdout.writeln(
      'Report: ${report.path}; actual model calls: $calls; credential revoked.',
    );
  }
}
