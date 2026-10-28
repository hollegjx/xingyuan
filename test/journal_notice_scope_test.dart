import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/app/home_page.dart';
import 'package:habit_checkin/features/assistant/assistant_providers.dart';
import 'package:habit_checkin/features/journal/domain/journal_entry.dart';
import 'package:habit_checkin/features/journal/journal_providers.dart';
import 'package:habit_checkin/features/journal/presentation/journal_editor_page.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'support/journal_ai_service.dart';
import 'support/journal_fixtures.dart';
import 'support/test_assistant_service.dart';
import 'support/ui_harness.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);
  Finder key(String value) => find.byKey(ValueKey(value));

  for (final kind in JournalKind.values) {
    for (final brightness in Brightness.values) {
      for (final (scale, keyboard) in [
        for (final scale in [1.0, 3.5])
          for (final keyboard in [0.0, 220.0]) (scale, keyboard),
      ]) {
        testUiWidgets(
          'journal notice stays local ${kind.name} ${brightness.name} $scale keyboard=$keyboard',
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
            final service = SyntheticJournalAi()..configured = false;
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
            );
            final assistant = await h.container.read(
              assistantStoreProvider.future,
            );
            await assistant.memories.consent();
            final consent = await assistant.memories.settings();
            h.container.invalidate(assistantSettingsProvider);
            await tester.pumpAndSettle();
            final homeMessenger = ScaffoldMessenger.of(
              tester.element(find.byType(HomePage)),
            );
            await tapVisible(
              tester,
              key(
                kind == JournalKind.diary ? 'entry-diary' : 'entry-quick-note',
              ),
            );
            const original = '合成草稿';
            await tester.enterText(key('journal-text'), original);
            tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
            await tester.pumpAndSettle();
            await tapVisible(tester, key('journal-ai-request'));
            expect(tester.takeException(), isNull);
            final editor = find.byType(JournalEditorPage);
            expect(
              ScaffoldMessenger.of(tester.element(editor)),
              isNot(same(homeMessenger)),
              reason: 'A journal notice must not be laid out by the home bar.',
            );
            final notices = find.byType(SnackBar, skipOffstage: false);
            expect(notices, findsOneWidget);
            expect(
              find.descendant(of: editor, matching: notices),
              findsOneWidget,
            );
            final notice = tester.getRect(notices);
            final bounds = tester.getRect(
              find.descendant(of: editor, matching: find.byType(Scaffold)),
            );
            expect(notice.top, greaterThanOrEqualTo(bounds.top));
            expect(notice.bottom, lessThanOrEqualTo(bounds.bottom));
            expect(notice.bottom, lessThanOrEqualTo(568 - keyboard));
            final message = find.text('AI 暂时连接不上，可以在「我的 → AI 设置」里检查连接。');
            expect(message, findsOneWidget);
            final closeIcon = find.descendant(
              of: notices,
              matching: find.byIcon(Icons.close),
            );
            expect(closeIcon, findsOneWidget);
            final iconText = tester.widget<RichText>(
              find.descendant(of: closeIcon, matching: find.byType(RichText)),
            );
            final foreground = iconText.text.style!.color!;
            final background = tester
                .widget<Material>(
                  find
                      .descendant(of: notices, matching: find.byType(Material))
                      .first,
                )
                .color!;
            final iconLuminance = foreground.computeLuminance();
            final backgroundLuminance = background.computeLuminance();
            final contrast =
                (math.max(iconLuminance, backgroundLuminance) + .05) /
                (math.min(iconLuminance, backgroundLuminance) + .05);
            expect(
              contrast,
              greaterThanOrEqualTo(3),
              reason: 'A hittable close icon must also be visible.',
            );
            expect(
              foreground,
              DefaultTextStyle.of(tester.element(message)).style.color,
              reason: 'The close icon must share the notice text foreground.',
            );
            expect(
              MediaQuery.textScalerOf(tester.element(message)).scale(14),
              14 * scale,
            );
            // Keep the same notice open while available keyboard space changes.
            for (final inset in [220.0, 0.0, keyboard]) {
              tester.view.viewInsets = FakeViewPadding(bottom: inset);
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull);
              expect(notices, findsOneWidget);
              final currentBounds = tester.getRect(
                find.descendant(of: editor, matching: find.byType(Scaffold)),
              );
              final currentNotice = tester.getRect(notices);
              expect(
                currentNotice.top,
                greaterThanOrEqualTo(currentBounds.top),
              );
              expect(currentNotice.bottom, lessThanOrEqualTo(568 - inset));
              expect(find.byType(BackButton).hitTestable(), findsOneWidget);
            }
            expect(service.calls, isEmpty);
            expect(
              tester.widget<TextField>(key('journal-text')).controller!.text,
              original,
            );
            final store = await h.container.read(
              journalStoreProvider(kind).future,
            );
            expect(await store.savedOn(h.clock.day), isEmpty);
            expect(await assistant.memories.settings(), consent);
            expect(find.byType(BackButton).hitTestable(), findsOneWidget);
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
            }
            await tapVisible(
              tester,
              find.descendant(
                of: notices,
                matching: find.byTooltip(
                  MaterialLocalizations.of(tester.element(message))
                      .closeButtonTooltip,
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(find.byType(SnackBar), findsNothing);
            expect(find.byType(BackButton).hitTestable(), findsOneWidget);
            await tapVisible(tester, key('journal-ai-request'));
            expect(notices, findsOneWidget);
            // Exercise route exit while the notice is still active.
            await tester.binding.handlePopRoute();
            await tester.pumpAndSettle();
            expect(editor, findsNothing);
            expect(find.byType(SnackBar), findsNothing);
            expect(await store.savedOn(h.clock.day), isEmpty);
            tester.view.viewInsets = const FakeViewPadding();
            homeMessenger.showSnackBar(const SnackBar(content: Text('Home')));
            await tester.pumpAndSettle();
            expect(find.text('Home'), findsOneWidget);
            homeMessenger.hideCurrentSnackBar();
            await tester.pumpAndSettle();
            expect(service.calls, isEmpty);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }
}
