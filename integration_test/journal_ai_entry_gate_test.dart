import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/assistant/assistant_providers.dart';
import 'package:habit_checkin/features/assistant/data/assistant_service.dart';
import 'package:habit_checkin/features/journal/ai/journal_ai_providers.dart';
import 'package:habit_checkin/features/journal/domain/journal_entry.dart';
import 'package:habit_checkin/features/journal/journal_providers.dart';
import 'package:habit_checkin/features/journal/presentation/journal_editor_page.dart';
import 'package:integration_test/integration_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import '../test/support/journal_ai_service.dart';
import '../test/support/journal_fixtures.dart';
import '../test/support/layout_capture.dart';
import '../test/support/test_assistant_service.dart';
import '../test/support/ui_harness.dart';

// Native renderer evidence with synthetic data, credentials and AI responses.
// This does not exercise OS text input, VoiceOver audio or a live model.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final capture = LayoutCapture();
  setUpAll(() async {
    tzdata.initializeTimeZones();
    await capture.prepare();
  });
  setUp(binding.testTextInput.register);
  tearDown(binding.testTextInput.unregister);
  Finder key(String value) => find.byKey(ValueKey(value));

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 3.5]) {
      for (final state in [
        'expired',
        'disconnected',
        'not-today',
        'generate',
      ]) {
        testUiWidgets('native AI entry $state ${brightness.name} $scale', (
          tester,
        ) async {
          expect(Platform.isIOS, isTrue);
          expect(binding.testTextInput.isRegistered, isTrue);
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
          final service = SyntheticJournalAi()
            ..configured = state != 'disconnected';
          final h = UiHarness();
          h.clock.setDay(2026, 10, 25);
          await h.mount(
            tester,
            journalAiService: service,
            assistantCredentials: ConversationTestCredentials(),
            journalPhotoFiles: {
              for (final kind in JournalKind.values)
                kind: MemoryJournalPhotoFiles(kind),
            },
            wrapApp: capture.wrap,
          );
          final assistant = await h.container.read(
            assistantStoreProvider.future,
          );
          await assistant.memories.consent();
          if (state == 'expired') {
            final settings = await assistant.memories.settings();
            await h.database
                .into(h.database.assistantSettings)
                .insertOnConflictUpdate(
                  settings.copyWith(
                    consentVersion: assistantConsentVersion - 1,
                  ),
                );
          }
          h.container.invalidate(assistantSettingsProvider);
          if (state == 'generate') {
            final notes = await h.container.read(quickNoteStoreProvider.future);
            await saveJournalNotes(notes, ['Synthetic note: I read one page.']);
          }
          await tester.pumpAndSettle();
          await tapVisible(tester, key('entry-diary'));
          if (state == 'not-today') {
            h.clock.setDay(2026, 10, 26);
            h.container.invalidate(assistantSettingsProvider);
            await tester.pumpAndSettle();
            expect(key('journal-ai-invite'), findsNothing);
          } else {
            expect(key('journal-ai-invite'), findsOneWidget);
          }
          Future<void> shot(String phase) =>
              capture.shot(tester, scale, '${brightness.name}-$state-$phase');
          await shot('entry');
          await tapVisible(
            tester,
            key(
              state == 'generate' ? 'journal-ai-invite' : 'journal-ai-request',
            ),
          );
          if (state == 'expired') {
            expect(find.text('开启 AI 功能'), findsOneWidget);
            expect(h.container.exists(journalAiServiceProvider), isFalse);
            expect(h.container.exists(assistantServiceProvider), isFalse);
            expect(
              (await assistant.memories.settings()).consentVersion,
              assistantConsentVersion - 1,
            );
            await shot('explanation');
            await tapVisible(tester, find.text('取消'));
          } else if (state == 'generate') {
            expect(key('journal-ai-suggestion'), findsOneWidget);
            expect(service.calls, hasLength(1));
            final diaries = await h.container.read(diaryStoreProvider.future);
            expect(await diaries.savedOn(h.clock.day), isEmpty);
            await shot('preview');
            await tapVisible(tester, key('journal-ai-keep'));
            expect(await diaries.savedOn(h.clock.day), isEmpty);
          } else {
            final message = state == 'disconnected'
                ? 'AI 暂时连接不上'
                : 'AI 只能为今天写日记。';
            expect(
              find.descendant(
                of: find.byType(JournalEditorPage),
                matching: find.textContaining(message),
              ),
              findsOneWidget,
            );
            await shot('explanation');
            final notices = find.byType(SnackBar, skipOffstage: false);
            expect(notices, findsOneWidget);
            final notice = tester.getRect(notices);
            expect(notice.top, greaterThanOrEqualTo(20));
            expect(notice.bottom, lessThanOrEqualTo(568));
            expect(find.byType(BackButton).hitTestable(), findsOneWidget);
            final text = find.descendant(
              of: notices,
              matching: find.textContaining(message),
            );
            expect(text, findsOneWidget);
            expect(
              MediaQuery.textScalerOf(tester.element(text)).scale(14),
              14 * scale,
            );
            final scroll = key('journal-notice-scroll');
            final position = tester
                .state<ScrollableState>(
                  find.descendant(
                    of: scroll,
                    matching: find.byType(Scrollable),
                  ),
                )
                .position;
            if (position.maxScrollExtent > 0) {
              await tester.drag(scroll, const Offset(0, -568));
              await tester.pumpAndSettle();
              expect(position.pixels, position.maxScrollExtent);
              await shot('explanation-end');
            }
            await tapVisible(
              tester,
              find.descendant(
                of: notices,
                matching: find.byTooltip(
                  MaterialLocalizations.of(tester.element(text))
                      .closeButtonTooltip,
                ),
              ),
            );
            expect(notices, findsNothing);
            expect(find.byType(BackButton).hitTestable(), findsOneWidget);
          }
          if (state != 'generate') expect(service.calls, isEmpty);
          expect(
            tester.widget<TextField>(key('journal-text')).controller!.text,
            isEmpty,
          );
          expect(tester.takeException(), isNull);
          await capture.passed(tester, scale);
          debugPrint('JOURNAL_AI_ENTRY $state ${brightness.name} scale=$scale');
        });
      }
    }
  }
}
