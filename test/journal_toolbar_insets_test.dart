import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/assistant/assistant_providers.dart';
import 'package:habit_checkin/features/journal/domain/journal_entry.dart';
import 'package:habit_checkin/features/journal/journal_providers.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'support/journal_ai_service.dart';
import 'support/journal_fixtures.dart';
import 'support/test_assistant_service.dart';
import 'support/ui_harness.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);
  Finder key(String name) => find.byKey(ValueKey(name));

  for (final kind in JournalKind.values) {
    for (final (brightness, cramped) in [
      for (final brightness in Brightness.values)
        for (final cramped in [false, true]) (brightness, cramped),
    ]) {
      testUiWidgets(
        '${kind.name} toolbar ${cramped ? 'exhausted height' : 'stale gap'} '
        '${brightness.name} preserves editing',
        (tester) async {
          tester.view.devicePixelRatio = 3;
          tester.view.physicalSize = const Size(414, 896) * 3;
          tester.platformDispatcher.platformBrightnessTestValue = brightness;
          addTearDown(() {
            tester.view.resetPhysicalSize();
            tester.view.resetDevicePixelRatio();
            tester.view.resetViewPadding();
            tester.view.resetViewInsets();
            tester.view.resetPadding();
            tester.platformDispatcher.clearPlatformBrightnessTestValue();
          });
          void metrics(double keyboard) {
            tester.view.viewPadding = const FakeViewPadding(
              top: 132,
              bottom: 102,
            );
            tester.view.padding = const FakeViewPadding(top: 132, bottom: 102);
            tester.view.viewInsets = FakeViewPadding(bottom: keyboard * 3);
          }

          metrics(0);
          final h = UiHarness();
          h.clock.setDay(2026, 10, 23);
          final service = SyntheticJournalAi();
          await h.mount(
            tester,
            journalAiService: service,
            assistantCredentials: ConversationTestCredentials(),
            journalPhotoFiles: {
              for (final entryKind in JournalKind.values)
                entryKind: MemoryJournalPhotoFiles(entryKind),
            },
          );
          final assistant = await h.container.read(
            assistantStoreProvider.future,
          );
          await assistant.memories.consent();
          h.container.invalidate(assistantSettingsProvider);
          await tester.pumpAndSettle();
          await tapVisible(
            tester,
            key(
              kind == JournalKind.quickNote
                  ? 'entry-quick-note'
                  : 'entry-diary',
            ),
          );
          final field = key('journal-text');
          const original = 'Synthetic keyboard transition. I read a book.';
          await tester.enterText(field, original);
          await tester.pumpAndSettle();
          final store = await h.container.read(
            journalStoreProvider(kind).future,
          );

          double toolbarGap() {
            final action = key('journal-ai-request');
            final row = find
                .ancestor(of: action, matching: find.byType(Wrap))
                .first;
            final body = find
                .ancestor(of: action, matching: find.byType(Column))
                .first;
            return tester.getBottomLeft(body).dy - tester.getBottomLeft(row).dy;
          }

          const actions = [
            'journal-add-photo',
            'journal-take-photo',
            'journal-ai-request',
            'delete-journal',
          ];
          if (cramped) {
            // Synthetic stress bounds, not measured iOS keyboard heights.
            for (final height in [780.0, 810.0, 740.0, 700.0]) {
              metrics(height);
              await tester.pump(const Duration(milliseconds: 16));
              expect(tester.takeException(), isNull, reason: 'inset=$height');
              for (final action in actions) {
                expect(key(action), findsNothing);
              }
              expect(
                tester.widget<TextField>(field).controller!.text,
                original,
              );
              expect(
                tester.widget<TextField>(field).focusNode!.hasFocus,
                isTrue,
              );
            }
          } else {
            metrics(336);
            await tester.pump(const Duration(milliseconds: 16));
            expect(tester.takeException(), isNull);
            expect(toolbarGap(), closeTo(2, .001));
          }

          metrics(336);
          await tester.pumpAndSettle();
          for (final action in actions) {
            expect(key(action).hitTestable(), findsOneWidget);
          }
          expect(toolbarGap(), closeTo(2, .001));
          expect(tester.widget<TextField>(field).controller!.text, original);
          expect(await store.savedOn(h.clock.day), isEmpty);
          expect(service.calls, isEmpty);

          tester.widget<TextField>(field).focusNode!.unfocus();
          metrics(0);
          await tester.pumpAndSettle();
          for (final action in actions) {
            expect(key(action).hitTestable(), findsOneWidget);
          }
          expect(toolbarGap(), closeTo(36, .001));
          expect(tester.widget<TextField>(field).controller!.text, original);
          expect(await store.savedOn(h.clock.day), isEmpty);
          await tapVisible(tester, key('save-journal'));
          final saved = await store.savedOn(h.clock.day);
          expect(saved, hasLength(1));
          expect(saved.single.entry.content, original);
          expect(saved.single.entry.revision, 1);
          expect(service.calls, isEmpty);
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      );
    }
  }
}
