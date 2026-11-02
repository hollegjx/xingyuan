import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/app/theme.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:habit_checkin/features/journal/domain/journal_entry.dart';
import 'package:habit_checkin/features/journal/journal_providers.dart';
import 'package:habit_checkin/shared/ui/sparkle.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'journal_diary_capture_test.dart' as pixels;
import 'support/journal_fixtures.dart';
import 'support/record_fixtures.dart';
import 'support/ui_harness.dart';
import 'today_c49_test.dart' show viewport;

Finder key(String value) => find.byKey(ValueKey(value));

void checkWeek(WidgetTester tester, int count) {
  final card = key('goal-recent-week');
  expect(card, findsOneWidget);
  expect(
    find.descendant(
      of: card,
      matching: find.text(count == 0 ? '最近 7 天还没有点亮' : '最近 7 天点亮了 $count 次'),
    ),
    findsOneWidget,
  );
  final stars = tester.widgetList<StarMark>(
    find.descendant(of: card, matching: find.byType(StarMark)),
  );
  expect(stars, hasLength(7));
  expect(stars.where((star) => star.lit), hasLength(count));
  expect(find.descendant(of: card, matching: find.text('今')), findsOneWidget);
  expect(find.text('每天'), findsOneWidget);
}

Future<void> mount(WidgetTester tester, UiHarness app, GlobalKey boundary) =>
    app.mount(
      tester,
      journalPhotoFiles: {
        for (final kind in JournalKind.values)
          kind: MemoryJournalPhotoFiles(kind),
      },
      recordPhotoFiles: MemoryRecordPhotoFiles(),
      recordPhotoPicker: StubRecordPhotoPicker(),
      wrapApp: (child) => RepaintBoundary(key: boundary, child: child),
    );

void main() {
  setUpAll(() async {
    tzdata.initializeTimeZones();
    await pixels.loadDiaryCaptureFont();
  });

  testUiWidgets('C64 zero recent completions and single exclusion', (
    tester,
  ) async {
    final app = UiHarness()..clock.setDay(2026, 11, 1);
    final habit = await app.repository.create(
      const GoalDraft(title: '测试习惯', kind: GoalKind.habit),
    );
    final single = await app.repository.create(
      GoalDraft(
        title: '测试任务',
        kind: GoalKind.single,
        plannedDay: app.clock.day,
      ),
    );
    await mount(tester, app, GlobalKey());
    await tapVisible(tester, key('detail-$habit'));
    checkWeek(tester, 0);
    await goBack(tester);
    await tapVisible(tester, key('detail-$single'));
    expect(key('goal-recent-week'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 3.5]) {
      testUiWidgets('C64 detail and lists ${brightness.name} $scale', (
        tester,
      ) async {
        viewport(tester, brightness, scale);
        final app = UiHarness()..clock.setDay(2026, 10, 24);
        final habit = await app.repository.create(
          const GoalDraft(title: '测试阅读', kind: GoalKind.habit),
        );
        // The first completion is outside the last seven days and must not count.
        for (final day in [24, 26, 29, 31]) {
          app.clock.setDay(2026, 10, day);
          await app.repository.setCompleted(
            habit,
            true,
            expectedDay: app.clock.day,
          );
        }
        app.clock.setDay(2026, 11, 1);
        final boundary = GlobalKey();
        await mount(tester, app, boundary);
        Future<void> shot(String page, Finder anchor, String value) async {
          if (pixels.captureFont.isEmpty) return;
          await pixels.capture(
            tester,
            boundary,
            'c64-$page-${brightness.name}-$scale',
            const Size(320, 568),
            text: anchor,
            expectedText: value,
            firstLineOnly: true,
          );
        }

        await tapVisible(tester, key('detail-$habit'));
        checkWeek(tester, 3);
        await shot('detail', find.text('测试阅读'), '测试阅读');
        final today = find.descendant(
          of: key('goal-recent-week'),
          matching: find.text('今'),
        );
        final paragraph = tester.renderObject<RenderParagraph>(
          find.descendant(of: today, matching: find.byType(RichText)),
        );
        final todayClipped = paragraph.didExceedMaxLines;
        final todayWidth = paragraph.size.width;
        await tester.ensureVisible(key('goal-recent-week'));
        await tester.pumpAndSettle();
        await shot('week', find.text('最近 7 天点亮了 3 次'), '最近 7 天点亮了 3 次');
        await goBack(tester);
        await tapVisible(tester, find.byTooltip('我的'));

        for (final diary in [false, true]) {
          await tapVisible(tester, key(diary ? 'my-diary' : 'my-quick-notes'));
          final empty = diary ? '还没有日记。点右上角，写下第一篇。' : '还没有随手记。想到什么，就记一笔。';
          expect(find.text(empty), findsOneWidget);
          await goBack(tester);
          if (diary) {
            await tapVisible(tester, find.byTooltip('今天'));
            await tapVisible(tester, key('entry-diary'));
            await tester.enterText(key('journal-text'), '测试日记：今天读了一章，想再读一遍。');
            await tester.pumpAndSettle();
            await tapVisible(tester, key('save-journal'));
            await tapVisible(tester, find.byTooltip('我的'));
          } else {
            final store = await app.container.read(
              quickNoteStoreProvider.future,
            );
            await saveJournalNotes(store, ['测试随手记：慢慢读，不着急。']);
            await tester.pumpAndSettle();
          }
          await tapVisible(tester, key(diary ? 'my-diary' : 'my-quick-notes'));
          final body = diary ? '测试日记：今天读了一章，想再读一遍。' : '测试随手记：慢慢读，不着急。';
          final preview = tester.widget<Text>(find.text(body));
          expect(preview.style!.fontFamily, xySerif);
          expect(preview.style!.height, 1.7);
          await shot(
            diary ? 'diary-list' : 'note-list',
            find.text(diary ? '日记本' : '随手记'),
            diary ? '日记本' : '随手记',
          );
          await goBack(tester);
        }
        expect(tester.takeException(), isNull);
        expect(
          todayClipped,
          isFalse,
          reason:
              'Today label clipped at 320px / $scale with width $todayWidth',
        );
        expect(app.permissions.requests, 0);
        expect(app.notifications.requests, isEmpty);
      });
    }
  }
}
