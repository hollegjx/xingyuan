import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/journal/domain/journal_entry.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'journal_writing_breakpoint_delta_test.dart' show rows;
import 'journal_writing_space_test.dart'
    show configure, key, keyboard, openEditor, writing;
import 'support/ui_harness.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);
  for (final kind in JournalKind.values) {
    testUiWidgets('R6 unfocused breakpoint preserves reading ${kind.name}', (
      tester,
    ) async {
      configure(tester, const Size(320, 568), 1.5, Brightness.dark);
      final (app, ai) = await openEditor(tester, GlobalKey(), kind);
      keyboard(tester, 200);
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(key('journal-text'));
      field.focusNode!.unfocus();
      await tester.pumpAndSettle();
      final scroll = tester.state<ScrollableState>(
        find
            .descendant(
              of: key('journal-editor-scroll'),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      scroll.position.jumpTo(60);
      await tester.pumpAndSettle();
      final baseline = await rows(app);
      final offset = scroll.position.pixels;
      for (final scale in [1.7, 1.5]) {
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        await tester.pumpAndSettle();
        expect(scroll.position.pixels, offset);
        expect(field.focusNode!.hasFocus, isFalse);
        expect(field.controller!.value, writing);
        expect(await rows(app), baseline);
        expect(ai.calls, isEmpty);
        expect(tester.takeException(), isNull);
      }
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
  }
}
