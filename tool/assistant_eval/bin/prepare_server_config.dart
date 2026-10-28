import 'dart:convert';
import 'dart:io';

import 'package:xingyuan_server/src/model_config.dart';

Future<void> main() async {
  final model = await loadModelConfig(
    '../../config/planning-gateway.local.json',
  );
  final output = File('../../config/assistant-deploy.local.json');
  if (await output.exists()) {
    throw StateError('Refusing to replace existing server config');
  }
  final temp = await output.parent.createTemp('.assistant-config-');
  try {
    final file = File('${temp.path}/config.json');
    await file.writeAsString(
      jsonEncode({
        'base_url': 'https://model.example.invalid/v1',
        'model': 'gpt-6-luna',
        'model_api_key': model.apiKey,
        'port': 8788,
        'devices_file': '/etc/xingyuan/devices.json',
        'reasoning': 'none',
        'max_completion_tokens': 4000,
      }),
      flush: true,
    );
    final chmod = await Process.run('chmod', ['600', file.path]);
    if (chmod.exitCode != 0) {
      throw const FileSystemException('Private config permissions');
    }
    await file.rename(output.path);
  } finally {
    await temp.delete(recursive: true);
  }
  stdout.writeln(
    'Prepared owner-only ignored server config; no values printed.',
  );
}
