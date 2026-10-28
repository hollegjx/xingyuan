import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'assistant_diary_ui_test.dart' show openDiarySuggestion, tapDiaryControl;
import 'journal_diary_capture_test.dart' show loadDiaryCaptureFont;
import 'journal_diary_experience_test.dart' show openEditorPreview;
import 'support/ui_harness.dart';

Finder control(String name) => find.byKey(ValueKey(name));

void expectUnbroken(
  WidgetTester tester,
  Finder richText,
  String word, {
  required Rect visible,
  required double scale,
  bool requireWidthSlack = false,
}) {
  final paragraph = tester.renderObject<RenderParagraph>(richText);
  final text = paragraph.text.toPlainText();
  final start = text.indexOf(word);
  expect(start, greaterThanOrEqualTo(0), reason: text);
  final boxes = paragraph.getBoxesForSelection(
    TextSelection(baseOffset: start, extentOffset: start + word.length),
  );
  expect(paragraph.textScaler.scale(17), 17 * scale);
  expect(paragraph.didExceedMaxLines, isFalse);
  expect(boxes, isNotEmpty);
  if (requireWidthSlack) {
    final intrinsic = paragraph.getMaxIntrinsicWidth(double.infinity);
    expect(
      paragraph.constraints.maxWidth,
      greaterThanOrEqualTo(intrinsic.ceilToDouble() + 1),
      reason: '$word needs room beyond fractional font metrics: $intrinsic',
    );
  }
  for (final box in boxes) {
    expect(
      box.top,
      closeTo(boxes.first.top, .01),
      reason: '$word split in $text',
    );
    final rect = box.toRect().shift(paragraph.localToGlobal(Offset.zero));
    expect(rect.left, greaterThanOrEqualTo(visible.left - .01));
    expect(rect.right, lessThanOrEqualTo(visible.right + .01));
    expect(rect.top, greaterThanOrEqualTo(visible.top - .01));
    expect(rect.bottom, lessThanOrEqualTo(visible.bottom + .01));
  }
}

Future<void> expectDate(WidgetTester tester, Finder scope, double scale) async {
  final date = find
      .descendant(of: scope, matching: find.byType(RichText))
      .evaluate()
      .where((element) {
        final text = (element.widget as RichText).text.toPlainText();
        return text.contains('2026') && text.contains('09');
      })
      .single;
  final finder = find.byElementPredicate((element) => element == date);
  await Scrollable.ensureVisible(date, alignment: .5);
  await tester.pumpAndSettle();
  final paragraph = tester.renderObject<RenderParagraph>(finder);
  final viewport = RenderAbstractViewport.of(paragraph);
  for (final group in ['2026', '10', '09']) {
    final start = paragraph.text.toPlainText().indexOf(group);
    final boxes = paragraph.getBoxesForSelection(
      TextSelection(baseOffset: start, extentOffset: start + group.length),
    );
    final region = boxes
        .map((box) => box.toRect())
        .reduce((a, b) => a.expandToInclude(b));
    final position = Scrollable.of(date).position;
    position.jumpTo(
      viewport
          .getOffsetToReveal(paragraph, .5, rect: region)
          .offset
          .clamp(position.minScrollExtent, position.maxScrollExtent),
    );
    await tester.pumpAndSettle();
    final viewportBox = viewport as RenderBox;
    final visible = viewportBox.localToGlobal(Offset.zero) & viewportBox.size;
    expectUnbroken(tester, finder, group, visible: visible, scale: scale);
  }
}

void main() {
  setUpAll(() async {
    tzdata.initializeTimeZones();
    await loadDiaryCaptureFont();
  });
  for (final brightness in Brightness.values) {
    for (final scale in [3.5, 4.0]) {
      void viewport(WidgetTester tester) {
        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1;
        tester.view.padding = const FakeViewPadding(top: 20);
        tester.view.viewPadding = const FakeViewPadding(top: 20);
        tester.view.viewInsets = const FakeViewPadding();
        tester.platformDispatcher.textScaleFactorTestValue = 3.5;
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
      }

      testUiWidgets(
        'date groups remain intact in preview confirmation receipt ${brightness.name} $scale',
        (tester) async {
          viewport(tester);
          await openDiarySuggestion(tester, preconsented: true);
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          await tester.pumpAndSettle();
          await expectDate(tester, control('chat-diary-suggested-date'), scale);
          await tapDiaryControl(tester, control('chat-diary-suggested-date'));
          await expectDate(tester, control('chat-diary-date'), scale);
          await tapDiaryControl(tester, control('chat-diary-save'));
          await expectDate(
            tester,
            find
                .byWidgetPredicate(
                  (widget) =>
                      widget is AlertDialog ||
                      widget is CupertinoAlertDialog ||
                      widget is BottomSheet,
                )
                .last,
            scale,
          );
          await tapDiaryControl(tester, control('chat-diary-confirm-save'));
          await expectDate(tester, control('chat-diary-receipt'), scale);
          expect(tester.takeException(), isNull);
        },
      );

      for (final chat in [false, true]) {
        testUiWidgets(
          'original disclosure labels stay unbroken ${chat ? 'chat' : 'editor'} ${brightness.name} $scale',
          (tester) async {
            viewport(tester);
            final prefix = chat ? 'chat-diary' : 'journal-ai';
            if (chat) {
              await openDiarySuggestion(
                tester,
                original: '原有日记',
                preconsented: true,
              );
              await tapDiaryControl(
                tester,
                control('chat-diary-suggested-date'),
              );
            } else {
              await openEditorPreview(tester, original: '原有日记');
            }
            tester.platformDispatcher.textScaleFactorTestValue = scale;
            await tester.pumpAndSettle();
            final toggle = control('$prefix-original-toggle');
            for (final label in ['查看原文', '收起原文']) {
              await Scrollable.ensureVisible(
                tester.element(toggle),
                alignment: .5,
              );
              await tester.pumpAndSettle();
              expect(toggle.hitTestable(), findsOneWidget);
              expect(tester.getSize(toggle).height, greaterThanOrEqualTo(44));
              expectUnbroken(
                tester,
                find.descendant(
                  of: find.descendant(of: toggle, matching: find.text(label)),
                  matching: find.byType(RichText),
                ),
                label,
                visible: tester
                    .getRect(toggle)
                    .intersect(const Rect.fromLTWH(0, 20, 320, 548)),
                scale: scale,
              );
              await tapDiaryControl(tester, toggle);
            }
            for (final action
                in chat
                    ? [
                        ('chat-diary-save', '保存日记'),
                        ('chat-diary-cancel', '取消建议'),
                      ]
                    : [
                        ('journal-ai-use', '放入草稿'),
                        ('journal-ai-keep', '暂不使用'),
                      ]) {
              final button = control(action.$1);
              await Scrollable.ensureVisible(
                tester.element(button),
                alignment: .5,
              );
              await tester.pumpAndSettle();
              expect(button.hitTestable(), findsOneWidget);
              expect(tester.getSize(button).height, greaterThanOrEqualTo(44));
              expectUnbroken(
                tester,
                find.descendant(of: button, matching: find.byType(RichText)),
                action.$2,
                requireWidthSlack: true,
                visible: tester
                    .getRect(button)
                    .intersect(const Rect.fromLTWH(0, 20, 320, 548)),
                scale: scale,
              );
            }
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }
}
