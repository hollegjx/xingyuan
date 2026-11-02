import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:habit_checkin/features/goals/presentation/goal_management_page.dart';
import 'package:habit_checkin/features/goals/presentation/goal_tile.dart';
import 'package:habit_checkin/features/journal/domain/journal_entry.dart';
import 'package:habit_checkin/features/journal/presentation/journal_list_page.dart';
import 'package:habit_checkin/features/journal/presentation/journal_style.dart';
import 'package:habit_checkin/shared/presentation.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'journal_diary_capture_test.dart' as pixels;
import 'support/ui_harness.dart';

void main() {
  setUpAll(() async {
    tzdata.initializeTimeZones();
    await pixels.loadDiaryCaptureFont();
  });
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 3.5]) {
      testUiWidgets('C45 review date scope ${brightness.name} $scale', (
        tester,
      ) async {
        _viewport(tester, brightness, scale);
        final app = UiHarness()..clock.setDay(2026, 10, 7);
        final timed = await app.repository.create(
          GoalDraft(
            title: 'TEST 定时阅读',
            kind: GoalKind.single,
            plannedDay: app.clock.day,
            startMinute: 1200,
            durationMinutes: 45,
          ),
        );
        final untimed = await app.repository.create(
          GoalDraft(
            title: 'TEST 随时整理',
            kind: GoalKind.single,
            plannedDay: app.clock.day,
          ),
        );
        final duration = await app.repository.create(
          GoalDraft(
            title: 'TEST 练习',
            kind: GoalKind.single,
            plannedDay: app.clock.day,
            durationMinutes: 30,
          ),
        );
        final habit = await app.repository.create(
          const GoalDraft(title: 'TEST 习惯', kind: GoalKind.habit),
        );
        app.clock.setDay(2026, 10, 9);
        await app.repository.setCompleted(
          timed,
          true,
          expectedDay: app.clock.day,
        );
        final boundary = GlobalKey();
        await app.mount(
          tester,
          wrapApp: (child) => RepaintBoundary(key: boundary, child: child),
        );
        await tapVisible(tester, find.byTooltip('回顾'));
        Finder tile(int id) => find.byWidgetPredicate(
          (widget) => widget is GoalTile && widget.view.goal.id == id,
        );
        Finder text(int id, String value) =>
            find.descendant(of: tile(id), matching: find.text(value));
        expect(text(timed, '计划 2026年10月7日 · 20:00 · 45 分钟'), findsOneWidget);
        expect(text(untimed, '计划 2026年10月7日'), findsOneWidget);
        expect(text(habit, '每天'), findsOneWidget);
        await tapVisible(
          tester,
          find.byKey(const ValueKey('review-day-2026-10-07')),
        );
        expect(text(timed, '20:00 · 45 分钟'), findsOneWidget);
        expect(text(untimed, '单次'), findsOneWidget);
        expect(text(duration, '30 分钟'), findsOneWidget);
        expect(text(habit, '每天'), findsOneWidget);
        for (final id in [timed, untimed, duration, habit]) {
          expect(find.byKey(ValueKey('complete-$id')), findsNothing);
          expect(find.byKey(ValueKey('undo-$id')), findsNothing);
        }
        await tester.ensureVisible(text(untimed, '单次'));
        await tester.pumpAndSettle();
        if (pixels.captureFont.isNotEmpty) {
          await pixels.capture(
            tester,
            boundary,
            'c45-review-${brightness.name}-$scale',
            const Size(320, 568),
            text: text(untimed, '单次'),
            expectedText: '单次',
          );
        }
        final goals = await app.repository.loadGoals();
        expect(
          goals.singleWhere((goal) => goal.id == timed).singleCompletion!.day,
          app.clock.day,
        );
        expect(
          goals.where((goal) => goal.completions.isNotEmpty),
          hasLength(1),
        );
        expect(app.permissions.requests, 0);
        expect(tester.takeException(), isNull);
      });
    }
    testUiWidgets('C45 primary accents and destinations ${brightness.name}', (
      tester,
    ) async {
      _viewport(tester, brightness, 1);
      final app = UiHarness();
      final boundary = GlobalKey();
      await app.mount(
        tester,
        wrapApp: (child) => RepaintBoundary(key: boundary, child: child),
      );
      await tapVisible(tester, find.byTooltip('我的'));
      for (final key in ['my-goals', 'my-diary', 'my-quick-notes']) {
        final row = find.byKey(ValueKey(key));
        final context = tester.element(row);
        final primary = Theme.of(context).colorScheme.primary;
        expect(journalNoteTint(context), primary);
        expect(
          tester
              .widget<XyIconTile>(
                find.descendant(of: row, matching: find.byType(XyIconTile)),
              )
              .color,
          primary,
        );
      }
      if (pixels.captureFont.isNotEmpty) {
        await pixels.capture(
          tester,
          boundary,
          'c45-my-${brightness.name}',
          const Size(320, 568),
          text: find.text('目标管理'),
          expectedText: '目标管理',
        );
      }
      await tapVisible(tester, find.byKey(const ValueKey('my-goals')));
      expect(find.byType(GoalManagementPage), findsOneWidget);
      await goBack(tester);
      await tapVisible(tester, find.byKey(const ValueKey('my-quick-notes')));
      expect(
        tester.widget<JournalListPage>(find.byType(JournalListPage)).kind,
        JournalKind.quickNote,
      );
      expect(await app.repository.loadGoals(), isEmpty);
      expect(app.permissions.requests, 0);
      expect(tester.takeException(), isNull);
    });
  }
}

void _viewport(WidgetTester tester, Brightness brightness, double scale) {
  tester.view.physicalSize = const Size(320, 568);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.platformBrightnessTestValue = brightness;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}
