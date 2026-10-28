import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/app/providers.dart';
import 'package:habit_checkin/features/assistant/assistant_providers.dart';
import 'package:habit_checkin/features/companion/companion_providers.dart';
import 'package:habit_checkin/features/journal/data/local_journal_store.dart';
import 'package:habit_checkin/features/journal/domain/journal_entry.dart';
import 'package:habit_checkin/features/journal/journal_providers.dart';
import 'package:habit_checkin/features/journal/presentation/journal_editor_page.dart';
import 'package:habit_checkin/shared/local_date.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:uuid/uuid.dart';

import 'journal_diary_capture_test.dart'
    show capture, captureDirectory, captureFont, loadDiaryCaptureFont;
import 'journal_writing_breakpoint_delta_test.dart' show rows;
import 'journal_writing_space_test.dart' show configure, key;
import 'support/journal_ai_service.dart';
import 'support/journal_fixtures.dart';
import 'support/record_fixtures.dart';
import 'support/test_assistant_service.dart';
import 'support/ui_harness.dart';

// AI1 CO36 source was imported unchanged in af27dd8 before the R14 repair.
const _baseline = 'aa468028bd57b88a52ad93b8a19342d5562192c5';
const _candidate = String.fromEnvironment('R14_PRODUCT_SOURCE');
const _testSource = String.fromEnvironment('R14_TEST_SOURCE');
const _source = 'test/journal_retrieval_independent_test.dart';
final _history = LocalDate(2026, 10, 26);
final _today = LocalDate(2026, 10, 27);
const _oldDiary = '合成：昨天读书。';
const _oldNote = '合成：晚间散步。';
const _newDiary = '合成：昨天读书，补记一页。';
const _newNote = '合成：晚间散步，补记天气。';

List<double> _rect(Rect value) => [
  value.left,
  value.top,
  value.right,
  value.bottom,
];

List<Map<String, Object?>> _table(Map<String, Object> data, String name) =>
    (data[name]! as List).cast<Map<String, Object?>>();

Map<String, Object?> _row(Map<String, Object> data, String table, String id) =>
    _table(data, table).singleWhere((row) => row['id'] == id);

void _unchangedOthers(
  Map<String, Object> before,
  Map<String, Object> after,
  String table,
  String id,
) {
  for (final name in before.keys) {
    final oldRows = _table(before, name);
    final newRows = _table(after, name);
    expect(newRows.length, oldRows.length, reason: '$name count');
    expect(
      newRows.where((row) => name != table || row['id'] != id).toList(),
      oldRows.where((row) => name != table || row['id'] != id).toList(),
      reason: '$name unrelated rows and every column',
    );
  }
}

void _savedIdentity(
  Map<String, Object?> before,
  Map<String, Object?> after, {
  required bool saved,
}) {
  for (final name in [
    'id',
    'owner',
    'day',
    'zone',
    'created_at',
    'deleted_at',
    if (!saved) ...[
      'content',
      'revision',
      'saved_at',
      'last_operation_id',
      'last_operation_draft_revision',
    ],
  ]) {
    expect(after[name], before[name], reason: 'Preserve $name');
  }
}

class _Evidence {
  _Evidence(this.label, this.size, this.scale, this.theme, this.boundary);

  final String label;
  final Size size;
  final double scale;
  final Brightness theme;
  final GlobalKey boundary;
  final issues = <String>[];
  final events = <Map<String, Object?>>[];
  final images = <Map<String, Object?>>[];
  Map<String, Object>? fixture;

