import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/assistant/data/local_proposal_store.dart';
import 'package:habit_checkin/features/assistant/domain/plan_preview.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'assistant_proposal_ui_test.dart' as proposals;
import 'journal_diary_capture_test.dart' as pixels;
import 'support/ui_harness.dart';

void main() {
  setUpAll(() async {
    tzdata.initializeTimeZones();
    await pixels.loadDiaryCaptureFont();
    if (pixels.captureFont.isNotEmpty) {
      final bytes = ByteData.sublistView(
        await File(pixels.captureFont).readAsBytes(),
      );
      for (final family in ['CupertinoSystemText', 'CupertinoSystemDisplay']) {
        await (FontLoader(family)..addFont(Future.value(bytes))).load();
      }
    }
  });
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0, 3.0]) {
      testUiWidgets(
        'C47 delete label and draft isolation ${brightness.name} $scale',
        (tester) async {
          tester.view.physicalSize = const Size(320, 568);
          tester.view.devicePixelRatio = 1;
          tester.view.padding = const FakeViewPadding(top: 20);
          tester.view.viewPadding = const FakeViewPadding(top: 20);
          tester.platformDispatcher.platformBrightnessTestValue = brightness;
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(() {
            tester.view.resetPhysicalSize();
            tester.view.resetDevicePixelRatio();
            tester.view.resetPadding();
            tester.view.resetViewPadding();
            tester.view.resetViewInsets();
            tester.platformDispatcher.clearPlatformBrightnessTestValue();
            tester.platformDispatcher.clearTextScaleFactorTestValue();
          });
          final app = UiHarness();
          final id = await proposals.seed(app);
          final store = LocalProposalStore(app.repository);
          final original = (await store.read(id)).itemsJson;
          final before = PlanPreview.decode(original);
          final boundary = GlobalKey();
          await app.mount(
            tester,
            wrapApp: (child) => RepaintBoundary(key: boundary, child: child),
          );
          await proposals.open(tester, id);
          await tapVisible(
            tester,
            find.byKey(const ValueKey('edit-plan-item-1')),
          );
          await tester.enterText(
            find.byKey(const ValueKey('assistant-plan-title')),
            'TEST unsaved edit',
          );
          await tapVisible(tester, find.text('取消'));
          expect((await store.read(id)).itemsJson, original);
          await tapVisible(
            tester,
            find.byKey(const ValueKey('edit-plan-item-1')),
          );
          tester.view.viewInsets = const FakeViewPadding(bottom: 200);
          await tester.pumpAndSettle();
          final remove = find.byKey(const ValueKey('delete-plan-item-1'));
          await tester.ensureVisible(remove);
          await tester.pumpAndSettle();
          final rect = tester.getRect(remove);
          expect(remove.hitTestable(), findsOneWidget);
          expect(rect.height, greaterThanOrEqualTo(44));
          expect(rect.top, greaterThanOrEqualTo(0));
          expect(rect.bottom, lessThanOrEqualTo(368));
          const label = '从计划中删除';
          final text = find.descendant(of: remove, matching: find.text(label));
          final paragraph = tester.renderObject<RenderParagraph>(
            find.descendant(of: text, matching: find.byType(RichText)),
          );
          expect(paragraph.text.toPlainText(), label);
          expect(paragraph.textScaler.scale(17), closeTo(17 * scale, 0.001));
          if (pixels.captureFont.isNotEmpty) {
            final boxes = paragraph.getBoxesForSelection(
              const TextSelection(baseOffset: 0, extentOffset: label.length),
            );
            expect(boxes, isNotEmpty);
            final offset = paragraph.localToGlobal(Offset.zero);
            for (final box in boxes) {
              final glyph = box.toRect().shift(offset);
              expect(glyph.left, greaterThanOrEqualTo(rect.left));
              expect(glyph.right, lessThanOrEqualTo(rect.right));
              expect(glyph.top, greaterThanOrEqualTo(rect.top));
              expect(glyph.bottom, lessThanOrEqualTo(rect.bottom));
            }
            if (scale == 3) {
              expect(
                boxes.map((box) => box.top).toSet().length,
                greaterThan(1),
              );
            }
            await pixels.capture(
              tester,
              boundary,
              'c47-${brightness.name}-$scale-delete-keyboard',
              const Size(320, 568),
              text: text,
              expectedText: label,
            );
          }
          expect(rect.width, greaterThanOrEqualTo(280));
          await tester.tap(remove);
          await tester.pumpAndSettle();
          tester.view.viewInsets = const FakeViewPadding();
          await tester.pumpAndSettle();
          final draft = PlanPreview.decode((await store.read(id)).itemsJson);
          expect(draft.items, hasLength(before.items.length - 1));
          expect(draft.items.single.task.title, before.items.first.task.title);
          expect(await app.repository.loadGoals(), isEmpty);
          expect(
            await app.database.select(app.database.checkIns).get(),
            isEmpty,
          );
          expect(app.permissions.requests, 0);
          expect(app.notifications.requests, isEmpty);
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      );
    }
  }
}
