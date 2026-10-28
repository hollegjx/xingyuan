import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:yaml/yaml.dart';

import '../test/support/cli_process.dart';

const _sqliteHash =
    '6d80ba56cff1fa44f62bebc3e6b6b71513cc628862a9745c223c7bea8bf813f3';
const _cache =
    '.dart_tool/hooks_runner/shared/sqlite3/build/download-6d80ba56/libsqlite3.dylib';

Future<void> main(List<String> args) async {
  final traceTools = args.length == 2 && args.last == '--trace-native-tools';
  if ((args.length != 1 && !traceTools) ||
      args.first != '--synthetic' ||
      Abi.current() != Abi.macosArm64) {
    stderr.writeln(
      'Usage on arm64 macOS: startup_probe --synthetic [--trace-native-tools]',
    );
    exitCode = 64;
    return;
  }
  final eval = File.fromUri(Platform.script).parent.parent;
  final repository = eval.parent.parent;
  for (final package in ['server', 'tool/assistant_eval']) {
    final lock = loadYaml(
      await File('${repository.path}/$package/pubspec.lock').readAsString(),
    ) as Map;
    if (lock['packages']['sqlite3']['version'] != '3.5.2') {
      throw StateError('Diagnostic requires pinned SQLite 3.5.2');
    }
  }
  final root = await Directory.systemTemp.createTemp('qa-startup-probe-');
  stdout.writeln('Synthetic evidence: ${root.path}');
  final dart = Platform.resolvedExecutable;
  Directory? wrappers;
  if (traceTools) {
    final source = Directory('${root.path}/trace-source');
    for (final path in [
      'tool/native_tool_trace.dart',
      'test/support/cli_process.dart',
    ]) {
      final destination = File('${source.path}/$path');
      await destination.parent.create(recursive: true);
      await File('${eval.path}/$path').copy(destination.path);
    }
    final binary = '${root.path}/native-tool-trace';
    final compiled = await runCli(dart, [
      'compile',
      'exe',
      '${source.path}/tool/native_tool_trace.dart',
      '-o',
      binary,
    ], timeout: const Duration(seconds: 120));
    await File('${root.path}/trace-compile.log')
        .writeAsString('${compiled.stdout}\n${compiled.stderr}');
    if (compiled.exitCode != 0) {
      throw StateError('Cannot compile trace wrapper');
    }
    wrappers = Directory('${root.path}/native-tools');
    await wrappers.create();
    for (final tool in ['otool', 'install_name_tool', 'codesign']) {
      final script = File('${wrappers.path}/$tool');
      final quoted = "'${binary.replaceAll("'", "'\\''")}'";
      await script.writeAsString('#!/bin/sh\nexec $quoted $tool "\$@"\n');
      final mode = await Process.run('chmod', ['700', script.path]);
      if (mode.exitCode != 0) throw StateError('Cannot prepare trace wrapper');
    }
  }
  final hash = await Process.run('shasum', [
    '-a',
    '256',
    '${eval.path}/$_cache',
  ]);
  if (hash.exitCode != 0 || !'${hash.stdout}'.startsWith('$_sqliteHash ')) {
    throw StateError('Expected pinned SQLite 3.5.2 arm64 macOS cache');
  }
  final tracked = await Process.run('git', [
    'ls-files',
    '-z',
    '--',
    'server/lib',
    'server/bin',
    'server/pubspec.yaml',
    'server/pubspec.lock',
    'packages/xingyuan_core/lib',
    'packages/xingyuan_core/pubspec.yaml',
    'packages/xingyuan_core/pubspec.lock',
    'tool/assistant_eval',
    'tool/run_planning_gateway.dart',
  ], workingDirectory: repository.path);
  if (tracked.exitCode != 0) {
    throw StateError('Cannot enumerate tracked source');
  }
  final files =
      '${tracked.stdout}'.split('\u0000').where((p) => p.isNotEmpty).toSet()
        ..add('tool/assistant_eval/test/support/cli_process.dart')
        ..add('tool/assistant_eval/test/cli_process_test.dart');
  final summary = <Map<String, Object?>>[];
  var failures = 0;
  for (final mode in ['serial', 'overlap', 'gateway']) {
    final sandbox = Directory('${root.path}/$mode');
    for (final path in files) {
      if (path.contains('/.dart_tool/') || path.contains('/build/')) {
        throw StateError('Generated files must not be copied as source');
      }
      final destination = File('${sandbox.path}/$path');
      await destination.parent.create(recursive: true);
      await File('${repository.path}/$path').copy(destination.path);
    }
    // Reuse only hash-checked public vendor bytes, not signed runtime output.
    for (final package in ['server', 'tool/assistant_eval']) {
      final destination = File('${sandbox.path}/$package/$_cache');
      await destination.parent.create(recursive: true);
      await File('${eval.path}/$_cache').copy(destination.path);
      final resolution = await Process.run(dart, [
        'pub',
        'get',
        '--offline',
        '--enforce-lockfile',
      ], workingDirectory: '${sandbox.path}/$package');
      await File('${sandbox.path}/${package.replaceAll('/', '-')}-pub.log')
          .writeAsString('${resolution.stdout}\n${resolution.stderr}');
      if (resolution.exitCode != 0) {
        throw StateError('Offline resolution failed');
      }
    }
    final original = Directory.current;
    Directory.current = '${sandbox.path}/tool/assistant_eval';
    try {
      Future<void> sample(int index) async {
        final watch = Stopwatch()..start();
        final arguments = mode == 'gateway'
            ? ['test', 'test/gateway_entry_test.dart', '--reporter', 'expanded']
            : ['run', 'bin/deployed_probe.dart', '--unknown'];
        try {
          final result = await runCli(
            dart,
            arguments,
            timeout: Duration(seconds: mode == 'gateway' ? 120 : 20),
            environment: wrappers == null
                ? null
                : {
                    'PATH': '${wrappers.path}:${Platform.environment['PATH']}',
                    'XINGYUAN_NATIVE_TRACE_ROOT': root.path,
                    'XINGYUAN_NATIVE_TRACE_SAMPLE': '$mode-$index',
                  },
          );
          final passed = mode == 'gateway'
              ? result.exitCode == 0
              : result.exitCode != 0 &&
                    '${result.stderr}'.contains('FormatException') &&
                    '${result.stdout}'.isEmpty;
          if (!passed) failures++;
          final log = File('${sandbox.path}/sample-$index.log');
          await log.writeAsString('${result.stdout}\n${result.stderr}');
          summary.add({
            'mode': mode,
            'sample': index,
            'exit': result.exitCode,
            'milliseconds': watch.elapsedMilliseconds,
            'expected_result': passed,
            'log': log.path,
          });
        } catch (error) {
          failures++;
          final log = File('${sandbox.path}/sample-$index.log');
          await log.writeAsString('$error');
          summary.add({
            'mode': mode,
            'sample': index,
            'expected_result': false,
            'milliseconds': watch.elapsedMilliseconds,
            'log': log.path,
          });
        }
      }

      if (mode == 'overlap') {
        // Deliberate stress in a disposable package, never a suite override.
        for (var round = 0; round < 3; round++) {
          await Future.wait([
            for (var i = 0; i < 4; i++) sample(round * 4 + i),
          ]);
        }
      } else {
        for (var i = 0; i < (mode == 'gateway' ? 1 : 4); i++) {
          await sample(i);
        }
      }
    } finally {
      Directory.current = original;
    }
  }
  final report = {
    'sdk': Platform.version,
    'sqlite_vendor_sha256': _sqliteHash,
    'native_tool_trace': traceTools,
    'scope': 'disposable source copies; no real config, model or device',
    'failures': failures,
    'samples': summary,
  };
  await File('${root.path}/report.json')
      .writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  stdout.writeln(jsonEncode(report));
  if (failures != 0) exitCode = 1;
}
