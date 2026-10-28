// R15 extends the handed-off CO38 journeys; original AI1 source remains untouched.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/assistant/assistant_providers.dart';
import 'package:habit_checkin/features/companion/companion_providers.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:habit_checkin/features/journal/data/local_journal_store.dart';
import 'package:habit_checkin/features/journal/domain/journal_entry.dart';
import 'package:habit_checkin/features/journal/journal_providers.dart';
import 'package:habit_checkin/features/journal/presentation/journal_editor_page.dart';
import 'package:habit_checkin/shared/local_date.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:uuid/uuid.dart';

import 'journal_diary_capture_test.dart'
    show captureDirectory, captureFont, loadDiaryCaptureFont;
import 'journal_writing_space_test.dart' show configure, key;
import 'support/diary_capture_pixels.dart';
import 'support/journal_ai_service.dart';
import 'support/journal_fixtures.dart';
import 'support/record_fixtures.dart';
import 'support/test_assistant_service.dart';
import 'support/ui_harness.dart';

const _product = String.fromEnvironment('R15_PRODUCT_SOURCE');
const _testedSource = String.fromEnvironment('R15_TEST_SOURCE');
const _source = 'test/journal_delete_confirmation_test.dart';
const _ios = !bool.fromEnvironment('R15_MATERIAL');
const _consequence = '文字、照片和草稿将被删除，目标和打卡不会改变。';
const _saved = '合成：已经保存的正文。';
const _draft = '合成：还没有保存的修改。';
const _continued = '合成：还没有保存的修改。\n取消后继续记录。';
const _failureText = '未能删除，请重试。原有内容未被清空。';

typedef _Rows = Map<String, List<Map<String, Object?>>>;

Future<_Rows> _rows(UiHarness h) async => {
  for (final table in [
    'diary_entries',
    'diary_photos',
    'quick_notes',
    'quick_note_photos',
    'goals',
    'check_ins',
  ])
    table:
        (await h.database
                .customSelect(
                  'SELECT * FROM $table ORDER BY ${table == 'check_ins' ? 'goal_id, occurrence_key' : 'id'}',
                )
                .get())
            .map((row) => row.data)
            .toList(),
};

Map<String, Object?> _row(_Rows rows, String table, String id) =>
    rows[table]!.singleWhere((row) => row['id'] == id);

void _onlyTarget(_Rows before, _Rows after, String table, String id) {
  for (final name in before.keys) {
    expect(
      after[name]!.length,
      before[name]!.length,
      reason: '$name row count',
    );
    expect(
      after[name]!.where((r) => name != table || r['id'] != id).toList(),
      before[name]!.where((r) => name != table || r['id'] != id).toList(),
      reason: '$name unrelated rows, all columns',
    );
  }
}

void _savedUnchanged(Map<String, Object?> before, Map<String, Object?> after) {
  for (final column in before.keys.where(
    (name) => !['draft_text', 'draft_revision', 'updated_at'].contains(name),
  )) {
    expect(after[column], before[column], reason: 'saved/identity $column');
  }
}

List<double> _rect(Rect rect) => [rect.left, rect.top, rect.right, rect.bottom];

class _Evidence {
  _Evidence(this.label, this.size, this.scale, this.theme, this.boundary);
  final String label;
  final Size size;
  final double scale;
  final Brightness theme;
  final GlobalKey boundary;
  final events = <Map<String, Object?>>[];
  final images = <Map<String, Object?>>[];
  final issues = <String>[];
  final data = <String, Object?>{};

