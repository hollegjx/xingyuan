import 'dart:convert';
import 'dart:io';

import 'package:xingyuan_server/src/device_registry.dart';

const journeyFormat = 'xingyuan-companion-journey-v1';

Future<void> _private(String path, String mode) async {
  if ((await Process.run('chmod', [mode, path])).exitCode != 0) {
    throw const FileSystemException('Private permissions required');
  }
}

Future<void> _json(String path, Object value) async {
  await File(path).writeAsString(
    const JsonEncoder.withIndent('  ').convert(value),
    flush: true,
  );
  await _private(path, '600');
}

Future<Map<String, dynamic>> _manifest(String directory) async {
  if (!File(directory).isAbsolute) throw const FormatException();
  final data = jsonDecode(
    await File('$directory/journey.json').readAsString(),
  ) as Map<String, dynamic>;
  if (data['format'] != journeyFormat ||
      data['run'] is! String ||
      !RegExp(r'^[a-z0-9-]{8,40}$').hasMatch(data['run'] as String)) {
    throw const FormatException('Journey manifest');
  }
  return data;
}

Future<Map<String, dynamic>> prepareJourney(
  String directory,
  String run,
) async {
  if (!File(directory).isAbsolute ||
      !RegExp(r'^[a-z0-9-]{8,40}$').hasMatch(run) ||
      await FileSystemEntity.type(directory) != FileSystemEntityType.notFound) {
    throw const FormatException('Use a new absolute private directory and run');
  }
  await Directory(directory).create();
  await _private(directory, '700');
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  final registry = DeviceRegistry('$directory/devices.json');
  for (final role in ['a', 'b']) {
    final token = await registry.issue('qa-$run-$role');
    await _json('$directory/client-$role.json', {
      'COMPANION_JOURNEY_RUN': run,
      'COMPANION_JOURNEY_ROLE': role,
      'COMPANION_JOURNEY_URL': 'http://127.0.0.1:$port',
      'COMPANION_JOURNEY_TOKEN': token,
    });
  }
  await _json('$directory/server.json', {
    'base_url': 'https://example.invalid/v1',
    'model': 'gpt-6-luna',
    'model_api_key': 'synthetic-unused-no-model-requests',
    'port': port,
    'devices_file': '$directory/devices.json',
    'companion_database': '$directory/data.db',
    'companion_objects': '$directory/objects',
  });
  final result = <String, dynamic>{
    'format': journeyFormat,
    'run': run,
    'port': port,
    'server_config': '$directory/server.json',
  };
  await _json('$directory/journey.json', result);
  return result;
}

Future<void> copyJourneyInvite(String directory, String reportPath) async {
  final manifest = await _manifest(directory);
  final report = jsonDecode(await File(reportPath).readAsString()) as Map;
  final code = report['invitation'];
  if (report['run'] != manifest['run'] ||
      report['role'] != 'a' ||
      report['phase'] != 'invite' ||
      code is! String ||
      !RegExp(r'^[A-HJ-NP-Z2-9]{8}$').hasMatch(code)) {
    throw const FormatException('Invitation report');
  }
  final path = '$directory/client-b.json';
  final client = jsonDecode(await File(path).readAsString()) as Map;
  if (client['COMPANION_JOURNEY_RUN'] != manifest['run'] ||
      client['COMPANION_JOURNEY_ROLE'] != 'b') {
    throw const FormatException('Client scope');
  }
  await _json(path, {...client, 'COMPANION_JOURNEY_INVITE': code});
}

Future<void> revokeJourney(String directory) async {
  final manifest = await _manifest(directory);
  final registry = DeviceRegistry('$directory/devices.json');
  for (final role in ['a', 'b']) {
    await registry.revoke('qa-${manifest['run']}-$role');
  }
}

Future<void> main(List<String> args) async {
  try {
    if (args.length == 3 && args[0] == 'prepare') {
      stdout.writeln(jsonEncode(await prepareJourney(args[1], args[2])));
    } else if (args.length == 3 && args[0] == 'invite') {
      await copyJourneyInvite(args[1], args[2]);
      stdout.writeln('Invitation transferred to private client configuration.');
    } else if (args.length == 2 && args[0] == 'revoke') {
      await revokeJourney(args[1]);
      stdout.writeln('Journey credentials revoked.');
    } else {
      throw const FormatException();
    }
  } catch (_) {
    stderr.writeln(
      'Usage: prepare_companion_journey prepare NEW_PRIVATE_DIR RUN | '
      'invite PRIVATE_DIR PRIVATE_REPORT | revoke PRIVATE_DIR',
    );
    exitCode = 64;
  }
}
