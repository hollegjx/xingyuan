import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/journal/domain/journal_entry.dart';
import 'package:habit_checkin/features/journal/journal_providers.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'journal_diary_capture_test.dart'
    show captureDirectory, captureFont, loadDiaryCaptureFont;
import 'journal_writing_space_test.dart'
    show configure, editable, key, keyboard, openEditor;
import 'support/ui_harness.dart';

const composing = TextEditingValue(
  text: '合成文字\nni\n保留草稿',
  selection: TextSelection.collapsed(offset: 7),
  composing: TextRange(start: 5, end: 7),
);

Rect caretBounds(WidgetTester tester) {
  final render = editable(tester);
  final selection = tester
      .widget<TextField>(key('journal-text'))
      .controller!
      .selection;
  return render
      .getLocalRectForCaret(TextPosition(offset: selection.extentOffset))
      .shift(render.localToGlobal(Offset.zero));
}

void expectCaretVisible(WidgetTester tester) {
  final caret = caretBounds(tester);
  final viewport = tester.getRect(key('journal-editor-scroll'));
  expect(caret.top, greaterThanOrEqualTo(viewport.top - 1));
  expect(caret.bottom, lessThanOrEqualTo(viewport.bottom + 1));
}

Future<Map<String, Object>> rows(UiHarness app) async => {
  for (final table in [
    'diary_entries',
    'diary_photos',
    'quick_notes',
    'quick_note_photos',
  ])
    table:
        (await app.database
                .customSelect('SELECT * FROM $table ORDER BY id')
                .get())
            .map((row) => row.data)
            .toList(),
};

Future<void> snapshot(
  WidgetTester tester,
  GlobalKey boundary,
  String name,
) async {
  if (captureDirectory.isEmpty) return;
  final render =
      boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await render.toImage();
    try {
      expect(image.width, 320);
      expect(image.height, 568);
      final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      await Directory(captureDirectory).create(recursive: true);
      await File('$captureDirectory/$name.png')
          .writeAsBytes(png.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

void main() {
  setUpAll(() async {
    tzdata.initializeTimeZones();
    await loadDiaryCaptureFont();
    if (captureFont.isNotEmpty) {
      final bytes = ByteData.sublistView(await File(captureFont).readAsBytes());
      for (final family in ['CupertinoSystemText', 'CupertinoSystemDisplay']) {
        await (FontLoader(family)..addFont(Future.value(bytes))).load();
      }
    }
  });

  for (final kind in JournalKind.values) {
    for (final startAdaptive in [false, true]) {
      final label =
          '${kind.name}-${startAdaptive ? 'from-content' : 'from-tools'}';
      testUiWidgets('R6 focused breakpoint roundtrip $label', (tester) async {
        final scales = startAdaptive ? [1.7, 1.5, 1.7] : [1.5, 1.7, 1.5];
        configure(
          tester,
          const Size(320, 568),
          scales.first,
          startAdaptive ? Brightness.dark : Brightness.light,
        );
        final boundary = GlobalKey();
        final (app, ai) = await openEditor(tester, boundary, kind);
        keyboard(tester, 200);
        tester.testTextInput.updateEditingValue(composing);
        await tester.pumpAndSettle();
        final store = await app.container.read(
          journalStoreProvider(kind).future,
        );
        var baseline = await rows(app);
        var expected = composing;
        final caretIssues = <String>[];
        final controller = tester
            .widget<TextField>(key('journal-text'))
            .controller!;
        final focus = tester.widget<TextField>(key('journal-text')).focusNode!;
        expect(controller.value, composing);
        expect(focus.hasFocus, isTrue);
        expect(tester.testTextInput.hasAnyClients, isTrue);
        expectCaretVisible(tester);
        await snapshot(tester, boundary, 'r6-delta-$label-before');

        for (var step = 1; step < scales.length; step++) {
          tester.platformDispatcher.textScaleFactorTestValue = scales[step];
          await tester.pumpAndSettle();
          final field = tester.widget<TextField>(key('journal-text'));
          final viewport = tester.getRect(key('journal-editor-scroll'));
          final caret = caretBounds(tester);
          final after = await rows(app);
          final unchanged = equals(baseline).matches(after, {});
          debugPrint(
            'R6_BREAKPOINT ${jsonEncode({
              'case': label,
              'step': step,
              'scale': scales[step],
              'valuePreserved': field.controller!.value == expected,
              'focused': field.focusNode!.hasFocus,
              'inputClient': tester.testTextInput.hasAnyClients,
              'databaseUnchanged': unchanged,
              'aiRequests': ai.calls.length,
              'caret': [caret.top, caret.bottom],
              'viewport': [viewport.top, viewport.bottom],
            })}',
          );
          await snapshot(tester, boundary, 'r6-delta-$label-step$step');
          expect(
            after,
            baseline,
            reason: 'Layout must not write a draft or save.',
          );
          expect(await store.savedOn(app.clock.day), isEmpty);
          expect(ai.calls, isEmpty);
          expect(field.controller, same(controller));
          expect(field.controller!.value, expected);
          expect(key('journal-ai-request'), findsOneWidget);
          expect(
            find.descendant(
              of: key('journal-editor-scroll'),
              matching: key('journal-ai-request'),
            ),
            findsNothing,
          );
          expect(
            field.focusNode!.hasFocus,
            isTrue,
            reason: 'A focused editor must stay focused across the adaptive breakpoint.',
          );
          expect(tester.testTextInput.hasAnyClients, isTrue);
          if (caret.top < viewport.top - 1 ||
              caret.bottom > viewport.bottom + 1) {
            caretIssues.add(
              'step$step scale${scales[step]} caret=$caret viewport=$viewport',
            );
          }
          expect(tester.takeException(), isNull);

          if (!startAdaptive && step == 1) {
            expected = const TextEditingValue(
              text: '合成文字\nnin\n保留草稿',
              selection: TextSelection.collapsed(offset: 8),
              composing: TextRange(start: 5, end: 8),
            );
            tester.testTextInput.updateEditingValue(expected);
            await tester.pumpAndSettle();
            expect(controller.value, expected);
            expect(focus.hasFocus, isTrue);
            expect(tester.testTextInput.hasAnyClients, isTrue);
            expectCaretVisible(tester);
            expect(await store.savedOn(app.clock.day), isEmpty);
            expect(ai.calls, isEmpty);
            baseline = await rows(app);
            debugPrint(
              'R6_BREAKPOINT_CONTINUE $label: input retained; caret visible without refocus or scroll',
            );
            await snapshot(
              tester,
              boundary,
              'r6-delta-$label-continued-at-content',
            );
          }
        }

        // Continue through the existing input connection, without refocusing.
        const continued = TextEditingValue(
          text: '合成文字\n你\n保留草稿',
          selection: TextSelection.collapsed(offset: 6),
        );
        tester.testTextInput.updateEditingValue(continued);
        await tester.pumpAndSettle();
        expect(controller.value, continued);
        expect(focus.hasFocus, isTrue);
        expect(
          (await store.onDay(app.clock.day)).single.entry.draftText,
          continued.text,
        );
        expect(await store.savedOn(app.clock.day), isEmpty);
        expect(ai.calls, isEmpty);
        expect(tester.takeException(), isNull);
        expectCaretVisible(tester);
        await snapshot(tester, boundary, 'r6-delta-$label-continued');
        expect(
          caretIssues,
          isEmpty,
          reason: 'Keep the active caret visible during a focused layout transition, before further input.',
        );
      }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
    }
  }
}