  // Accumulate every character's visible bounds across actual scroll positions.
  Set<int> visible(WidgetTester tester, String value, String state) {
    final finder = find.text(value);
    expect(finder, findsOneWidget);
    final paragraph = tester.renderObject<RenderParagraph>(
      find.descendant(of: finder, matching: find.byType(RichText)),
    );
    final origin = paragraph.localToGlobal(Offset.zero);
    var clip = Offset.zero & size;
    RenderObject? ancestor = paragraph.parent;
    while (ancestor != null) {
      if (ancestor is RenderAbstractViewport && ancestor is RenderBox) {
        final box = ancestor as RenderBox;
        clip = clip.intersect(box.localToGlobal(Offset.zero) & box.size);
      }
      ancestor = ancestor.parent;
    }
    final seen = <int>{};
    final boxes = <Object>[];
    for (var i = 0; i < value.length; i++) {
      if (value[i] == '\n') continue;
      final glyphs = paragraph.getBoxesForSelection(
        TextSelection(baseOffset: i, extentOffset: i + 1),
      );
      for (final glyph in glyphs) {
        final bounds = glyph.toRect().shift(origin);
        boxes.add({'index': i, 'rect': _rect(bounds)});
        if (clip.inflate(.5).contains(bounds.topLeft) &&
            clip.inflate(.5).contains(bounds.bottomRight)) {
          seen.add(i);
        }
      }
    }
    final style = (paragraph.text as TextSpan).style!;
    events.add({
      'state': state,
      'text': value,
      'visibleCharacters': seen.toList(),
      'clip': _rect(clip),
      'paragraph': _rect(origin & paragraph.size),
      'glyphs': boxes,
      'fontSize': style.fontSize,
      'scaledFontSize': paragraph.textScaler.scale(style.fontSize!),
      'ellipsis': paragraph.didExceedMaxLines,
      'scrollOffsets': [
        for (final e in find.byType(Scrollable).evaluate())
          if (e is StatefulElement && e.state is ScrollableState)
            (e.state as ScrollableState).position.pixels,
      ],
    });
    if (paragraph.didExceedMaxLines) issues.add('$state: ellipsized $value');
    return seen;
  }

