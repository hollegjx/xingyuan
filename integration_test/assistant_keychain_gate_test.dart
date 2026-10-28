import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/assistant/data/device_credential_store.dart';
import 'package:integration_test/integration_test.dart';

// Run only on an isolated simulator. This never reads the real credential key.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const run = String.fromEnvironment('ASSISTANT_KEYCHAIN_RUN');
  const phase = String.fromEnvironment('ASSISTANT_KEYCHAIN_PHASE');

  testWidgets('isolated simulator Keychain persistence', (tester) async {
    expect(RegExp(r'^[a-zA-Z0-9-]{8,80}$').hasMatch(run), isTrue);
    expect(['write', 'read'].contains(phase), isTrue);
    final store = DeviceCredentialStore(key: 'assistant-probe-$run');
    if (phase == 'write') {
      expect(await store.read(), isNull);
      final random = Random.secure();
      final token = base64Url
          .encode(List.generate(32, (_) => random.nextInt(256)))
          .replaceAll('=', '');
      await store.save(token);
      expect(await store.read() == token, isTrue);
    } else {
      final persisted = await store.read();
      expect(
        persisted != null && RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(persisted),
        isTrue,
      );
      await store.clear();
      expect(await store.read(), isNull);
    }
  });
}
