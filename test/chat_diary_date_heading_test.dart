import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/features/journal/presentation/diary_preview_body.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'assistant_diary_entry_layout_test.dart' show viewport;
import 'assistant_diary_ui_test.dart' show tapDiaryControl;
import 'chat_diary_initial_read_guard_test.dart' show ReadFixture;
import 'chat_diary_initial_read_recovery_test.dart' show readState;
import 'chat_diary_recovery_journey_test.dart'
    show control, correction, expectCorrection, frame;
import 'chat_diary_refresh_original_test.dart' show RefreshFixture;
import 'journal_diary_capture_test.dart' show captureFont, loadDiaryCaptureFont;
import 'support/ui_harness.dart';

Finder get dateTile => control('chat-diary-date');
Finder get heading => find.descendant(
  of: dateTile,
  matching: find.byWidgetPredicate(
    (widget) =>
        widget is Text && (widget.data == '日期' || widget.data == '日记日期'),
  ),
);

Future<void> expectDateAction(WidgetTester tester, String value) async {
  final semantics = tester.ensureSemantics();
  try {
    await Scrollable.ensureVisible(tester.element(dateTile), alignment: 0);
    await tester.pumpAndSettle();
    final node = tester.getSemantics(dateTile);
    expect(node.label, '日记日期\n$value');
    expect(node.getSemanticsData().hasAction(ui.SemanticsAction.tap), isTrue);
    var tapCount = 0;
    void countActions(SemanticsNode current) {
      if (current.getSemanticsData().hasAction(ui.SemanticsAction.tap)) {
        tapCount++;
      }
      current.visitChildren((child) {
        countActions(child);
        return true;
      });
    }

    countActions(node);
    expect(tapCount, 1);
    expect(tester.getSize(dateTile).width, greaterThanOrEqualTo(44));
    expect(tester.getSize(dateTile).height, greaterThanOrEqualTo(44));
    expect(dateTile.hitTestable(), findsOneWidget);
    expect(
      find.descendant(
        of: dateTile,
        matching: find.byIcon(CupertinoIcons.calendar),
      ),
      findsOneWidget,
    );
  } finally {
    semantics.dispose();
  }
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

  for (final large in [false, true]) {
    for (final theme in Brightness.values) {
      final size = large ? const Size(320, 568) : const Size(390, 844);
      final scale = large ? 4.0 : 1.0;
      final name = '${large ? '320-4x' : '390-1x'}-${theme.name}';
      testUiWidgets('R10 date heading stays on one line $name', (tester) async {
        viewport(tester, size, scale, theme);
        final app = RefreshFixture();
        await app.openEdited(tester);
        final before = await readState(app.db);
        final label = tester.widget<Text>(heading).data!;
        await frame(tester, app.boundary, 'r10-$name-date', size, label);
        final paragraph = tester.renderObject<RenderParagraph>(
          find.descendant(of: heading, matching: find.byType(RichText)),
        );
        final boxes = paragraph.getBoxesForSelection(
          TextSelection(baseOffset: 0, extentOffset: label.length),
        );
        expect(boxes, isNotEmpty);
        debugPrint(
          'R10 $name label=$label width=${paragraph.size.width} '
          'height=${paragraph.size.height} tops=${boxes.map((b) => b.top).toList()}',
        );
        expect(
          boxes.every((box) => (box.top - boxes.first.top).abs() < .01),
          isTrue,
          reason:
              'The visible date heading must not leave an orphan character.',
        );
        expect(paragraph.textScaler.scale(17), 17 * scale);
        expect(paragraph.didExceedMaxLines, isFalse);
        expect(label, '日期');
        expect(tester.widget<Text>(heading).maxLines, isNull);
        await expectDateAction(tester, app.clock.day.key);
        final date = find.descendant(
          of: dateTile,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Text && widget.semanticsLabel == app.clock.day.key,
          ),
        );
        expect(date, findsOneWidget);
        expect(
          tester.widget<Text>(date).data!.replaceAll('\n', '-'),
          app.clock.day.key,
        );
        expectCorrection(tester);
        await app.expectUnchanged(expected: before);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testUiWidgets('R10 date cancel and historical selection retain exact edits', (
    tester,
  ) async {
    viewport(tester, const Size(390, 844), 1, Brightness.light);
    final app = RefreshFixture();
    await app.openEdited(tester);
    final day = app.clock.day.addDays(-1);
    const original = '合成昨日正文，选择日期不得覆盖。';
    await app.saveText(original, day: day);
    final before = await readState(app.db);
    await expectDateAction(tester, app.clock.day.key);
    await tapDiaryControl(tester, dateTile);
    await tapVisible(tester, find.text('取消'));
    await expectDateAction(tester, app.clock.day.key);
    expectCorrection(tester);
    expect(
      tester.widget<FilledButton>(control('chat-diary-save')).onPressed,
      isNotNull,
    );
    await app.expectUnchanged(expected: before);

    await tapDiaryControl(tester, dateTile);
    await tapVisible(tester, find.text('${day.day}'));
    await tapVisible(tester, find.text('确定'));
    await expectDateAction(tester, day.key);
    expectCorrection(tester);
    expect(
      tester.widget<DiaryPreviewBody>(find.byType(DiaryPreviewBody)).original,
      original,
    );
    expect(
      tester.widget<FilledButton>(control('chat-diary-save')).onPressed,
      isNull,
    );
    await app.expectUnchanged(expected: before);
    await tapDiaryControl(tester, find.text('追加'));
    expect(
      tester.widget<Text>(control('chat-diary-suggestion')).data,
      '$original\n\n${correction.text}',
    );
    await tapDiaryControl(tester, control('chat-diary-save'));
    expect(find.text(day.key), findsWidgets);
    await tapVisible(tester, find.text('取消'));
    expectCorrection(tester);
    await app.expectUnchanged(expected: before);
    expect(tester.takeException(), isNull);
  });

  testUiWidgets('R10 unknown date stays unknown until explicit selection', (
    tester,
  ) async {
    viewport(tester, const Size(320, 568), 4, Brightness.dark);
    final app = ReadFixture();
    await app.mount(tester);
    await app.db
        .update(app.db.assistantDiaryProposals)
        .write(
          const AssistantDiaryProposalsCompanion(suggestedDay: Value(null)),
        );
    final before = await readState(app.db);
    await tapDiaryControl(tester, find.text('预览日记建议'));
    await tapDiaryControl(tester, control('chat-diary-edit'));
    await tester.showKeyboard(control('chat-diary-edited-text'));
    tester.testTextInput.updateEditingValue(correction);
    await tester.pumpAndSettle();
    await tapDiaryControl(tester, control('chat-diary-edit'));
    await expectDateAction(tester, '尚未选择');
    expect(control('chat-diary-suggested-date'), findsNothing);
    expect(
      tester.widget<FilledButton>(control('chat-diary-save')).onPressed,
      isNull,
    );
    await frame(
      tester,
      app.boundary,
      'r10-320-4x-dark-unknown',
      const Size(320, 568),
      '日期',
    );
    await tapDiaryControl(tester, dateTile);
    await tapVisible(tester, find.text('取消'));
    await expectDateAction(tester, '尚未选择');
    expectCorrection(tester);
    expect(
      tester.widget<FilledButton>(control('chat-diary-save')).onPressed,
      isNull,
    );
    await app.expectUnchanged(expected: before);

    final day = app.clock.day.addDays(-1);
    await tapDiaryControl(tester, dateTile);
    await tapVisible(tester, find.text('${day.day}'));
    await tapVisible(tester, find.text('确定'));
    await expectDateAction(tester, day.key);
    expectCorrection(tester);
    expect(
      tester.widget<FilledButton>(control('chat-diary-save')).onPressed,
      isNotNull,
    );
    expect(
      tester.widget<DiaryPreviewBody>(find.byType(DiaryPreviewBody)).original,
      isEmpty,
    );
    await app.expectUnchanged(expected: before);
    expect(tester.takeException(), isNull);
  });
}
