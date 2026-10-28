import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:xingyuan_server/src/agent_ledger.dart';
import 'package:xingyuan_server/src/agent_runner.dart';
import 'package:xingyuan_server/src/companion_service.dart';
import 'package:xingyuan_server/src/companion_store.dart';
import 'package:xingyuan_server/src/device_registry.dart';
import 'package:xingyuan_server/src/model_config.dart';
import 'package:xingyuan_server/src/object_store.dart';
import 'package:xingyuan_server/src/service.dart';

Future<void> main(List<String> args) async {
  if (args.length != 2 || args.first != '--config') {
    stderr.writeln('Usage: server --config /private/assistant-server.json');
    exitCode = 64;
    return;
  }
  CompanionStore? companionStore;
  AgentLedger? agentLedger;
  Timer? photoMaintenance;
  try {
    final config = jsonDecode(await File(args.last).readAsString()) as Map;
    final port = config['port'] as int;
    if (port < 1024 || port > 65535) throw const FormatException();
    final model = await loadModelConfig(
      args.last,
      reasoning: (config['reasoning'] as String?) ?? 'none',
      maxCompletionTokens: (config['max_completion_tokens'] as int?) ?? 4000,
    );
    final devices = DeviceRegistry(config['devices_file'] as String);
    await devices.entries();
    final ledgerPath = config['agent_ledger_database'];
    if (ledgerPath != null && ledgerPath is! String) {
      throw const FormatException('Agent ledger configuration');
    }
    agentLedger = ledgerPath == null
        ? null
        : AgentLedger.open(ledgerPath as String);
    final companionPath = config['companion_database'];
    if (companionPath != null && companionPath is! String) {
      throw const FormatException('Companion configuration');
    }
    companionStore = companionPath == null
        ? null
        : CompanionStore.open(companionPath as String);
    final objectsPath = config['companion_objects'];
    if (objectsPath != null &&
        (objectsPath is! String || companionStore == null)) {
      throw const FormatException('Photo configuration');
    }
    final objects = objectsPath == null
        ? null
        : await DiskObjectStore.open(objectsPath as String);
    if (objects == null && (companionStore?.requiresPhotoStore ?? false)) {
      throw const FormatException('Photo storage required');
    }
    if (objects != null) {
      final store = companionStore!;
      Future<void> maintain() async {
        store.expireUnattachedPhotos();
        await store.reconcilePhotoObjects(objects);
      }

      await maintain();
      var running = false;
      photoMaintenance = Timer.periodic(const Duration(minutes: 5), (_) async {
        if (running) return;
        running = true;
        try {
          await maintain();
        } catch (_) {
          stdout.writeln(jsonEncode({'event': 'photo_maintenance_pending'}));
        } finally {
          running = false;
        }
      });
    }
    final companion = companionStore == null
        ? null
        : CompanionService(
            devices: devices,
            store: companionStore,
            objects: objects,
            log: (event) => stdout.writeln(jsonEncode(event)),
          );
    final service = AssistantService(
      devices: devices,
      turn: model.turn,
      summarize: model.summarize,
      analyzeDay: model.analyzeDay,
      polishNote: model.polishNote,
      generateDiary: model.generateDiary,
      agent: agentLedger == null
          ? null
          : AgentRunner(ledger: agentLedger, transport: model.agentTurn),
      log: (event) => stdout.writeln(jsonEncode(event)),
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    for (final signal in [ProcessSignal.sigint, ProcessSignal.sigterm]) {
      signal.watch().listen((_) async {
        photoMaintenance?.cancel();
        await server.close(force: true);
        companionStore?.close();
        agentLedger?.close();
        exit(0);
      });
    }
    await for (final request in server) {
      if (companion != null && request.uri.path.startsWith('/v1/companion/')) {
        companion.handle(request);
      } else {
        service.handle(request);
      }
    }
  } catch (_) {
    photoMaintenance?.cancel();
    companionStore?.close();
    agentLedger?.close();
    stderr.writeln(
      'Assistant server failed: verify private config, credentials and port.',
    );
    exitCode = 1;
  }
}
