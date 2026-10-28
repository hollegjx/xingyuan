// R17 scoped evidence reuses the CO43 capture/data helpers from AI1 source
// 41425263534911aeb5ad310876f44aacd0859b0914c83947817e0e5390e4b7b4.
// The original dirty-dialog audit and its failures remain separate and unchanged.
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
import 'package:habit_checkin/features/records/data/record_photo.dart';
import 'package:image/image.dart' as img;
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:uuid/uuid.dart';

import 'journal_diary_capture_test.dart'
    show captureDirectory, captureFont, loadDiaryCaptureFont;
import 'journal_writing_space_test.dart' show configure, key;
import 'support/journal_ai_service.dart';
import 'support/journal_fixtures.dart';
import 'support/record_fixtures.dart';
import 'support/test_assistant_service.dart';
import 'support/ui_harness.dart';

const _baseline = '07692f3d89cfcdeff5aea79fc5b2e92280378750';
const _source = 'test/goal_form_recovery_test.dart';
const _title = '合成整理';
const _validation = '名称需要 1 至 60 个字符';
const _date = '2026年10月28日';
const _product = String.fromEnvironment('R17_PRODUCT_SOURCE');
const _testSource = String.fromEnvironment('R17_TEST_SOURCE');

List<double> _rect(Rect r) => [r.left, r.top, r.right, r.bottom];

Future<Map<String, Object?>> _rows(UiHarness h) async {
  final names = await h.database
      .customSelect(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name NOT LIKE 'sqlite_%' ORDER BY name",
      )
      .get();
  return {
    for (final row in names)
      row.read<String>('name'):
          (await h.database
                  .customSelect('SELECT * FROM "${row.read<String>('name')}"')
                  .get())
              .map((r) => r.data)
              .toList()
            ..sort((a, b) => jsonEncode(a).compareTo(jsonEncode(b))),
  };
}

Map<String, Object?> _photos(Map<JournalKind, MemoryJournalPhotoFiles> files) =>
    {
      for (final entry in files.entries)
        entry.key.name: {
          for (final photo in entry.value.entries.entries)
            photo.key: {
              'bytes': photo.value.length,
              'sha256': sha256.convert(photo.value).toString(),
            },
        },
    };

Future<void> _seed(
  LocalJournalStore store,
  JournalSnapshot value,
  MemoryJournalPhotoFiles files,
  SanitizedRecordPhoto image,
) async {
  value = await store.writeDraft(
    value.entry.id,
    content: '合成无关记录',
    expectedDraftRevision: value.entry.draftRevision,
  );
  value = await store.addPhoto(
    value.entry.id,
    photo: await files.write(image),
    expectedDraftRevision: value.entry.draftRevision,
  );
  await store.save(
    value.entry.id,
    operationId: const Uuid().v4(),
    expectedRevision: value.entry.revision,
    expectedDraftRevision: value.entry.draftRevision,
  );
}

