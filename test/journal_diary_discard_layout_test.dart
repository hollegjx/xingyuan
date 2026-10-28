// Adapted from AI1 72c04c35708bb75811c64cd526f54171de600e0a.
// Original assertions remain; the unavailable snapshot helper is inlined.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'assistant_diary_ui_test.dart' show openDiarySuggestion, tapDiaryControl;
import 'journal_diary_capture_test.dart'
    show capture, captureFont, loadDiaryCaptureFont;
import 'journal_diary_edit_test.dart' show edit;
import 'journal_diary_experience_test.dart' show openEditorPreview;
import 'support/ui_harness.dart';

Future<List<Object?>> snapshot(UiHarness app) async => [
  for (final table in [
    'diary_entries',
    'diary_photos',
    'assistant_diary_proposals',
  ])
    (await app.database.customSelect('SELECT * FROM $table ORDER BY id').get())
        .map((row) => row.data)
        .toList(),
];

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
  for (final chat in [false, true]) {
    for (final brightness in Brightness.values) {
      for (final scale in [3.5, 4.0]) {
        final prefix = chat ? 'chat-diary' : 'journal-ai';
        testUiWidgets(
          'R2 discard actions large $prefix ${brightness.name} $scale',
          (tester) async {
            tester.view.physicalSize = const Size(320, 568);
            tester.view.devicePixelRatio = 1;
            tester.view.padding = const FakeViewPadding(top: 20);
            tester.view.viewPadding = const FakeViewPadding(top: 20);
            // The added 4x case isolates the diary route. Opening the upstream
            // chat composer at 4x has a separate recorded overflow; 3.5x is
            // unchanged from AI1's original failing path.
            tester.platformDispatcher.textScaleFactorTestValue =
                chat && scale == 4.0 ? 3.5 : scale;
            tester.platformDispatcher.platformBrightnessTestValue = brightness;
            addTearDown(() {
              tester.view.resetPhysicalSize();
              tester.view.resetDevicePixelRatio();
              tester.view.resetPadding();
              tester.view.resetViewPadding();
              tester.platformDispatcher.clearTextScaleFactorTestValue();
              tester.platformDispatcher.clearPlatformBrightnessTestValue();
            });
            final boundary = GlobalKey();
            Widget wrap(Widget child) =>
                RepaintBoundary(key: boundary, child: child);
            final UiHarness app;
            final void Function() onlyRequest;
            if (chat) {
              final (h, service) = await openDiarySuggestion(
                tester,
                original: '合成原文',
                preconsented: true,
                wrapApp: wrap,
              );
              app = h;
              onlyRequest = () => expect(service.requests, hasLength(1));
            } else {
              final (h, service) = await openEditorPreview(
                tester,
                original: '合成原文',
                wrapApp: wrap,
              );
              app = h;
              onlyRequest = () => expect(service.calls, hasLength(1));
            }
            tester.platformDispatcher.textScaleFactorTestValue = scale;
            await tester.pumpAndSettle();
            Finder key(String name) => find.byKey(ValueKey(name));
            const text = '合成中文修改\n保留原来的语气。';
            await edit(tester, prefix, text);
            final before = await snapshot(app);
            await tapDiaryControl(
              tester,
              key(chat ? 'chat-diary-cancel' : 'journal-ai-keep'),
            );
            await capture(
              tester,
              boundary,
              '$prefix-discard-${brightness.name}-$scale-reading',
              const Size(320, 568),
              text: find.text('放弃这次修改？'),
              expectedText: '放弃这次修改？',
            );
            final stranded = <String>[];
            for (final action in [('cancel', '继续修改'), ('confirm', '放弃修改')]) {
              final button = key('$prefix-discard-${action.$1}');
              await Scrollable.ensureVisible(
                tester.element(button),
                alignment: .5,
              );
              await tester.pumpAndSettle();
              expect(button.hitTestable(), findsOneWidget);
              expect(tester.getSize(button).height, greaterThanOrEqualTo(44));
              final rich = find.descendant(
                of: button,
                matching: find.byType(RichText),
              );
              final paragraph = tester.renderObject<RenderParagraph>(rich);
              expect(paragraph.text.toPlainText(), action.$2);
              expect(paragraph.textScaler.scale(17), closeTo(17 * scale, .01));
              expect(paragraph.didExceedMaxLines, isFalse);
              var visible = const Rect.fromLTWH(0, 20, 320, 548);
              RenderObject? ancestor = paragraph;
              while (ancestor != null) {
                if (ancestor is RenderAbstractViewport &&
                    ancestor is RenderBox) {
                  final viewport = ancestor as RenderBox;
                  visible = visible.intersect(
                    viewport.localToGlobal(Offset.zero) & viewport.size,
                  );
                }
                ancestor = ancestor.parent;
              }
              final origin = paragraph.localToGlobal(Offset.zero);
              final lines = <double, int>{};
              for (var i = 0; i < action.$2.length; i++) {
                for (final box in paragraph.getBoxesForSelection(
                  TextSelection(baseOffset: i, extentOffset: i + 1),
                )) {
                  final top = box.top.roundToDouble();
                  lines[top] = (lines[top] ?? 0) + 1;
                }
              }
              if (lines.values.any((count) => count == 1)) {
                stranded.add(action.$2);
              }
              for (final box in paragraph.getBoxesForSelection(
                TextSelection(baseOffset: 0, extentOffset: action.$2.length),
              )) {
                final rect = box.toRect().shift(origin);
                expect(visible.inflate(.5).contains(rect.topLeft), isTrue);
                expect(visible.inflate(.5).contains(rect.bottomRight), isTrue);
              }
              await capture(
                tester,
                boundary,
                '$prefix-discard-${brightness.name}-$scale-${action.$1}',
                const Size(320, 568),
                text: button,
                expectedText: action.$2,
              );
            }
            // Both full-width choices stay available together at the scroll end.
            expect(key('$prefix-discard-cancel').hitTestable(), findsOneWidget);
            expect(
              key('$prefix-discard-confirm').hitTestable(),
              findsOneWidget,
            );
            await tapDiaryControl(tester, key('$prefix-discard-cancel'));
            expect(tester.widget<Text>(key('$prefix-suggestion')).data, text);
            expect(await snapshot(app), before);
            onlyRequest();
            expect(tester.takeException(), isNull);
            expect(
              stranded,
              isEmpty,
              reason: 'Do not strand a single action character.',
            );
            await tapDiaryControl(
              tester,
              key(chat ? 'chat-diary-cancel' : 'journal-ai-keep'),
            );
            await tester.binding.handlePopRoute();
            await tester.pumpAndSettle();
            expect(tester.widget<Text>(key('$prefix-suggestion')).data, text);
            expect(await snapshot(app), before);
            await tapDiaryControl(
              tester,
              key(chat ? 'chat-diary-cancel' : 'journal-ai-keep'),
            );
            await tapDiaryControl(tester, key('$prefix-discard-confirm'));
            expect(
              (await snapshot(app)).take(2).toList(),
              before.take(2).toList(),
            );
            if (chat) {
              expect(
                (await app.database
                        .select(app.database.assistantDiaryProposals)
                        .getSingle())
                    .status,
                'cancelled',
              );
            } else {
              expect(key('$prefix-suggestion'), findsNothing);
              expect(
                tester.widget<TextField>(key('journal-text')).controller!.text,
                '合成原文',
              );
            }
            onlyRequest();
            expect(tester.takeException(), isNull);
          },
          variant: TargetPlatformVariant({TargetPlatform.iOS}),
        );
      }
    }
  }
}
