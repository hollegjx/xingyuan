import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/assistant/assistant_providers.dart';
import 'package:habit_checkin/features/companion/companion_providers.dart';
import 'package:habit_checkin/features/journal/data/local_journal_store.dart';
import 'package:habit_checkin/features/journal/domain/journal_entry.dart';
import 'package:habit_checkin/features/journal/journal_providers.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'journal_diary_capture_test.dart'
    show capture, captureDirectory, captureFont, loadDiaryCaptureFont;
import 'journal_writing_breakpoint_delta_test.dart'
    show caretBounds, expectCaretVisible, rows;
import 'journal_writing_space_test.dart' show configure, key, keyboard;
import 'support/journal_ai_service.dart';
import 'support/journal_fixtures.dart';
import 'support/record_fixtures.dart';
import 'support/test_assistant_service.dart';
import 'support/ui_harness.dart';

const _stage = String.fromEnvironment(
  'LIMIT_CAPTURE_STAGE',
  defaultValue: 'check',
);
const _original = '原已保存的合成日记，不应在拒绝保存时改变。';
const _corrected = '合成修正。';
const _diaryLimit = '正文最多 5000 字';
final _overLimit = '${'合成文本。' * 999}末尾\n保留文';

Future<(UiHarness, SyntheticJournalAi, StubRecordPhotoPicker)> _mount(
  WidgetTester tester,
  GlobalKey boundary,
) async {
  final h = UiHarness();
  h.clock.setDay(2026, 10, 27);
  final ai = SyntheticJournalAi();
  final picker = StubRecordPhotoPicker();
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
  return (h, ai, picker);
}

Future<JournalSnapshot> _seed(LocalJournalStore store, UiHarness h) async {
  var seed = await switch (store) {
    LocalDiaryStore diary => diary.beginDraft(h.clock.day),
    LocalQuickNoteStore notes => notes.beginDraft(day: h.clock.day),
    _ => throw StateError('Unsupported synthetic journal store'),
  };
  seed = await store.writeDraft(
    seed.entry.id,
    content: _original,
    expectedDraftRevision: seed.entry.draftRevision,
  );
  return store.save(
    seed.entry.id,
    operationId: '12345678-1234-4234-8234-123456789abc',
    expectedRevision: seed.entry.revision,
    expectedDraftRevision: seed.entry.draftRevision,
  );
}

RenderParagraph _paragraph(WidgetTester tester, Finder text) =>
    tester.renderObject<RenderParagraph>(
      find.descendant(of: text, matching: find.byType(RichText)),
    );

void _expectFullText(WidgetTester tester, Finder text, String value) {
  final render = _paragraph(tester, text);
  expect(render.text.toPlainText(), value);
  expect(
    render.size.width,
    greaterThan(0),
    reason: 'Full feedback needs width',
  );
  expect(
    render.didExceedMaxLines,
    isFalse,
    reason: 'Do not ellipsize feedback',
  );
  final boxes = render.getBoxesForSelection(
    TextSelection(baseOffset: 0, extentOffset: value.length),
  );
  expect(boxes, isNotEmpty, reason: 'An empty glyph list is not visible text');
  final viewport = tester.getRect(key('journal-editor-scroll'));
  for (final box in boxes) {
    final rect = box.toRect().shift(render.localToGlobal(Offset.zero));
    expect(rect.left, greaterThanOrEqualTo(viewport.left));
    expect(rect.right, lessThanOrEqualTo(viewport.right));
    expect(rect.top, greaterThanOrEqualTo(viewport.top));
    expect(rect.bottom, lessThanOrEqualTo(viewport.bottom));
  }
}

Future<void> _show(WidgetTester tester, Finder text) async {
  await Scrollable.ensureVisible(tester.element(text), alignment: .5);
  await tester.pumpAndSettle();
}

Future<void> _showFeedback(
  WidgetTester tester,
  Finder error,
  Finder counter,
  String count,
) async {
  await _show(tester, error);
  final viewport = tester.getRect(key('journal-editor-scroll'));
  final together = tester
      .getRect(error)
      .expandToInclude(tester.getRect(counter));
  // Wider test-font glyphs can need more lines than the whole viewport.
  // In that case each complete message is still checked after scrolling.
  if (together.height <= viewport.height) {
    await Scrollable.ensureVisible(
      tester.element(counter),
      alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart,
    );
    await tester.pumpAndSettle();
    _expectFullText(tester, counter, count);
  }
}

