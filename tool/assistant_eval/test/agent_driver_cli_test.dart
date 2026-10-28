import 'dart:io';

import 'package:test/test.dart';

import 'support/cli_process.dart';

void main() {
  test(
    'CLI rejects missing live gates before reading config or creating output',
    () async {
      final dir = Directory.systemTemp.createTempSync('agent-driver-denial-');
      addTearDown(() => dir.deleteSync(recursive: true));
      for (final args in <List<String>>[
        [],
        ['--output', '${dir.path}/out'],
        ['--live', '--output', '${dir.path}/out'],
        [
          '--live',
          '--output',
          '${dir.path}/out',
          '--fixture-version',
          'agent-c26-v3',
        ],
        [
          '--scripted',
          '--output',
          '${dir.path}/out',
          '--fixture-version',
          '../config',
        ],
        [
          '--scripted',
          '--output',
          '${dir.path}/out',
          '--fixture-version',
          'agent-c26-v3',
          '--config',
          'UNREAD_PRIVATE_CONFIG',
        ],
        [
          '--live',
          '--output',
          '${dir.path}/out',
          '--config',
          'UNREAD_PRIVATE_CONFIG',
        ],
        [
          '--scripted',
          '--output',
          '${dir.path}/out',
          '--authorization',
          'UNREAD_PRIVATE_MARKER',
        ],
        [
          '--live',
          '--output',
          '${dir.path}/out',
          '--config',
          'UNREAD_PRIVATE_CONFIG',
          '--authorization',
          '${dir.path}/missing-marker',
        ],
      ]) {
        final result = await runCli(Platform.resolvedExecutable, [
          'run',
          'bin/agent_run.dart',
          ...args,
        ]);
        expect(result.exitCode, 64);
        expect(
          '${result.stdout}${result.stderr}',
          isNot(contains('UNREAD_PRIVATE')),
        );
        expect(dir.listSync(), isEmpty);
      }
    },
  );
}
