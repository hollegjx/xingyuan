import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/assistant/assistant_providers.dart';
import 'package:habit_checkin/features/companion/companion_providers.dart';
import 'package:habit_checkin/features/journal/domain/journal_entry.dart';
import 'package:habit_checkin/features/journal/journal_providers.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'journal_diary_capture_test.dart'
    show captureDirectory, captureFont, loadDiaryCaptureFont;
import 'journal_writing_breakpoint_delta_test.dart' show rows, snapshot;
import 'journal_writing_space_test.dart' show configure, key;
import 'support/diary_capture_pixels.dart';
import 'support/journal_ai_service.dart';
import 'support/journal_fixtures.dart';
import 'support/record_fixtures.dart';
import 'support/test_assistant_service.dart';
import 'support/ui_harness.dart';

const _message = '正文最多 5000 字';
const _original = '原有合成日记。';
final _tooLong = '${'合成文本。' * 999}末尾\n保留文';

RenderParagraph _paragraph(WidgetTester tester, Finder finder) =>
    tester.renderObject<RenderParagraph>(
      find.descendant(of: finder, matching: find.byType(RichText)),
    );

List<double> _rect(Rect rect) => [rect.left, rect.top, rect.right, rect.bottom];

Map<String, Object?> _geometry(
  WidgetTester tester,
  Finder finder,
  String text,
  List<String> issues,
) {
  final render = _paragraph(tester, finder);
  expect(render.text.toPlainText(), text);
  final origin = render.localToGlobal(Offset.zero);
  final boxes = render.getBoxesForSelection(
    TextSelection(baseOffset: 0, extentOffset: text.length),
  );
  final viewport = tester.getRect(key('journal-editor-scroll'));
  if (render.size.width <= 0) issues.add('$text: zero width');
  if (boxes.isEmpty) issues.add('$text: empty glyphs');
  if (render.didExceedMaxLines) issues.add('$text: ellipsized');
  for (final box in boxes) {
    final rect = box.toRect().shift(origin);
    if (rect.left < viewport.left ||
        rect.right > viewport.right ||
        rect.top < viewport.top ||
        rect.bottom > viewport.bottom) {
      issues.add('$text: glyph outside viewport');
    }
  }
  return {
    'rect': _rect(origin & render.size),
    'glyphs': [for (final box in boxes) _rect(box.toRect().shift(origin))],
    'exceeded': render.didExceedMaxLines,
    'scaled14': render.textScaler.scale(14),
  };
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

  for (final scale in [1.5, 1.6]) {
    testUiWidgets('R12 full feedback near AI breakpoint $scale', (
      tester,
    ) async {
      configure(tester, const Size(320, 568), scale, Brightness.dark);
      final h = UiHarness();
      h.clock.setDay(2026, 10, 27);
      final ai = SyntheticJournalAi();
      final picker = StubRecordPhotoPicker();
      final boundary = GlobalKey();
      await h.mount(
        tester,
        journalAiService: ai,
        assistantCredentials: ConversationTestCredentials(),
        recordPhotoPicker: picker,
        journalPhotoFiles: {
          for (final kind in JournalKind.values)
            kind: MemoryJournalPhotoFiles(kind),
        },
        wrapApp: (child) => RepaintBoundary(key: boundary, child: child),
      );
      final store = await h.container.read(diaryStoreProvider.future);
      var seed = await store.beginDraft(h.clock.day);
      seed = await store.writeDraft(
        seed.entry.id,
        content: _original,
        expectedDraftRevision: seed.entry.draftRevision,
      );
      seed = await store.save(
        seed.entry.id,
        operationId: '12345678-1234-4234-8234-123456789abc',
        expectedRevision: seed.entry.revision,
        expectedDraftRevision: seed.entry.draftRevision,
      );
      await tester.pumpAndSettle();
      await tapVisible(tester, key('entry-diary'));
      final field = tester.widget<TextField>(key('journal-text'));
      await tester.showKeyboard(key('journal-text'));
      final editing = TextEditingValue(
        text: _tooLong,
        selection: const TextSelection(baseOffset: 4998, extentOffset: 5000),
      );
      expect(_tooLong.characters.length, 5001);
      tester.testTextInput.updateEditingValue(editing);
      await tester.pumpAndSettle();
      field.focusNode!.unfocus();
      final error = find.text(_message);
      final counter = find.text('5001 / 5000');
      await Scrollable.ensureVisible(tester.element(error), alignment: .5);
      await tester.pumpAndSettle();
      final inContent = find
          .descendant(
            of: key('journal-editor-scroll'),
            matching: key('journal-ai-request'),
          )
          .evaluate()
          .isNotEmpty;
      final layoutWidth = tester.getSize(key('journal-editor-scroll')).width;
      expect(layoutWidth, 320);
      expect(inContent, isFalse);
      expect(
        tester.widget<TextField>(key('journal-text')).decoration!.errorText,
        isNull,
      );
      final issues = <String>[];
      final errorGeometry = _geometry(tester, error, _message, issues);
      final counterGeometry = _geometry(tester, counter, '5001 / 5000', issues);
      expect(_paragraph(tester, error).textScaler.scale(14), scale * 14);
      final semantics = tester.ensureSemantics();
      late String semanticLabel;
      late bool liveRegion;
      try {
        await tester.pump();
        final data = tester.getSemantics(error).getSemanticsData();
        semanticLabel = data.label;
        liveRegion = data.flagsCollection.isLiveRegion;
        expect(semanticLabel, contains(_message));
        expect(liveRegion, isTrue);
      } finally {
        semantics.dispose();
      }
      await tester.pump();
      await snapshot(tester, boundary, 'r12-boundary-$scale');
      if (issues.isEmpty) {
        final render =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final paragraph = _paragraph(tester, error);
        final offset = paragraph.localToGlobal(Offset.zero, ancestor: render);
        final boxes = paragraph.getBoxesForSelection(
          const TextSelection(baseOffset: 0, extentOffset: _message.length),
        );
        await tester.runAsync(() async {
          final image = await render.toImage();
          try {
            verifyDiaryCapturePixels(
              (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!,
              width: image.width,
              height: image.height,
              textRegions: [
                for (final box in boxes) box.toRect().shift(offset).inflate(1),
              ],
            );
          } finally {
            image.dispose();
          }
        });
      }
      expect(field.controller!.value, editing);
      final before = await rows(h);
      await tapVisible(tester, key('save-journal'));
      expect(await rows(h), before);
      expect(field.controller!.value, editing);
      final saved = (await store.savedOn(h.clock.day)).single.entry;
      expect(saved.content, _original);
      expect(saved.revision, seed.entry.revision);
      expect(saved.lastOperationId, seed.entry.lastOperationId);
      expect(saved.draftText, _tooLong);
      expect(ai.calls, isEmpty);
      expect(picker.calls, 0);
      expect(h.container.exists(assistantServiceProvider), isFalse);
      expect(h.container.exists(pairingControllerProvider), isFalse);
      expect(h.container.exists(chatControllerProvider), isFalse);
      final evidence = {
        'baseline_candidate': 'c9592b232f526912b2cf14fd820731ee5a14bd7d',
        'product_source': const String.fromEnvironment('R12_PRODUCT_SOURCE'),
        'qa_source': const String.fromEnvironment('R12_QA_SOURCE'),
        'scale': scale,
        'layout_width': layoutWidth,
        'scaled_ai_threshold': 12 * 17 * scale,
        'in_content': inContent,
        'error': errorGeometry,
        'counter': counterGeometry,
        'semantics_label': semanticLabel,
        'live_region': liveRegion,
        'over_limit_characters': _tooLong.characters.length,
        'selection': [
          editing.selection.baseOffset,
          editing.selection.extentOffset,
        ],
        'rejected_save_four_tables_unchanged': true,
        'saved_revision_operation_and_draft_preserved': true,
        'ai_and_picker_calls': 0,
        'visibility_issues': issues,
      };
      debugPrint('R12_BOUNDARY ${jsonEncode(evidence)}');
      if (captureDirectory.isNotEmpty) {
        await tester.runAsync(() async {
          final output = File('$captureDirectory/r12-boundary-$scale.json');
          expect(output.existsSync(), isFalse);
          await output.writeAsString(jsonEncode(evidence));
        });
      }
      expect(tester.takeException(), isNull);
      // Keep the failing visual assertion after recording data protection.
      expect(
        issues,
        isEmpty,
        reason: 'Full pre-save feedback at the breakpoint',
      );
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
  }
}
