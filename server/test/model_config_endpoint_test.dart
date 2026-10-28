import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:xingyuan_server/model_access.dart';

void main() {
  test('required destination uses one synthetic config snapshot before credentials', () async {
    final dir = Directory.systemTemp.createTempSync('agent-config-test-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/synthetic.json');
    final endpoint = Uri.parse('https://synthetic.invalid/v1/chat/completions');
    file.writeAsStringSync(
      jsonEncode({
        'base_url': 'https://elsewhere.invalid/v1',
        'model': 'gpt-6-luna',
        'model_api_key': 'SYNTHETIC_ONLY',
      }),
    );
    await Process.run('chmod', ['600', file.path]);
    await expectLater(
      loadModelConfig(file.path, requiredEndpoint: endpoint),
      throwsFormatException,
    );
    file.writeAsStringSync(
      jsonEncode({
        'base_url': 'https://synthetic.invalid/v1',
        'model': 'gpt-6-luna',
        'model_api_key': 'SYNTHETIC_ONLY',
      }),
    );
    final loaded = await loadModelConfig(file.path, requiredEndpoint: endpoint);
    expect(loaded.endpoint, endpoint);
    // No network method is invoked; legacy callers need no new option.
    expect((await loadModelConfig(file.path)).endpoint, endpoint);
  });
}