  Future<void> frame(
    WidgetTester tester,
    String state,
    String visibleText,
  ) async {
    final render =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final paragraph = tester.renderObject<RenderParagraph>(
      find.descendant(
        of: find.text(visibleText),
        matching: find.byType(RichText),
      ),
    );
    final origin = paragraph.localToGlobal(Offset.zero);
    final regions = paragraph
        .getBoxesForSelection(
          TextSelection(baseOffset: 0, extentOffset: visibleText.length),
        )
        .map((b) => b.toRect().shift(origin))
        .where(
          (r) =>
              (Offset.zero & size).contains(r.topLeft) &&
              (Offset.zero & size).contains(r.bottomRight),
        )
        .toList();
    await tester.runAsync(() async {
      final image = await render.toImage();
      try {
        expect(image.width, size.width.toInt());
        expect(image.height, size.height.toInt());
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!
            .buffer
            .asUint8List();
        final name = '$label-$state.png';
        if (captureDirectory.isNotEmpty) {
          await Directory(captureDirectory).create(recursive: true);
          await File('$captureDirectory/$name').writeAsBytes(bytes);
        }
        images.add({
          'file': name,
          'state': state,
          'sha256': sha256.convert(bytes).toString(),
          'width': image.width,
          'height': image.height,
        });
        // Pixels support the raw image; glyph/viewport evidence is separate.
        verifyDiaryCapturePixels(
          (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!,
          width: image.width,
          height: image.height,
          textRegions: regions,
        );
      } finally {
        image.dispose();
      }
    });
  }

  Future<void> readConfirmation(WidgetTester tester, JournalKind kind) async {
    final titleFinder = find.textContaining(
      kind == JournalKind.diary ? '日记？' : '随手记？',
    );
    final title = tester.widget<Text>(titleFinder).data!;
    final panel = key('journal-delete-confirmation-panel');
    final initialTitle = visible(tester, title, 'initial-title');
    final initialBody = visible(tester, _consequence, 'initial-consequence');
    data['initialTitle'] = initialTitle.toList();
    data['initialConsequence'] = initialBody.toList();
    data['platform'] = Theme.of(tester.element(find.text(title))).platform.name;
    await frame(
      tester,
      'confirmation-entry',
      panel.evaluate().isEmpty ? '取消' : title,
    );
    if (scale >= 2) {
      final bodyEvent = events.last;
      final clip = (bodyEvent['clip']! as List<double>);
      final bodyRect = bodyEvent['paragraph']! as List<double>;
      expect(bodyRect[2] - bodyRect[0], greaterThanOrEqualTo(size.width - 32));
      expect(
        clip[2] - clip[0],
        greaterThanOrEqualTo(size.width - 32),
        reason:
            'R15 needs the full-width reading surface, not the 240px dialog',
      );
      expect(
        clip[3] - clip[1],
        greaterThan(400),
        reason:
            'One tall reading viewport, not separate reading/actions windows',
      );
      final scroll = Scrollable.maybeOf(tester.element(titleFinder));
      expect(scroll, isNotNull);
      for (final value in [_consequence, '取消', '删除']) {
        expect(
          Scrollable.maybeOf(tester.element(find.text(value))),
          same(scroll),
          reason: 'Title, consequences and actions share one scroll flow',
        );
      }
      expect(tester.getRect(panel).top, greaterThanOrEqualTo(20));
      expect(tester.getRect(panel).bottom, lessThanOrEqualTo(size.height));
      expect(
        initialBody,
        isNotEmpty,
        reason: 'Initial frame must already expose the consequence',
      );
      expect(initialTitle.length, title.replaceAll('\n', '').length);
      final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(of: titleFinder, matching: find.byType(RichText)),
      );
      for (final group in ['删除', kind == JournalKind.diary ? '日记？' : '随手记？']) {
        final start = title.indexOf(group);
        expect(start, greaterThanOrEqualTo(0));
        final boxes = paragraph.getBoxesForSelection(
          TextSelection(baseOffset: start, extentOffset: start + group.length),
        );
        expect(boxes, isNotEmpty);
        expect(
          boxes.map((b) => b.top).toSet(),
          hasLength(1),
          reason: 'Whole title word group: $group',
        );
      }
    } else {
      expect(
        panel,
        findsNothing,
        reason: 'Ordinary adaptive dialog is retained',
      );
    }
    expect(
      title.replaceAll('\n', ''),
      kind == JournalKind.diary ? '删除日记？' : '删除随手记？',
    );
    for (final value in [title, _consequence, '删除', '取消']) {
      await tester.ensureVisible(find.text(value));
      await tester.pumpAndSettle();
      final seen = visible(tester, value, 'read-$value');
      final measured = events.last;
      final baseSize = measured['fontSize']! as double;
      expect(
        measured['scaledFontSize'],
        closeTo(baseSize * scale, .001),
        reason: 'System text scaling is not capped',
      );
      if (scale == 4 && value == _consequence) {
        await frame(tester, 'consequence-start', _consequence);
      }
      var step = 0;
      while (seen.length < value.replaceAll('\n', '').length && step < 8) {
        final scrollable = Scrollable.maybeOf(tester.element(find.text(value)));
        if (scrollable == null || scrollable.position.extentAfter < 1) break;
        final view = find
            .ancestor(of: find.text(value), matching: find.byType(Scrollable))
            .first;
        await tester.drag(view, const Offset(0, -90));
        await tester.pumpAndSettle();
        step++;
        seen.addAll(visible(tester, value, 'read-$value-scroll-$step'));
        await frame(
          tester,
          'reading-${value == _consequence ? 'consequence' : 'title'}-$step',
          value,
        );
      }
      if (seen.length != value.replaceAll('\n', '').length) {
        issues.add(
          'Unreadable characters in $value: ${value.length - seen.length}',
        );
      }
    }
    for (final action in [find.text('取消'), key('confirm-delete-journal')]) {
      await tester.ensureVisible(action);
      await tester.pumpAndSettle();
      expect(action.hitTestable(), findsOneWidget);
      events.add({
        'state': 'action-hit',
        'finder': action.toString(),
        'rect': _rect(tester.getRect(action)),
      });
    }
    await frame(tester, 'confirmation-actions', '删除');
    // The safe action remains a single explicit cancellation, not a new step.
    final semantics = tester.ensureSemantics();
    try {
      await tester.pump();
      for (final label in ['取消', '删除']) {
        final action = label == '删除'
            ? key('confirm-delete-journal')
            : find.text('取消');
        await tester.ensureVisible(action);
        await tester.pumpAndSettle();
        expect(action.hitTestable(), findsOneWidget);
        final node = tester.getSemantics(action).getSemanticsData();
        expect(node.label, label);
        expect(node.flagsCollection.isButton, isTrue);
        expect(node.hasAction(ui.SemanticsAction.tap), isTrue);
      }
    } finally {
      semantics.dispose();
    }
  }

