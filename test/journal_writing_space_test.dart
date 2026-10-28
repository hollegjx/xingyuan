import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/assistant/assistant_providers.dart';
import 'package:habit_checkin/features/journal/ai/journal_ai_providers.dart';
import 'package:habit_checkin/features/journal/domain/journal_entry.dart';
import 'package:habit_checkin/features/journal/journal_providers.dart';
import 'package:image/image.dart' as img;
import 'package:timezone/data/latest.dart' as tzdata;

import 'assistant_diary_ui_test.dart' show tapDiaryControl;
import 'journal_diary_capture_test.dart'
    show capture, captureDirectory, captureFont, loadDiaryCaptureFont;
import 'journal_interaction_regression_test.dart' show waitForPhotoAction;
import 'support/journal_ai_service.dart';
import 'support/journal_fixtures.dart';
import 'support/record_fixtures.dart';
import 'support/test_assistant_service.dart';
import 'support/ui_harness.dart';

const phase = String.fromEnvironment('R6_CAPTURE_STAGE', defaultValue: 'check');
const writing = TextEditingValue(
  text: '合成\n文字\n记录\n保留\n草稿\n测试',
  selection: TextSelection(baseOffset: 0, extentOffset: 1),
);
Finder key(String name) => find.byKey(ValueKey(name));

void configure(WidgetTester tester, Size size, double scale, Brightness theme) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  tester.platformDispatcher.platformBrightnessTestValue = theme;
  keyboard(tester, 0);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    tester.view.resetViewPadding();
    tester.view.resetPadding();
    tester.view.resetViewInsets();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
    tester.platformDispatcher.clearPlatformBrightnessTestValue();
  });
}

void keyboard(WidgetTester tester, double height) {
  final narrow = tester.view.physicalSize.width == 320;
  final top = narrow ? 20.0 : 47.0;
  final bottom = narrow ? 0.0 : 34.0;
  tester.view.viewPadding = FakeViewPadding(top: top, bottom: bottom);
  tester.view.padding = FakeViewPadding(
    top: top,
    bottom: math.max(0, bottom - height),
  );
  tester.view.viewInsets = FakeViewPadding(bottom: height);
}

Future<(UiHarness, SyntheticJournalAi)> openEditor(
  WidgetTester tester,
  GlobalKey boundary,
  JournalKind kind, {
  StubRecordPhotoPicker? picker,
  bool consent = false,
  bool connected = true,
}) async {
  final app = UiHarness();
  final ai = SyntheticJournalAi()..configured = connected;
  await app.mount(
    tester,
    journalAiService: ai,
    recordPhotoPicker: picker,
    assistantCredentials: ConversationTestCredentials(),
    journalPhotoFiles: {
      for (final kind in JournalKind.values)
        kind: MemoryJournalPhotoFiles(kind),
    },
    wrapApp: (child) => RepaintBoundary(key: boundary, child: child),
  );
  if (consent) {
    final store = await app.container.read(assistantStoreProvider.future);
    await store.memories.consent();
    app.container.invalidate(assistantSettingsProvider);
    await tester.pumpAndSettle();
  }
  await tapDiaryControl(
    tester,
    key(kind == JournalKind.diary ? 'entry-diary' : 'entry-quick-note'),
  );
  await tester.showKeyboard(key('journal-text'));
  tester.testTextInput.updateEditingValue(writing);
  await tester.pumpAndSettle();
  return (app, ai);
}

