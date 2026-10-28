import 'dart:io';

Future<void> main(List<String> args) async {
  if (args.length != 2 || args.first != '--config') {
    stderr.writeln(
      'Usage: dart run tool/run_planning_gateway.dart --config /private/assistant-server.json',
    );
    stderr.writeln(
      'The old /plan gateway is retired. This entry runs the shared assistant server.',
    );
    exitCode = 64;
    return;
  }
  final directory = File.fromUri(Platform.script).parent.parent;
  final config = File(args.last).absolute.path;
  try {
    final child = await Process.start(
      Platform.resolvedExecutable,
      ['run', 'bin/server.dart', '--config', config],
      workingDirectory: '${directory.path}/server',
      mode: ProcessStartMode.inheritStdio,
    );
    final signals = [
      for (final signal in [ProcessSignal.sigint, ProcessSignal.sigterm])
        signal.watch().listen((_) => child.kill(signal)),
    ];
    try {
      exitCode = await child.exitCode;
    } finally {
      for (final subscription in signals) {
        await subscription.cancel();
      }
    }
  } catch (_) {
    stderr.writeln(
      'Shared assistant server could not start. Check Dart, configuration and server dependencies.',
    );
    exitCode = 1;
  }
}