  Future<void> finish(WidgetTester tester) async {
    final evidence = <String, Object?>{
      'product': _product,
      'testCommit': _testedSource,
      'source': _source,
      'sourceSha256': sha256
          .convert(File(_source).readAsBytesSync())
          .toString(),
      'runtimeSourceSha256': {
        for (final file in [
          'lib/features/journal/presentation/journal_editor_controller.dart',
          'lib/features/journal/presentation/journal_editor_page.dart',
          'lib/features/journal/presentation/journal_delete_confirmation.dart',
        ])
          file: sha256.convert(File(file).readAsBytesSync()).toString(),
      },
      'label': label,
      'viewport': [size.width, size.height],
      'dpr': 1,
      'scale': scale,
      'theme': theme.name,
      'keyboardInset': 0,
      'font': captureFont,
      'fontSha256': captureFont.isEmpty
          ? null
          : sha256.convert(File(captureFont).readAsBytesSync()).toString(),
      'data': data,
      'events': events,
      'images': images,
      'issues': issues,
    };
    if (captureDirectory.isNotEmpty) {
      await tester.runAsync(() async {
        await Directory(captureDirectory).create(recursive: true);
        await File(
          '$captureDirectory/$label.json',
        ).writeAsString(const JsonEncoder.withIndent('  ').convert(evidence));
      });
    }
    debugPrint(
      'R15_RESULT ${jsonEncode({'case': label, 'issues': issues, 'images': images.length})}',
    );
  }
}

Future<JournalSnapshot> _save(
  LocalJournalStore store,
  JournalSnapshot row,
  String text,
) async {
  row = await store.writeDraft(
    row.entry.id,
    content: text,
    expectedDraftRevision: row.entry.draftRevision,
  );
  return store.save(
    row.entry.id,
    operationId: const Uuid().v4(),
    expectedRevision: row.entry.revision,
    expectedDraftRevision: row.entry.draftRevision,
  );
}

TextEditingValue _editing(WidgetTester tester) =>
    tester.widget<TextField>(key('journal-text')).controller!.value;

