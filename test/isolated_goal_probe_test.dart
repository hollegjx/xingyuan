import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/app/providers.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/features/assistant/assistant_providers.dart';
import 'package:habit_checkin/features/companion/companion_providers.dart';
import 'package:habit_checkin/features/records/record_providers.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'support/isolated_goal_probe.dart';
import 'support/test_clock.dart';

void main() {
  late Directory temporary;
  late AppDatabase db;
  late ProviderContainer container;
  var ordinaryOpens = 0;

  setUp(() async {
    tzdata.initializeTimeZones();
    temporary = await Directory.systemTemp.createTemp('isolated-goal-probe-');
    db = AppDatabase(NativeDatabase.memory());
    ordinaryOpens = 0;
    container = ProviderContainer(
      overrides: [
        databaseFactoryProvider.overrideWithValue(() {
          ordinaryOpens++;
          throw StateError('Ordinary database must not open');
        }),
        ...isolatedGoalProbeOverrides(
          goals: LocalGoalRepository(db, TestClock()),
          workspace: temporary,
        ),
      ],
    );
  });
  tearDown(() async {
    container.dispose();
    await db.close();
    await temporary.delete(recursive: true);
  });

  test('background cleanup and pages share only the probe database', () async {
    expect(await container.read(databaseProvider.future), same(db));
    final files = await container.read(chatPhotoFilesProvider.future);
    expect(files.db, same(db));
    await container.read(chatPhotoCleanupProvider.future);
    expect(ordinaryOpens, 0);
  });

  test('both photo roots remain inside the unique probe workspace', () async {
    final records = await container.read(recordPhotoRootProvider.future);
    final chat = await container.read(chatPhotoFilesProvider.future);
    expect(records.path, '${temporary.path}/record_photos');
    expect(chat.root.path, '${temporary.path}/chat_photos');
  });

  test(
    'ordinary Keychain is neither read nor written by a personal probe',
    () async {
      final credentials = container.read(assistantCredentialProvider);
      expect(await credentials.read(), isNull);
      await expectLater(credentials.save('synthetic'), throwsStateError);
      await expectLater(credentials.clear(), throwsStateError);
      expect(await credentials.read(), isNull);
    },
  );

  test(
    'live journey credentials remain read-only with isolated cleanup',
    () async {
      container.dispose();
      container = ProviderContainer(
        overrides: [
          databaseFactoryProvider.overrideWithValue(() {
            ordinaryOpens++;
            throw StateError('Ordinary database must not open');
          }),
          ...isolatedGoalProbeOverrides(
            goals: LocalGoalRepository(db, TestClock()),
            workspace: temporary,
            credential: 'synthetic-live-credential',
          ),
        ],
      );
      final credentials = container.read(assistantCredentialProvider);
      expect(await credentials.read(), 'synthetic-live-credential');
      await expectLater(credentials.save('replacement'), throwsStateError);
      await expectLater(credentials.clear(), throwsStateError);
      expect(await credentials.read(), 'synthetic-live-credential');
      final files = await container.read(chatPhotoFilesProvider.future);
      expect(files.db, same(db));
      expect(files.root.path, '${temporary.path}/chat_photos');
      await container.read(chatPhotoCleanupProvider.future);
      expect(ordinaryOpens, 0);
    },
  );
}