Future<void> _expectFeedbackSemantics(
  WidgetTester tester,
  Finder error,
  String message,
) async {
  final handle = tester.ensureSemantics();
  try {
    await tester.pump();
    final data = tester.getSemantics(error).getSemanticsData();
    expect(data.label, contains(message));
    final inline =
        tester.widget<TextField>(key('journal-text')).decoration!.errorText !=
        null;
    expect(
      data.flagsCollection.isLiveRegion,
      !inline || !MediaQuery.supportsAnnounceOf(tester.element(error)),
    );
  } finally {
    handle.dispose();
  }
}

// Preserve the failing frame before checking geometry, using R6's boundary export.
Future<void> _raw(
  WidgetTester tester,
  GlobalKey boundary,
  Size size,
  String label,
  Finder text,
) async {
  if (captureDirectory.isEmpty) return;
  final render =
      boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final paragraph = _paragraph(tester, text);
  final boxes = paragraph.getBoxesForSelection(
    TextSelection(
      baseOffset: 0,
      extentOffset: paragraph.text.toPlainText().length,
    ),
  );
  final geometry = {
    'error_width': paragraph.size.width,
    'error_height': paragraph.size.height,
    'glyph_boxes': boxes.length,
    'did_exceed_max_lines': paragraph.didExceedMaxLines,
    'text_scale_at_14': paragraph.textScaler.scale(14),
    'source': const String.fromEnvironment('LIMIT_CAPTURE_SOURCE'),
  };
  debugPrint('LIMIT $label ${jsonEncode(geometry)}');
  await tester.runAsync(() async {
    await Directory(captureDirectory).create(recursive: true);
    if (_stage == 'before') {
      final image = await render.toImage();
      try {
        expect(image.width, size.width.toInt());
        expect(image.height, size.height.toInt());
        final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        final file = File('$captureDirectory/limit-$_stage-$label-inline.png');
        expect(file.existsSync(), isFalse);
        await file.writeAsBytes(png.buffer.asUint8List(), flush: true);
      } finally {
        image.dispose();
      }
    }
    await File('$captureDirectory/limit-$_stage-$label.json')
        .writeAsString(jsonEncode(geometry));
  });
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

  for (final kind in JournalKind.values) {
    for (final profile in [
      (const Size(390, 844), 1.0, Brightness.light, '390-1x-light'),
      (const Size(320, 568), 4.0, Brightness.dark, '320-4x-dark'),
    ]) {
      testUiWidgets('R13 single length feedback ${kind.name} ${profile.$4}', (
        tester,
      ) async {
        configure(tester, profile.$1, profile.$2, profile.$3);
        final boundary = GlobalKey();
        final (h, ai, picker) = await _mount(tester, boundary);
        final LocalJournalStore store = kind == JournalKind.diary
            ? await h.container.read(diaryStoreProvider.future)
            : await h.container.read(quickNoteStoreProvider.future);
        final seed = await _seed(store, h);
        await tester.pumpAndSettle();
        await tapVisible(
          tester,
          key(
            kind == JournalKind.diary
                ? 'entry-diary'
                : 'journal-entry-${seed.entry.id}',
          ),
        );
        final field = tester.widget<TextField>(key('journal-text'));
        final text = '${'合成文本。' * (kind.maxLength ~/ 5)}超';
        final message = '正文最多 ${kind.maxLength} 字';
        final count = '${kind.maxLength + 1} / ${kind.maxLength}';
        final label = 'r13-$_stage-${kind.name}-${profile.$4}';
        final editing = TextEditingValue(
          text: text,
          selection: TextSelection(
            baseOffset: text.length - 3,
            extentOffset: text.length - 1,
          ),
        );
        await tester.showKeyboard(key('journal-text'));
        tester.testTextInput.updateEditingValue(editing);
        await tester.pumpAndSettle();
        field.focusNode!.unfocus();
        final feedback = find.text(message);
        expect(feedback, findsOneWidget);
        await _showFeedback(tester, feedback, find.text(count), count);
        _expectFullText(tester, feedback, message);
        await _expectFeedbackSemantics(tester, feedback, message);
        await capture(
          tester,
          boundary,
          '$label-before-save',
          profile.$1,
          text: feedback,
          expectedText: message,
        );
        final before = await rows(h);
        await tapVisible(tester, key('save-journal'));
        expect(await rows(h), before);
        expect(field.controller!.value, editing);
        final rejected = (await store.savedOn(h.clock.day)).single.entry;
        expect(rejected.content, _original);
        expect(rejected.revision, seed.entry.revision);
        expect(rejected.lastOperationId, seed.entry.lastOperationId);
        expect(rejected.draftText, text);
        expect(text.characters.length, kind.maxLength + 1);
        final copies = feedback.evaluate().length;
        // Keep all baseline copies and data evidence before the red assertion.
        for (var i = 0; i < copies; i++) {
          await _show(tester, feedback.at(i));
          if (copies == 1) {
            await _showFeedback(
              tester,
              feedback.at(i),
              find.text(count),
              count,
            );
          }
          _expectFullText(tester, feedback.at(i), message);
          await capture(
            tester,
            boundary,
            '$label-rejected-$i',
            profile.$1,
            text: feedback.at(i),
            expectedText: message,
          );
        }
        final evidence = {
          'source': const String.fromEnvironment('LIMIT_CAPTURE_SOURCE'),
          'stage': _stage,
          'kind': kind.name,
          'copies_after_rejection': copies,
          'characters': text.characters.length,
          'selection': [
            editing.selection.baseOffset,
            editing.selection.extentOffset,
          ],
          'four_tables_unchanged': true,
          'saved_revision_receipt_and_draft_preserved': true,
        };
        debugPrint('R13 ${jsonEncode(evidence)}');
        if (captureDirectory.isNotEmpty) {
          await tester.runAsync(() async {
            final file = File('$captureDirectory/$label.json');
            expect(file.existsSync(), isFalse);
            await file.writeAsString(jsonEncode(evidence));
          });
        }
        expect(
          feedback,
          findsOneWidget,
          reason: 'One complete length explanation after rejected save',
        );
        expect(key('journal-error'), findsNothing);
        await _expectFeedbackSemantics(tester, feedback, message);
        await _show(tester, find.text(count));
        _expectFullText(tester, find.text(count), count);
        await tester.showKeyboard(key('journal-text'));
        const corrected = TextEditingValue(
          text: _corrected,
          selection: TextSelection(baseOffset: 1, extentOffset: 3),
        );
        tester.testTextInput.updateEditingValue(corrected);
        await tester.pumpAndSettle();
        field.focusNode!.unfocus();
        expect(field.controller!.value, corrected);
        expect(feedback, findsNothing);
        expect(key('journal-error'), findsNothing);
        final draft = (await store.savedOn(h.clock.day)).single.entry;
        expect(draft.content, _original);
        expect(draft.revision, seed.entry.revision);
        expect(draft.lastOperationId, seed.entry.lastOperationId);
        expect(draft.draftText, _corrected);
        await Scrollable.ensureVisible(
          tester.element(key('journal-text')),
          alignment: 0,
        );
        await tester.pumpAndSettle();
        await capture(
          tester,
          boundary,
          '$label-corrected',
          profile.$1,
          text: key('journal-text'),
          expectedText: _corrected,
          editable: true,
        );
        await tapVisible(tester, key('save-journal'));
        expect(key('journal-text'), findsNothing);
        final saved = await store.savedOn(h.clock.day);
        expect(saved, hasLength(1));
        expect(saved.single.entry.content, _corrected);
        expect(saved.single.entry.revision, seed.entry.revision + 1);
        expect(saved.single.entry.draftText, isNull);
        expect(ai.calls, isEmpty);
        expect(picker.calls, 0);
        expect(h.container.exists(assistantServiceProvider), isFalse);
        expect(h.container.exists(pairingControllerProvider), isFalse);
        expect(h.container.exists(chatControllerProvider), isFalse);
        expect(tester.takeException(), isNull);
      }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
    }
  }

  for (final profile in [
    (const Size(320, 568), 4.0, Brightness.dark, '320-4x-dark'),
    (const Size(320, 568), 4.0, Brightness.light, '320-4x-light'),
    (const Size(390, 844), 1.0, Brightness.light, '390-1x-light'),
  ]) {
    testUiWidgets('R12 diary full limit feedback ${profile.$4}', (
      tester,
    ) async {
      configure(tester, profile.$1, profile.$2, profile.$3);
      final boundary = GlobalKey();
      final (h, ai, picker) = await _mount(tester, boundary);
      final store = await h.container.read(diaryStoreProvider.future);
      final seed = await _seed(store, h);
      await tester.pumpAndSettle();
      await tapVisible(tester, key('entry-diary'));
      final field = tester.widget<TextField>(key('journal-text'));
      expect(_overLimit.characters.length, 5001);
      await tester.showKeyboard(key('journal-text'));
      final editing = TextEditingValue(
        text: _overLimit,
        selection: TextSelection(
          baseOffset: _overLimit.length - 3,
          extentOffset: _overLimit.length - 1,
        ),
      );
      tester.testTextInput.updateEditingValue(editing);
      await tester.pumpAndSettle();
      field.focusNode!.unfocus();
      final error = find.text(_diaryLimit);
      await _show(tester, error);
      await _raw(tester, boundary, profile.$1, profile.$4, error);
      _expectFullText(tester, error, _diaryLimit);
      expect(_paragraph(tester, error).textScaler.scale(14), profile.$2 * 14);
      final counter = find.text('5001 / 5000');
      await _showFeedback(tester, error, counter, '5001 / 5000');
      _expectFullText(tester, error, _diaryLimit);
      await capture(
        tester,
        boundary,
        'limit-$_stage-${profile.$4}-error',
        profile.$1,
        text: error,
        expectedText: _diaryLimit,
      );
      await _show(tester, counter);
      _expectFullText(tester, counter, '5001 / 5000');
      expect(field.controller!.value, editing);
      final before = await rows(h);
      await tapVisible(tester, key('save-journal'));
      expect(await rows(h), before);
      expect(field.controller!.value, editing);
      final unchanged = (await store.savedOn(h.clock.day)).single.entry;
      expect(unchanged.content, _original);
      expect(unchanged.revision, seed.entry.revision);
      expect(unchanged.lastOperationId, seed.entry.lastOperationId);
      expect(unchanged.draftText, _overLimit);
      final feedback = find.text(_diaryLimit);
      expect(feedback, findsOneWidget);
      expect(key('journal-error'), findsNothing);
      await _show(tester, feedback);
      _expectFullText(tester, feedback, _diaryLimit);

      await tester.showKeyboard(key('journal-text'));
      keyboard(tester, 200);
      await tester.pumpAndSettle();
      const correction = TextEditingValue(
        text: _corrected,
        selection: TextSelection(baseOffset: 1, extentOffset: 3),
      );
      tester.testTextInput.updateEditingValue(correction);
      await tester.pumpAndSettle();
      expect(field.controller!.value, correction);
      final viewport = tester.getRect(key('journal-editor-scroll'));
      final caret = caretBounds(tester);
      if (caret.bottom > viewport.bottom) {
        // Scroll from the gutter, without starting a text-selection gesture.
        await tester.dragFrom(
          Offset(viewport.left + 4, viewport.center.dy),
          Offset(0, viewport.bottom - caret.bottom - 32),
        );
        await tester.pumpAndSettle();
      }
      expect(field.controller!.value, correction);
      expectCaretVisible(tester);
      expect(feedback, findsNothing);
      expect(find.text(_diaryLimit), findsNothing);
      expect(find.text('5001 / 5000'), findsNothing);
      final draft = (await store.atDay(h.clock.day))!.entry;
      expect(draft.content, _original);
      expect(draft.revision, seed.entry.revision);
      expect(draft.draftText, _corrected);
      expect(key('save-journal').hitTestable(), findsOneWidget);
      expect(
        tester.widget<TextButton>(key('save-journal')).onPressed,
        isNotNull,
      );
      keyboard(tester, 0);
      field.focusNode!.unfocus();
      await Scrollable.ensureVisible(
        tester.element(key('journal-text')),
        alignment: 0,
      );
      await tester.pumpAndSettle();
      expect(field.controller!.value, correction);
      await capture(
        tester,
        boundary,
        'limit-$_stage-${profile.$4}-corrected',
        profile.$1,
        text: key('journal-text'),
        expectedText: _corrected,
        editable: true,
      );
      await tapVisible(tester, key('save-journal'));
      expect(key('journal-text'), findsNothing);
      final saved = await store.savedOn(h.clock.day);
      expect(saved, hasLength(1));
      expect(saved.single.entry.content, _corrected);
      expect(saved.single.entry.revision, seed.entry.revision + 1);
      expect(saved.single.entry.draftText, isNull);
      expect(ai.calls, isEmpty);
      expect(picker.calls, 0);
      expect(h.container.exists(assistantServiceProvider), isFalse);
      expect(h.container.exists(pairingControllerProvider), isFalse);
      expect(h.container.exists(chatControllerProvider), isFalse);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
  }

  for (final scale in [4.0, 1.5]) {
    testUiWidgets(
      'R12 quick note near-limit and full boundary feedback $scale',
      (tester) async {
        configure(tester, const Size(320, 568), scale, Brightness.dark);
        final boundary = GlobalKey();
        final (h, ai, picker) = await _mount(tester, boundary);
        await tapVisible(tester, key('entry-quick-note'));
        final store = await h.container.read(quickNoteStoreProvider.future);
        for (final length in [799, 800, 1001, 1000]) {
          final text = '合' * length;
          await tester.enterText(key('journal-text'), text);
          await tester.pumpAndSettle();
          tester.widget<TextField>(key('journal-text')).focusNode!.unfocus();
          final counter = find.text('$length / 1000');
          if (length == 799) {
            expect(counter, findsNothing);
          } else {
            await _show(tester, counter);
            _expectFullText(tester, counter, '$length / 1000');
          }
          final error = find.text('正文最多 1000 字');
          if (length == 1001) {
            await _showFeedback(tester, error, counter, '$length / 1000');
            _expectFullText(tester, error, '正文最多 1000 字');
            await capture(
              tester,
              boundary,
              'limit-$_stage-quick-note-$scale-error',
              const Size(320, 568),
              text: error,
              expectedText: '正文最多 1000 字',
            );
          } else {
            expect(error, findsNothing);
          }
          expect((await store.onDay(h.clock.day)).single.entry.draftText, text);
          expect(await store.savedOn(h.clock.day), isEmpty);
        }
        expect(ai.calls, isEmpty);
        expect(picker.calls, 0);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  }

  testUiWidgets('R13 storage failure stays visible and explicit retry saves', (
    tester,
  ) async {
    const size = Size(390, 844);
    configure(tester, size, 1, Brightness.light);
    final boundary = GlobalKey();
    final (h, ai, picker) = await _mount(tester, boundary);
    final store = await h.container.read(diaryStoreProvider.future);
    final seed = await _seed(store, h);
    await tester.pumpAndSettle();
    await tapVisible(tester, key('entry-diary'));
    await tester.enterText(key('journal-text'), _corrected);
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(key('journal-text'));
    field.focusNode!.unfocus();
    final editing = field.controller!.value;
    await h.database.customStatement(
      'CREATE TRIGGER r13_save_failure BEFORE UPDATE ON diary_entries '
      'WHEN NEW.revision > OLD.revision '
      "BEGIN SELECT RAISE(ABORT, 'synthetic save failure'); END",
    );
    final before = await rows(h);
    await tapVisible(tester, key('save-journal'));
    expect(await rows(h), before);
    expect(field.controller!.value, editing);
    const message = '未能保存，请重试。原有内容未被清空。';
    final error = key('journal-error');
    expect(find.text(message), findsOneWidget);
    await _show(tester, error);
    _expectFullText(tester, error, message);
    expect(key('retry-journal-draft'), findsNothing);
    await capture(
      tester,
      boundary,
      'r13-$_stage-storage-failure',
      size,
      text: error,
      expectedText: message,
    );
    final rejected = (await store.savedOn(h.clock.day)).single.entry;
    expect(rejected.content, _original);
    expect(rejected.revision, seed.entry.revision);
    expect(rejected.lastOperationId, seed.entry.lastOperationId);
    expect(rejected.draftText, _corrected);
    await h.database.customStatement('DROP TRIGGER r13_save_failure');
    expect(await rows(h), before);
    await tapVisible(tester, key('save-journal'));
    final saved = (await store.savedOn(h.clock.day)).single.entry;
    expect(saved.content, _corrected);
    expect(saved.revision, seed.entry.revision + 1);
    expect(saved.draftText, isNull);
    expect(key('journal-text'), findsNothing);
    expect(ai.calls, isEmpty);
    expect(picker.calls, 0);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testUiWidgets('R13 length feedback retains failed draft and retry action', (
    tester,
  ) async {
    const size = Size(390, 844);
    configure(tester, size, 1, Brightness.light);
    final boundary = GlobalKey();
    final (h, ai, picker) = await _mount(tester, boundary);
    final store = await h.container.read(quickNoteStoreProvider.future);
    final seed = await _seed(store, h);
    await tester.pumpAndSettle();
    await tapVisible(tester, key('journal-entry-${seed.entry.id}'));
    final field = tester.widget<TextField>(key('journal-text'));
    await h.database.customStatement(
      'CREATE TRIGGER r13_draft_failure BEFORE UPDATE ON quick_notes '
      'WHEN length(NEW.draft_text) > 1000 '
      "BEGIN SELECT RAISE(ABORT, 'synthetic draft failure'); END",
    );
    final before = await rows(h);
    final editing = TextEditingValue(
      text: '合' * 1001,
      selection: const TextSelection(baseOffset: 998, extentOffset: 1000),
    );
    await tester.showKeyboard(key('journal-text'));
    tester.testTextInput.updateEditingValue(editing);
    await tester.pumpAndSettle();
    field.focusNode!.unfocus();
    expect(await rows(h), before);
    expect(field.controller!.value, editing);
    expect(find.text('草稿未保存'), findsOneWidget);
    const message = '未能保存，请重试。原有内容未被清空。';
    final error = key('journal-error');
    final limit = find.text('正文最多 1000 字');
    expect(limit, findsOneWidget);
    await _show(tester, limit);
    _expectFullText(tester, limit, '正文最多 1000 字');
    await tapVisible(tester, key('save-journal'));
    expect(await rows(h), before);
    expect(field.controller!.value, editing);
    await _show(tester, error);
    _expectFullText(tester, error, message);
    final retry = key('retry-journal-draft');
    await _show(tester, retry);
    expect(retry.hitTestable(), findsOneWidget);
    expect(tester.widget<TextButton>(retry).onPressed, isNotNull);
    await capture(
      tester,
      boundary,
      'r13-$_stage-draft-failure',
      size,
      text: error,
      expectedText: message,
    );
    await h.database.customStatement('DROP TRIGGER r13_draft_failure');
    await tapVisible(tester, retry);
    expect(field.controller!.value, editing);
    expect(find.text('草稿已保存在本机'), findsOneWidget);
    expect(error, findsNothing);
    expect(retry, findsNothing);
    expect(limit, findsOneWidget);
    final recovered = (await store.savedOn(h.clock.day)).single.entry;
    expect(recovered.content, _original);
    expect(recovered.revision, seed.entry.revision);
    expect(recovered.lastOperationId, seed.entry.lastOperationId);
    expect(recovered.draftText, editing.text);
    final beforeReject = await rows(h);
    await tapVisible(tester, key('save-journal'));
    expect(await rows(h), beforeReject);
    expect(field.controller!.value, editing);
    expect(limit, findsOneWidget);
    expect(error, findsNothing);
    await _show(tester, limit);
    _expectFullText(tester, limit, '正文最多 1000 字');
    await tester.enterText(key('journal-text'), _corrected);
    await tester.pumpAndSettle();
    expect((await store.savedOn(h.clock.day)).single.entry.content, _original);
    await tapVisible(tester, key('save-journal'));
    final saved = (await store.savedOn(h.clock.day)).single.entry;
    expect(saved.content, _corrected);
    expect(saved.revision, seed.entry.revision + 1);
    expect(saved.draftText, isNull);
    expect(key('journal-text'), findsNothing);
    expect(ai.calls, isEmpty);
    expect(picker.calls, 0);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testUiWidgets('R12 non-length controller error remains readable', (
    tester,
  ) async {
    configure(tester, const Size(320, 568), 4, Brightness.dark);
    final boundary = GlobalKey();
    final (h, ai, picker) = await _mount(tester, boundary);
    final store = await h.container.read(diaryStoreProvider.future);
    await _seed(store, h);
    await tester.pumpAndSettle();
    await tapVisible(tester, key('entry-diary'));
    await tester.enterText(key('journal-text'), '');
    await tester.pumpAndSettle();
    final before = await rows(h);
    await tapVisible(tester, key('save-journal'));
    expect(await rows(h), before);
    final error = key('journal-error');
    await _show(tester, error);
    _expectFullText(tester, error, '请写下文字或添加照片');
    expect(ai.calls, isEmpty);
    expect(picker.calls, 0);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
}
