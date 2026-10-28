import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'journal_diary_capture_test.dart' show captureFont, loadDiaryCaptureFont;
import 'journal_writing_space_test.dart' show configure, key;
import 'support/ui_harness.dart';

const nameRule = '名称需要 1 至 60 个字符';

void expectCompleteText(WidgetTester tester, Finder finder) {
  final paragraph = tester.renderObject<RenderParagraph>(
    find.descendant(of: finder, matching: find.byType(RichText)),
  );
  final text = paragraph.text.toPlainText();
  expect(paragraph.didExceedMaxLines, isFalse, reason: text);
  for (var i = 0; i < text.length; i++) {
    if (text[i].trim().isEmpty) continue;
    final boxes = paragraph.getBoxesForSelection(
      TextSelection(baseOffset: i, extentOffset: i + 1),
    );
    expect(boxes, isNotEmpty, reason: '$text glyph $i');
    for (final box in boxes) {
      expect(box.left, greaterThanOrEqualTo(-0.1));
      expect(box.right, lessThanOrEqualTo(paragraph.size.width + 0.1));
      expect(box.top, greaterThanOrEqualTo(-0.1));
      expect(box.bottom, lessThanOrEqualTo(paragraph.size.height + 0.1));
    }
  }
}

Future<UiHarness> openGoalForm(
  WidgetTester tester, {
  required bool narrow,
}) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
  configure(
    tester,
    narrow ? const Size(320, 568) : const Size(390, 844),
    narrow ? 4 : 1,
    narrow ? Brightness.dark : Brightness.light,
  );
  final h = UiHarness()..clock.setDay(2026, 10, 27, hour: 17);
  await h.mount(tester);
  await tapVisible(tester, key('entry-new-goal'));
  expect(find.text(nameRule), findsNothing);
  return h;
}

void main() {
  void testForm(String name, Future<void> Function(WidgetTester) body) {
    testUiWidgets(name, (tester) async {
      try {
        await body(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

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

  testForm('R17 narrow name rejection preserves the complete rule', (
    tester,
  ) async {
    final h = await openGoalForm(tester, narrow: true);
    await tapVisible(tester, key('save-goal'));
    await tester.ensureVisible(find.text(nameRule));
    await tester.pumpAndSettle();
    expectCompleteText(tester, find.text(nameRule));
    final p = tester.renderObject<RenderParagraph>(find.text(nameRule));
    expect(p.textScaler.scale(p.text.style!.fontSize!), 52);
    expect(await h.repository.loadGoals(), isEmpty);
  });

  testForm('R17 name correction clears only the stale field error', (
    tester,
  ) async {
    final h = await openGoalForm(tester, narrow: false);
    await tapVisible(tester, key('save-goal'));
    expect(find.text(nameRule), findsOneWidget);
    await tester.enterText(key('goal-title'), '合成整理');
    await tester.pumpAndSettle();
    expect(find.text(nameRule), findsNothing);
    expect(await h.repository.loadGoals(), isEmpty);
  });

  testForm('R17 narrow date selection keeps whole readable numbers', (
    tester,
  ) async {
    final h = await openGoalForm(tester, narrow: true);
    await tapVisible(tester, key('goal-kind'));
    await tapVisible(tester, find.text('单次任务').last);
    await tapVisible(tester, key('planned-day'));
    if (find.byType(DatePickerDialog).evaluate().isNotEmpty) {
      final finder = find.text('28').last;
      expectCompleteText(tester, finder);
      final p = tester.renderObject<RenderParagraph>(finder);
      final first = p
          .getBoxesForSelection(
            const TextSelection(baseOffset: 0, extentOffset: 1),
          )
          .single;
      final second = p
          .getBoxesForSelection(
            const TextSelection(baseOffset: 1, extentOffset: 2),
          )
          .single;
      expect(first.top, second.top, reason: 'A day number is one intact unit');
    } else {
      expect(find.byType(InputDatePickerFormField), findsOneWidget);
      for (final value in ['2026年', '10月', '27日']) {
        final number = value.substring(0, value.length - 1);
        final label = find.text(value).evaluate().isNotEmpty
            ? value
            : '$number\n${value[value.length - 1]}';
        await tester.ensureVisible(find.text(label));
        await tester.pumpAndSettle();
        expectCompleteText(tester, find.text(label));
      }
    }
    expect(await h.repository.loadGoals(), isEmpty);
  });
}
