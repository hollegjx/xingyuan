import 'dart:io';

import 'package:test/test.dart';

import 'support/cli_process.dart';

void main() {
  for (final args in [
    <String>['--token-file'],
    <String>['--unknown'],
    <String>['--reading-plan', '--unexpected'],
    <String>['--legacy-memory', '--unexpected'],
  ]) {
    test(
      'deployment probe rejects $args before credentials or network',
      () async {
        final result = await runCli(Platform.resolvedExecutable, [
          'run',
          'bin/deployed_probe.dart',
          ...args,
        ]);
        expect(result.exitCode, isNot(0), reason: '${result.stderr}');
        expect(result.stderr, contains('FormatException'));
        expect(result.stdout, isEmpty);
      },
    );
  }

  for (final args in [
    <String>[],
    <String>['--live', '--simulator'],
    <String>['--live', '--live'],
    <String>['--unexpected'],
    <String>[
      '--live',
      '--suite',
      'unknown',
      '--simulator',
      'unused',
      '--run',
      'valid-run',
      '--flutter',
      '/missing/flutter',
    ],
    <String>['--live', '--suite', 'scenarios', '--suite', 'long'],
    <String>[
      '--live',
      '--simulator',
      'not-a-device',
      '--run',
      '../bad',
      '--flutter',
      '/missing/flutter',
    ],
  ]) {
    test(
      'simulator live probe rejects unsafe or incomplete CLI $args',
      () async {
        final result = await runCli(Platform.resolvedExecutable, [
          'run',
          'bin/simulator_live_probe.dart',
          ...args,
        ]);
        expect(result.exitCode, 64, reason: '${result.stderr}');
        expect(result.stdout, isEmpty);
        expect(result.stderr, isNot(contains('Unhandled exception')));
      },
    );
  }
}
