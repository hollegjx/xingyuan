import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<ProcessResult> runCli(
  String executable,
  List<String> arguments, {
  Duration timeout = const Duration(seconds: 20),
  Map<String, String>? environment,
}) async {
  final process = await Process.start(
    executable,
    arguments,
    environment: environment,
  );
  final output = StringBuffer();
  final errors = StringBuffer();
  final stdout = process.stdout.transform(utf8.decoder).listen(output.write);
  final stderr = process.stderr.transform(utf8.decoder).listen(errors.write);
  var exited = false;
  final exit = process.exitCode.then((code) {
    exited = true;
    return code;
  });
  final completed = Future.wait<Object?>([
    exit,
    stdout.asFuture<void>(),
    stderr.asFuture<void>(),
  ]);
  try {
    final result = await completed.timeout(timeout);
    return ProcessResult(
      process.pid,
      result.first as int,
      output.toString(),
      errors.toString(),
    );
  } on TimeoutException {
    throw TimeoutException(
      'CLI did not finish. stdout: $output\nstderr: $errors',
      timeout,
    );
  } finally {
    // A Future timeout alone leaves dart run (and its native build) alive.
    try {
      if (!exited) {
        process.kill(ProcessSignal.sigterm);
        try {
          await exit.timeout(const Duration(seconds: 2));
        } on TimeoutException {
          process.kill(ProcessSignal.sigkill);
          await exit.timeout(const Duration(seconds: 2));
        }
      }
    } finally {
      await stdout.cancel();
      await stderr.cancel();
    }
  }
}
