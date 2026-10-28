import 'dart:math' as math;

import 'package:flutter/gestures.dart';
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

  for (final (size, top) in [
    (const Size(414, 896), 44.0),
    (const Size(393, 852), 59.0),
  ]) {
    for (final (brightness, stalePadding) in [
      for (final brightness in Brightness.values)
        for (final stalePadding in [false, true]) (brightness, stalePadding),
    ]) {
      testUiWidgets(
        'journal keyboard metric transitions at $size ${brightness.name} '
        'with ${stalePadding ? 'stale' : 'consistent'} bottom padding',
        (tester) async {
          tester.view.devicePixelRatio = 3;
          tester.view.physicalSize = size * 3;
          tester.platformDispatcher.platformBrightnessTestValue = brightness;
          addTearDown(() {
            tester.view.resetPhysicalSize();
            tester.view.resetDevicePixelRatio();
            tester.view.resetViewPadding();
            tester.view.resetViewInsets();
            tester.view.resetPadding();
            tester.platformDispatcher.clearPlatformBrightnessTestValue();
          });

          void metrics(double keyboard, {bool keepBottomPadding = false}) {
            tester.view.viewPadding = FakeViewPadding(
              top: top * 3,
              bottom: 102,
            );
            tester.view.viewInsets = FakeViewPadding(bottom: keyboard * 3);
            tester.view.padding = FakeViewPadding(
              top: top * 3,
              bottom: (keepBottomPadding ? 34 : math.max(0, 34 - keyboard)) * 3,
            );
          }

          Future<void> frames(List<double> heights, String phase) async {
            for (final height in heights) {
              metrics(height, keepBottomPadding: stalePadding);
              await tester.pump(const Duration(milliseconds: 16));
              expect(tester.view.viewInsets.bottom, height * 3);
              expect(
                tester.view.padding.bottom,
                (stalePadding ? 34 : math.max(0, 34 - height)) * 3,
              );
              expect(
                tester.takeException(),
                isNull,
                reason:
                    '$phase at keyboard inset $height '
                    '(stale bottom padding: $stalePadding)',
              );
            }
            metrics(heights.last);
            await tester.pump(const Duration(milliseconds: 16));
            expect(tester.takeException(), isNull, reason: '$phase settled');
          }

          metrics(0);
          final ai = SyntheticJournalAi();
          final h = UiHarness();
          h.clock.setDay(2026, 10, 23);
          await h.mount(
            tester,
            journalAiService: ai,
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
          h.container.invalidate(assistantSettingsProvider);
          await tester.pumpAndSettle();

          for (final kind in JournalKind.values) {
            final original = 'Synthetic ${kind.name}.\nI read one chapter.';
            await tapVisible(
              tester,
              key(
                kind == JournalKind.quickNote
                    ? 'entry-quick-note'
                    : 'entry-diary',
              ),
            );
            final field = key('journal-text');
            await tester.tap(field, kind: PointerDeviceKind.touch);
            await tester.enterText(field, original);
            await frames([0, 17, 34, 80, 170, 260, 336], '${kind.name} open');
            await tester.pumpAndSettle();
            expect(key('journal-ai-request').hitTestable(), findsOneWidget);
            expect(
              tester.getBottomRight(key('journal-ai-request')).dy,
              lessThanOrEqualTo(size.height - 336),
            );

            // Synthetic metrics exercise intermediate frames, not an OS keyboard.
            await tester.tap(key('journal-ai-request'));
            await frames([300, 210, 90, 34, 17, 0], '${kind.name} preview');
            await tester.pumpAndSettle();
            expect(key('journal-ai-suggestion'), findsOneWidget);
            if (kind == JournalKind.diary) {
              await tapVisible(tester, find.text('替换'));
            }
            await tapVisible(tester, key('journal-ai-use'));
            expect(
              tester.widget<TextField>(field).controller!.text,
              kind == JournalKind.quickNote ? ai.rewrite : ai.diary,
            );
            final store = await h.container.read(
              journalStoreProvider(kind).future,
            );
            expect(await store.savedOn(h.clock.day), isEmpty);

            await tester.ensureVisible(field);
            await tester.tap(field, kind: PointerDeviceKind.touch);
            await frames([
              0,
              120,
              336,
              0,
              336,
              0,
              34,
              170,
              336,
            ], '${kind.name} toggle');
            await tester.pumpAndSettle();
            final editable = tester.widget<EditableText>(
              find.descendant(of: field, matching: find.byType(EditableText)),
            );
            expect(editable.focusNode.hasFocus, isTrue);
            await tester.tapAt(
              tester.getTopLeft(field) + const Offset(-6, 24),
              kind: PointerDeviceKind.touch,
            );
            await frames([260, 170, 80, 34, 17, 0], '${kind.name} dismiss');
            await tester.pumpAndSettle();
            expect(editable.focusNode.hasFocus, isFalse);
            await tapVisible(tester, key('journal-ai-undo'));
            expect(tester.widget<TextField>(field).controller!.text, original);
            expect(await store.savedOn(h.clock.day), isEmpty);
            await tapVisible(tester, key('save-journal'));
            expect(
              (await store.savedOn(h.clock.day)).single.entry.content,
              original,
            );
            expect(tester.takeException(), isNull);
          }
          expect(ai.calls, hasLength(2));
        },
        variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      );
    }
  }
}
