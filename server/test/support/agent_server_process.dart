import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:xingyuan_server/src/agent_ledger.dart';
import 'package:xingyuan_server/src/agent_runner.dart';
import 'package:xingyuan_server/src/device_registry.dart';
import 'package:xingyuan_server/src/model_client.dart';
import 'package:xingyuan_server/src/service.dart';

// Test-only composition of production classes. Never loads a model config/key.
Future<void> main(List<String> args) async {
  if (args.length != 3) {
    exitCode = 64;
    return;
  }
  final ledger = AgentLedger.open(args[0]);
  final model = AssistantModelClient(
    endpoint: Uri.parse(
      'http://127.0.0.1:${int.parse(args[2])}/chat/completions',
    ),
    apiKey: 'synthetic-key',
    timeout: const Duration(seconds: 2),
  );
  final service = AssistantService(
    devices: DeviceRegistry(args[1]),
    turn: (_) => throw StateError('unused'),
    summarize: (_) => throw StateError('unused'),
    agent: AgentRunner(ledger: ledger, transport: model.agentTurn),
    log: (event) => stdout.writeln(jsonEncode(event)),
  );
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  for (final signal in [ProcessSignal.sigint, ProcessSignal.sigterm]) {
    signal.watch().listen((_) async {
      await server.close(force: true);
      ledger.close();
      exit(0);
    });
  }
  stdout.writeln(jsonEncode({'ready_port': server.port}));
  await for (final request in server) {
    unawaited(service.handle(request));
  }
}
