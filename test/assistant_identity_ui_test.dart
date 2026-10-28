import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/app/home_page.dart';
import 'package:habit_checkin/data/sync/identity_store.dart';
import 'package:habit_checkin/data/sync/sync_identity.dart';
import 'package:habit_checkin/features/assistant/assistant_providers.dart';
import 'package:habit_checkin/features/assistant/data/local_memory_store.dart';
import 'package:habit_checkin/features/assistant/data/local_proposal_store.dart';
import 'package:habit_checkin/features/assistant/presentation/assistant_memory_page.dart';
import 'package:habit_checkin/features/assistant/presentation/assistant_consent_page.dart';
import 'package:habit_checkin/features/assistant/presentation/assistant_proposal_page.dart';
import 'package:habit_checkin/features/assistant/presentation/assistant_sessions_page.dart';
import 'package:habit_checkin/features/assistant/presentation/assistant_settings_page.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'support/assistant_fixtures.dart';
import 'support/sync_fixtures.dart';
import 'support/test_assistant_service.dart';
import 'support/ui_harness.dart';

Future<void> openPage(WidgetTester tester, Widget page) async {
  unawaited(
    Navigator.of(tester.element(find.byType(HomePage)))
        .push(MaterialPageRoute<void>(builder: (_) => page)),
  );
  await tester.pumpAndSettle();
}

Future<void> switchAway(WidgetTester tester, UiHarness app) async {
  final identity = IdentityStore(app.database);
  await identity.finish(await identity.begin(accountA));
  await tester.pumpAndSettle();
}