  Map<String, Object?> text(
    WidgetTester tester,
    Finder finder,
    String state, {
    bool singleLine = false,
    bool visible = true,
  }) {
    expect(finder, findsOneWidget, reason: state);
    final paragraph = tester.renderObject<RenderParagraph>(
      find.descendant(of: finder, matching: find.byType(RichText)),
    );
    final value = paragraph.text.toPlainText();
    final origin = paragraph.localToGlobal(Offset.zero);
    final bounds = origin & paragraph.size;
    final boxes = paragraph.getBoxesForSelection(
      TextSelection(baseOffset: 0, extentOffset: value.length),
    );
    final lines = boxes.map((box) => box.top).toSet().length;
    final style = (paragraph.text as TextSpan).style!;
    final viewport = find.ancestor(
      of: finder,
      matching: find.byType(SingleChildScrollView),
    );
    final clip = viewport.evaluate().isEmpty
        ? Offset.zero & size
        : tester.getRect(viewport.first);
    if (singleLine && lines != 1) issues.add('$state: $lines lines ($value)');
    if (singleLine && paragraph.didExceedMaxLines) {
      issues.add('$state: ellipsized ($value)');
    }
    if (boxes.isEmpty) issues.add('$state: no glyph boxes');
    for (final box in boxes) {
      final glyph = box.toRect().shift(origin);
      if (singleLine &&
          (glyph.left < bounds.left - 1 || glyph.right > bounds.right + 1)) {
        issues.add('$state: glyph outside paragraph width ($value)');
      }
      if (visible &&
          (glyph.left < clip.left - 1 ||
              glyph.right > clip.right + 1 ||
              glyph.top < clip.top - 1 ||
              glyph.bottom > clip.bottom + 1)) {
        issues.add('$state: glyph outside current viewport ($value)');
      }
    }
    final result = <String, Object?>{
      'state': state,
      'text': value,
      'rect': _rect(bounds),
      'viewport': _rect(clip),
      'glyphs': [for (final box in boxes) _rect(box.toRect().shift(origin))],
      'lines': lines,
      'didExceedMaxLines': paragraph.didExceedMaxLines,
      'resolvedFontSize': style.fontSize,
      'scaledResolvedFontSize': paragraph.textScaler.scale(style.fontSize!),
      'fontFamily': style.fontFamily,
      'fontWeight': style.fontWeight?.value,
    };
    events.add(result);
    return result;
  }

  Future<void> tile(
    WidgetTester tester,
    String id,
    JournalKind kind,
    String summary,
    String state, {
    bool draft = false,
    String day = '26',
    String weekday = '周一',
    String time = '18:40',
  }) async {
    final tile = key('journal-entry-$id');
    expect(tile, findsOneWidget);
    await Scrollable.ensureVisible(tester.element(tile), alignment: 0);
    await tester.pumpAndSettle();
    Finder child(String value) =>
        find.descendant(of: tile, matching: find.text(value));
    if (kind == JournalKind.diary) {
      text(tester, child(day), '$state/day', singleLine: true);
      text(tester, child(weekday), '$state/weekday', singleLine: true);
    } else {
      text(tester, child(time), '$state/time', singleLine: true);
    }
    // Summaries intentionally allow truncation and scrolling.
    text(tester, child(summary), '$state/summary', visible: false);
    final summaryRect = tester.getRect(child(summary));
    final fields = kind == JournalKind.diary ? [day, weekday] : [time];
    for (final field in fields) {
      final metadataRect = tester.getRect(child(field));
      expect(metadataRect.overlaps(summaryRect), isFalse, reason: state);
      if (scale > 1) {
        expect(metadataRect.bottom, lessThanOrEqualTo(summaryRect.top));
        expect(summaryRect.left, closeTo(tester.getRect(tile).left + 16, .01));
      }
    }
    expect(child('草稿'), draft ? findsOneWidget : findsNothing);
    if (draft) {
      await Scrollable.ensureVisible(tester.element(child('草稿')));
      await tester.pumpAndSettle();
      text(tester, child('草稿'), '$state/draft', singleLine: true);
      await Scrollable.ensureVisible(tester.element(tile), alignment: 0);
      await tester.pumpAndSettle();
    }
    events.add({
      'state': state,
      'tile': id,
      'rect': _rect(tester.getRect(tile)),
      'center': [tester.getCenter(tile).dx, tester.getCenter(tile).dy],
      'centerHitTestable': tile.hitTestable().evaluate().isNotEmpty,
    });
  }

  void actions(WidgetTester tester, String state) {
    final back = find.byType(BackButton).last;
    final save = key('save-journal');
    expect(back.hitTestable(), findsOneWidget);
    expect(save.hitTestable(), findsOneWidget);
    expect(tester.widget<TextButton>(save).onPressed, isNotNull);
    text(
      tester,
      find.descendant(of: save, matching: find.text('完成')),
      '$state/save',
      singleLine: true,
    );
    events.add({
      'state': state,
      'back': _rect(tester.getRect(back)),
      'save': _rect(tester.getRect(save)),
      'backHit': true,
      'saveHit': true,
    });
  }

