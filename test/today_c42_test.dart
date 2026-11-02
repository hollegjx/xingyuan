import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:habit_checkin/features/goals/presentation/goal_tile.dart';
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
      testUiWidgets('C42 today scope ${brightness.name} ${scale}x', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.platformBrightnessTestValue = brightness;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final app = UiHarness()..clock.setDay(2026, 10, 8);
        final overdue = await app.repository.create(
          GoalDraft(
            title: 'TEST overdue',
            kind: GoalKind.single,
            plannedDay: app.clock.day,
            startMinute: 1200,
            durationMinutes: 45,
          ),
        );
        app.clock.setDay(2026, 10, 9);
        final timed = await app.repository.create(
          GoalDraft(
            title: 'TEST 今天阅读',
            kind: GoalKind.single,
            plannedDay: app.clock.day,
            startMinute: 1200,
            durationMinutes: 45,
          ),
        );
        final untimed = await app.repository.create(
          GoalDraft(
            title: 'TEST untimed',
            kind: GoalKind.single,
            plannedDay: app.clock.day,
          ),
        );
        final minutes = await app.repository.create(
          GoalDraft(
            title: 'TEST duration',
            kind: GoalKind.single,
            plannedDay: app.clock.day,
            durationMinutes: 30,
          ),
        );
        final habit = await app.repository.create(
          const GoalDraft(title: 'TEST habit', kind: GoalKind.habit),
        );
        final boundary = GlobalKey();
        await app.mount(
          tester,
          wrapApp: (child) => RepaintBoundary(key: boundary, child: child),
        );
        Finder tile(int id) => find.byWidgetPredicate(
          (widget) => widget is GoalTile && widget.view.goal.id == id,
        );
        Finder text(int id, String value) =>
            find.descendant(of: tile(id), matching: find.text(value));
        expect(text(timed, '20:00 · 45 分钟'), findsOneWidget);
        expect(text(untimed, '今天'), findsOneWidget);
        expect(text(minutes, '30 分钟'), findsOneWidget);
        expect(text(overdue, '计划 2026年10月8日 · 20:00 · 45 分钟'), findsOneWidget);
        expect(text(overdue, '已逾期，仍可完成'), findsOneWidget);
        expect(text(habit, '每天'), findsOneWidget);
        expect(find.text('等待点亮 · 5'), findsOneWidget);

        final heading = find.text('今天的目标');
        await tester.ensureVisible(heading);
        await tester.pumpAndSettle();
        if (pixels.captureFont.isNotEmpty) {
          await pixels.capture(
            tester,
            boundary,
            'c42-today-${brightness.name}-$scale',
            const Size(320, 568),
            text: heading,
            expectedText: '今天的目标',
          );
        }
        await tapVisible(tester, find.byKey(ValueKey('complete-$timed')));
        expect(find.text('等待点亮 · 4'), findsOneWidget);
        expect(find.text('已点亮 · 1'), findsOneWidget);
        final goals = await app.repository.loadGoals();
        expect(
          goals.where((goal) => goal.completions.isNotEmpty),
          hasLength(1),
        );
        final goal = goals.singleWhere((goal) => goal.id == timed);
        unawaited(
          Navigator.of(tester.element(tile(timed))).push(
            MaterialPageRoute<void>(
              builder: (_) => Scaffold(
                body: SingleChildScrollView(
                  child: GoalTile(
                    view: goal.dayView(app.clock.day, today: app.clock.day),
                    onOpen: () {},
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          text(timed, scheduleLabel(goal.kind, goal.scheduleOn(app.clock.day))),
          findsOneWidget,
        );
        expect(find.byKey(ValueKey('undo-$timed')), findsNothing);
        expect(app.permissions.requests, 0);
        expect(app.notifications.requests, isEmpty);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
