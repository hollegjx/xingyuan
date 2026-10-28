import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/assistant/assistant_providers.dart';
import 'package:habit_checkin/features/assistant/data/device_credential_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const store = DeviceCredentialStore();
  final token = base64Url.encode(List.filled(32, 11)).replaceAll('=', '');

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    FlutterSecureStorage.setMockInitialValues({'unrelated': 'must-remain'});
  });
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('credential roundtrip and clear touch only the dedicated key', () async {
    expect(await store.read(), isNull);
    await store.save(' $token\n');
    expect(await store.read(), token);
    await store.clear();
    expect(await store.read(), isNull);
    expect(
      await const FlutterSecureStorage().read(key: 'unrelated'),
      'must-remain',
    );
  });

  test('invalid credential cannot overwrite an existing credential', () async {
    await store.save(token);
    for (final value in ['', 'invalid', '$token\r\nheader: x']) {
      await expectLater(
        store.save(value),
        throwsA(isA<DeviceCredentialFailure>()),
      );
      expect(await store.read(), token);
    }
  });

  test(
    'credential mutation announces start and completion and rejects overlap',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final revision = container.read(
        assistantCredentialRevisionProvider.notifier,
      );
      final gate = Completer<void>();
      final changing = revision.change(() => gate.future);
      expect(revision.changing, true);
      expect(container.read(assistantCredentialRevisionProvider), 1);
      var duplicate = false;
      await expectLater(
        revision.change(() async {
          duplicate = true;
        }),
        throwsA(isA<DeviceCredentialFailure>()),
      );
      expect(duplicate, false);
      gate.complete();
      await changing;
      expect(revision.changing, false);
      expect(container.read(assistantCredentialRevisionProvider), 2);
    },
  );

  test('failed credential mutation releases the pending state', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final revision = container.read(
      assistantCredentialRevisionProvider.notifier,
    );
    await expectLater(
      revision.change(() async {
        throw const DeviceCredentialFailure('SYNTHETIC keychain failure');
      }),
      throwsA(isA<DeviceCredentialFailure>()),
    );
    expect(revision.changing, false);
    expect(container.read(assistantCredentialRevisionProvider), 2);
  });

  test(
    'device credential cannot synchronize or migrate via iCloud Keychain',
    () {
      final options = DeviceCredentialStore.iosOptions.toMap();
      expect(options['accessibility'], 'unlocked_this_device');
      expect(options['synchronizable'], 'false');
      expect(options['accountName'], 'xingyuan.assistant');
      expect(options, isNot(contains('groupId')));
    },
  );
}
