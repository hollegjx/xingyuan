import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:xingyuan_server/src/agent_ledger.dart';
import 'package:xingyuan_server/src/device_registry.dart';

import 'support/agent_fixtures.dart';

void main() {
  test('real isolated process restart keeps quota and rejects both old continuation and initial replay', () async {
    final directory = await Directory.systemTemp.createTemp(
      'xingyuan-agent-process-',
    );
    final registry = DeviceRegistry('${directory.path}/devices.json');
    final token = await registry.issue('qa-agent-process');
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var calls = 0;
    upstream.listen((request) async {
      await request.drain<void>();
      calls++;
      request.response.write(jsonEncode(agentEnvelope()));
      await request.response.close();
    });
    final client = HttpClient();
    final output = StringBuffer();
    Process? process;
    Future<void> stop() async {
      final child = process;
      if (child == null) return;
      child.kill(ProcessSignal.sigterm);
      try {
        expect(await child.exitCode.timeout(const Duration(seconds: 5)), 0);
      } on TimeoutException {
        child.kill(ProcessSignal.sigkill);
        await child.exitCode;
        rethrow;
      } finally {
        process = null;
      }
    }

    Future<int> start() async {
      final ready = Completer<int>();
      final child = await Process.start(Platform.resolvedExecutable, [
        'run',
        'test/support/agent_server_process.dart',
        '${directory.path}/agent.sqlite',
        registry.path,
        '${upstream.port}',
      ]);
      process = child;
      child.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            output.writeln(line);
            if (line.startsWith('{')) {
              final value = jsonDecode(line);
              if (value is Map &&
                  value['ready_port'] is int &&
                  !ready.isCompleted) {
                ready.complete(value['ready_port'] as int);
              }
            }
          });
      child.stderr.transform(utf8.decoder).listen(output.write);
      child.exitCode.then((code) {
        if (!ready.isCompleted) {
          ready.completeError(StateError('child exited $code'));
        }
      });
      return ready.future.timeout(const Duration(seconds: 20));
    }

    Future<(int, Map<String, dynamic>)> send(int port, Object body) async {
      final request = await client.postUrl(
        Uri.parse('http://127.0.0.1:$port/v1/agent/turn'),
      );
      request.headers.contentType = ContentType.json;
      request.headers.set('authorization', 'Bearer $token');
      request.write(jsonEncode(body));
      final response = await request.close();
      return (
        response.statusCode,
        jsonDecode(await utf8.decoder.bind(response).join())
            as Map<String, dynamic>,
      );
    }

    try {
      final firstPort = await start();
      final source = agentFixture();
      final first = await send(firstPort, source);
      expect(first.$1, 200);
      expect(first.$2['kind'], 'tool_call');
      await stop();
      final secondPort = await start();
      expect(
        (await send(
          secondPort,
          agentContinue(source, first.$2, agentOk()),
        )).$2['code'],
        'run_restart_required',
      );
      expect((await send(secondPort, source)).$2['code'], 'start_replayed');
      expect(calls, 1);
      expect(
        (await send(secondPort, agentFixture(id: 'new-user-action'))).$1,
        200,
      );
      await stop();
      final ledger = AgentLedger.open('${directory.path}/agent.sqlite');
      try {
        expect(ledger.dailyUsage('qa-agent-process', DateTime.now().toUtc()), {
          'runs': 2,
          'tokens': 240,
        });
      } finally {
        ledger.close();
      }
      expect(calls, 2);
      for (final private in [
        token,
        'synthetic-key',
        'synthetic-private',
        'qa-agent-process',
      ]) {
        expect(output.toString(), isNot(contains(private)));
      }
    } finally {
      await stop();
      client.close(force: true);
      await upstream.close(force: true);
      await directory.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(seconds: 60)));
}
