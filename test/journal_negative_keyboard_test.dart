import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/assistant/assistant_providers.dart';
import 'package:habit_checkin/features/journal/domain/journal_entry.dart';
import 'package:habit_checkin/features/journal/journal_providers.dart';
import 'package:habit_checkin/features/journal/presentation/journal_viewport.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'support/journal_ai_service.dart';
import 'support/journal_fixtures.dart';
import 'support/test_assistant_service.dart';
import 'support/ui_harness.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);
  Finder key(String name) => find.byKey(ValueKey(name));
  const nativeNegativeInset = -14085.679880511618;

  for (final (rawInset, expectedInset) in [
    (nativeNegativeInset / 3, 0.0),
    (0.0, 0.0),
    (345.0, 345.0),
    (double.nan, 0.0),
    (double.infinity, 0.0),
  ]) {
    testWidgets('journal viewport only normalizes bottom metrics $rawInset', (
      tester,
    ) async {
      final source = MediaQueryData(
        size: const Size(414, 896),
        devicePixelRatio: 3,
        viewPadding: const EdgeInsets.fromLTRB(7, 44, 9, 34),
        viewInsets: EdgeInsets.fromLTRB(1, 2, 3, rawInset),
        padding: const EdgeInsets.fromLTRB(7, 44, 9, 4729),
        textScaler: TextScaler.linear(3.5),
      );
      late MediaQueryData actual;
      await tester.pumpWidget(
        MediaQuery(
          data: source,
          child: JournalViewport(
            builder: (context) {
              actual = MediaQuery.of(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(
        actual,
        source.copyWith(
          viewInsets: source.viewInsets.copyWith(bottom: expectedInset),
          padding: source.padding.copyWith(
            bottom: math.max(0, 34 - expectedInset),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });
  }

  for (final kind in JournalKind.values) {
    for (final brightness in Brightness.values) {
      testUiWidgets('${kind.name} tolerates native negative keyboard metrics '
          '${brightness.name}', (tester) async {
        tester.view.devicePixelRatio = 3;
        tester.view.physicalSize = const Size(1242, 2688);
        tester.platformDispatcher.platformBrightnessTestValue = brightness;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          tester.view.resetViewPadding();
          tester.view.resetViewInsets();
          tester.view.resetPadding();
          tester.platformDispatcher.clearPlatformBrightnessTestValue();
        });
        void metrics(double physicalInset) {
          tester.view.viewPadding = const FakeViewPadding(
            top: 132,
            bottom: 102,
          );
          tester.view.viewInsets = FakeViewPadding(bottom: physicalInset);
          tester.view.padding = FakeViewPadding(
            top: 132,
            bottom: math.max(0, 102 - physicalInset),
          );
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
        final assistant = await h.container.read(assistantStoreProvider.future);
        await assistant.memories.consent();
        h.container.invalidate(assistantSettingsProvider);
        await tester.pumpAndSettle();
        if (kind == JournalKind.diary) {
          await tapVisible(tester, key('entry-quick-note'));
          await tester.enterText(key('journal-text'), 'I read a book.');
          await tester.pumpAndSettle();
          await tapVisible(tester, key('save-journal'));
        }
        await tapVisible(
          tester,
          key(
            kind == JournalKind.quickNote ? 'entry-quick-note' : 'entry-diary',
          ),
        );
        final field = key('journal-text');
        const original = 'A quiet day.\nI read a book.';
        await tester.enterText(field, original);
        await tester.pumpAndSettle();
        final store = await h.container.read(journalStoreProvider(kind).future);

        // Physical pixels copied from the native report; not an OS replay.
        for (final inset in [1035.0, nativeNegativeInset, -1.0, 0.0, 1008.0]) {
          metrics(inset);
          await tester.pump(const Duration(milliseconds: 16));
          expect(tester.takeException(), isNull, reason: 'raw inset=$inset');
          expect(tester.view.viewInsets.bottom, inset);
          expect(tester.view.padding.bottom, math.max(0, 102 - inset));
          expect(tester.widget<TextField>(field).controller!.text, original);
          expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
          expect(key('journal-ai-request').hitTestable(), findsOneWidget);
          expect(key('save-journal').hitTestable(), findsOneWidget);
        }
        expect(await store.savedOn(h.clock.day), isEmpty);
        expect(service.calls, isEmpty);

        metrics(0);
        await tester.pumpAndSettle();
        await tapVisible(tester, key('journal-ai-request'));
        expect(key('journal-ai-suggestion'), findsOneWidget);
        metrics(nativeNegativeInset);
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.takeException(), isNull, reason: 'preview transition');
        expect(key('journal-ai-use').hitTestable(), findsOneWidget);
        if (kind == JournalKind.diary) {
          expect(find.text('追加').hitTestable(), findsOneWidget);
          await tapVisible(tester, find.text('追加'));
        }
        await tapVisible(tester, key('journal-ai-use'));
        expect(tester.takeException(), isNull);
        expect(
          tester.widget<TextField>(field).controller!.text,
          kind == JournalKind.quickNote
              ? service.rewrite
              : '$original\n\n${service.diary}',
        );
        expect(await store.savedOn(h.clock.day), isEmpty);

        metrics(0);
        await tester.pumpAndSettle();
        await tapVisible(tester, key('journal-ai-undo'));
        expect(tester.widget<TextField>(field).controller!.text, original);
        await tapVisible(tester, key('save-journal'));
        final saved = await store.savedOn(h.clock.day);
        expect(saved, hasLength(1));
        expect(saved.single.entry.content, original);
        expect(saved.single.entry.revision, 1);
        expect(service.calls, hasLength(1));
        expect(tester.takeException(), isNull);
      }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
    }
  }
}