  Future<void> image(
    WidgetTester tester,
    String state,
    Finder paintedText,
    String value,
  ) async {
    final name = '$label-$state';
    await capture(
      tester,
      boundary,
      name,
      size,
      text: paintedText,
      expectedText: value,
      firstLineOnly: true,
    );
    if (captureDirectory.isNotEmpty) {
      final digest = await tester.runAsync(() async {
        final bytes = await File('$captureDirectory/$name.png').readAsBytes();
        return sha256.convert(bytes).toString();
      });
      images.add({
        'state': state,
        'file': '$name.png',
        'sha256': digest,
        'width': size.width,
        'height': size.height,
      });
    }
  }

  Future<void> finish(WidgetTester tester) async {
    final evidence = {
      'candidate': _candidate,
      'baseline': _baseline,
      'testSource': _testSource,
      'sourceSha256': sha256
          .convert(File(_source).readAsBytesSync())
          .toString(),
      'label': label,
      'viewport': [size.width, size.height],
      'dpr': 1,
      'scale': scale,
      'theme': theme.name,
      'font': captureFont,
      'fontSha256': captureFont.isEmpty
          ? null
          : sha256.convert(File(captureFont).readAsBytesSync()).toString(),
      'fixture': fixture,
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
      'CO36_RESULT ${jsonEncode({'case': label, 'issues': issues, 'images': images.length, 'candidate': _candidate, 'sourceSha256': evidence['sourceSha256']})}',
    );
  }
}

Future<JournalSnapshot> _seed(
  LocalJournalStore store,
  JournalSnapshot draft,
  String text,
) async {
  draft = await store.writeDraft(
    draft.entry.id,
    content: text,
    expectedDraftRevision: draft.entry.draftRevision,
  );
  return store.save(
    draft.entry.id,
    operationId: const Uuid().v4(),
    expectedRevision: draft.entry.revision,
    expectedDraftRevision: draft.entry.draftRevision,
  );
}

Future<void> _leaveEditor(WidgetTester tester) => tapVisible(
  tester,
  find.descendant(
    of: find.byType(JournalEditorPage),
    matching: find.byType(BackButton),
  ),
);

