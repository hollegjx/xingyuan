import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'assistant_diary_ui_test.dart' show openDiarySuggestion, tapDiaryControl;
import 'journal_diary_experience_test.dart' show openEditorPreview;
import 'support/diary_capture_pixels.dart';
import 'support/ui_harness.dart';

// Optional export of actual widgets with synthetic data. Not native iOS proof.
const captureDirectory = String.fromEnvironment('DIARY_CAPTURE_DIR');
const captureFont = String.fromEnvironment('DIARY_CAPTURE_FONT');
const draft =
    '今天读完了一章，有一段还没读懂，想再读一遍。\n\n'
    '下班买了面包。没什么特别的，就想把这些小事记下来。';
const original = '早上醒得比平时早，慢慢吃了早餐。';

Future<void> capture(
  WidgetTester tester,
  GlobalKey boundaryKey,
  String name,
  Size size, {
  required Finder text,
  required String expectedText,
  bool firstLineOnly = false,
  bool editable = false,
}) async {
  expect(tester.takeException(), isNull);
  final boundary =
      boundaryKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  expect(boundary.debugNeedsPaint, isFalse);
  final RenderBox textRender;
  final List<ui.TextBox> boxes;
  final selection = TextSelection(
    baseOffset: 0,
    extentOffset: expectedText.length,
  );
  if (editable) {
    final input = find.descendant(
      of: text,
      matching: find.byType(EditableText),
    );
    expect(input, findsOneWidget);
    final render = tester.state<EditableTextState>(input).renderEditable;
    expect(render.text!.toPlainText(), expectedText);
    textRender = render;
    boxes = render.getBoxesForSelection(selection);
  } else {
    final richText = find.descendant(of: text, matching: find.byType(RichText));
    expect(richText, findsOneWidget);
    final paragraph = tester.renderObject<RenderParagraph>(richText);
    expect(paragraph.text.toPlainText(), expectedText);
    textRender = paragraph;
    boxes = paragraph.getBoxesForSelection(selection);
  }
  expect(boxes, isNotEmpty);
  final offset = textRender.localToGlobal(Offset.zero, ancestor: boundary);
  final regions = [
    for (final box in boxes)
      if (!firstLineOnly || (box.top - boxes.first.top).abs() < .01)
        box.toRect().shift(offset).inflate(1),
  ];
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    try {
      expect(image.width, size.width.toInt());
      expect(image.height, size.height.toInt());
      verifyDiaryCapturePixels(
        (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!,
        width: image.width,
        height: image.height,
        textRegions: regions,
      );
      if (captureDirectory.isNotEmpty) {
        final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        await Directory(captureDirectory).create(recursive: true);
        await File('$captureDirectory/$name.png')
            .writeAsBytes(png.buffer.asUint8List());
      }
    } finally {
      image.dispose();
    }
  });
}

Future<void> loadDiaryCaptureFont() async {
  if (captureFont.isNotEmpty) {
    for (final font in {
      'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
      'packages/cupertino_icons/CupertinoIcons':
          'packages/cupertino_icons/assets/CupertinoIcons.ttf',
    }.entries) {
      await (FontLoader(font.key)..addFont(rootBundle.load(font.value))).load();
    }
    final bytes = ByteData.sublistView(await File(captureFont).readAsBytes());
    // Test-process aliases only; no font bundled or production theme change.
    for (final family in [
      'Roboto',
      '.SF UI Text',
      '.SF UI Display',
      '.SF Pro Text',
      '.SF Pro Display',
    ]) {
      await (FontLoader(family)..addFont(Future.value(bytes))).load();
    }
  }
}