Future<void> switchBack(WidgetTester tester, UiHarness app) async {
  final identity = IdentityStore(app.database);
  await identity.finish(await identity.begin(SyncIdentity.guest));
  app.container.invalidate(assistantStoreProvider);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(tzdata.initializeTimeZones);

  for (final mode in ['preview', 'editor', 'time-picker', 'undo']) {
    testUiWidgets('identity change hides proposal $mode and its overlays', (
      tester,
    ) async {
      final app = UiHarness();
      await seedAssistantReply(app.database);
      final proposals = LocalProposalStore(app.repository);
      final id = await proposals.saveDraft(
        sessionId: 'test-session',
        messageId: 'test-message',
        preview: syntheticPreview(count: 1),
      );
      if (mode == 'undo') {
        await proposals.apply(id, syntheticPreview(count: 1));
      }
      await app.mount(tester);
      await openPage(tester, AssistantProposalPage(proposalId: id));
      if (mode == 'editor' || mode == 'time-picker') {
        await tapVisible(tester, find.byTooltip('编辑条目'));
        if (mode == 'time-picker') {
          await tapVisible(tester, find.byKey(const ValueKey('start-time')));
          expect(find.byType(TimePickerDialog), findsOneWidget);
        }
      } else if (mode == 'undo') {
        await tapVisible(
          tester,
          find.byKey(const ValueKey('assistant-undo-plan')),
        );
        expect(
          find.byWidgetPredicate((widget) => widget is AlertDialog),
          findsOneWidget,
        );
      }
      final before = await app.database.select(app.database.goals).get();
      await switchAway(tester, app);
      expect(find.textContaining('TEST item'), findsNothing);
      expect(find.byType(TimePickerDialog), findsNothing);
      expect(
        find.byWidgetPredicate((widget) => widget is AlertDialog),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('assistant-apply-plan')), findsNothing);
      expect(
        find.byKey(const ValueKey('assistant-save-plan-item')),
        findsNothing,
      );
      await switchBack(tester, app);
      expect(find.textContaining('TEST item'), findsNothing);
      expect(await app.database.select(app.database.goals).get(), before);
      expect(tester.takeException(), isNull);
    });
  }

  for (final mode in ['list', 'editor', 'clear', 'date-picker']) {
    testUiWidgets('identity change hides memory $mode without deleting data', (
      tester,
    ) async {
      final app = UiHarness();
      final memories = LocalMemoryStore(app.repository);
      final id = await memories.add(
        const MemoryDraft(category: '偏好', text: 'TEST private memory'),
      );
      await app.mount(tester);
      await openPage(tester, const AssistantMemoryPage());
      expect(find.text('TEST private memory'), findsOneWidget);
      if (mode == 'editor' || mode == 'date-picker') {
        await tapVisible(tester, find.byKey(ValueKey('edit-$id')));
        if (mode == 'date-picker') {
          await tapVisible(tester, find.byTooltip('选择到期日'));
          expect(find.byType(DatePickerDialog), findsOneWidget);
        }
      } else if (mode == 'clear') {
        await tapVisible(tester, find.byTooltip('清空记忆'));
        expect(
          find.byWidgetPredicate((widget) => widget is AlertDialog),
          findsOneWidget,
        );
      }
      final before = await app.database
          .select(app.database.assistantMemories)
          .get();
      await switchAway(tester, app);
      expect(find.text('TEST private memory'), findsNothing);
      expect(find.byType(DatePickerDialog), findsNothing);
      expect(
        find.byWidgetPredicate((widget) => widget is AlertDialog),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('assistant-memory-save')), findsNothing);
      await switchBack(tester, app);
      expect(find.text('TEST private memory'), findsNothing);
      expect(
        await app.database.select(app.database.assistantMemories).get(),
        before,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testUiWidgets('identity change dismisses cached session rename text', (
    tester,
  ) async {
    final app = UiHarness();
    await seedAssistantReply(app.database);
    await LocalMemoryStore(app.repository).consent();
    await app.mount(
      tester,
      assistantService: ConversationTestService(),
      assistantCredentials: ConversationTestCredentials(),
    );
    final controller = await app.container.read(
      assistantConversationProvider.future,
    );
    await openPage(tester, AssistantSessionsPage(controller: controller));
    await tapVisible(tester, find.byTooltip('重命名会话'));
    expect(
      tester
          .widget<TextFormField>(
            find.byKey(const ValueKey('assistant-session-title')),
          )
          .controller!
          .text,
      'TEST session',
    );
    await switchAway(tester, app);
    expect(find.text('TEST session'), findsNothing);
    expect(
      find.byWidgetPredicate((widget) => widget is AlertDialog),
      findsNothing,
    );
    await switchBack(tester, app);
    expect(find.text('TEST session'), findsNothing);
    expect(
      (await app.database.select(app.database.assistantSessions).get())
          .single
          .title,
      'TEST session',
    );
    expect(tester.takeException(), isNull);
  });

  testUiWidgets(
    'pending identity switch hides a 3x memory page before it finishes',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final app = UiHarness();
      await LocalMemoryStore(app.repository)
          .add(const MemoryDraft(category: '偏好', text: 'TEST pending switch'));
      await app.mount(tester);
      await openPage(tester, const AssistantMemoryPage());
      await IdentityStore(app.database).begin(accountA);
      await tester.pumpAndSettle();
      expect(find.text('TEST pending switch'), findsNothing);
      expect(find.textContaining('身份已变化'), findsOneWidget);
      final back = find.widgetWithText(OutlinedButton, '返回');
      await tester.ensureVisible(back);
      await tester.pumpAndSettle();
      expect(back.hitTestable(), findsOneWidget);
      expect(tester.getSize(back).height, greaterThanOrEqualTo(44));
      await tester.tap(back);
      await tester.pumpAndSettle();
      expect(find.byType(AssistantMemoryPage), findsNothing);
      expect(
        (await app.database.select(app.database.assistantMemories).get())
            .single
            .content,
        'TEST pending switch',
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final consent in [false, true]) {
    testUiWidgets(
      'identity change invalidates ${consent ? 'consent' : 'settings'} actions',
      (tester) async {
        final app = UiHarness();
        final credentials = ConversationTestCredentials();
        final service = ConversationTestService();
        await app.mount(
          tester,
          assistantService: service,
          assistantCredentials: credentials,
        );
        await openPage(
          tester,
          consent
              ? const AssistantConsentPage()
              : const AssistantSettingsPage(),
        );
        if (!consent) {
          await tapVisible(
            tester,
            find.byKey(const ValueKey('assistant-credential')),
          );
          await tester.enterText(
            find.byKey(const ValueKey('assistant-credential')),
            'b' * 43,
          );
        }
        await switchAway(tester, app);
        await switchBack(tester, app);
        expect(
          find.byKey(const ValueKey('assistant-consent-confirm')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('assistant-save-credential')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('assistant-credential')),
          findsNothing,
        );
        expect(credentials.value, 'a' * 43);
        expect(
          await app.database.select(app.database.assistantSettings).get(),
          isEmpty,
        );
        expect(service.healthCalls, 0);
        expect(service.requests, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testUiWidgets('inline consent can reopen after identity invalidation', (
    tester,
  ) async {
    final app = UiHarness();
    final service = ConversationTestService();
    await app.mount(
      tester,
      assistantService: service,
      assistantCredentials: ConversationTestCredentials(),
    );
    await tapVisible(tester, find.byTooltip('规划'));
    expect(find.text('AI 数据授权'), findsOneWidget);
    await switchAway(tester, app);
    await switchBack(tester, app);
    expect(find.text('AI 数据授权'), findsNothing);
    expect(
      await app.database.select(app.database.assistantSettings).get(),
      isEmpty,
    );
    await tapVisible(tester, find.byType(OutlinedButton));
    expect(find.text('AI 数据授权'), findsOneWidget);
    expect(
      await app.database.select(app.database.assistantSettings).get(),
      isEmpty,
    );
    expect(service.requests, isEmpty);
    expect(service.healthCalls, 0);
    await tapVisible(
      tester,
      find.byKey(const ValueKey('assistant-consent-confirm')),
    );
    final settings = await app.database
        .select(app.database.assistantSettings)
        .get();
    expect(settings.single.owner, 'guest');
    expect(settings.single.consentedAt, isNotNull);
    expect(service.requests, isEmpty);
    expect(service.healthCalls, 0);
    expect(tester.takeException(), isNull);
  });
}
