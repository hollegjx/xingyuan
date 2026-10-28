import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/assistant/assistant_providers.dart';
import 'package:habit_checkin/features/journal/domain/journal_entry.dart';
import 'package:habit_checkin/features/journal/journal_providers.dart';
import 'package:integration_test/integration_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import '../test/journal_ai_interaction_regression_test.dart' as regression;
import '../test/journal_ai_ui_test.dart' as journal;
import '../test/journal_notice_scope_test.dart' as notice;
import '../test/journal_ui_test.dart' as journal_ui;
import '../test/support/journal_ai_service.dart';
import '../test/support/journal_fixtures.dart';
import '../test/support/layout_capture.dart';
import '../test/support/test_assistant_service.dart';
import '../test/support/ui_harness.dart';

// Synthetic in-memory data and credentials; no backend or model requests.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const systemText = bool.fromEnvironment('JOURNAL_AI_SYSTEM_TEXT');
  final capture = LayoutCapture();
  setUp(() {
    binding.testTextInput.register();
    expect(binding.testTextInput.isRegistered, isTrue);
  });
  tearDown(binding.testTextInput.unregister);
  setUpAll(() async {
    tzdata.initializeTimeZones();
    await capture.prepare();
  });
  if (!systemText) {
    journal.main();
    regression.main();
    notice.main();
    journal_ui.main();
  }
  Finder key(String name) => find.byKey(ValueKey(name));
  for (final brightness in Brightness.values) {
    for (final scale in systemText ? <double?>[null] : <double?>[1, 3.5]) {
      testUiWidgets(
        'native journal AI ${brightness.name} scale ${scale ?? 'system'}',
        (tester) async {
          expect(Platform.isIOS, isTrue);
          tester.platformDispatcher.platformBrightnessTestValue = brightness;
          addTearDown(
            tester.platformDispatcher.clearPlatformBrightnessTestValue,
          );
          if (scale != null) {
            tester.view.physicalSize = const Size(320, 568);
            tester.view.devicePixelRatio = 1;
            tester.view.padding = const FakeViewPadding(top: 20);
            tester.view.viewPadding = const FakeViewPadding(top: 20);
            tester.view.viewInsets = const FakeViewPadding();
            tester.platformDispatcher.textScaleFactorTestValue = scale;
            addTearDown(() {
              tester.view.resetPhysicalSize();
              tester.view.resetDevicePixelRatio();
              tester.view.resetPadding();
              tester.view.resetViewPadding();
              tester.view.resetViewInsets();
              tester.platformDispatcher.clearTextScaleFactorTestValue();
            });
          }
          final semantics = tester.ensureSemantics();
          try {
            final service = SyntheticJournalAi();
            final h = UiHarness();
            h.clock.setDay(2026, 10, 23);
            await h.mount(
              tester,
              journalAiService: service,
              assistantCredentials: ConversationTestCredentials(),
              journalPhotoFiles: {
                for (final kind in JournalKind.values)
                  kind: MemoryJournalPhotoFiles(kind),
              },
              wrapApp: scale == null ? null : capture.wrap,
            );
            final effectiveScale =
                MediaQuery.textScalerOf(
                  tester.element(find.byType(NavigationBar)),
                ).scale(14) /
                14;
            if (systemText) expect(effectiveScale, greaterThanOrEqualTo(3));
            final store = await h.container.read(assistantStoreProvider.future);
            await store.memories.consent();
            h.container.invalidate(assistantSettingsProvider);
            await tester.pumpAndSettle();
            Future<void> shot(String name) async {
              if (scale != null) {
                await capture.shot(tester, scale, '${brightness.name}-$name');
              }
            }

            Future<void> inspectPreview(String name) async {
              final diary = name == 'diary-preview';
              final reading = key(
                diary ? 'journal-ai-suggestion' : 'journal-ai-original',
              );
              final scroll = find.ancestor(
                of: reading,
                matching: find.byType(SingleChildScrollView),
              );
              expect(scroll, findsOneWidget);
              RenderParagraph paragraph(Finder text) =>
                  tester.renderObject<RenderParagraph>(
                    find.descendant(of: text, matching: find.byType(RichText)),
                  );
              if (scale == 3.5) {
                final position = tester
                    .state<ScrollableState>(
                      find.descendant(
                        of: scroll,
                        matching: find.byType(Scrollable),
                      ),
                    )
                    .position;
                expect(position.pixels, 0);
                final original = paragraph(reading);
                final firstLine = original
                    .getBoxesForSelection(
                      const TextSelection(baseOffset: 0, extentOffset: 1),
                    )
                    .single
                    .toRect()
                    .shift(original.localToGlobal(Offset.zero));
                final viewport = tester.getRect(scroll);
                expect(firstLine.top, greaterThanOrEqualTo(viewport.top));
                expect(firstLine.bottom, lessThanOrEqualTo(viewport.bottom));
              }
              await shot(name);
              for (final entry in {
                'journal-ai-use': diary ? '放入草稿' : '使用',
                'journal-ai-keep': diary ? '暂不使用' : '保留原文',
              }.entries) {
                await tester.ensureVisible(key(entry.key));
                await tester.pumpAndSettle();
                expect(key(entry.key).hitTestable(), findsOneWidget);
                if (scale == 3.5) {
                  final render = paragraph(
                    find.descendant(
                      of: key(entry.key),
                      matching: find.text(entry.value),
                    ),
                  );
                  final boxes = render.getBoxesForSelection(
                    TextSelection(
                      baseOffset: 0,
                      extentOffset: entry.value.length,
                    ),
                  );
                  expect(boxes, isNotEmpty);
                  expect(render.didExceedMaxLines, isFalse);
                  expect(render.textScaler.scale(17), 17 * 3.5);
                  final bounds = tester.getRect(key(entry.key));
                  for (final box in boxes) {
                    expect(box.top, closeTo(boxes.first.top, 0.01));
                    final rect = box.toRect().shift(
                      render.localToGlobal(Offset.zero),
                    );
                    expect(rect.left, greaterThanOrEqualTo(bounds.left));
                    expect(rect.right, lessThanOrEqualTo(bounds.right));
                  }
                }
              }
              await shot('$name-actions');
            }

            String draft() =>
                tester.widget<TextField>(key('journal-text')).controller!.text;
            await tapVisible(tester, key('entry-quick-note'));
            await tester.enterText(key('journal-text'), '今天读完了一章。');
            await tester.pumpAndSettle();
            final data = tester
                .getSemantics(key('journal-ai-request'))
                .getSemanticsData();
            // iOS exposes the accessible name as tooltip, not always label.
            expect('${data.label}\n${data.tooltip}', contains('润色'));
            expect(data.hasAction(SemanticsAction.tap), isTrue);
            await tapVisible(tester, key('journal-ai-request'));
            expect(key('journal-ai-suggestion'), findsOneWidget);
            await inspectPreview('polish-preview');
            await tapVisible(tester, key('journal-ai-keep'));
            expect(key('journal-ai-suggestion'), findsNothing);
            expect(draft(), '今天读完了一章。');
            final notes = await h.container.read(quickNoteStoreProvider.future);
            expect(await notes.savedOn(h.clock.day), isEmpty);
            await tapVisible(tester, key('journal-ai-request'));
            await tapVisible(tester, key('journal-ai-use'));
            expect(draft(), service.rewrite);
            expect(await notes.savedOn(h.clock.day), isEmpty);
            await tester.ensureVisible(key('journal-ai-applied'));
            await tester.pumpAndSettle();
            await shot('polish-applied');
            await tapVisible(tester, key('journal-ai-undo'));
            expect(draft(), '今天读完了一章。');
            await tapVisible(tester, key('save-journal'));
            await tapVisible(tester, key('entry-diary'));
            await tester.enterText(key('journal-text'), '自己的开头');
            await tester.pumpAndSettle();
            await tapVisible(tester, key('journal-ai-request'));
            expect(key('journal-ai-suggestion'), findsOneWidget);
            await inspectPreview('diary-preview');
            await tapVisible(tester, find.text('追加'));
            await shot('diary-choice');
            await tapVisible(tester, key('journal-ai-use'));
            expect(draft(), '自己的开头\n\n${service.diary}');
            final diaries = await h.container.read(diaryStoreProvider.future);
            expect(await diaries.savedOn(h.clock.day), isEmpty);
            await tapVisible(tester, key('journal-ai-undo'));
            expect(draft(), '自己的开头');
            await goBack(tester);
            await tapVisible(tester, find.byTooltip('我的'));
            await shot('my');
            expect(service.calls, hasLength(3));
            expect(tester.takeException(), isNull);
            if (scale != null) await capture.passed(tester, scale);
            debugPrint(
              'JOURNAL_AI_NATIVE theme=${brightness.name} effective_scale=$effectiveScale system_text=$systemText',
            );
          } finally {
            semantics.dispose();
          }
        },
      );
    }
  }
}