void main() {
  setUpAll(() async {
    tzdata.initializeTimeZones();
    if (captureDirectory.isNotEmpty) {
      expect(captureDirectory.startsWith('/tmp/xingyuan-ai2-r17-'), isTrue);
      expect(Directory(captureDirectory).existsSync(), isFalse);
      await Directory(captureDirectory).create(recursive: true);
    }
    await loadDiaryCaptureFont();
    if (captureFont.isNotEmpty) {
      final bytes = ByteData.sublistView(await File(captureFont).readAsBytes());
      for (final family in ['CupertinoSystemText', 'CupertinoSystemDisplay']) {
        await (FontLoader(family)..addFont(Future.value(bytes))).load();
      }
    }
  });

  for (final label in ['ordinary', 'narrow', 'keyboard']) {
    final narrow = label != 'ordinary';
    final keyboard = label == 'keyboard';
    testUiWidgets('R17 Today name and date recovery $label', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final size = narrow ? const Size(320, 568) : const Size(390, 844);
      configure(
        tester,
        size,
        narrow ? 4 : 1,
        narrow ? Brightness.dark : Brightness.light,
      );
      final semantics = tester.ensureSemantics();
      final h = UiHarness()..clock.setDay(2026, 10, 27, hour: 17);
      final ai = SyntheticJournalAi();
      final picker = StubRecordPhotoPicker();
      final photos = {
        for (final kind in JournalKind.values)
          kind: MemoryJournalPhotoFiles(kind),
      };
      final boundary = GlobalKey();
      final states = <Map<String, Object?>>[];
      final geometry = <Map<String, Object?>>[];
      final images = <Map<String, Object?>>[];
      final issues = <String>{};
      Map<String, Object?>? before;
      Map<String, Object?>? photoBefore;
      int? created;
      var complete = false;
      var phase = 'setup';

      void textGeometry(String value, String state) {
        final finder = find.text(value).last;
        expect(finder, findsOneWidget);
        final p = tester.renderObject<RenderParagraph>(
          find.descendant(of: finder, matching: find.byType(RichText)),
        );
        final origin = p.localToGlobal(Offset.zero);
        final bounds = origin & p.size;
        var clip = Offset.zero & size;
        RenderObject? ancestor = p.parent;
        while (ancestor != null) {
          if (ancestor is RenderAbstractViewport && ancestor is RenderBox) {
            final viewport = ancestor as RenderBox;
            clip = clip.intersect(
              viewport.localToGlobal(Offset.zero) & viewport.size,
            );
          }
          ancestor = ancestor.parent;
        }
        final glyphs = <Map<String, Object?>>[];
        var missing = 0;
        var clipped = 0;
        for (var i = 0; i < value.length; i++) {
          final boxes = p.getBoxesForSelection(
            TextSelection(baseOffset: i, extentOffset: i + 1),
          );
          if (boxes.isEmpty && value[i].trim().isNotEmpty) missing++;
          for (final box in boxes) {
            final r = box.toRect().shift(origin);
            final visible =
                r.left >= clip.left - 0.1 &&
                r.top >= clip.top - 0.1 &&
                r.right <= clip.right + 0.1 &&
                r.bottom <= clip.bottom + 0.1;
            if (!visible) clipped++;
            glyphs.add({'index': i, 'rect': _rect(r), 'visible': visible});
          }
        }
        if (p.didExceedMaxLines || missing > 0 || clipped > 0) {
          issues.add(
            '$state/$value: missing=$missing clipped=$clipped exceeded=${p.didExceedMaxLines}',
          );
        }
        geometry.add({
          'state': state,
          'text': value,
          'rect': _rect(bounds),
          'clip': _rect(clip),
          'glyphs': glyphs,
          'missing': missing,
          'clipped': clipped,
          'didExceedMaxLines': p.didExceedMaxLines,
          'maxLines': p.maxLines,
          'baseFont': p.text.style?.fontSize,
          'scaledFont': p.textScaler.scale(p.text.style?.fontSize ?? 14),
        });
      }

      Future<void> record(String state, {bool picture = false}) async {
        phase = state;
        final rows = await _rows(h);
        final memoryPhotos = _photos(photos);
        expect(memoryPhotos, photoBefore);
        if (created == null) {
          expect(rows, before, reason: '$state does not create or modify data');
        } else {
          for (final entry in before!.entries) {
            final after = (rows[entry.key]! as List)
                .cast<Map<String, Object?>>();
            final old = (entry.value! as List).cast<Map<String, Object?>>();
            final keyColumn = entry.key == 'goals' ? 'id' : 'goal_id';
            if ([
              'goals',
              'goal_titles',
              'goal_schedules',
              'goal_reminders',
              'sync_states',
            ].contains(entry.key)) {
              expect(after.where((r) => r[keyColumn] != created).toList(), old);
              expect(after.where((r) => r[keyColumn] == created), hasLength(1));
            } else {
              expect(after, old, reason: '$state preserves ${entry.key}');
            }
          }
        }
        expect(h.permissions.requests, 0);
        expect(h.permissions.settingsOpens, 0);
        expect(h.notifications.scheduled, isEmpty);
        expect(h.notifications.requests, isEmpty);
        expect(ai.calls, isEmpty);
        expect(picker.calls, 0);
        states.add({
          'state': state,
          'created': created,
          'rows': rows,
          'photos': memoryPhotos,
          'permissionRequests': h.permissions.requests,
          'scheduled': h.notifications.scheduled.length,
        });
        if (!picture || captureDirectory.isEmpty) return;
        await tester.runAsync(() async {
          final render =
              boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await render.toImage();
          try {
            final bytes = (await image.toByteData(
              format: ui.ImageByteFormat.png,
            ))!.buffer.asUint8List();
            final file = '$label-$state.png';
            expect(File('$captureDirectory/$file').existsSync(), isFalse);
            await File('$captureDirectory/$file').writeAsBytes(bytes);
            images.add({
              'file': file,
              'sha256': sha256.convert(bytes).toString(),
              'width': image.width,
              'height': image.height,
              'state': state,
            });
          } finally {
            image.dispose();
          }
        });
      }

      Future<void> expose(
        Finder finder,
        String state, {
        String? text,
        bool picture = false,
      }) async {
        phase = state;
        expect(finder, findsOneWidget);
        final initial = tester.getRect(finder);
        await tester.ensureVisible(finder);
        await tester.pumpAndSettle();
        final aligned = tester.getRect(finder);
        geometry.add({
          'state': state,
          'actionRectBefore': _rect(initial),
          'actionRectAfter': _rect(aligned),
          'ensureVisible': true,
          'moved': initial != aligned,
          'hit': finder.hitTestable().evaluate().isNotEmpty,
        });
        expect(finder.hitTestable(), findsOneWidget);
        if (text != null) textGeometry(text, state);
        await record(state, picture: picture);
      }

      try {
        await h.mount(
          tester,
          journalAiService: ai,
          recordPhotoPicker: picker,
          assistantCredentials: ConversationTestCredentials(),
          journalPhotoFiles: photos,
          wrapApp: (child) => RepaintBoundary(key: boundary, child: child),
        );
        final goal = await h.repository.create(
          const GoalDraft(title: '无关习惯', kind: GoalKind.habit),
        );
        await h.repository.setCompleted(goal, true, expectedDay: h.clock.day);
        final diary = await h.container.read(diaryStoreProvider.future);
        final notes = await h.container.read(quickNoteStoreProvider.future);
        final photo = (await tester.runAsync(
          () => sanitizeRecordPhoto(
            img.encodePng(img.Image(width: 24, height: 16)),
          ),
        ))!;
        await _seed(
          diary,
          await diary.beginDraft(h.clock.day.addDays(-1)),
          photos[JournalKind.diary]!,
          photo,
        );
        await _seed(
          notes,
          await notes.beginDraft(day: h.clock.day.addDays(-1)),
          photos[JournalKind.quickNote]!,
          photo,
        );
        await tester.pumpAndSettle();
        before = await _rows(h);
        photoBefore = _photos(photos);
        await record('today-initial', picture: true);
        await expose(
          key('entry-new-goal'),
          'today-entry-aligned',
          text: '新目标',
          picture: narrow,
        );
        await tester.tap(key('entry-new-goal'));
        await tester.pumpAndSettle();
        await record('form-initial', picture: true);

        expect(find.text(_validation), findsNothing);
        if (!keyboard) {
          await expose(key('save-goal'), 'empty-save', text: '保存');
          await tester.tap(key('save-goal'));
          await tester.pumpAndSettle();
          await record('name-error-initial', picture: true);
          await expose(
            find.text(_validation),
            'name-error-aligned',
            text: _validation,
            picture: narrow,
          );
        }
        await expose(key('goal-title'), 'name-input');
        await tester.enterText(key('goal-title'), _title);
        tester.testTextInput.hide();
        await tester.pumpAndSettle();
        expect(find.text(_validation), findsNothing);
        await record('name-corrected', picture: !keyboard);
        await expose(key('goal-kind'), 'kind');
        await tester.tap(key('goal-kind'));
        await tester.pumpAndSettle();
        await expose(find.text('单次任务').last, 'single-type', text: '单次任务');
        await tester.tap(find.text('单次任务').last);
        await tester.pumpAndSettle();
        await expose(key('planned-day'), 'date-button', text: '2026年10月27日');
        await tester.tap(key('planned-day'));
        await tester.pumpAndSettle();
        await record('date-initial', picture: true);
        final dateField = find.descendant(
          of: find.byType(InputDatePickerFormField),
          matching: find.byType(TextFormField),
        );
        Future<void> inputDate(String value, String phase) async {
          await expose(dateField, '$phase-field');
          await tester.enterText(dateField, value);
          tester.testTextInput.hide();
          await tester.pumpAndSettle();
          expect(
            tester.widget<TextFormField>(dateField).controller!.text,
            value,
          );
          await record('$phase-entered');
        }

        Future<void> candidate(
          int year,
          int month,
          int day,
          String phase,
        ) async {
          await tester.ensureVisible(key('goal-date-candidate'));
          await tester.pumpAndSettle();
          geometry.add({
            'state': '$phase-date-group',
            'ensureVisible': true,
            'rect': _rect(tester.getRect(key('goal-date-candidate'))),
          });
          for (final unit in ['$year年', '$month月', '$day日']) {
            final number = unit.substring(0, unit.length - 1);
            final label = find.text(unit).evaluate().isNotEmpty
                ? unit
                : '$number\n${unit[unit.length - 1]}';
            if (tester.getSize(key('goal-date-candidate')).height >
                size.height - (keyboard ? 200 : 0) - 76) {
              await tester.ensureVisible(find.text(label));
              await tester.pumpAndSettle();
            }
            textGeometry(label, '$phase-$unit');
            final paragraph = tester.renderObject<RenderParagraph>(
              find.descendant(
                of: find.text(label),
                matching: find.byType(RichText),
              ),
            );
            final boxes = paragraph.getBoxesForSelection(
              TextSelection(baseOffset: 0, extentOffset: number.length),
            );
            expect(
              boxes.map((b) => b.top).toSet(),
              hasLength(1),
              reason: 'A complete date number must not split across lines',
            );
            expect(paragraph.textScaler.scale(17), narrow ? 68 : 17);
          }
          await record('$phase-candidate', picture: true);
        }

        if (find.byType(InputDatePickerFormField).evaluate().isNotEmpty) {
          expect(find.byType(DatePickerDialog), findsNothing);
          expect(find.byType(InputDatePickerFormField), findsOneWidget);
          await candidate(2026, 10, 27, 'initial');
          if (!keyboard) {
            await inputDate('9999/12/31', 'maximum');
            await candidate(9999, 12, 31, 'maximum');
            await expose(key('goal-date-cancel'), 'cancel-maximum', text: '取消');
            await tester.tap(key('goal-date-cancel'));
            await tester.pumpAndSettle();
            await expose(
              key('planned-day'),
              'date-after-cancel',
              text: '2026年10月27日',
              picture: true,
            );
            await tester.tap(key('planned-day'));
            await tester.pumpAndSettle();
            expect(
              tester.widget<TextFormField>(dateField).controller!.text,
              '2026/10/27',
            );
            for (final value in ['2026/02/30', '2026/10/26', '10000/01/01']) {
              final phase = 'invalid-${value.replaceAll('/', '-')}';
              await inputDate(value, phase);
              await expose(
                key('goal-date-confirm'),
                '$phase-confirm',
                text: '确定',
              );
              await tester.tap(key('goal-date-confirm'));
              await tester.pumpAndSettle();
              expect(dateField, findsOneWidget);
              expect(
                tester.widget<TextFormField>(dateField).controller!.text,
                value,
              );
              final error = value != '2026/02/30'
                  ? '日期需从今天起，最晚为9999年12月31日'
                  : '请输入有效日期（年/月/日）';
              await expose(
                find.text(error),
                '$phase-error',
                text: error,
                picture: true,
              );
            }
          }
          await inputDate('2026/10/28', 'corrected-date');
          expect(find.text('请输入有效日期（年/月/日）'), findsNothing);
          expect(find.text('日期需从今天起，最晚为9999年12月31日'), findsNothing);
          if (keyboard) {
            tester.view.viewInsets = const FakeViewPadding(bottom: 200);
            await tester.pumpAndSettle();
            await expose(dateField, 'keyboard-input', picture: true);
          }
          await candidate(2026, 10, 28, 'corrected');
          if (!keyboard) {
            await tester.tap(find.byType(BackButton).hitTestable());
            await tester.pumpAndSettle();
            await expose(
              key('planned-day'),
              'date-after-back',
              text: '2026年10月27日',
            );
            await tester.tap(key('planned-day'));
            await tester.pumpAndSettle();
            await inputDate('2026/10/28', 'final-date');
          }
          await expose(
            key('goal-date-confirm'),
            'date-confirm',
            text: '确定',
            picture: true,
          );
          final semantics = tester
              .getSemantics(key('goal-date-confirm'))
              .getSemanticsData();
          expect(semantics.flagsCollection.isButton, isTrue);
          expect(semantics.hasAction(ui.SemanticsAction.tap), isTrue);
          await tester.tap(key('goal-date-confirm'));
        } else {
          expect(find.byType(DatePickerDialog), findsOneWidget);
          await expose(find.text('28').last, 'calendar-day', text: '28');
          await tester.tap(find.text('28').last);
          await tester.pumpAndSettle();
          await tester.tap(
            find.descendant(
              of: find.byType(DatePickerDialog),
              matching: find.widgetWithText(TextButton, '取消'),
            ),
          );
          await tester.pumpAndSettle();
          await expose(
            key('planned-day'),
            'date-after-cancel',
            text: '2026年10月27日',
          );
          await tester.tap(key('planned-day'));
          await tester.pumpAndSettle();
          await tester.tap(find.byIcon(Icons.edit_outlined));
          await tester.pumpAndSettle();
          await inputDate('2026/02/30', 'calendar-invalid');
          await tester.tap(find.widgetWithText(TextButton, '确定'));
          await tester.pumpAndSettle();
          final invalid = MaterialLocalizations.of(tester.element(dateField))
              .invalidDateFormatLabel;
          await expose(
            find.text(invalid),
            'calendar-invalid-error',
            text: invalid,
            picture: true,
          );
          await inputDate('2026/10/28', 'calendar-corrected');
          await tester.tap(find.widgetWithText(TextButton, '确定'));
        }
        await tester.pumpAndSettle();
        if (keyboard) {
          tester.view.viewInsets = const FakeViewPadding();
          await tester.pumpAndSettle();
        }
        await expose(
          key('planned-day'),
          'date-selected',
          text: _date,
          picture: true,
        );
        await expose(key('reminder-toggle'), 'reminder-off', text: '提醒');
        expect(
          tester.widget<SwitchListTile>(key('reminder-toggle')).value,
          isFalse,
        );
        if (keyboard) {
          expect(issues, isEmpty);
          expect(tester.takeException(), isNull);
          complete = true;
          return;
        }
        if (!narrow) {
          await h.database.customStatement(
            "CREATE TRIGGER fail_r17 BEFORE INSERT ON goals "
            "BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END",
          );
          await expose(key('save-goal'), 'failed-save');
          await tester.tap(key('save-goal'));
          await tester.pumpAndSettle();
          const saveError = '未能保存，请重试。原有记录未被清空。';
          expect(find.text(saveError), findsOneWidget);
          await record('save-failed');
          await expose(key('goal-title'), 'failed-save-name');
          await tester.enterText(key('goal-title'), '');
          await tester.pumpAndSettle();
          expect(find.text(_validation), findsOneWidget);
          await tester.enterText(key('goal-title'), _title);
          tester.testTextInput.hide();
          await tester.pumpAndSettle();
          expect(find.text(_validation), findsNothing);
          expect(find.text(saveError), findsOneWidget);
          await record('field-corrected-save-error-retained');
          await h.database.customStatement('DROP TRIGGER fail_r17');
        }
        await expose(
          key('save-goal'),
          'final-save-aligned',
          text: '保存',
          picture: true,
        );
        await tester.tap(key('save-goal'));
        await tester.tap(key('save-goal'));
        await tester.pumpAndSettle();
        final goals = await h.repository.loadGoals();
        expect(goals, hasLength(2));
        final saved = goals.singleWhere((g) => g.id != goal);
        created = saved.id;
        expect(saved.titleOn(h.clock.day), _title);
        expect(saved.kind, GoalKind.single);
        expect(
          saved.scheduleOn(h.clock.day).plannedDay,
          h.clock.day.addDays(1),
        );
        expect(saved.scheduleOn(h.clock.day).startMinute, isNull);
        expect(saved.scheduleOn(h.clock.day).durationMinutes, isNull);
        expect(saved.reminder.enabled, isFalse);
        expect(saved.reminder.minuteOfDay, 1200);
        expect(saved.reminder.status, 'disabled');
        await record('saved-today');
        await openMenu(tester, '目标管理');
        await expose(
          key('detail-${saved.id}'),
          'found-management',
          text: _title,
          picture: true,
        );
        await tester.tap(key('detail-${saved.id}'));
        await tester.pumpAndSettle();
        await record('found-detail-initial', picture: true);
        expect(find.text(_title), findsWidgets);
        if (narrow) {
          h.clock.setDay(2026, 10, 29, hour: 17);
          await tapVisible(tester, key('edit-goal'));
          await tapVisible(tester, key('planned-day'));
          expect(
            tester.widget<TextFormField>(dateField).controller!.text,
            '2026/10/29',
          );
          await candidate(2026, 10, 29, 'overdue-clamped');
          await tapVisible(tester, key('goal-date-cancel'));
          expect(find.text(_date), findsOneWidget);
          expect(
            (await h.repository.loadGoals())
                .singleWhere((g) => g.id == created)
                .scheduleOn(h.clock.day)
                .plannedDay!
                .key,
            '2026-10-28',
          );
          await record('overdue-cancel-preserved');
        }
        expect(h.container.exists(assistantServiceProvider), isFalse);
        expect(h.container.exists(pairingControllerProvider), isFalse);
        expect(h.container.exists(chatControllerProvider), isFalse);
        expect(tester.takeException(), isNull);
        complete = true;
        expect(
          issues,
          isEmpty,
          reason: 'Full text must remain readable at the original scale',
        );
      } finally {
        semantics.dispose();
        debugDefaultTargetPlatformOverride = null;
        if (captureDirectory.isNotEmpty) {
          await tester.runAsync(() async {
            final file = File('$captureDirectory/$label.json');
            expect(file.existsSync(), isFalse);
            await file.writeAsString(
              const JsonEncoder.withIndent('  ').convert({
                'baseline': _baseline,
                'productSource': _product,
                'testSource': _testSource,
                'purpose': keyboard
                    ? 'injected-keyboard-date'
                    : 'name-date-create-recovery',
                'source': _source,
                'sourceSha256': sha256
                    .convert(File(_source).readAsBytesSync())
                    .toString(),
                'font': captureFont,
                'fontSha256': captureFont.isEmpty
                    ? null
                    : sha256
                          .convert(File(captureFont).readAsBytesSync())
                          .toString(),
                'runtime': {
                  for (final f in [
                    'lib/features/goals/presentation/goal_form_page.dart',
                    'lib/features/goals/presentation/goal_date_picker.dart',
                    'lib/features/goals/presentation/today_view.dart',
                    'lib/shared/presentation.dart',
                    'lib/data/local/local_goal_repository.dart',
                  ])
                    f: sha256.convert(File(f).readAsBytesSync()).toString(),
                },
                'label': label,
                'size': [size.width, size.height],
                'scale': narrow ? 4 : 1,
                'platform': 'iOS-target widget',
                'keyboard': keyboard ? 200 : 0,
                'dpr': 1,
                'completedJourney': complete,
                'lastPhase': phase,
                'issues': issues.toList(),
                'fixture': before,
                'photoFixture': photoBefore,
                'created': created,
                'states': states,
                'geometry': geometry,
                'images': images,
                'aiCalls': ai.calls.length,
                'pickerCalls': picker.calls,
                'permissions': h.permissions.requests,
                'scheduled': h.notifications.scheduled,
              }),
            );
          });
        }
      }
    });
  }
}
