import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'support/ui_harness.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);

  for (final scale in [1.0, 2.0, 3.0]) {
    testUiWidgets(
      'manual timing can be entered and cleared at 320px / ${scale}x text',
      (tester) async {
        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final app = UiHarness();
        await app.mount(tester);
        await tapVisible(tester, find.byKey(const ValueKey('entry-new-goal')));
        await tester.enterText(
          find.byKey(const ValueKey('goal-title')),
          'TEST 时间',
        );
        await tapVisible(tester, find.byKey(const ValueKey('start-time')));
        final dialog = scale > 1.5
            ? find.byType(CupertinoDatePicker)
            : find.byType(TimePickerDialog);
        expect(dialog, findsOneWidget);
        if (scale > 1.5) {
          final picker = tester.widget<CupertinoDatePicker>(dialog);
          expect(picker.mode, CupertinoDatePickerMode.time);
          expect(picker.use24hFormat, isTrue);
          final wheels = find.byWidgetPredicate(
            (widget) =>
                widget is CupertinoPicker && widget.scrollController != null,
          );
          expect(wheels, findsNWidgets(2));
          tester
              .widget<CupertinoPicker>(wheels.at(0))
              .scrollController!
              .jumpToItem(18);
          tester
              .widget<CupertinoPicker>(wheels.at(1))
              .scrollController!
              .jumpToItem(45);
          await tester.pumpAndSettle();
          await tapVisible(
            tester,
            find.byKey(const ValueKey('time-picker-cancel')),
          );
          expect(find.text('未设置'), findsWidgets);
          await tapVisible(tester, find.byKey(const ValueKey('start-time')));
          tester
              .widget<CupertinoPicker>(wheels.at(0))
              .scrollController!
              .jumpToItem(18);
          tester
              .widget<CupertinoPicker>(wheels.at(1))
              .scrollController!
              .jumpToItem(45);
          await tester.pumpAndSettle();
        }
        await tapVisible(tester, find.widgetWithText(TextButton, '确定'));
        expect(dialog, findsNothing);
        await tester.ensureVisible(
          find.byKey(const ValueKey('duration-minutes')),
        );
        await tester.enterText(
          find.byKey(const ValueKey('duration-minutes')),
          '30',
        );
        await tapVisible(tester, find.byTooltip('增加 5 分钟'));
        await tapVisible(tester, find.byTooltip('减少 5 分钟'));
        await tapVisible(tester, find.byKey(const ValueKey('reminder-toggle')));
        await tapVisible(tester, find.byKey(const ValueKey('save-goal')));
        final goal = (await app.repository.loadGoals()).single;
        final minute = scale > 1.5 ? 1125 : 1170;
        expect(goal.scheduleOn(app.clock.day).startMinute, minute);
        expect(goal.scheduleOn(app.clock.day).durationMinutes, 30);
        expect(goal.reminder.enabled, isTrue);
        expect(goal.reminder.minuteOfDay, minute);
        expect(app.permissions.requests, 1);
        expect(app.notifications.requests, isEmpty);
        await tapVisible(tester, find.byKey(ValueKey('detail-${goal.id}')));
        expect(
          find.text('每天 · ${scale > 1.5 ? '18:45' : '19:30'} · 30 分钟'),
          findsOneWidget,
        );
        await tapVisible(tester, find.byKey(const ValueKey('edit-goal')));
        await tapVisible(
          tester,
          find.byKey(const ValueKey('clear-start-time')),
        );
        await tapVisible(tester, find.byTooltip('清除预计分钟'));
        await tapVisible(tester, find.byKey(const ValueKey('reminder-toggle')));
        await tapVisible(tester, find.byKey(const ValueKey('save-goal')));
        final updated = (await app.repository.loadGoals()).single;
        expect(updated.scheduleOn(app.clock.day).startMinute, minute);
        expect(
          updated.scheduleOn(app.clock.day.addDays(1)).startMinute,
          isNull,
        );
        expect(
          updated.scheduleOn(app.clock.day.addDays(1)).durationMinutes,
          isNull,
        );
        expect(updated.reminder.enabled, isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final minute in [0, 1439]) {
    testUiWidgets(
      'standard large-text picker preserves boundary minute $minute',
      (tester) async {
        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 3;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final app = UiHarness();
        await app.mount(tester);
        await tapVisible(tester, find.byKey(const ValueKey('entry-new-goal')));
        await tester.enterText(
          find.byKey(const ValueKey('goal-title')),
          'TEST boundary $minute',
        );
        await tapVisible(tester, find.byKey(const ValueKey('start-time')));
        final wheels = find.byWidgetPredicate(
          (widget) =>
              widget is CupertinoPicker && widget.scrollController != null,
        );
        expect(wheels, findsNWidgets(2));
        tester
            .widget<CupertinoPicker>(wheels.at(0))
            .scrollController!
            .jumpToItem(minute ~/ 60);
        tester
            .widget<CupertinoPicker>(wheels.at(1))
            .scrollController!
            .jumpToItem(minute % 60);
        await tester.pumpAndSettle();
        await tapVisible(
          tester,
          find.byKey(const ValueKey('time-picker-confirm')),
        );
        await tapVisible(tester, find.byKey(const ValueKey('start-time')));
        final reopened = tester.widget<CupertinoDatePicker>(
          find.byType(CupertinoDatePicker),
        );
        expect(reopened.initialDateTime.hour, minute ~/ 60);
        expect(reopened.initialDateTime.minute, minute % 60);
        await tapVisible(
          tester,
          find.byKey(const ValueKey('time-picker-cancel')),
        );
        await tapVisible(tester, find.byKey(const ValueKey('save-goal')));
        final goal = (await app.repository.loadGoals()).single;
        expect(goal.scheduleOn(app.clock.day).startMinute, minute);
        expect(goal.scheduleOn(app.clock.day).durationMinutes, isNull);
        expect(goal.reminder.enabled, isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testUiWidgets(
    'invalid minutes do not save; editing timing retains an explicitly chosen reminder',
    (tester) async {
      final app = UiHarness();
      final id = await app.repository.create(
        const GoalDraft(
          title: 'TEST existing time',
          kind: GoalKind.habit,
          startMinute: 420,
          durationMinutes: 30,
          reminderEnabled: true,
          reminderMinute: 400,
        ),
      );
      await app.mount(tester);
      await tapVisible(tester, find.byKey(ValueKey('detail-$id')));
      await tapVisible(tester, find.byKey(const ValueKey('edit-goal')));
      await tester.ensureVisible(
        find.byKey(const ValueKey('duration-minutes')),
      );
      await tester.enterText(
        find.byKey(const ValueKey('duration-minutes')),
        '481',
      );
      await tapVisible(tester, find.byKey(const ValueKey('save-goal')));
      expect(find.text('预计分钟需为 5 至 480'), findsOneWidget);
      expect(
        (await app.repository.loadGoals()).single
            .scheduleOn(app.clock.day.addDays(1))
            .durationMinutes,
        30,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('duration-minutes')),
      );
      await tester.enterText(
        find.byKey(const ValueKey('duration-minutes')),
        '45',
      );
      await tapVisible(tester, find.byKey(const ValueKey('clear-start-time')));
      await tapVisible(tester, find.byKey(const ValueKey('save-goal')));
      final goal = (await app.repository.loadGoals()).single;
      expect(goal.reminder.minuteOfDay, 400);
      expect(goal.scheduleOn(app.clock.day.addDays(1)).durationMinutes, 45);
      expect(tester.takeException(), isNull);
    },
  );
}