Future<void> _type(WidgetTester tester, String text) async {
  await tester.showKeyboard(key('journal-text'));
  tester.testTextInput.updateEditingValue(
    TextEditingValue(
      text: text,
      selection: const TextSelection(baseOffset: 3, extentOffset: 6),
    ),
  );
  tester.testTextInput.hide();
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    tzdata.initializeTimeZones();
    expect(
      captureDirectory.isEmpty ||
          captureDirectory.startsWith('/tmp/xingyuan-ai2-r15-'),
      isTrue,
    );
    if (captureDirectory.isNotEmpty) {
      expect(RegExp(r'^[a-f0-9]{40}$').hasMatch(_product), isTrue);
      expect(RegExp(r'^[a-f0-9]{40}$').hasMatch(_testedSource), isTrue);
    }
    await loadDiaryCaptureFont();
    if (_ios && captureFont.isNotEmpty) {
      final bytes = ByteData.sublistView(await File(captureFont).readAsBytes());
      for (final family in ['CupertinoSystemText', 'CupertinoSystemDisplay']) {
        await (FontLoader(family)..addFont(Future.value(bytes))).load();
      }
    }
  });
  setUp(() {
    if (_ios) debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
  });
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  for (final variant in [
    ('ordinary', const Size(390, 844), 1.0, Brightness.light),
    ('small-2x', const Size(320, 568), 2.0, Brightness.light),
    ('small-4x', const Size(320, 568), 4.0, Brightness.dark),
    ('failure', const Size(390, 844), 1.0, Brightness.light),
  ]) {
    for (final kind in JournalKind.values) {
      final label = '${variant.$1}-${kind.name}';
      testUiWidgets('R15 deletion $label', (tester) async {
        configure(tester, variant.$2, variant.$3, variant.$4);
        final h = UiHarness()..clock.setDay(2026, 10, 27, hour: 13);
        final ai = SyntheticJournalAi();
        final picker = StubRecordPhotoPicker();
        final boundary = GlobalKey();
        final e = _Evidence(
          label,
          variant.$2,
          variant.$3,
          variant.$4,
          boundary,
        );
        try {
          await h.mount(
            tester,
            journalAiService: ai,
            assistantCredentials: ConversationTestCredentials(),
            recordPhotoPicker: picker,
            journalPhotoFiles: {
              for (final k in JournalKind.values) k: MemoryJournalPhotoFiles(k),
            },
            wrapApp: (child) => RepaintBoundary(key: boundary, child: child),
          );
          final day = LocalDate(2026, 10, 27);
          final goal = await h.repository.create(
            const GoalDraft(title: '合成对照目标', kind: GoalKind.habit),
          );
          await h.repository.setCompleted(goal, true, expectedDay: day);
          final diary = await h.container.read(diaryStoreProvider.future);
          final notes = await h.container.read(quickNoteStoreProvider.future);
          await _save(
            diary,
            await diary.beginDraft(LocalDate(2026, 10, 26)),
            '合成：另一天的日记。',
          );
          await _save(
            notes,
            await notes.beginDraft(day: LocalDate(2026, 10, 26)),
            '合成：另一天的随手记。',
          );
          final d = await _save(diary, await diary.beginDraft(day), _saved);
          final n = await _save(
            notes,
            await notes.beginDraft(day: day),
            _saved,
          );
          final store = kind == JournalKind.diary ? diary : notes;
          final target = kind == JournalKind.diary ? d : n;
          final id = target.entry.id;
          final table = kind == JournalKind.diary
              ? 'diary_entries'
              : 'quick_notes';
          var draft = kind == JournalKind.diary
              ? await diary.beginDraft(day)
              : await notes.beginDraft(day: day, id: id);
          draft = await store.writeDraft(
            id,
            content: _draft,
            expectedDraftRevision: draft.entry.draftRevision,
          );
          await tester.pumpAndSettle();
          await tapVisible(tester, find.byTooltip('我的'));
          await tapVisible(
            tester,
            key(kind == JournalKind.diary ? 'my-diary' : 'my-quick-notes'),
          );
          await tapVisible(tester, key('journal-entry-$id'));
          await _type(tester, _draft);
          final editing = _editing(tester);
          final before = await _rows(h);
          e.data.addAll({
            'target': id,
            'table': table,
            'before': before,
            'selection': [
              editing.selection.baseOffset,
              editing.selection.extentOffset,
            ],
          });
          expect(before['goals'], hasLength(1));
          expect(before['check_ins'], hasLength(1));
          expect(_row(before, table, id)['content'], _saved);
          expect(_row(before, table, id)['draft_text'], _draft);
          await tapVisible(tester, key('delete-journal'));
          await e.readConfirmation(tester, kind);
          expect(
            await _rows(h),
            before,
            reason: 'Opening confirmation must not save',
          );
          await tapVisible(tester, find.text('取消'));
          expect(
            _editing(tester),
            editing,
            reason: 'Cancel keeps draft and selection',
          );
          final cancelled = await _rows(h);
          e.data['cancelled'] = cancelled;
          expect(
            cancelled,
            before,
            reason: 'Cancel keeps every compared row and column',
          );

          if (variant.$1 == 'ordinary' || variant.$3 == 4) {
            await tapVisible(tester, key('delete-journal'));
            await tester.binding.handlePopRoute();
            await tester.pumpAndSettle();
            expect(_editing(tester), editing);
            expect(await _rows(h), before);
            await tapVisible(tester, key('delete-journal'));
            await tester.tapAt(const Offset(4, 30));
            await tester.pumpAndSettle();
            expect(key('confirm-delete-journal'), findsNothing);
            expect(_editing(tester), editing);
            expect(await _rows(h), before);
            e.data['backAndBarrierCancelled'] = true;
          }

          if (variant.$3 == 1) {
            await _type(tester, _continued);
            await tapVisible(
              tester,
              find.descendant(
                of: find.byType(JournalEditorPage),
                matching: find.byType(BackButton),
              ),
            );
            await tapVisible(tester, key('journal-entry-$id'));
            expect(_editing(tester).text, _continued);
            final reopened = await _rows(h);
            e.data['reopened'] = reopened;
            _onlyTarget(before, reopened, table, id);
            _savedUnchanged(_row(before, table, id), _row(reopened, table, id));
            expect(_row(reopened, table, id)['draft_text'], _continued);
            await e.frame(tester, 'reopened-editor', '完成');
            final retryEditing = _editing(tester);
            if (variant.$1 == 'failure') {
              await h.database.customStatement(
                "CREATE TRIGGER r15_delete_failure BEFORE UPDATE ON $table "
                "WHEN NEW.id = '$id' AND NEW.deleted_at IS NOT NULL "
                "BEGIN SELECT RAISE(ABORT, 'SYNTHETIC delete failure'); END",
              );
              await tapVisible(tester, key('delete-journal'));
              await tapVisible(tester, key('confirm-delete-journal'));
              expect(find.byType(JournalEditorPage), findsOneWidget);
              expect(_editing(tester), retryEditing);
              expect(find.text(_failureText), findsOneWidget);
              expect(find.textContaining('本地清理'), findsNothing);
              final failed = await _rows(h);
              e.data['failed'] = failed;
              expect(
                failed,
                reopened,
                reason: 'Deletion transaction rolls back completely',
              );
              await tester.ensureVisible(find.text(_failureText));
              await tester.pumpAndSettle();
              await e.frame(tester, 'delete-failure', _failureText);
              await h.database.customStatement(
                'DROP TRIGGER r15_delete_failure',
              );
            }
            await tapVisible(tester, key('delete-journal'));
            expect(await _rows(h), reopened);
            await tapVisible(tester, key('confirm-delete-journal'));
            expect(find.byType(JournalEditorPage), findsNothing);
            final deleted = await _rows(h);
            e.data['deleted'] = deleted;
            _onlyTarget(reopened, deleted, table, id);
            final old = _row(reopened, table, id);
            final now = _row(deleted, table, id);
            final changes = {
              'content',
              'saved_at',
              'deleted_at',
              'revision',
              'last_operation_id',
              'last_operation_draft_revision',
              'draft_text',
              'draft_revision',
              'updated_at',
            };
            for (final column in old.keys.where((c) => !changes.contains(c))) {
              expect(
                now[column],
                old[column],
                reason: 'Soft-delete identity $column',
              );
            }
            expect(now['content'], '');
            expect(now['saved_at'], isNull);
            expect(now['draft_text'], isNull);
            expect(
              now['deleted_at'],
              h.clock.read().instant.microsecondsSinceEpoch,
            );
            expect(
              now['updated_at'],
              h.clock.read().instant.microsecondsSinceEpoch,
            );
            expect(now['revision'], (old['revision']! as int) + 1);
            expect(now['draft_revision'], (old['draft_revision']! as int) + 1);
            expect(now['last_operation_draft_revision'], old['draft_revision']);
            expect(now['last_operation_id'], isNot(old['last_operation_id']));
            expect(
              (await store.savedOn(day)).where((r) => r.entry.id == id),
              isEmpty,
            );
            expect(key('journal-entry-$id'), findsNothing);
          }
          expect(ai.calls, isEmpty);
          expect(picker.calls, 0);
          expect(h.container.exists(assistantServiceProvider), isFalse);
          expect(h.container.exists(pairingControllerProvider), isFalse);
          expect(h.container.exists(chatControllerProvider), isFalse);
          e.data['privacy'] = {
            'aiCalls': 0,
            'pickerCalls': 0,
            'assistantInstantiated': false,
            'pairingInstantiated': false,
            'chatInstantiated': false,
          };
          expect(tester.takeException(), isNull);
          expect(
            e.issues,
            isEmpty,
            reason: 'Complete readable confirmation across scroll states',
          );
          e.data['completed'] = true;
        } finally {
          try {
            await e.finish(tester);
          } finally {
            debugDefaultTargetPlatformOverride = null;
          }
        }
      });
    }
  }
}
