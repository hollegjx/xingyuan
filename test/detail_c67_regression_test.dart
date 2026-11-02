import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/app/providers.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:habit_checkin/shared/local_date.dart';
import 'package:habit_checkin/shared/presentation.dart';
import 'package:habit_checkin/shared/ui/sparkle.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'journal_diary_capture_test.dart' show loadDiaryCaptureFont;
import 'support/record_fixtures.dart';
import 'support/ui_harness.dart';
import 'today_c49_test.dart' show viewport;

Finder key(String value) => find.byKey(ValueKey(value));

void fullText(WidgetTester tester, Finder finder) {
  expect(finder, findsOneWidget);
  final p = tester.renderObject<RenderParagraph>(
    find.descendant(of: finder, matching: find.byType(RichText)),
  );
  expect(p.didExceedMaxLines, isFalse);
  final painter = TextPainter(
    text: p.text,
    textDirection: p.textDirection,
    textScaler: p.textScaler,
  )..layout(maxWidth: p.size.width);
  expect(p.size.height, closeTo(painter.height, .01));
  painter.dispose();
  final text = p.text.toPlainText();
  for (var i = 0; i < text.length; i++) {
    if (text[i].trim().isEmpty) continue;
    final boxes = p.getBoxesForSelection(
      TextSelection(baseOffset: i, extentOffset: i + 1),
    );
    expect(boxes, isNotEmpty);
    for (final box in boxes) {
      expect(box.left, greaterThanOrEqualTo(-.01));
      expect(box.right, lessThanOrEqualTo(p.size.width + .01));
      expect(box.bottom, lessThanOrEqualTo(p.size.height + .01));
    }
  }
}

void week(WidgetTester tester, List<LocalDate> days, Set<LocalDate> completed) {
  final card = key('goal-recent-week');
  expect(card, findsOneWidget);
  final stars = tester
      .widgetList<StarMark>(
        find.descendant(of: card, matching: find.byType(StarMark)),
      )
      .toList();
  expect(stars.map((s) => s.lit), days.map(completed.contains));
  final labels = tester
      .widgetList<Semantics>(
        find.descendant(of: card, matching: find.byType(Semantics)),
      )
      .where((s) => s.properties.label != null)
      .toList();
  expect(labels.map((s) => s.properties.label), [
    for (final day in days)
      '${dateLabel(day)}${completed.contains(day) ? '，已点亮' : ''}',
  ]);
  expect(labels.every((s) => s.excludeSemantics), isTrue);
  for (final element
      in find.descendant(of: card, matching: find.byType(Text)).evaluate()) {
    fullText(tester, find.byWidget(element.widget));
  }
  final current = tester.widget<Text>(
    find.descendant(of: card, matching: find.text('今')),
  );
  expect(current.style!.fontWeight, FontWeight.w700);
  expect(
    current.style!.color,
    Theme.of(tester.element(card)).colorScheme.primary,
  );
}

