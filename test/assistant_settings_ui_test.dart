import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/sync/identity_store.dart';
import 'package:habit_checkin/data/sync/sync_identity.dart';
import 'package:habit_checkin/features/assistant/assistant_providers.dart';
import 'package:habit_checkin/features/assistant/data/assistant_service.dart';
import 'package:habit_checkin/features/assistant/data/device_credential_store.dart';
import 'package:habit_checkin/features/assistant/data/local_memory_store.dart';
import 'package:habit_checkin/features/assistant/presentation/assistant_consent_page.dart';
import 'package:habit_checkin/features/assistant/presentation/assistant_memory_page.dart';
import 'package:habit_checkin/features/assistant/presentation/assistant_settings_page.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:xingyuan_core/xingyuan_core.dart';

import 'support/sync_fixtures.dart';
import 'support/ui_harness.dart';

class TestDeviceCredentials extends DeviceCredentialStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> save(String input) async {
    if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(input.trim())) {
      throw const DeviceCredentialFailure('设备凭证格式不正确，原有凭证未更改。');
    }
    value = input.trim();
  }

  @override
  Future<void> clear() async {
    value = null;
  }
}

class SettingsTestService implements AssistantService {
  int healthCalls = 0;
  @override
  bool configured = true;
  @override
  Future<void> health({required AssistantAccess access}) async {
    if (access.consentVersion != assistantConsentVersion ||
        !await access.isCurrent()) {
      throw const AssistantFailure(AssistantFailureKind.consent);
    }
    healthCalls++;
  }

  @override
  Future<TurnResponse> turn(
    TurnRequest request, {
    required AssistantAccess access,
    AssistantCancellation? cancellation,
  }) async => throw const AssistantFailure(AssistantFailureKind.unconfigured);
  @override
  Future<SummaryResponse> summarize(
    SummaryRequest request, {
    required AssistantAccess access,
    AssistantCancellation? cancellation,
  }) async => throw const AssistantFailure(AssistantFailureKind.unconfigured);
}

Future<void> openAi(WidgetTester tester) async {
  await openMenu(tester, '设置');
  await tapVisible(tester, find.text('AI 设置'));
}

Future<void> openMemory(WidgetTester tester) async {
  await openAi(tester);
  await tapVisible(tester, find.widgetWithText(OutlinedButton, '管理记忆'));
}