Future<void> namedAction(
  WidgetTester tester,
  GlobalKey boundary,
  JournalKind kind,
  Size size,
  bool large,
  String name,
) async {
  final action = key('journal-ai-request');
  expect(action, findsOneWidget);
  expect(
    find.descendant(of: key('journal-editor-scroll'), matching: action),
    findsNothing,
  );
  await tester.ensureVisible(action);
  await tester.pumpAndSettle();
  expect(action.hitTestable(), findsOneWidget);
  final rect = tester.getRect(action);
  expect(rect.width, greaterThanOrEqualTo(44));
  expect(rect.height, greaterThanOrEqualTo(44));
  final label = kind == JournalKind.diary ? 'AI 写日记' : '润色';
  final handle = tester.ensureSemantics();
  try {
    await tester.pump();
    final semantics = tester.getSemantics(action).getSemanticsData();
    expect(semantics.label, label);
    expect(semantics.flagsCollection.isButton, isTrue);
    expect(semantics.hasAction(ui.SemanticsAction.tap), isTrue);
  } finally {
    handle.dispose();
  }
  final text = find.descendant(of: action, matching: find.byType(Text));
  expect(find.byTooltip(label), findsOneWidget);
  if (large) {
    expect(text, findsNothing);
    expect(key('journal-ai-invite'), findsNothing);
  } else {
    expect(tester.widget<Text>(text).data, label);
    final paragraph = tester.renderObject<RenderParagraph>(
      find.descendant(of: text, matching: find.byType(RichText)),
    );
    final group = paragraph.getBoxesForSelection(
      TextSelection(baseOffset: 0, extentOffset: label.length),
    );
    expect(group.map((box) => box.top).toSet(), hasLength(1));
  }
  if (large) {
    final count = find.text('0/3');
    if (count.hitTestable().evaluate().isEmpty) {
      await tester.ensureVisible(count);
      await tester.pumpAndSettle();
    }
  }
  await capture(
    tester,
    boundary,
    name,
    size,
    text: large ? find.text('0/3') : text,
    expectedText: large ? '0/3' : label,
  );
}

RenderEditable editable(WidgetTester tester) => tester
    .state<EditableTextState>(
      find.descendant(
        of: key('journal-text'),
        matching: find.byType(EditableText),
      ),
    )
    .renderEditable;

Rect tools(WidgetTester tester) => tester.getRect(
  find
      .ancestor(
        of: key('journal-add-photo'),
        matching: find.byType(DecoratedBox),
      )
      .first,
);

