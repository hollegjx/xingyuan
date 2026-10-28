import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';

import 'support/cli_process.dart';

void main() {
  for (final ignoreTerm in [false, true]) {
    test('CLI timeout reaps its child (ignore TERM: $ignoreTerm)', () async {
      final temporary = await Directory.systemTemp.createTemp('eval-child-');
      final pidFile = File('${temporary.path}/pid');
      int? pid;
      try {
        await expectLater(
          runCli('/bin/sh', [
            '-c',
            '${ignoreTerm ? "trap '' TERM; " : ""}'
                r'echo $$ > "$1"; printf synthetic-started >&2; exec sleep 60',
            'synthetic-timeout-child',
            pidFile.path,
          ], timeout: const Duration(seconds: 1)),
          throwsA(
            isA<TimeoutException>().having(
              (error) => error.message,
              'captured stderr',
              contains('synthetic-started'),
            ),
          ),
        );
        expect(await pidFile.exists(), isTrue);
        pid = int.parse((await pidFile.readAsString()).trim());
        final alive = await Process.run('/bin/kill', ['-0', '$pid']);
        expect(
          alive.exitCode,
          isNot(0),
          reason:
              'A timed-out CLI must not keep building shared native assets.',
        );
        pid = null;
      } finally {
        if (pid != null) Process.killPid(pid, ProcessSignal.sigkill);
        await temporary.delete(recursive: true);
      }
    });
  }

  test('CLI keeps exact exit status and both output streams', () async {
    final result = await runCli('/bin/sh', [
      '-c',
      'printf synthetic-output; printf synthetic-error >&2; exit 64',
    ]);
    expect(result.exitCode, 64);
    expect(result.stdout, 'synthetic-output');
    expect(result.stderr, 'synthetic-error');
  });

  test('CLI forwards only its explicit child environment override', () async {
    const key = 'XINGYUAN_SYNTHETIC_CLI_TEST';
    final original = Platform.environment[key];
    final result = await runCli(
      '/bin/sh',
      ['-c', r'printf "%s" "$XINGYUAN_SYNTHETIC_CLI_TEST"'],
      environment: {key: 'synthetic-child-only'},
    );
    expect(result.exitCode, 0);
    expect(result.stdout, 'synthetic-child-only');
    expect(result.stderr, isEmpty);
    expect(Platform.environment[key], original);
  });
}
