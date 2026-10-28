import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'companion_fault_proxy.dart';
import 'prepare_companion_journey.dart';

// Synthetic local reproduction, not a diagnosis of a historical port owner.
Future<void> main(List<String> args) async {
  if (args.length == 3 && args.first == '--hold-source-port') {
    final port = int.parse(args[1]);
    final target = int.parse(args[2]);
    if ([port, target].any((value) => value < 1024 || value > 65535)) {
      throw const FormatException('QA port');
    }
    final stopping = ProcessSignal.sigterm.watch().first;
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      target,
      sourceAddress: InternetAddress.loopbackIPv4,
      sourcePort: port,
      timeout: const Duration(seconds: 10),
    );
    stdout.writeln('ready');
    await stopping;
    socket.destroy();
    return;
  }
  if (args.length == 2 && args.first == '--hold-port') {
    final port = int.parse(args.last);
    if (port < 1024 || port > 65535) throw const FormatException('QA port');
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    final stopping = ProcessSignal.sigterm.watch().first;
    stdout.writeln('ready');
    await stopping;
    await socket.close();
    return;
  }
  final sourcePort = args.length == 2 && args.last == '--source-port';
  if (args.isEmpty ||
      args.first != '--synthetic' ||
      (args.length != 1 && !sourcePort)) {
    stderr.writeln('Usage: fault_proxy_port_probe --synthetic [--source-port]');
    exitCode = 64;
    return;
  }
  final temporary = await Directory.systemTemp.createTemp('qa-port-probe-');
  final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  upstream.listen((request) async {
    await request.drain<void>();
    request.response.write('synthetic');
    await request.response.close();
  });
  final results = <Map<String, Object?>>[];
  try {
    for (var trial = 0; trial < 10; trial++) {
      final journey = '${temporary.path}/trial-$trial';
      await prepareJourney(journey, 'synthetic-port-$trial');
      final file = File('$journey/client-a.json');
      final client = jsonDecode(await file.readAsString()) as Map;
      await file.writeAsString(
        jsonEncode({
          ...client,
          'COMPANION_JOURNEY_URL': 'http://127.0.0.1:${upstream.port}',
        }),
      );
      final prepared = await prepareFaultProxy(journey);
      final directory = prepared['directory'] as String;
      final port = prepared['port'] as int;
      CompanionFaultProxy? proxy;
      Process? contender;
      ServerSocket? target;
      StreamIterator<Socket>? connections;
      Socket? peer;
      try {
        proxy = await CompanionFaultProxy.open(directory);
        await proxy.close();
        proxy = null;
        // Identical close/reopen path with no competing listener.
        proxy = await CompanionFaultProxy.open(directory);
        await proxy.close();
        proxy = null;
        // Also test an established outbound socket, with no competing listener.
        target = sourcePort
            ? await ServerSocket.bind(InternetAddress.loopbackIPv4, 0)
            : null;
        if (target != null) connections = StreamIterator(target);
        contender = await Process.start(Platform.resolvedExecutable, [
          'run',
          Platform.script.toFilePath(),
          sourcePort ? '--hold-source-port' : '--hold-port',
          '$port',
          if (target != null) '${target.port}',
        ]);
        final errors = utf8.decoder.bind(contender.stderr).join();
        final ready = await utf8.decoder
            .bind(contender.stdout)
            .transform(const LineSplitter())
            .first
            .timeout(const Duration(seconds: 10));
        if (ready != 'ready') throw StateError('Contender failed to bind');
        if (connections != null) {
          if (!await connections.moveNext().timeout(
            const Duration(seconds: 10),
          )) {
            throw StateError('No established source-port connection');
          }
          final connection = peer = connections.current;
          if (connection.remotePort != port) {
            throw StateError('Contender did not use the selected source port');
          }
          connection.listen((_) {}, onDone: connection.destroy);
        }
        int? collisionCode;
        var boundDuringContention = false;
        try {
          proxy = await CompanionFaultProxy.open(directory);
          boundDuringContention = true;
          if (!sourcePort) {
            throw StateError('A second owner unexpectedly bound the same port');
          }
        } on SocketException catch (error) {
          collisionCode = error.osError?.errorCode;
          if (collisionCode != (Platform.isMacOS ? 48 : 98)) rethrow;
        }
        await proxy?.close();
        proxy = null;
        contender.kill(ProcessSignal.sigterm);
        if (await contender.exitCode.timeout(const Duration(seconds: 10)) !=
            0) {
          throw StateError('Contender failed to exit: ${await errors}');
        }
        await errors;
        contender = null;
        int? afterExitCode;
        try {
          proxy = await CompanionFaultProxy.open(directory);
        } on SocketException catch (error) {
          afterExitCode = error.osError?.errorCode;
          if (!sourcePort || afterExitCode != (Platform.isMacOS ? 48 : 98)) {
            rethrow;
          }
        }
        results.add({
          'trial': trial,
          'port': port,
          'uncontended_reopen': true,
          'bind_while_contender_active': boundDuringContention,
          'controlled_collision_errno': collisionCode,
          'contender_kind': sourcePort ? 'outbound_socket' : 'listener',
          'reopen_after_contender_closed': proxy != null,
          'after_contender_exit_errno': afterExitCode,
        });
      } finally {
        if (contender != null) {
          contender.kill(ProcessSignal.sigkill);
          await contender.exitCode.timeout(const Duration(seconds: 10));
        }
        peer?.destroy();
        await connections?.cancel();
        await target?.close();
        await proxy?.close();
      }
    }
    stdout.writeln(
      jsonEncode({
        'scope': sourcePort
            ? 'synthetic source-port reuse; historical owner unknown'
            : 'synthetic controlled contention; historical owner unknown',
        'os': Platform.operatingSystem,
        'sdk': Platform.version,
        'results': results,
      }),
    );
  } finally {
    await upstream.close(force: true);
    await temporary.delete(recursive: true);
  }
}