Future<void> measure(
  WidgetTester tester,
  GlobalKey boundary,
  String name,
  Size size,
  double inset,
) async {
  final render = editable(tester);
  final scroll = tester.getRect(key('journal-editor-scroll'));
  final input = render.localToGlobal(Offset.zero) & render.size;
  final clip = input
      .intersect(scroll)
      .intersect(Rect.fromLTWH(0, 0, size.width, size.height - inset));
  final first = render
      .getLocalRectForCaret(const TextPosition(offset: 0))
      .shift(render.localToGlobal(Offset.zero));
  final line = render.preferredLineHeight;
  final bar = key('journal-add-photo').evaluate().isEmpty
      ? null
      : tools(tester);
  final geometry = <String, Object?>{
    'case': name,
    'keyboard': inset,
    'scroll': [scroll.left, scroll.top, scroll.width, scroll.height],
    'editable': [input.left, input.top, input.width, input.height],
    'visible': [clip.left, clip.top, clip.width, clip.height],
    'tools': bar == null ? null : [bar.left, bar.top, bar.width, bar.height],
    'lineHeight': line,
    'caretTop': first.top,
    'caretBottom': first.bottom,
  };
  debugPrint('R6 ${jsonEncode(geometry)}');
  await capture(
    tester,
    boundary,
    name,
    size,
    text: key('journal-text'),
    expectedText: writing.text,
    firstLineOnly: true,
    editable: true,
  );
  if (captureDirectory.isNotEmpty) {
    await tester.runAsync(() async {
      await File('$captureDirectory/$name.json')
          .writeAsString(jsonEncode(geometry));
    });
  }
  final requiredLines = inset == 0 ? 2 : 1;
  final fullLines = render
      .getBoxesForSelection(
        TextSelection(baseOffset: 0, extentOffset: writing.text.length),
      )
      .map((box) => box.toRect().shift(render.localToGlobal(Offset.zero)))
      .where(
        (box) => box.top >= scroll.top - 1 && box.bottom <= scroll.bottom + 1,
      )
      .map((box) => box.top)
      .toSet();
  expect(fullLines.length, greaterThanOrEqualTo(requiredLines));
  expect(
    clip.height,
    greaterThanOrEqualTo(line * requiredLines),
    reason:
        'R6 needs $requiredLines full scaled body lines, not merely no overflow.',
  );
  // The caret may extend beyond the font's layout box; the scroll viewport
  // (not the RenderEditable bounds) determines whether it is clipped.
  expect(first.top, greaterThanOrEqualTo(scroll.top - 1));
  expect(first.bottom, lessThanOrEqualTo(scroll.bottom + 1));
  if (bar != null) expect(clip.bottom, lessThanOrEqualTo(bar.top + 1));
  expect(tester.takeException(), isNull);
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
    for (final theme in Brightness.values) {
      for (final large in [false, true]) {
        final size = large ? const Size(320, 568) : const Size(390, 844);
        final label =
            '${kind.name}-${large ? '320-4x' : '390-1x'}-${theme.name}';
        testUiWidgets('R6 writing space $label', (tester) async {
          configure(tester, size, large ? 4 : 1, theme);
          final boundary = GlobalKey();
          final picker = StubRecordPhotoPicker();
          final (app, ai) = await openEditor(
            tester,
            boundary,
            kind,
            picker: picker,
          );
          final field = tester.widget<TextField>(key('journal-text'));
          field.focusNode!.unfocus();
          await namedAction(
            tester,
            boundary,
            kind,
            size,
            large,
            'r6-$phase-$label-action',
          );
          await Scrollable.ensureVisible(
            tester.element(key('journal-text')),
            alignment: 0,
          );
          await tester.pumpAndSettle();
          await measure(tester, boundary, 'r6-$phase-$label-k0', size, 0);
          expect(field.controller!.value, writing);
          await tester.showKeyboard(key('journal-text'));
          keyboard(tester, 200);
          tester.testTextInput.updateEditingValue(writing);
          await tester.pumpAndSettle();
          await measure(tester, boundary, 'r6-$phase-$label-k200', size, 200);
          expect(field.controller!.value, writing);
          tester.testTextInput.updateEditingValue(
            writing.copyWith(
              selection: TextSelection.collapsed(offset: writing.text.length),
            ),
          );
          await tester.pumpAndSettle();
          final render = editable(tester);
          final caret = render
              .getLocalRectForCaret(TextPosition(offset: writing.text.length))
              .shift(render.localToGlobal(Offset.zero));
          final viewport = tester.getRect(key('journal-editor-scroll'));
          expect(caret.top, greaterThanOrEqualTo(viewport.top - 1));
          expect(caret.bottom, lessThanOrEqualTo(viewport.bottom + 1));
          expect(caret.bottom, lessThanOrEqualTo(tools(tester).top + 1));
          expect(field.controller!.text, writing.text);
          tester.testTextInput.updateEditingValue(writing);
          await tester.pumpAndSettle();
          // Preserve the existing exhausted-height rule, then recover tools.
          keyboard(tester, large ? 350 : 700);
          await tester.pumpAndSettle();
          for (final action in [
            'journal-add-photo',
            'journal-take-photo',
            'delete-journal',
            'journal-ai-request',
          ]) {
            expect(key(action), findsNothing);
          }
          expect(field.controller!.value, writing);
          expect(tester.takeException(), isNull);
          field.focusNode!.unfocus();
          keyboard(tester, 0);
          await tester.pumpAndSettle();
          for (final action in [
            'journal-add-photo',
            'journal-take-photo',
            'delete-journal',
          ]) {
            expect(key(action).hitTestable(), findsOneWidget);
            final bounds = tester.getRect(key(action));
            expect(bounds.width, greaterThanOrEqualTo(44));
            expect(bounds.height, greaterThanOrEqualTo(44));
          }
          final store = await app.container.read(
            journalStoreProvider(kind).future,
          );
          expect(await store.savedOn(app.clock.day), isEmpty);
          expect(
            (await store.watchOn(app.clock.day).first).single.entry.draftText,
            writing.text,
          );
          expect(ai.calls, isEmpty);
          await tapDiaryControl(tester, key('delete-journal'));
          expect(key('confirm-delete-journal'), findsOneWidget);
          await tapDiaryControl(tester, find.text('取消'));
          expect(field.controller!.value, writing);
          expect(
            (await store.watchOn(app.clock.day).first).single.entry.draftText,
            writing.text,
          );
          if (large) {
            await tapDiaryControl(tester, key('journal-add-photo'));
            expect(picker.calls, 1);
            expect(
              (await store.onDay(app.clock.day)).single.draftPhotos,
              isEmpty,
            );
            picker.onPick = () async =>
                img.encodePng(img.Image(width: 40, height: 30));
            for (var count = 1; count <= 3; count++) {
              await tapDiaryControl(tester, key('journal-add-photo'));
              await waitForPhotoAction(tester, photos: count);
              expect(
                (await store.onDay(app.clock.day)).single.draftPhotos,
                hasLength(count),
              );
            }
            for (final action in ['journal-add-photo', 'journal-take-photo']) {
              expect(tester.widget<IconButton>(key(action)).onPressed, isNull);
            }
            expect(picker.calls, 4);
            expect(field.controller!.value, writing);
          }
          await tapDiaryControl(tester, key('save-journal'));
          final saved = await store.savedOn(app.clock.day);
          expect(saved, hasLength(1));
          expect(saved.single.entry.content, writing.text);
          expect(saved.single.entry.revision, 1);
          expect(saved.single.savedPhotos, hasLength(large ? 3 : 0));
          expect(ai.calls, isEmpty);
        }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
      }

      for (final gate in [
        'consent',
        'offline',
        if (kind == JournalKind.diary) 'history',
      ]) {
        testUiWidgets('R6 named action $gate ${kind.name} ${theme.name}', (
          tester,
        ) async {
          const size = Size(320, 568);
          configure(tester, size, 4, theme);
          final boundary = GlobalKey();
          final (app, ai) = await openEditor(
            tester,
            boundary,
            kind,
            consent: gate != 'consent',
            connected: gate != 'offline',
          );
          final field = tester.widget<TextField>(key('journal-text'));
          field.focusNode!.unfocus();
          if (gate == 'history') {
            final day = app.clock.day;
            app.clock.setDay(day.year, day.month, day.day + 1);
            app.container.invalidate(assistantSettingsProvider);
            await tester.pumpAndSettle();
          }
          await namedAction(
            tester,
            boundary,
            kind,
            size,
            true,
            'r6-$phase-${kind.name}-${theme.name}-$gate-action',
          );
          await tapDiaryControl(tester, key('journal-ai-request'));
          if (gate == 'consent') {
            expect(find.text('开启 AI 功能'), findsOneWidget);
            expect(find.textContaining('不发照片'), findsOneWidget);
            expect(app.container.exists(journalAiServiceProvider), isFalse);
            expect(app.container.exists(assistantServiceProvider), isFalse);
            await tapDiaryControl(tester, find.text('取消'));
          } else {
            final notice = find.descendant(
              of: key('journal-notice-scroll'),
              matching: find.textContaining(
                gate == 'offline' ? 'AI 暂时连接不上' : 'AI 只能为今天写日记',
              ),
            );
            expect(notice, findsOneWidget);
          }
          expect(ai.calls, isEmpty);
          expect(field.controller!.value, writing);
          expect(tester.takeException(), isNull);
        }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
      }
    }
  }
}
