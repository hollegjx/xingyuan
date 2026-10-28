import 'dart:convert';
import 'dart:io';

import 'model_client.dart';

Future<AssistantModelClient> loadModelConfig(
  String path, {
  String reasoning = 'none',
  int maxCompletionTokens = 4000,
  void Function()? onCall,
  Uri? requiredEndpoint,
}) async {
  try {
    final file = File(path);
    if ((await file.stat()).mode & 0x3f != 0) {
      throw const FormatException('Config must have owner-only permissions');
    }
    final config =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final base = Uri.parse(config['base_url'] as String);
    if (base.scheme != 'https' ||
        base.host.isEmpty ||
        base.userInfo.isNotEmpty ||
        base.hasQuery ||
        base.hasFragment ||
        config['model'] != 'gpt-6-luna') {
      throw const FormatException();
    }
    String key;
    final endpoint = base.replace(
      path: '${base.path.replaceFirst(RegExp(r'/$'), '')}/chat/completions',
    );
    // Validate the same parsed snapshot used for credential selection.
    if (requiredEndpoint != null && endpoint != requiredEndpoint) {
      throw const FormatException();
    }
    if (config['model_api_key'] case final String secret
        when secret.isNotEmpty) {
      key = secret;
    } else {
      if (!Platform.isMacOS) throw const FormatException();
      final result = await Process.run('security', [
        'find-generic-password',
        '-s',
        config['keychain_service'] as String,
        '-a',
        config['keychain_account'] as String,
        '-w',
      ]);
      key = (result.stdout as String).trim();
      if (result.exitCode != 0 || key.isEmpty) throw const FormatException();
    }
    return AssistantModelClient(
      endpoint: endpoint,
      apiKey: key,
      reasoning: reasoning,
      maxCompletionTokens: maxCompletionTokens,
      onCall: onCall,
    );
  } catch (_) {
    throw const FormatException(
      'Model configuration or credential unavailable',
    );
  }
}
