import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/assistant/assistant_providers.dart';
import 'package:habit_checkin/features/journal/domain/journal_entry.dart';
import 'package:habit_checkin/features/journal/journal_providers.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'support/journal_ai_service.dart';
import 'support/journal_fixtures.dart';
import 'support/test_assistant_service.dart';
import 'support/ui_harness.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);
  Finder key(String name) => find.byKey(ValueKey(name));
  const original = '我读完了一章';

  Future<UiHarness> openPreview(
    WidgetTester tester,
    SyntheticJournalAi service,
    JournalKind kind,
    Brightness brightness,
    double scale,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 20);
    tester.view.viewPadding = const FakeViewPadding(top: 20);
    tester.view.viewInsets = const FakeViewPadding();
    tester.platformDispatcher.textScaleFactorTestValue = scale;
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
    final h = UiHarness();
    h.clock.setDay(2026, 10, 24);
    await h.mount(
      tester,
      journalAiService: service,
      assistantCredentials: ConversationTestCredentials(),
      journalPhotoFiles: {
        for (final kind in JournalKind.values)
          kind: MemoryJournalPhotoFiles(kind),
      },
    );
    final settings = await h.container.read(assistantStoreProvider.future);
    await settings.memories.consent();
    h.container.invalidate(assistantSettingsProvider);
    await tester.pumpAndSettle();
    await tapVisible(tester, key('entry-quick-note'));
    await tester.enterText(key('journal-text'), original);
    await tester.pumpAndSettle();
    if (kind == JournalKind.diary) {
      await tapVisible(tester, key('save-journal'));
      await tapVisible(tester, key('entry-diary'));
      await tester.enterText(key('journal-text'), original);
      await tester.pumpAndSettle();
    }
    await tapVisible(tester, key('journal-ai-request'));
    expect(tester.takeException(), isNull);
    expect(service.calls, hasLength(1));
    return h;
  }

  Finder previewScroll() => find.ancestor(
    of: key('journal-ai-suggestion'),
    matching: find.byType(SingleChildScrollView),
  );

  RenderParagraph paragraph(WidgetTester tester, Finder text) =>
      tester.renderObject<RenderParagraph>(
        find.descendant(of: text, matching: find.byType(RichText)),
      );

  void expectSingleLine(WidgetTester tester, String action, String label) {
    final button = key(action);
    final render = paragraph(
      tester,
      find.descendant(of: button, matching: find.text(label)),
    );
    final boxes = render.getBoxesForSelection(
      TextSelection(baseOffset: 0, extentOffset: label.length),
    );
    expect(boxes, isNotEmpty);
    expect(render.didExceedMaxLines, isFalse);
    expect(render.textScaler.scale(17), 17 * 3.5);
    final bounds = tester.getRect(button);
    for (final box in boxes) {
      expect(
        box.top,
        closeTo(boxes.first.top, 0.01),
        reason: '$label must stay on one line without shrinking the text',
      );
      final rect = box.toRect().shift(render.localToGlobal(Offset.zero));
      expect(rect.left, greaterThanOrEqualTo(bounds.left));
      expect(rect.right, lessThanOrEqualTo(bounds.right));
    }
  }

  for (final brightness in Brightness.values) {
    for (final kind in JournalKind.values) {
      testUiWidgets(
        'preview first reading line visible at 320x568 3.5x ${kind.name} ${brightness.name}',
        (tester) async {
          await openPreview(
            tester,
            SyntheticJournalAi(),
            kind,
            brightness,
            3.5,
          );
          if (kind == JournalKind.diary) {
            final title = paragraph(tester, find.text('日记草稿'));
            final boxes = title.getBoxesForSelection(
              const TextSelection(baseOffset: 0, extentOffset: 4),
            );
            expect(title.textScaler.scale(17), 17 * 3.5);
            expect(boxes, isNotEmpty);
            for (final box in boxes) {
              expect(
                box.top,
                closeTo(boxes.first.top, 0.01),
                reason: 'Diary title must not lose a line to decoration',
              );
            }
          }
          final scroll = previewScroll();
          expect(scroll, findsOneWidget);
          final position = tester
              .state<ScrollableState>(
                find.descendant(of: scroll, matching: find.byType(Scrollable)),
              )
              .position;
          expect(position.pixels, 0);
          final render = paragraph(
            tester,
            key(
              kind == JournalKind.diary
                  ? 'journal-ai-suggestion'
                  : 'journal-ai-original',
            ),
          );
          final firstLine = render
              .getBoxesForSelection(
                const TextSelection(baseOffset: 0, extentOffset: 1),
              )
              .single
              .toRect()
              .shift(render.localToGlobal(Offset.zero));
          final viewport = tester.getRect(scroll);
          expect(firstLine.top, greaterThanOrEqualTo(viewport.top));
          expect(
            firstLine.bottom,
            lessThanOrEqualTo(viewport.bottom),
            reason:
                'The primary reading surface must be readable before scrolling',
          );
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant({
          TargetPlatform.iOS,
          TargetPlatform.android,
        }),
      );

      testUiWidgets(
        'preview action labels stay single line at 320x568 3.5x ${kind.name} ${brightness.name}',
        (tester) async {
          final service = SyntheticJournalAi();
          final h = await openPreview(tester, service, kind, brightness, 3.5);
          expectSingleLine(
            tester,
            'journal-ai-keep',
            kind == JournalKind.diary ? '暂不使用' : '保留原文',
          );
          expectSingleLine(
            tester,
            'journal-ai-use',
            kind == JournalKind.diary ? '放入草稿' : '使用',
          );
          final scroll = previewScroll();
          for (final action in ['journal-ai-use', 'journal-ai-keep']) {
            expect(
              find.descendant(of: scroll, matching: key(action)),
              findsOneWidget,
            );
            await tester.ensureVisible(key(action));
            await tester.pumpAndSettle();
            expect(key(action).hitTestable(), findsOneWidget);
          }
          final use = tester.getRect(key('journal-ai-use'));
          final keep = tester.getRect(key('journal-ai-keep'));
          expect(use.bottom, lessThan(keep.top));
          expect(use.width, 280);
          expect(keep.width, 280);
          if (kind == JournalKind.diary) {
            await tapVisible(tester, find.text('追加'));
          }
          await tapVisible(tester, key('journal-ai-use'));
          expect(
            tester.widget<TextField>(key('journal-text')).controller!.text,
            kind == JournalKind.diary
                ? '$original\n\n${service.diary}'
                : service.rewrite,
          );
          final store = await h.container.read(
            journalStoreProvider(kind).future,
          );
          expect(await store.savedOn(h.clock.day), isEmpty);
          await tapVisible(tester, key('journal-ai-undo'));
          expect(
            tester.widget<TextField>(key('journal-text')).controller!.text,
            original,
          );
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant({
          TargetPlatform.iOS,
          TargetPlatform.android,
        }),
      );

      testUiWidgets(
        'normal preview actions stay fixed while scrolling ${kind.name} ${brightness.name}',
        (tester) async {
          final service = SyntheticJournalAi()
            ..rewrite = '合成文字。' * 100
            ..diary = '合成日记。' * 100;
          await openPreview(tester, service, kind, brightness, 1);
          final keep = tester.getRect(key('journal-ai-keep'));
          final use = tester.getRect(key('journal-ai-use'));
          expect(keep.center.dy, use.center.dy);
          expect(keep.width, use.width);
          expect(keep.right, lessThan(use.left));
          expect(key('journal-ai-keep').hitTestable(), findsOneWidget);
          if (kind == JournalKind.diary) {
            await tapVisible(tester, find.text('追加'));
          }
          expect(key('journal-ai-use').hitTestable(), findsOneWidget);
          final scroll = previewScroll();
          expect(
            find.descendant(of: scroll, matching: key('journal-ai-use')),
            findsNothing,
          );
          await tester.drag(scroll, const Offset(0, -150));
          await tester.pumpAndSettle();
          final position = tester
              .state<ScrollableState>(
                find.descendant(of: scroll, matching: find.byType(Scrollable)),
              )
              .position;
          expect(position.pixels, greaterThan(0));
          expect(tester.getRect(key('journal-ai-keep')), keep);
          expect(tester.getRect(key('journal-ai-use')), use);
          await tapVisible(tester, key('journal-ai-keep'));
          expect(
            tester.widget<TextField>(key('journal-text')).controller!.text,
            original,
          );
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant({
          TargetPlatform.iOS,
          TargetPlatform.android,
        }),
      );
    }
  }
}