void main() {
  setUpAll(() async {
    tzdata.initializeTimeZones();
    await loadDiaryCaptureFont();
  });
  for (final brightness in Brightness.values) {
    for (final largeText in [false, true]) {
      for (final chat in [false, true]) {
        final label =
            '${chat ? 'chat' : 'editor'}-${brightness.name}-'
            '${largeText ? 'small-large-text' : 'standard'}';
        testUiWidgets('diary reading and actions render $label', (
          tester,
        ) async {
          final size = largeText ? const Size(320, 568) : const Size(390, 844);
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          tester.view.padding = const FakeViewPadding(top: 20);
          tester.view.viewPadding = const FakeViewPadding(top: 20);
          tester.view.viewInsets = const FakeViewPadding();
          tester.platformDispatcher.platformBrightnessTestValue = brightness;
          tester.platformDispatcher.textScaleFactorTestValue = largeText
              ? 3.5
              : 1;
          addTearDown(() {
            tester.view.resetPhysicalSize();
            tester.view.resetDevicePixelRatio();
            tester.view.resetPadding();
            tester.view.resetViewPadding();
            tester.view.resetViewInsets();
            tester.platformDispatcher.clearPlatformBrightnessTestValue();
            tester.platformDispatcher.clearTextScaleFactorTestValue();
          });
          final boundary = GlobalKey();
          Widget wrap(Widget child) =>
              RepaintBoundary(key: boundary, child: child);
          if (chat) {
            await openDiarySuggestion(
              tester,
              original: original,
              content: draft,
              preconsented: true,
              wrapApp: wrap,
            );
            await tapDiaryControl(
              tester,
              find.byKey(const ValueKey('chat-diary-suggested-date')),
            );
            Scrollable.of(
              tester.element(find.byKey(const ValueKey('chat-diary-date'))),
            ).position.jumpTo(0);
            await tester.pumpAndSettle();
          } else {
            await openEditorPreview(
              tester,
              original: original,
              suggestion: draft,
              wrapApp: wrap,
            );
          }
          final suggestion = find.byKey(
            ValueKey(chat ? 'chat-diary-suggestion' : 'journal-ai-suggestion'),
          );
          await capture(
            tester,
            boundary,
            '$label-reading',
            size,
            text: suggestion,
            expectedText: draft,
            firstLineOnly: true,
          );
          await tapDiaryControl(tester, find.text('追加'));
          expect(tester.widget<Text>(suggestion).data, '$original\n\n$draft');
          final action = find.byKey(
            ValueKey(chat ? 'chat-diary-save' : 'journal-ai-use'),
          );
          await Scrollable.ensureVisible(
            tester.element(action),
            alignment: 0.5,
          );
          await tester.pumpAndSettle();
          expect(action.hitTestable(), findsOneWidget);
          expect(tester.widget<FilledButton>(action).onPressed, isNotNull);
          if (largeText) {
            final paragraph = tester.renderObject<RenderParagraph>(
              find.descendant(of: action, matching: find.byType(RichText)),
            );
            final boxes = paragraph.getBoxesForSelection(
              TextSelection(
                baseOffset: 0,
                extentOffset: paragraph.text.toPlainText().length,
              ),
            );
            expect(paragraph.textScaler.scale(17), 17 * 3.5);
            expect(boxes, isNotEmpty);
            for (final box in boxes) {
              expect(
                box.top,
                closeTo(boxes.first.top, 0.01),
                reason: 'Save label must stay on one line without shrinking',
              );
            }
          }
          await capture(
            tester,
            boundary,
            '$label-actions',
            size,
            text: action,
            expectedText: chat ? '保存日记' : '放入草稿',
          );
          final prefix = chat ? 'chat-diary' : 'journal-ai';
          final edit = find.byKey(ValueKey('$prefix-edit'));
          await tapDiaryControl(tester, edit);
          final field = find.byKey(ValueKey('$prefix-edited-text'));
          const corrected = '我只想保留这一句。';
          await tester.enterText(field, corrected);
          FocusManager.instance.primaryFocus?.unfocus();
          await tester.pumpAndSettle();
          await Scrollable.ensureVisible(tester.element(field), alignment: 0);
          await tester.pumpAndSettle();
          await capture(
            tester,
            boundary,
            '$label-editing',
            size,
            text: field,
            expectedText: corrected,
            editable: true,
            firstLineOnly: true,
          );
          await tapDiaryControl(tester, edit);
          await Scrollable.ensureVisible(
            tester.element(suggestion),
            alignment: 0,
          );
          await tester.pumpAndSettle();
          await capture(
            tester,
            boundary,
            '$label-corrected',
            size,
            text: suggestion,
            expectedText: '$original\n\n$corrected',
            firstLineOnly: true,
          );
        });
      }
    }
  }
}
