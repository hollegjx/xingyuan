import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/assistant/data/assistant_service.dart';
import 'package:integration_test/integration_test.dart';

// Run only on a test simulator. No database, Keychain or model call is used.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native HTTPS health reachability and elapsed time', (
    tester,
  ) async {
    expect(Platform.isIOS, isTrue);
    expect(
      const bool.fromEnvironment('ASSISTANT_HTTPS_PROBE'),
      isTrue,
      reason: 'Explicit opt-in is required before any public network request',
    );
    const address = String.fromEnvironment('ASSISTANT_BASE_URL');
    expect(address, 'https://assistant.example.invalid');
    var credentialReads = 0;
    final service = HttpAssistantService(
      endpoint: Uri.parse(address),
      readCredential: () async {
        credentialReads++;
        throw StateError('The health probe must not read credentials');
      },
    );
    final access = AssistantAccess(
      consentVersion: assistantConsentVersion,
      isCurrent: () async => true,
    );
    final samples = <int>[];
    for (var index = 0; index < 3; index++) {
      final watch = Stopwatch()..start();
      await service.health(access: access);
      watch.stop();
      samples.add(watch.elapsedMilliseconds);
    }
    expect(credentialReads, 0);
    // This is complete client-request time, not isolated network transit time.
    // ignore: avoid_print
    print(
      'ASSISTANT_HTTPS ${jsonEncode({'endpoint': address, 'samples_ms': samples, 'credential_reads': credentialReads, 'model_calls': 0, 'phone_verified': false})}',
    );
  }, timeout: const Timeout(Duration(minutes: 5)));
}
