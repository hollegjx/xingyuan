import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support/cli_process.dart';

void main() {
  test(
    'gateway entry rejects the retired positional config invocation',
    () async {
      final result = await runCli(Platform.resolvedExecutable, [
        'run',
        '../../tool/run_planning_gateway.dart',
        'old.json',
      ]);
      expect(result.exitCode, 64);
      expect(result.stderr, contains('old /plan gateway is retired'));
    },
  );

  test('gateway entry delegates to the shared server from another working directory', () async {
    final result = await runCli(Platform.resolvedExecutable, [
      'run',
      '../../tool/run_planning_gateway.dart',
      '--config',
      'nonexistent-test-config.json',
    ]);
    expect(result.exitCode, 1);
    expect(
      result.stderr,
      contains('Assistant server failed: verify private config'),
    );
    expect(result.stdout, isEmpty);
  });

  for (final signal in [ProcessSignal.sigint, ProcessSignal.sigterm]) {
    test('shared gateway serves health and exits cleanly on $signal', () async {
      final directory = await Directory.systemTemp.createTemp(
        'assistant-gateway-',
      );
      final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = listener.port;
      await listener.close();
      final registry = File('${directory.path}/devices.json');
      final config = File('${directory.path}/config.json');
      await registry.writeAsString('[]');
      await config.writeAsString(
        jsonEncode({
          'base_url': 'https://model.invalid/v1',
          'model': 'gpt-6-luna',
          'model_api_key': 'synthetic-unissued-key',
          'port': port,
          'devices_file': registry.path,
        }),
      );
      for (final file in [registry, config]) {
        final result = await Process.run('chmod', ['600', file.path]);
        expect(result.exitCode, 0);
      }
      final process = await Process.start(Platform.resolvedExecutable, [
        'run',
        '../../tool/run_planning_gateway.dart',
        '--config',
        config.path,
      ]);
      final output = utf8.decoder.bind(process.stdout).join();
      final errors = utf8.decoder.bind(process.stderr).join();
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 1);
      try {
        var healthy = false;
        final deadline = DateTime.now().add(const Duration(seconds: 20));
        while (!healthy && DateTime.now().isBefore(deadline)) {
          try {
            final request = await client.getUrl(
              Uri.parse('http://127.0.0.1:$port/v1/health'),
            );
            final response = await request.close().timeout(
              const Duration(seconds: 2),
            );
            final body =
                jsonDecode(await utf8.decoder.bind(response).join()) as Map;
            healthy =
                response.statusCode == 200 &&
                body['protocol'] == 'xingyuan.assistant.v1';
          } on SocketException {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
        }
        expect(healthy, isTrue);
        final request = await client.postUrl(
          Uri.parse('http://127.0.0.1:$port/v1/turn'),
        );
        final response = await request.close();
        await response.drain<void>();
        expect(response.statusCode, 401);
        expect(process.kill(signal), isTrue);
        expect(await process.exitCode.timeout(const Duration(seconds: 10)), 0);
        // Dart may report native build hooks on stderr before starting the server.
        expect(
          await errors,
          matches(RegExp(r'^(Running build hooks\.\.\.)*$')),
        );
        final lines = const LineSplitter().convert(await output);
        expect(lines, hasLength(2));
        for (final line in lines) {
          expect((jsonDecode(line) as Map)['usage'], isEmpty);
        }
        final rebound = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          port,
        );
        await rebound.close();
      } finally {
        client.close(force: true);
        process.kill(ProcessSignal.sigterm);
        await process.exitCode.timeout(const Duration(seconds: 10));
        await directory.delete(recursive: true);
      }
    });
  }
}