void main() {
  setUpAll(() async {
    tzdata.initializeTimeZones();
    expect(
      captureDirectory.isEmpty ||
          captureDirectory.startsWith('/tmp/xingyuan-ai2-r14-'),
      isTrue,
    );
    if (captureDirectory.isNotEmpty) {
      expect(_candidate, matches(RegExp(r'^[0-9a-f]{40}$')));
      expect(_testSource, matches(RegExp(r'^[0-9a-f]{40}$')));
    }
    await loadDiaryCaptureFont();
  });

  for (final variant in [
    ('390-1x-light', const Size(390, 844), 1.0, Brightness.light),
    ('320-2x-light', const Size(320, 568), 2.0, Brightness.light),
    ('320-4x-dark', const Size(320, 568), 4.0, Brightness.dark),
  ]) {
    testUiWidgets('CO36 saved retrieval ${variant.$1}', (tester) async {
      configure(tester, variant.$2, variant.$3, variant.$4);
      final h = UiHarness();
      h.clock.setDay(2026, 10, 27);
      final ai = SyntheticJournalAi();
      final picker = StubRecordPhotoPicker();
      final boundary = GlobalKey();
      final evidence = _Evidence(
        variant.$1,
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
            for (final kind in JournalKind.values)
              kind: MemoryJournalPhotoFiles(kind),
          },
          wrapApp: (child) => RepaintBoundary(key: boundary, child: child),
        );
        final diary = await h.container.read(diaryStoreProvider.future);
        final notes = await h.container.read(quickNoteStoreProvider.future);
        h.clock.setDay(2026, 10, 26, hour: 9, minute: 5);
        final historicalDiary = await _seed(
          diary,
          await diary.beginDraft(_history),
          _oldDiary,
        );
        final morning = await _seed(
          notes,
          await notes.beginDraft(),
          '合成：晨间记事。',
        );
        h.clock.setDay(2026, 10, 26, hour: 18, minute: 40);
        final evening = await _seed(notes, await notes.beginDraft(), _oldNote);
        h.clock.setDay(2026, 10, 27, hour: 8, minute: 15);
        final todayNote = await _seed(
          notes,
          await notes.beginDraft(),
          '合成：今早早餐。',
        );
        final todayDiary = await _seed(
          diary,
          await diary.beginDraft(_today),
          '合成：今天读书。',
        );
        h.clock.setDay(2026, 10, 27, hour: 12);
        await h.container.read(environmentProvider.notifier).refresh();
        await tester.pumpAndSettle();
        evidence.fixture = await rows(h);
        expect(key('journal-entry-${todayNote.entry.id}'), findsOneWidget);
        expect(key('journal-entry-${todayDiary.entry.id}'), findsOneWidget);
        expect(key('journal-entry-${evening.entry.id}'), findsNothing);
        expect(key('journal-entry-${historicalDiary.entry.id}'), findsNothing);
        if (variant.$3 == 1) {
          await tester.ensureVisible(
            key('journal-entry-${todayNote.entry.id}'),
          );
          await tester.pumpAndSettle();
          await evidence.image(
            tester,
            'today',
            find.text('合成：今早早餐。'),
            '合成：今早早餐。',
          );
        }
        for (final target in [
          (todayNote, JournalKind.quickNote, '合成：今早早餐。'),
          (todayDiary, JournalKind.diary, '合成：今天读书。'),
        ]) {
          final id = target.$1.entry.id;
          await evidence.tile(
            tester,
            id,
            target.$2,
            target.$3,
            'today/${target.$2.name}',
            day: '27',
            weekday: '周二',
            time: '08:15',
          );
          await evidence.image(
            tester,
            'today-${target.$2.name}',
            find.descendant(
              of: key('journal-entry-$id'),
              matching: find.text(target.$3),
            ),
            target.$3,
          );
        }

        await tapVisible(tester, find.byTooltip('我的'));
        for (final target in [
          (
            JournalKind.diary,
            historicalDiary,
            _oldDiary,
            _newDiary,
            'my-diary',
          ),
          (
            JournalKind.quickNote,
            evening,
            _oldNote,
            _newNote,
            'my-quick-notes',
          ),
        ]) {
          final kind = target.$1;
          final id = target.$2.entry.id;
          final table = kind == JournalKind.diary
              ? 'diary_entries'
              : 'quick_notes';
          final before = await rows(h);
          final original = _row(before, table, id);
          await tapVisible(tester, key(target.$5));
          if (kind == JournalKind.quickNote) {
            expect(
              tester.getTopLeft(key('journal-entry-${evening.entry.id}')).dy,
              lessThan(
                tester.getTopLeft(key('journal-entry-${morning.entry.id}')).dy,
              ),
            );
          }
          await tapVisible(tester, key('journal-entry-$id'));
          expect(
            tester
                .widget<JournalEditorPage>(find.byType(JournalEditorPage))
                .day,
            _history,
          );
          expect(
            tester.widget<TextField>(key('journal-text')).controller!.text,
            target.$3,
          );
          evidence.actions(tester, '${kind.name}/opened');
          await tester.enterText(key('journal-text'), target.$4);
          await tester.pumpAndSettle();
          await _leaveEditor(tester);
          expect(find.byType(JournalEditorPage), findsNothing);
          final drafted = await rows(h);
          _unchangedOthers(before, drafted, table, id);
          _savedIdentity(original, _row(drafted, table, id), saved: false);
          expect(_row(drafted, table, id)['draft_text'], target.$4);
          await evidence.tile(
            tester,
            id,
            kind,
            target.$3,
            '${kind.name}/returned-draft',
            draft: true,
          );
          final summary = find.descendant(
            of: key('journal-entry-$id'),
            matching: find.text(target.$3),
          );
          await evidence.image(
            tester,
            '${kind.name}-draft-list',
            summary,
            target.$3,
          );
          await tapVisible(tester, key('journal-entry-$id'));
          expect(
            tester.widget<TextField>(key('journal-text')).controller!.text,
            target.$4,
          );
          expect(
            tester
                .widget<JournalEditorPage>(find.byType(JournalEditorPage))
                .day,
            _history,
          );
          evidence.actions(tester, '${kind.name}/reopened');
          if (kind == JournalKind.quickNote && variant.$3 != 1) {
            await evidence.image(
              tester,
              'note-reopened',
              find.descendant(
                of: key('save-journal'),
                matching: find.text('完成'),
              ),
              '完成',
            );
          }
          final reopened = await rows(h);
          _unchangedOthers(before, reopened, table, id);
          _savedIdentity(original, _row(reopened, table, id), saved: false);
          expect(_row(reopened, table, id)['draft_text'], target.$4);
          await tapVisible(tester, key('save-journal'));
          expect(find.byType(JournalEditorPage), findsNothing);
          final saved = await rows(h);
          _unchangedOthers(before, saved, table, id);
          final actual = _row(saved, table, id);
          _savedIdentity(original, actual, saved: true);
          expect(actual['content'], target.$4);
          expect(actual['revision'], (original['revision']! as int) + 1);
          expect(actual['draft_text'], isNull);
          await evidence.tile(
            tester,
            id,
            kind,
            target.$4,
            '${kind.name}/saved',
          );
          evidence.events.add({
            'state': '${kind.name}/data',
            'before': before,
            'drafted': drafted,
            'reopened': reopened,
            'saved': saved,
            'otherRowsAndColumnsUnchanged': true,
          });
          await goBack(tester);
        }

        await tapVisible(tester, find.byTooltip('回顾'));
        await tapVisible(tester, key('review-day-${_history.key}'));
        expect(key('journal-entry-${todayDiary.entry.id}'), findsNothing);
        expect(key('journal-entry-${todayNote.entry.id}'), findsNothing);
        for (final target in [
          (historicalDiary, _newDiary),
          (evening, _newNote),
        ]) {
          await tapVisible(tester, key('journal-entry-${target.$1.entry.id}'));
          expect(
            tester
                .widget<JournalEditorPage>(find.byType(JournalEditorPage))
                .day,
            _history,
          );
          expect(
            tester.widget<TextField>(key('journal-text')).controller!.text,
            target.$2,
          );
          await _leaveEditor(tester);
          final kind = target.$1.entry.id == historicalDiary.entry.id
              ? JournalKind.diary
              : JournalKind.quickNote;
          await evidence.tile(
            tester,
            target.$1.entry.id,
            kind,
            target.$2,
            'review/${kind.name}',
          );
          await evidence.image(
            tester,
            'review-${kind.name}',
            find.descendant(
              of: key('journal-entry-${target.$1.entry.id}'),
              matching: find.text(target.$2),
            ),
            target.$2,
          );
        }
        if (variant.$3 == 1) {
          final heading = find.text('2026年10月26日');
          await Scrollable.ensureVisible(tester.element(heading), alignment: 0);
          await tester.pumpAndSettle();
          evidence.text(tester, heading, 'review/full-date');
          await evidence.image(
            tester,
            'review-history',
            heading,
            '2026年10月26日',
          );
        }
        final afterReview = await rows(h);
        for (final table in evidence.fixture!.keys) {
          final ids = {historicalDiary.entry.id, evening.entry.id};
          expect(
            _table(
              afterReview,
              table,
            ).where((row) => !ids.contains(row['id'])).toList(),
            _table(
              evidence.fixture!,
              table,
            ).where((row) => !ids.contains(row['id'])).toList(),
          );
          expect(
            _table(afterReview, table).length,
            _table(evidence.fixture!, table).length,
          );
        }
        expect((await diary.atDay(_history))!.entry.revision, 2);
        expect((await diary.atDay(_today))!.entry.content, '合成：今天读书。');
        expect(ai.calls, isEmpty);
        expect(picker.calls, 0);
        expect(h.container.exists(assistantServiceProvider), isFalse);
        expect(h.container.exists(pairingControllerProvider), isFalse);
        expect(h.container.exists(chatControllerProvider), isFalse);
        evidence.events.add({
          'state': 'review-complete',
          'rows': afterReview,
          'aiCalls': 0,
          'pickerCalls': 0,
          'assistantPairingChatUninstantiated': true,
        });
        expect(tester.takeException(), isNull);
        expect(
          evidence.issues,
          isEmpty,
          reason: 'Retain first geometry failures',
        );
      } finally {
        await evidence.finish(tester);
      }
    });
  }
}
