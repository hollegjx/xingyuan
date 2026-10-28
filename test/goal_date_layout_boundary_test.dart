import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'goal_form_recovery_red_test.dart' show expectCompleteText, openGoalForm;
import 'journal_diary_capture_test.dart' show captureFont, loadDiaryCaptureFont;
import 'journal_writing_space_test.dart' show key;
import 'support/ui_harness.dart';

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

  testUiWidgets('R17 measured date layout boundary preserves both paths', (
    tester,
  ) async {
    try {
      final h = await openGoalForm(tester, narrow: false);
      await tapVisible(tester, key('goal-kind'));
      await tapVisible(tester, find.text('单次任务').last);
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      await tester.pumpAndSettle();
      final context = tester.element(key('planned-day'));
      final theme = Theme.of(context);
      final style =
          theme.datePickerTheme.dayStyle ?? theme.textTheme.bodyLarge!;
      final painter = TextPainter(
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      );
      var width = 0.0;
      for (var day = 1; day <= 31; day++) {
        painter.text = TextSpan(text: '$day', style: style);
        painter.layout();
        width = math.max(width, painter.width);
      }
      final threshold = (width + 8) * 7 + 64;
      expect(painter.height, lessThan(40));
      painter.dispose();
      for (final delta in [-1.0, 1.0]) {
        tester.view.physicalSize = Size(math.min(threshold, 344) + delta, 844);
        await tester.pumpAndSettle();
        await tapVisible(tester, key('planned-day'));
        if (delta < 0 || threshold >= 344) {
          expect(find.byType(DatePickerDialog), findsNothing);
          expect(find.byType(InputDatePickerFormField), findsOneWidget);
          await tester.ensureVisible(key('goal-date-candidate'));
          await tester.pumpAndSettle();
          for (final unit in ['2026年', '10月', '27日']) {
            expectCompleteText(tester, find.text(unit));
          }
          await tapVisible(tester, key('goal-date-cancel'));
        } else {
          expect(find.byType(DatePickerDialog), findsOneWidget);
          final day = find.text('28').last;
          expectCompleteText(tester, day);
          final p = tester.renderObject<RenderParagraph>(day);
          expect(
            p
                .getBoxesForSelection(
                  const TextSelection(baseOffset: 0, extentOffset: 2),
                )
                .map((b) => b.top)
                .toSet(),
            hasLength(1),
          );
          await tester.tap(
            find.descendant(
              of: find.byType(DatePickerDialog),
              matching: find.widgetWithText(TextButton, '取消'),
            ),
          );
          await tester.pumpAndSettle();
        }
        expect(find.text('2026年10月27日'), findsOneWidget);
        expect(await h.repository.loadGoals(), isEmpty);
        expect(h.permissions.requests, 0);
        expect(tester.takeException(), isNull);
        debugPrint(
          'R17 boundary: width=${math.min(threshold, 344) + delta}, '
          'threshold=$threshold, dayWidth=$width, input=${delta < 0 || threshold >= 344}',
        );
      }
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