void main() {
  setUpAll(() async {
    tzdata.initializeTimeZones();
    await loadDiaryCaptureFont();
  });
  for (final brightness in Brightness.values) {
    testUiWidgets(
      'AI1 year boundary, isolation, undo, rollover ${brightness.name}',
      (tester) async {
        viewport(tester, brightness, 3.5);
        final app = UiHarness()..clock.setDay(2026, 12, 25);
        final target = await app.repository.create(
          const GoalDraft(title: '测试跨年记录', kind: GoalKind.habit),
        );
        final other = await app.repository.create(
          const GoalDraft(title: '测试另一目标', kind: GoalKind.habit),
        );
        for (var offset = 0; offset <= 7; offset++) {
          final day = LocalDate(2026, 12, 25).addDays(offset);
          app.clock.setDay(day.year, day.month, day.day);
          await app.repository.setCompleted(other, true, expectedDay: day);
          if ([0, 1, 6, 7].contains(offset)) {
            await app.repository.setCompleted(target, true, expectedDay: day);
          }
        }
        await app.mount(tester, recordPhotoFiles: MemoryRecordPhotoFiles());
        await tapVisible(tester, key('detail-$target'));
        final days = [
          for (var i = 0; i < 7; i++) LocalDate(2026, 12, 26).addDays(i),
        ];
        final done = {
          LocalDate(2026, 12, 26),
          LocalDate(2026, 12, 31),
          LocalDate(2027, 1, 1),
        };
        week(tester, days, done);
        expect(find.text('最近 7 天点亮了 3 次'), findsOneWidget);
        expect(find.text('每天'), findsOneWidget);
        await app.repository.setCompleted(
          target,
          false,
          expectedDay: app.clock.day,
        );
        await tester.pumpAndSettle();
        done.remove(LocalDate(2027, 1, 1));
        week(tester, days, done);
        expect(find.text('最近 7 天点亮了 2 次'), findsOneWidget);
        app.clock.setDay(2027, 1, 2);
        await app.container.read(environmentProvider.notifier).refresh();
        await tester.pumpAndSettle();
        week(
          tester,
          [for (final day in days) day.addDays(1)],
          {LocalDate(2026, 12, 31)},
        );
        expect(find.text('最近 7 天点亮了 1 次'), findsOneWidget);
        tester.platformDispatcher.textScaleFactorTestValue = 1;
        await tester.pumpAndSettle();
        week(
          tester,
          [for (final day in days) day.addDays(1)],
          {LocalDate(2026, 12, 31)},
        );
        final goals = await app.repository.loadGoals();
        expect(
          goals.singleWhere((g) => g.id == other).completions,
          hasLength(8),
        );
        final targetGoal = goals.singleWhere((g) => g.id == target);
        expect(targetGoal.completions, hasLength(4));
        expect(
          targetGoal.completions
              .where((entry) => entry.completed)
              .map((entry) => entry.day),
          unorderedEquals([
            LocalDate(2026, 12, 25),
            LocalDate(2026, 12, 26),
            LocalDate(2026, 12, 31),
          ]),
        );
        expect(
          targetGoal.completions
              .where((entry) => !entry.completed)
              .map((entry) => entry.day),
          [LocalDate(2027, 1, 1)],
        );
        expect(targetGoal.completionOn(LocalDate(2027, 1, 1)), isNull);
        expect(
          goals
              .singleWhere((g) => g.id == other)
              .completions
              .every((entry) => entry.completed),
          isTrue,
        );
        expect(app.permissions.requests, 0);
        expect(app.notifications.requests, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );

    testUiWidgets(
      'AI1 reminder explanation and denied save ${brightness.name}',
      (tester) async {
        viewport(tester, brightness, 3.5);
        final app = UiHarness();
        await app.mount(tester);
        await tapVisible(tester, key('entry-new-goal'));
        await tester.enterText(key('goal-title'), '测试提醒拒绝');
        const footer = '提醒会提前排好。很久不打开星愿，排好的提醒可能会用完；打开一次就会补上。';
        expect(find.text(footer), findsNothing);
        final tile = tester.widget<SwitchListTile>(key('reminder-toggle'));
        expect(tile.value, isFalse);
        final icons = find.descendant(
          of: key('reminder-toggle'),
          matching: find.byIcon(CupertinoIcons.bell),
        );
        expect(icons, findsOneWidget);
        expect(
          find.descendant(
            of: key('reminder-toggle'),
            matching: find.byIcon(CupertinoIcons.bell_fill),
          ),
          findsNothing,
        );
        await tapVisible(tester, key('reminder-toggle'));
        fullText(tester, find.text(footer));
        expect(app.permissions.requests, 0);
        await tapVisible(tester, key('save-goal'));
        final goal = (await app.repository.loadGoals()).single;
        expect(goal.titleOn(app.clock.day), '测试提醒拒绝');
        expect(app.permissions.requests, 1);
        expect(app.notifications.requests, isEmpty);
        expect(app.permissions.settingsOpens, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