void main() {
  setUpAll(tzdata.initializeTimeZones);
  testUiWidgets(
    'an editor opened before identity changes cannot save even after switching back',
    (tester) async {
      final app = UiHarness();
      await app.mount(
        tester,
        assistantService: SettingsTestService(),
        assistantCredentials: TestDeviceCredentials(),
      );
      await openMemory(tester);
      await tapVisible(
        tester,
        find.byKey(const ValueKey('assistant-memory-add')),
      );
      await tester.enterText(
        find.byKey(const ValueKey('assistant-memory-text')),
        'TEST stale draft',
      );
      final originalStore = await app.container.read(
        assistantStoreProvider.future,
      );
      final identity = IdentityStore(app.database);
      await identity.finish(await identity.begin(accountA));
      await identity.finish(await identity.begin(SyncIdentity.guest));
      app.container.invalidate(assistantStoreProvider);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('assistant-memory-save')), findsNothing);
      expect(find.byType(AssistantMemoryEditPage), findsNothing);
      expect(find.text('TEST stale draft'), findsNothing);
      await expectLater(
        originalStore.memories.add(
          const MemoryDraft(category: '偏好', text: 'TEST stale draft'),
        ),
        throwsA(isA<StaleIdentity>()),
      );
      expect(
        await app.database.select(app.database.assistantMemories).get(),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );
  for (final scale in [1.0, 2.0, 3.0]) {
    testUiWidgets(
      'AI consent, credential and memory editing work at 320px ${scale}x',
      (tester) async {
        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final app = UiHarness();
        final credentials = TestDeviceCredentials();
        final service = SettingsTestService();
        await app.mount(
          tester,
          assistantService: service,
          assistantCredentials: credentials,
        );
        await openAi(tester);
        expect(find.byType(AssistantSettingsPage), findsOneWidget);
        expect(service.healthCalls, 0);
        expect(
          tester
              .widget<OutlinedButton>(
                find.byKey(const ValueKey('assistant-health')),
              )
              .onPressed,
          isNull,
        );
        await tapVisible(tester, find.widgetWithText(TextButton, '查看授权'));
        expect(find.byType(AssistantConsentPage), findsOneWidget);
        await tapVisible(
          tester,
          find.byKey(const ValueKey('assistant-consent-confirm')),
        );
        final settings = await app.container.read(
          assistantSettingsProvider.future,
        );
        expect(settings.consentVersion, assistantConsentVersion);
        expect(service.healthCalls, 0);
        await tapVisible(
          tester,
          find.byKey(const ValueKey('assistant-health')),
        );
        expect(service.healthCalls, 1);
        await tester.ensureVisible(
          find.byKey(const ValueKey('assistant-credential')),
        );
        await tester.enterText(
          find.byKey(const ValueKey('assistant-credential')),
          'a' * 43,
        );
        expect(
          tester
              .widget<TextField>(
                find.byKey(const ValueKey('assistant-credential')),
              )
              .obscureText,
          isTrue,
        );
        await tapVisible(
          tester,
          find.byKey(const ValueKey('assistant-save-credential')),
        );
        expect(credentials.value, 'a' * 43);
        expect(
          tester
              .widget<TextField>(
                find.byKey(const ValueKey('assistant-credential')),
              )
              .controller!
              .text,
          isEmpty,
        );
        await tapVisible(tester, find.widgetWithText(SwitchListTile, '发送记忆'));
        expect(
          (await app.container.read(assistantSettingsProvider.future))
              .sendMemories,
          isFalse,
        );
        await tapVisible(tester, find.widgetWithText(OutlinedButton, '管理记忆'));
        await tapVisible(
          tester,
          find.byKey(const ValueKey('assistant-memory-add')),
        );
        await tester.enterText(
          find.byKey(const ValueKey('assistant-memory-text')),
          'TEST 晚上有空',
        );
        await tapVisible(tester, find.byTooltip('选择到期日'));
        await tapVisible(tester, find.widgetWithText(TextButton, '确定'));
        await tapVisible(tester, find.widgetWithText(SwitchListTile, '置顶'));
        await tapVisible(
          tester,
          find.byKey(const ValueKey('assistant-memory-save')),
        );
        final memory = (await app.container.read(
          assistantMemoriesProvider.future,
        )).single;
        expect(memory.content, 'TEST 晚上有空');
        expect(memory.pinned, isTrue);
        expect(memory.expiresOn, app.clock.day.key);
        expect(find.byType(AssistantMemoryPage), findsOneWidget);
        await tapVisible(tester, find.byKey(ValueKey('edit-${memory.id}')));
        await tester.enterText(
          find.byKey(const ValueKey('assistant-memory-text')),
          'TEST 改为下午',
        );
        await tapVisible(tester, find.byTooltip('清除到期日'));
        await tapVisible(
          tester,
          find.byKey(const ValueKey('assistant-memory-save')),
        );
        final changed = (await app.container.read(
          assistantMemoriesProvider.future,
        )).single;
        expect(changed.content, 'TEST 改为下午');
        expect(changed.expiresOn, isNull);
        await tapVisible(tester, find.byKey(ValueKey('pin-${memory.id}')));
        expect(
          (await app.container.read(assistantMemoriesProvider.future))
              .single
              .pinned,
          isFalse,
        );
        await tapVisible(tester, find.byKey(ValueKey('delete-${memory.id}')));
        await tapVisible(tester, find.widgetWithText(FilledButton, '删除'));
        expect(
          await app.container.read(assistantMemoriesProvider.future),
          isEmpty,
        );
        expect(service.healthCalls, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testUiWidgets(
    'memory clear is confirmed and owner-scoped; expired rows remain visible',
    (tester) async {
      final app = UiHarness();
      final mine = LocalMemoryStore(app.repository);
      await mine.add(
        MemoryDraft(
          category: '偏好',
          text: 'TEST expired',
          expiresOn: CalendarDate.parse(app.clock.day.addDays(-1).key),
        ),
      );
      final other = LocalMemoryStore(
        LocalGoalRepository(app.database, app.clock, owner: accountA.owner),
      );
      await other.add(const MemoryDraft(category: '偏好', text: 'TEST other'));
      await app.mount(
        tester,
        assistantService: SettingsTestService(),
        assistantCredentials: TestDeviceCredentials(),
      );
      await openMemory(tester);
      expect(find.text('TEST expired'), findsOneWidget);
      expect(find.textContaining('已过期'), findsOneWidget);
      expect(find.text('TEST other'), findsNothing);
      await tapVisible(
        tester,
        find.byKey(const ValueKey('assistant-memory-clear')),
      );
      await tapVisible(tester, find.widgetWithText(TextButton, '取消'));
      expect(await mine.list(), hasLength(1));
      await tapVisible(
        tester,
        find.byKey(const ValueKey('assistant-memory-clear')),
      );
      await tapVisible(tester, find.widgetWithText(FilledButton, '删除'));
      expect(await mine.list(), isEmpty);
      expect(await other.list(), hasLength(1));
      expect(await app.repository.loadGoals(), isEmpty);
    },
  );

  testUiWidgets(
    'bad credentials preserve the previous key; clear removes it without a network call',
    (tester) async {
      final app = UiHarness();
      final keys = TestDeviceCredentials()..value = 'a' * 43;
      final service = SettingsTestService();
      await app.mount(
        tester,
        assistantService: service,
        assistantCredentials: keys,
      );
      await openAi(tester);
      await tester.enterText(
        find.byKey(const ValueKey('assistant-credential')),
        'bad',
      );
      await tapVisible(
        tester,
        find.byKey(const ValueKey('assistant-save-credential')),
      );
      expect(keys.value, 'a' * 43);
      expect(find.textContaining('原有凭证未更改'), findsOneWidget);
      await tapVisible(
        tester,
        find.byKey(const ValueKey('assistant-clear-credential')),
      );
      expect(keys.value, isNull);
      expect(service.healthCalls, 0);
    },
  );

  testUiWidgets(
    'memory validation rejects empty and sensitive contents without creating data',
    (tester) async {
      final app = UiHarness();
      await app.mount(
        tester,
        assistantService: SettingsTestService(),
        assistantCredentials: TestDeviceCredentials(),
      );
      await openMemory(tester);
      await tapVisible(
        tester,
        find.byKey(const ValueKey('assistant-memory-add')),
      );
      await tapVisible(
        tester,
        find.byKey(const ValueKey('assistant-memory-save')),
      );
      expect(find.byType(AssistantMemoryEditPage), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('assistant-memory-text')),
        'TEST 密码 123',
      );
      await tapVisible(
        tester,
        find.byKey(const ValueKey('assistant-memory-save')),
      );
      expect(find.byType(AssistantMemoryEditPage), findsOneWidget);
      expect(
        await app.container.read(assistantMemoriesProvider.future),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
