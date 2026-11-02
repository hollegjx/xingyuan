import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/app/theme.dart';
import 'package:habit_checkin/shared/ui/today_sky.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:habit_checkin/features/goals/presentation/goal_tile.dart';
import 'package:habit_checkin/features/records/data/local_day_record_store.dart';
import 'package:habit_checkin/features/records/presentation/day_record_page.dart';
import 'package:habit_checkin/features/records/presentation/day_record_preview.dart';
import 'package:habit_checkin/features/records/record_providers.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'journal_diary_capture_test.dart' as pixels;
import 'support/record_fixtures.dart';
import 'support/ui_harness.dart';

void viewport(WidgetTester tester, Brightness brightness, double scale) {
  tester.view.physicalSize = const Size(320, 568);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.platformBrightnessTestValue = brightness;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

void main() {
  setUpAll(() async {
    tzdata.initializeTimeZones();
    await pixels.loadDiaryCaptureFont();
  });
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0, 3.5]) {
      testUiWidgets('C49 unique record journey ${brightness.name} ${scale}x', (
        tester,
      ) async {
        viewport(tester, brightness, scale);
        final app = UiHarness()..clock.setDay(2026, 10, 31);
        final goal = await app.repository.create(
          const GoalDraft(title: '测试阅读', kind: GoalKind.habit),
        );
        final boundary = GlobalKey();
        await app.mount(
          tester,
          recordPhotoFiles: MemoryRecordPhotoFiles(),
          wrapApp: (child) => RepaintBoundary(key: boundary, child: child),
        );
        final record = find.byKey(
          ValueKey('record-$goal-${app.clock.day.key}'),
        );
        final tile = find.byWidgetPredicate(
          (widget) => widget is GoalTile && widget.view.goal.id == goal,
        );
        final detail = find.byKey(ValueKey('detail-$goal'));
        final title = find.descendant(of: tile, matching: find.text('测试阅读'));
        Future<void> shot(String state, Finder text, String value) async {
          if (pixels.captureFont.isEmpty) return;
          await tester.ensureVisible(text);
          await tester.pumpAndSettle();
          await pixels.capture(
            tester,
            boundary,
            'c49-${brightness.name}-$scale-$state',
            const Size(320, 568),
            text: text,
            expectedText: value,
          );
        }

        expect(record, findsOneWidget);
        expect(tester.widget(record), isA<IconButton>());
        expect(tester.widget<IconButton>(record).tooltip, '写记录');
        expect(
          tester.widget<IconButton>(record).color,
          tester.element(record).xy.faint,
        );
        await tester.ensureVisible(record);
        await tester.pumpAndSettle();
        final pencilRect = tester.getRect(record);
        final detailRect = tester.getRect(detail);
        expect(pencilRect.width, greaterThanOrEqualTo(44));
        expect(pencilRect.height, greaterThanOrEqualTo(44));
        expect(pencilRect.right, lessThanOrEqualTo(detailRect.left));
        expect(pencilRect.top, closeTo(detailRect.top, .01));
        expect(
          find.descendant(of: tile, matching: find.text('写记录')),
          findsNothing,
        );
        expect(
          await app.database.select(app.database.dayRecords).get(),
          isEmpty,
        );
        await shot('empty', title, '测试阅读');

        await tapVisible(tester, record);
        expect(find.byType(DayRecordPage), findsOneWidget);
        const content = '测试记录';
        await tester.enterText(
          find.byKey(const ValueKey('record-text')),
          content,
        );
        await goBack(tester);
        expect(record, findsOneWidget);
        expect(tester.widget(record), isA<InkWell>());
        expect(find.byTooltip('写记录'), findsNothing);
        final draft =
            (await app.database.select(app.database.dayRecords).get()).single;
        expect(draft.draftText, content);
        expect(draft.savedAt, isNull);
        await shot('draft', find.text('有未保存草稿'), '有未保存草稿');

        await tapVisible(tester, record);
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('record-text')))
              .controller!
              .text,
          content,
        );
        await tapVisible(tester, find.byKey(const ValueKey('save-record')));
        expect(record, findsOneWidget);
        expect(find.byTooltip('写记录'), findsNothing);
        expect(find.text(content), findsOneWidget);
        expect(await app.database.select(app.database.checkIns).get(), isEmpty);
        await shot('saved', find.text(content), content);
        await tapVisible(tester, find.byKey(ValueKey('complete-$goal')));
        expect(find.text('已点亮 1 颗星'), findsOneWidget);
        // C67 replaces the progress ring with the constellation sky.
        final progress = tester.widget<TodaySky>(find.byType(TodaySky));
        expect(progress.done, 1);
        expect(progress.total, 1);
        await tapVisible(tester, find.byKey(ValueKey('undo-$goal')));
        expect(find.text(content), findsOneWidget);

        await tapVisible(tester, record);
        await tapVisible(tester, find.byKey(const ValueKey('delete-record')));
        await tapVisible(tester, find.text('取消'));
        expect(
          (await app.database.select(app.database.dayRecords).get())
              .single
              .content,
          content,
        );
        await tapVisible(tester, find.byKey(const ValueKey('delete-record')));
        await tapVisible(
          tester,
          find.byKey(const ValueKey('confirm-delete-record')),
        );
        expect(record, findsOneWidget);
        expect(tester.widget(record), isA<IconButton>());
        expect(find.text(content), findsNothing);
        expect(
          (await app.repository.loadGoals()).single.titleOn(app.clock.day),
          '测试阅读',
        );
        expect(
          (await app.database.select(app.database.checkIns).get()).every(
            (row) => !row.completed,
          ),
          isTrue,
        );
        expect(app.permissions.requests, 0);
        expect(app.notifications.requests, isEmpty);
        expect(tester.takeException(), isNull);
      });
    }

    testUiWidgets('C61 writing entries ${brightness.name}', (tester) async {
      viewport(tester, brightness, 1);
      final app = UiHarness();
      final boundary = GlobalKey();
      await app.mount(
        tester,
        wrapApp: (child) => RepaintBoundary(key: boundary, child: child),
      );
      final summary = find.byKey(const ValueKey('today-summary'));
      final decoration =
          tester.widget<DecoratedBox>(summary).decoration as BoxDecoration;
      expect(decoration.shape, BoxShape.rectangle);
      expect(decoration.color, tester.element(summary).xy.card);
      expect(decoration.gradient, isNull);
      expect(decoration.boxShadow, isNull);
      for (final key in ['entry-quick-note', 'entry-diary', 'entry-new-goal']) {
        expect(find.byKey(ValueKey(key)), findsOneWidget);
      }
      expect(find.byKey(const ValueKey('entry-check-in')), findsNothing);
      expect(find.byType(TodaySky), findsOneWidget);
      if (pixels.captureFont.isNotEmpty) {
        await pixels.capture(
          tester,
          boundary,
          'c49-${brightness.name}-home',
          const Size(320, 568),
          text: find.byKey(const ValueKey('today-count')),
          expectedText: '已点亮 0 颗星',
        );
      }
      await tapVisible(tester, find.byKey(const ValueKey('entry-new-goal')));
      expect(find.byKey(const ValueKey('goal-title')), findsOneWidget);
      expect(await app.repository.loadGoals(), isEmpty);
      expect(tester.takeException(), isNull);
    });

    testUiWidgets('C49 loading and one retry ${brightness.name}', (
      tester,
    ) async {
      viewport(tester, brightness, 1);
      final app = UiHarness();
      final goal = await app.repository.create(
        const GoalDraft(title: 'TEST retry', kind: GoalKind.habit),
      );
      await app.mount(tester, recordPhotoFiles: MemoryRecordPhotoFiles());
      final value = (await app.repository.loadGoals()).single.dayView(
        app.clock.day,
        today: app.clock.day,
      );
      final stream = StreamController<List<DayRecordSnapshot>>();
      addTearDown(() {
        // Widget teardown cancels the listener; do not await a fake-clock event.
        unawaited(stream.close());
      });
      var reads = 0;
      final context = tester.element(find.byType(GoalTile));
      unawaited(
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => ProviderScope(
              overrides: [
                dayRecordsProvider(app.clock.day).overrideWith((ref) {
                  reads++;
                  return reads == 1
                      ? stream.stream
                      : Stream.value(<DayRecordSnapshot>[]);
                }),
              ],
              child: Scaffold(
                body: GoalTile(view: value, interactive: true, onOpen: () {}),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final record = find.byKey(ValueKey('record-$goal-${app.clock.day.key}'));
      expect(record, findsNothing);
      expect(find.byType(DayRecordPreview), findsNWidgets(2));
      expect(reads, 1);
      stream.addError(StateError('SYNTHETIC read failure'));
      await tester.pumpAndSettle();
      expect(record, findsNothing);
      expect(find.text('记录读取失败，重试'), findsOneWidget);
      await tapVisible(tester, find.text('记录读取失败，重试'));
      expect(reads, 2);
      expect(record, findsOneWidget);
      expect(tester.widget(record), isA<IconButton>());
      expect(find.text('记录读取失败，重试'), findsNothing);
      expect(await app.database.select(app.database.dayRecords).get(), isEmpty);
      expect(await app.database.select(app.database.checkIns).get(), isEmpty);
      expect(tester.takeException(), isNull);
    });
  }
}
