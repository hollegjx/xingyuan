import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/sync/identity_store.dart';
import 'package:habit_checkin/data/sync/sync_identity.dart';
import 'package:habit_checkin/features/assistant/assistant_providers.dart';
import 'package:habit_checkin/features/assistant/data/assistant_service.dart';
import 'package:habit_checkin/features/journal/domain/journal_entry.dart';
import 'package:habit_checkin/features/journal/ai/journal_ai_providers.dart';
import 'package:habit_checkin/features/journal/journal_providers.dart';
import 'package:habit_checkin/features/journal/presentation/journal_editor_page.dart';
import 'package:habit_checkin/shared/presentation.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'support/journal_ai_service.dart';
import 'support/journal_fixtures.dart';
import 'support/journal_request_size.dart';
import 'support/test_assistant_service.dart';
import 'support/ui_harness.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);
  Finder key(String name) => find.byKey(ValueKey(name));
  Finder notice(String text) => find.descendant(
    of: find.byType(JournalEditorPage),
    matching: find.textContaining(text),
  );
  String draft(WidgetTester tester) =>
      tester.widget<TextField>(key('journal-text')).controller!.text;

  Future<UiHarness> mount(
    WidgetTester tester,
    SyntheticJournalAi service, {
    bool consent = true,
  }) async {
    final h = UiHarness();
    h.clock.setDay(2026, 10, 23);
    await h.mount(
      tester,
      journalAiService: service,
      assistantCredentials: ConversationTestCredentials(),
      journalPhotoFiles: {
        for (final kind in JournalKind.values)
          kind: MemoryJournalPhotoFiles(kind),
      },
    );
    if (consent) {
      final store = await h.container.read(assistantStoreProvider.future);
      await store.memories.consent();
      h.container.invalidate(assistantSettingsProvider);
      await tester.pumpAndSettle();
    }
    return h;
  }

  Future<void> write(WidgetTester tester, String text) async {
    await tester.enterText(key('journal-text'), text);
    await tester.pumpAndSettle();
  }

  testUiWidgets(
    'consent is explicit, can be revoked, and offline editing stays available',
    (tester) async {
      final service = SyntheticJournalAi();
      final h = await mount(tester, service, consent: false);
      await tapVisible(tester, key('entry-quick-note'));
      await write(tester, '我读完了一章');
      expect(h.container.exists(journalAiServiceProvider), isFalse);
      expect(h.container.exists(assistantServiceProvider), isFalse);
      await tapVisible(tester, key('journal-ai-request'));
      expect(find.text('开启 AI 功能'), findsOneWidget);
      expect(find.textContaining('只发送这一条的文字，不发照片'), findsOneWidget);
      expect(h.container.exists(journalAiServiceProvider), isFalse);
      expect(h.container.exists(assistantServiceProvider), isFalse);
      expect(service.calls, isEmpty);
      await tapVisible(tester, key('journal-ai-open-settings'));
      await tapVisible(tester, key('assistant-enabled'));
      expect(service.calls, isEmpty);
      await tapVisible(tester, key('assistant-consent-confirm'));
      expect(
        (await h.container.read(assistantSettingsProvider.future))
            .consentVersion,
        assistantConsentVersion,
      );
      await tapVisible(tester, key('assistant-enabled'));
      expect(
        (await h.container.read(assistantSettingsProvider.future)).consentedAt,
        isNull,
      );
      await goBack(tester);
      await tapVisible(tester, key('journal-ai-request'));
      expect(find.text('开启 AI 功能'), findsOneWidget);
      expect(service.calls, isEmpty);
      await tapVisible(tester, find.text('取消'));
      await tapVisible(tester, key('save-journal'));
      final store = await h.container.read(quickNoteStoreProvider.future);
      expect((await store.savedOn(h.clock.day)).single.entry.content, '我读完了一章');
      expect(service.calls, isEmpty);
    },
  );

  for (final kind in JournalKind.values) {
    testUiWidgets('expired consent explains ${kind.name} without a service', (
      tester,
    ) async {
      final service = SyntheticJournalAi();
      final h = await mount(tester, service);
      final memories = (await h.container.read(assistantStoreProvider.future))
          .memories;
      final settings = await memories.settings();
      await h.database
          .into(h.database.assistantSettings)
          .insertOnConflictUpdate(
            settings.copyWith(consentVersion: assistantConsentVersion - 1),
          );
      h.container.invalidate(assistantSettingsProvider);
      await tester.pumpAndSettle();
      await tapVisible(
        tester,
        key(kind == JournalKind.diary ? 'entry-diary' : 'entry-quick-note'),
      );
      expect(find.text('AI 未开启'), findsOneWidget);
      expect(h.container.exists(journalAiServiceProvider), isFalse);
      await tapVisible(tester, key('journal-ai-request'));
      expect(find.text('开启 AI 功能'), findsOneWidget);
      expect(find.textContaining('不发照片'), findsOneWidget);
      expect(h.container.exists(journalAiServiceProvider), isFalse);
      expect(service.calls, isEmpty);
      expect(
        (await memories.settings()).consentVersion,
        assistantConsentVersion - 1,
      );
      await tapVisible(tester, find.text('取消'));
      expect(service.calls, isEmpty);
    });

    testUiWidgets(
      'disconnected ${kind.name} explains the action without requests',
      (tester) async {
        final service = SyntheticJournalAi()..configured = false;
        await mount(tester, service);
        await tapVisible(
          tester,
          key(kind == JournalKind.diary ? 'entry-diary' : 'entry-quick-note'),
        );
        expect(
          find.text(kind == JournalKind.diary ? 'AI 写日记' : '润色'),
          findsOneWidget,
        );
        await tapVisible(tester, key('journal-ai-request'));
        expect(notice('AI 暂时连接不上'), findsOneWidget);
        expect(service.calls, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testUiWidgets('AI invitation is limited to an empty diary for today', (
    tester,
  ) async {
    final service = SyntheticJournalAi();
    await mount(tester, service, consent: false);
    await tapVisible(tester, key('entry-quick-note'));
    expect(key('journal-ai-invite'), findsNothing);
    await goBack(tester);
    await tapVisible(tester, key('entry-diary'));
    expect(key('journal-ai-invite'), findsOneWidget);
    await tapVisible(tester, key('journal-ai-invite'));
    expect(find.text('开启 AI 功能'), findsOneWidget);
    expect(find.textContaining('只发送今天的打卡和随手记文字，不发照片'), findsOneWidget);
    await tapVisible(tester, find.text('取消'));
    await write(tester, '自己的日记');
    expect(key('journal-ai-invite'), findsNothing);
    await tapVisible(tester, key('save-journal'));
    await tapVisible(tester, key('entry-diary'));
    expect(key('journal-ai-invite'), findsNothing);
    await write(tester, '  ');
    expect(key('journal-ai-invite'), findsOneWidget);
    expect(service.calls, isEmpty);
  });

  testUiWidgets(
    'AI invitation previews today without saving or replacing text',
    (tester) async {
      final service = SyntheticJournalAi();
      final h = await mount(tester, service);
      final notes = await h.container.read(quickNoteStoreProvider.future);
      await saveJournalNotes(notes, ['合成当天记录']);
      await tapVisible(tester, key('entry-diary'));
      await tapVisible(tester, key('journal-ai-invite'));
      expect(key('journal-ai-suggestion'), findsOneWidget);
      expect(service.calls, hasLength(1));
      final store = await h.container.read(diaryStoreProvider.future);
      expect(await store.savedOn(h.clock.day), isEmpty);
      await tapVisible(tester, key('journal-ai-keep'));
      expect(draft(tester), isEmpty);
      expect(await store.savedOn(h.clock.day), isEmpty);
      expect((await notes.savedOn(h.clock.day)).single.entry.content, '合成当天记录');
    },
  );

  testUiWidgets(
    'reentrant unavailable AI callbacks open only one consent dialog',
    (tester) async {
      final service = SyntheticJournalAi();
      await mount(tester, service, consent: false);
      await tapVisible(tester, key('entry-quick-note'));
      final action = tester
          .widget<TextButton>(key('journal-ai-request'))
          .onPressed!;
      for (var i = 0; i < 4; i++) {
        action();
      }
      await tester.pumpAndSettle();
      expect(
        find.byKey(
          const ValueKey('journal-ai-open-settings'),
          skipOffstage: false,
        ),
        findsOneWidget,
      );
      await tapVisible(tester, find.text('取消'));
      expect(find.text('开启 AI 功能'), findsNothing);
      expect(service.calls, isEmpty);
    },
  );

  testUiWidgets(
    'clock rollback hides invitation and explains the future date',
    (tester) async {
      final service = SyntheticJournalAi();
      final h = await mount(tester, service);
      await tapVisible(tester, key('entry-diary'));
      expect(key('journal-ai-invite'), findsOneWidget);
      h.clock.setDay(2026, 10, 22);
      h.container.invalidate(assistantSettingsProvider);
      await tester.pumpAndSettle();
      expect(key('journal-ai-invite'), findsNothing);
      await tapVisible(tester, key('journal-ai-request'));
      expect(notice('AI 只能为今天写日记。'), findsOneWidget);
      expect(service.calls, isEmpty);
    },
  );

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 3.5]) {
      testUiWidgets(
        'AI invitation stays accessible at 320px $scale ${brightness.name}',
        (tester) async {
          tester.view.physicalSize = const Size(320, 568);
          tester.view.devicePixelRatio = 1;
          tester.view.padding = const FakeViewPadding(top: 20);
          tester.view.viewPadding = const FakeViewPadding(top: 20);
          tester.view.viewInsets = const FakeViewPadding();
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          tester.platformDispatcher.platformBrightnessTestValue = brightness;
          addTearDown(() {
            tester.view.resetPhysicalSize();
            tester.view.resetDevicePixelRatio();
            tester.view.resetPadding();
            tester.view.resetViewPadding();
            tester.view.resetViewInsets();
            tester.platformDispatcher.clearTextScaleFactorTestValue();
            tester.platformDispatcher.clearPlatformBrightnessTestValue();
          });
          final service = SyntheticJournalAi();
          final h = await mount(tester, service, consent: false);
          await tapVisible(tester, key('entry-diary'));
          expect(find.byTooltip('AI 写日记'), findsOneWidget);
          if (scale > 1.6) {
            expect(
              find.descendant(
                of: key('journal-ai-request'),
                matching: find.byType(Text),
              ),
              findsNothing,
            );
          }
          await tapVisible(
            tester,
            key(scale == 1 ? 'journal-ai-invite' : 'journal-ai-request'),
          );
          expect(find.text('开启 AI 功能'), findsOneWidget);
          await tapVisible(tester, find.text('取消'));
          expect(h.container.exists(journalAiServiceProvider), isFalse);
          expect(service.calls, isEmpty);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 3.5]) {
      testUiWidgets(
        'oversized diary explains the limit at 320px $scale ${brightness.name} without losing drafts',
        (tester) async {
          tester.view.physicalSize = const Size(320, 568);
          tester.view.devicePixelRatio = 1;
          tester.view.padding = const FakeViewPadding(top: 20);
          tester.view.viewPadding = const FakeViewPadding(top: 20);
          tester.view.viewInsets = const FakeViewPadding();
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          tester.platformDispatcher.platformBrightnessTestValue = brightness;
          addTearDown(() {
            tester.view.resetPhysicalSize();
            tester.view.resetDevicePixelRatio();
            tester.view.resetPadding();
            tester.view.resetViewPadding();
            tester.view.resetViewInsets();
            tester.platformDispatcher.clearTextScaleFactorTestValue();
            tester.platformDispatcher.clearPlatformBrightnessTestValue();
          });
          final service = SyntheticJournalAi();
          final h = await mount(tester, service);
          final notes =
              diaryPayloadOfSize(64001, unit: '中')['notes']! as List<String>;
          final store = await h.container.read(quickNoteStoreProvider.future);
          await saveJournalNotes(store, notes);
          await tester.pumpAndSettle();
          await tapVisible(tester, key('entry-diary'));
          await write(tester, '自己的日记草稿');
          await tapVisible(tester, key('journal-ai-request'));
          expect(find.textContaining('今天的素材太多'), findsOneWidget);
          expect(key('journal-ai-suggestion'), findsNothing);
          expect(service.calls, isEmpty);
          expect(draft(tester), '自己的日记草稿');
          await tapVisible(tester, key('save-journal'));
          final diary = await h.container.read(diaryStoreProvider.future);
          expect(
            (await diary.savedOn(h.clock.day)).single.entry.content,
            '自己的日记草稿',
          );
          expect(
            (await store.savedOn(h.clock.day)).map((row) => row.entry.content),
            unorderedEquals(notes),
          );
          expect(service.calls, isEmpty);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testUiWidgets('polish preview keep, explicit use, undo, then explicit save', (
    tester,
  ) async {
    final service = SyntheticJournalAi();
    final h = await mount(tester, service);
    await tapVisible(tester, key('entry-quick-note'));
    await write(tester, '我读完了一章');
    await tapVisible(tester, key('journal-ai-request'));
    expect(find.text('我读完了一章'), findsWidgets);
    expect(key('journal-ai-suggestion'), findsOneWidget);
    final store = await h.container.read(quickNoteStoreProvider.future);
    expect(await store.savedOn(h.clock.day), isEmpty);
    await tapVisible(tester, key('journal-ai-keep'));
    expect(draft(tester), '我读完了一章');
    await tapVisible(tester, key('journal-ai-request'));
    await tapVisible(tester, key('journal-ai-use'));
    expect(draft(tester), service.rewrite);
    expect(await store.savedOn(h.clock.day), isEmpty);
    await tapVisible(tester, key('journal-ai-undo'));
    expect(draft(tester), '我读完了一章');
    expect(key('journal-ai-applied'), findsNothing);
    await tapVisible(tester, key('save-journal'));
    expect((await store.savedOn(h.clock.day)).single.entry.content, '我读完了一章');
    expect(service.calls, hasLength(2));
  });

  for (final change in ['consent', 'connection']) {
    testUiWidgets('applied draft keeps settings and local undo after $change', (
      tester,
    ) async {
      final service = SyntheticJournalAi();
      final h = await mount(tester, service);
      await tapVisible(tester, key('entry-quick-note'));
      await write(tester, '我读完了一章');
      await tapVisible(tester, key('journal-ai-request'));
      await tapVisible(tester, key('journal-ai-use'));
      expect(draft(tester), service.rewrite);
      if (change == 'consent') {
        final store = await h.container.read(assistantStoreProvider.future);
        await store.memories.revokeConsent();
        h.container.invalidate(assistantSettingsProvider);
      } else {
        service.configured = false;
        h.container
            .read(assistantCredentialRevisionProvider.notifier)
            .changed();
      }
      await tester.pumpAndSettle();
      await tapVisible(tester, key('journal-ai-request'));
      if (change == 'consent') {
        expect(find.text('开启 AI 功能'), findsOneWidget);
        await tapVisible(tester, find.text('取消'));
      } else {
        expect(notice('AI 暂时连接不上'), findsOneWidget);
      }
      expect(service.calls, hasLength(1));
      expect(key('journal-ai-settings'), findsOneWidget);
      expect(key('journal-ai-applied'), findsOneWidget);
      expect(
        tester.widget<IconButton>(key('journal-ai-undo')).onPressed,
        isNotNull,
      );
      await tapVisible(tester, key('journal-ai-settings'));
      expect(key('assistant-enabled'), findsOneWidget);
      await goBack(tester);
      expect(draft(tester), service.rewrite);
      await tapVisible(tester, key('journal-ai-undo'));
      expect(draft(tester), '我读完了一章');
      final store = await h.container.read(quickNoteStoreProvider.future);
      expect(await store.savedOn(h.clock.day), isEmpty);
      expect(service.calls, hasLength(1));
    });
  }

  for (final choice in ['cancel', 'replace', 'append']) {
    testUiWidgets(
      'diary $choice is required when the draft already has content',
      (tester) async {
        final service = SyntheticJournalAi();
        final h = await mount(tester, service);
        await tapVisible(tester, key('entry-quick-note'));
        await write(tester, '我读完了一章');
        await tapVisible(tester, key('save-journal'));
        await tapVisible(tester, key('entry-diary'));
        await write(tester, '自己的开头');
        await tapVisible(tester, key('journal-ai-request'));
        expect(
          tester.widget<FilledButton>(key('journal-ai-use')).onPressed,
          isNull,
        );
        if (choice == 'cancel') {
          expect(key('journal-ai-suggestion'), findsOneWidget);
          await tapVisible(tester, key('journal-ai-keep'));
          expect(draft(tester), '自己的开头');
        } else {
          await tapVisible(tester, find.text(choice == 'append' ? '追加' : '替换'));
          await tapVisible(tester, key('journal-ai-use'));
          expect(
            draft(tester),
            choice == 'append' ? '自己的开头\n\n${service.diary}' : service.diary,
          );
          expect(key('journal-ai-applied'), findsOneWidget);
          await tapVisible(tester, key('journal-ai-undo'));
          expect(draft(tester), '自己的开头');
        }
        final store = await h.container.read(diaryStoreProvider.future);
        expect(await store.savedOn(h.clock.day), isEmpty);
      },
    );
  }

  for (final change in ['cancel', 'revoke', 'credential', 'identity']) {
    testUiWidgets(
      'in-flight $change hides any late result and keeps the original draft',
      (tester) async {
        final service = SyntheticJournalAi()..gate = Completer<void>();
        final h = await mount(tester, service);
        await tapVisible(tester, key('entry-quick-note'));
        await write(tester, '我读完了一章');
        await tapVisible(tester, key('journal-ai-request'), settle: false);
        expect(service.calls, hasLength(1));
        expect(key('journal-ai-cancel'), findsOneWidget);
        expect(find.byType(XyActivity), findsOneWidget);
        expect(key('journal-ai-suggestion'), findsNothing);
        expect(draft(tester), '我读完了一章');
        switch (change) {
          case 'cancel':
            await tapVisible(tester, key('journal-ai-cancel'));
          case 'revoke':
            final store = await h.container.read(assistantStoreProvider.future);
            await store.memories.revokeConsent();
            h.container.invalidate(assistantSettingsProvider);
            await tester.pumpAndSettle();
          case 'credential':
            h.container
                .read(assistantCredentialRevisionProvider.notifier)
                .changed();
            await tester.pumpAndSettle();
          case 'identity':
            final identity = IdentityStore(h.database);
            await identity.finish(
              await identity.begin(
                SyncIdentity.account('55555555-5555-4555-8555-555555555555'),
              ),
            );
            await tester.pumpAndSettle();
        }
        service.gate!.complete();
        await tester.pumpAndSettle();
        expect(key('journal-ai-cancel'), findsNothing);
        expect(find.byType(XyActivity), findsNothing);
        expect(key('journal-ai-suggestion'), findsNothing);
        if (change == 'identity') {
          expect(key('journal-text'), findsNothing);
        } else {
          expect(draft(tester), '我读完了一章');
        }
        final rows = await h.database.select(h.database.quickNotes).get();
        expect(rows.single.draftText, '我读完了一章');
        expect(rows.single.savedAt, isNull);
      },
    );
  }

  for (final change in ['revoke', 'identity']) {
    testUiWidgets('open preview is hidden immediately after $change', (
      tester,
    ) async {
      final service = SyntheticJournalAi();
      final h = await mount(tester, service);
      await tapVisible(tester, key('entry-quick-note'));
      await write(tester, '我读完了一章');
      await tapVisible(tester, key('journal-ai-request'));
      expect(key('journal-ai-suggestion'), findsOneWidget);
      if (change == 'revoke') {
        final store = await h.container.read(assistantStoreProvider.future);
        await store.memories.revokeConsent();
        h.container.invalidate(assistantSettingsProvider);
      } else {
        final identity = IdentityStore(h.database);
        await identity.finish(
          await identity.begin(
            SyncIdentity.account('55555555-5555-4555-8555-555555555555'),
          ),
        );
      }
      await tester.pumpAndSettle();
      expect(key('journal-ai-suggestion'), findsNothing);
      if (change == 'revoke') {
        expect(
          tester.widget<FilledButton>(key('journal-ai-use')).onPressed,
          isNull,
        );
        await tapVisible(tester, key('journal-ai-keep'));
        expect(draft(tester), '我读完了一章');
      } else {
        expect(key('journal-ai-use'), findsNothing);
        expect(key('journal-text'), findsNothing);
      }
      expect(
        (await h.database.select(h.database.quickNotes).get()).single.savedAt,
        isNull,
      );
    });
  }

  testUiWidgets(
    'historical diary edits remain local and cannot generate from today',
    (tester) async {
      final service = SyntheticJournalAi();
      final h = await mount(tester, service);
      final yesterday = h.clock.day.addDays(-1);
      await tapVisible(tester, find.byTooltip('回顾'));
      await tapVisible(tester, key('review-day-${yesterday.key}'));
      await tapVisible(tester, key('write-diary-${yesterday.key}'));
      expect(key('journal-ai-invite'), findsNothing);
      await tapVisible(tester, key('journal-ai-request'));
      expect(find.text('AI 只能为今天写日记。'), findsOneWidget);
      expect(service.calls, isEmpty);
      await write(tester, '昨天的日记');
      await tapVisible(tester, key('save-journal'));
      final store = await h.container.read(diaryStoreProvider.future);
      expect((await store.atDay(yesterday))!.entry.content, '昨天的日记');
      expect(service.calls, isEmpty);
    },
  );

  for (final brightness in Brightness.values) {
    for (final size in [const Size(320, 568), const Size(568, 320)]) {
      testUiWidgets(
        'diary preview and append at $size 3.5x ${brightness.name}',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          // Synthetic pixels must not retain a native 3x safe area or keyboard.
          tester.view.padding = const FakeViewPadding(top: 20);
          tester.view.viewPadding = const FakeViewPadding(top: 20);
          tester.view.viewInsets = const FakeViewPadding();
          tester.platformDispatcher.textScaleFactorTestValue = 3.5;
          tester.platformDispatcher.platformBrightnessTestValue = brightness;
          addTearDown(() {
            tester.view.resetPhysicalSize();
            tester.view.resetDevicePixelRatio();
            tester.view.resetPadding();
            tester.view.resetViewPadding();
            tester.view.resetViewInsets();
            tester.platformDispatcher.clearTextScaleFactorTestValue();
            tester.platformDispatcher.clearPlatformBrightnessTestValue();
          });
          final service = SyntheticJournalAi()..diary = '合成日记。' * 280;
          final h = await mount(tester, service);
          await tapVisible(tester, key('entry-quick-note'));
          await write(tester, '今天读完了一章');
          await tapVisible(tester, key('save-journal'));
          await tapVisible(tester, key('entry-diary'));
          await write(tester, '自己的开头');
          await tapVisible(tester, key('journal-ai-request'));
          expect(key('journal-ai-suggestion'), findsOneWidget);
          expect(tester.takeException(), isNull);
          final scroll = find.ancestor(
            of: key('journal-ai-suggestion'),
            matching: find.byType(SingleChildScrollView),
          );
          expect(scroll, findsOneWidget);
          await tester.drag(scroll, const Offset(0, -150));
          await tester.pumpAndSettle();
          final position = tester
              .state<ScrollableState>(
                find.descendant(of: scroll, matching: find.byType(Scrollable)),
              )
              .position;
          expect(position.pixels, greaterThan(0));
          // At accessibility sizes actions follow the text in the scroll view.
          for (final action in ['journal-ai-keep', 'journal-ai-use']) {
            await tester.ensureVisible(key(action));
            await tester.pumpAndSettle();
            expect(key(action).hitTestable(), findsOneWidget);
          }
          await tapVisible(tester, find.text('追加'));
          await tapVisible(tester, key('journal-ai-use'));
          expect(draft(tester), '自己的开头\n\n${service.diary}');
          final store = await h.container.read(diaryStoreProvider.future);
          expect(await store.savedOn(h.clock.day), isEmpty);
          await tapVisible(tester, key('journal-ai-undo'));
          expect(draft(tester), '自己的开头');
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant({
          TargetPlatform.iOS,
          TargetPlatform.android,
        }),
      );
    }

    testUiWidgets(
      'long AI preview at 320px 3.5x ${brightness.name} stays scrollable and dismissible',
      (tester) async {
        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1;
        tester.view.padding = const FakeViewPadding(top: 20);
        tester.view.viewPadding = const FakeViewPadding(top: 20);
        tester.view.viewInsets = const FakeViewPadding();
        tester.platformDispatcher.textScaleFactorTestValue = 3.5;
        tester.platformDispatcher.platformBrightnessTestValue = brightness;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          tester.view.resetPadding();
          tester.view.resetViewPadding();
          tester.view.resetViewInsets();
          tester.platformDispatcher.clearTextScaleFactorTestValue();
          tester.platformDispatcher.clearPlatformBrightnessTestValue();
        });
        final service = SyntheticJournalAi()..rewrite = '合成文字。' * 180;
        await mount(tester, service);
        await tapVisible(tester, key('entry-quick-note'));
        await write(tester, '我读完了一章');
        await tapVisible(tester, key('journal-ai-request'));
        expect(tester.takeException(), isNull);
        await tapVisible(tester, key('journal-ai-use'));
        expect(draft(tester), service.rewrite);
        await tapVisible(tester, key('journal-ai-undo'));
        expect(draft(tester), '我读完了一章');
        await goBack(tester);
        expect(find.byType(JournalEditorPage), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
