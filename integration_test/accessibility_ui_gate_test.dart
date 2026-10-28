import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/app/app.dart';
import 'package:habit_checkin/app/providers.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/local/open_database.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:integration_test/integration_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();

  testWidgets('device large text keeps calendar and pickers interactive', (
    tester,
  ) async {
    const run = String.fromEnvironment('ACCESSIBILITY_PROBE_RUN');
    expect(
      RegExp(r'^[a-zA-Z0-9-]+$').hasMatch(run),
      isTrue,
      reason: 'Use a fresh alphanumeric/hyphen token for each run',
    );
    final db = openAppDatabase(name: 'habit_checkin_accessibility_gate');
    final clock = DeviceClock();
    await clock.refreshZone();
    final repository = LocalGoalRepository(db, clock, owner: 'layout-$run');

    Future<void> tap(Finder finder) async {
      await tester.ensureVisible(finder);
      await tester.tap(finder);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }

    try {
      expect(
        await repository.loadGoals(),
        isEmpty,
        reason: 'Never erase probe data; choose a fresh run token',
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            clockProvider.overrideWithValue(clock),
            refreshClockProvider.overrideWithValue(clock.refreshZone),
            goalRepositoryProvider.overrideWith((ref) => repository),
          ],
          child: const HabitCheckinApp(),
        ),
      );
      await tester.pumpAndSettle();
      final context = tester.element(
        find.byKey(const ValueKey('entry-new-goal')),
      );
      final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
      expect(
        textScale,
        greaterThan(1),
        reason: 'Configure the test simulator accessibility text size first',
      );
      final size = MediaQuery.sizeOf(context);
      debugPrint('Accessibility viewport=$size; effective14pxScale=$textScale');

      await tap(find.byKey(const ValueKey('entry-new-goal')));
      await tester.enterText(
        find.byKey(const ValueKey('goal-title')),
        'TEST 大字体阅读与中文 📖',
      );
      await tap(find.byKey(const ValueKey('goal-kind')));
      await tap(find.text('单次任务').last);
      await tap(find.byKey(const ValueKey('planned-day')));
      expect(find.byType(DatePickerDialog), findsOneWidget);
      await tap(find.widgetWithText(TextButton, '确定'));
      await tap(find.byKey(const ValueKey('reminder-toggle')));
      await tap(find.byKey(const ValueKey('reminder-time')));
      expect(find.byType(CupertinoDatePicker), findsOneWidget);
      expect(
        tester
            .widget<CupertinoDatePicker>(find.byType(CupertinoDatePicker))
            .use24hFormat,
        isTrue,
      );
      await tap(find.byKey(const ValueKey('time-picker-confirm')));
      expect(find.byType(CupertinoDatePicker), findsNothing);
      // Exercise the picker without saving an opt-in or requesting permission.
      await tap(find.byKey(const ValueKey('reminder-toggle')));
      await tap(find.byKey(const ValueKey('save-goal')));
      final goal = (await repository.loadGoals()).single;
      expect(goal.kind, GoalKind.single);
      expect(goal.reminder.enabled, isFalse);
      expect(goal.reminder.needsReconcile, isFalse);
      await tap(find.byKey(ValueKey('complete-${goal.id}')));
      expect(find.text('今日已完成 1 项'), findsOneWidget);
      await tap(find.byKey(ValueKey('undo-${goal.id}')));
      expect(find.text('今日已完成 0 项'), findsOneWidget);
      await tap(find.byKey(ValueKey('complete-${goal.id}')));

      await tap(find.byTooltip('回顾'));
      final calendar = find.byWidgetPredicate(
        (widget) =>
            widget is SingleChildScrollView &&
            widget.scrollDirection == Axis.horizontal,
      );
      await tester.ensureVisible(calendar);
      await tester.pumpAndSettle();
      final scroll = tester.widget<SingleChildScrollView>(calendar).controller!;
      expect(
        scroll.position.maxScrollExtent,
        greaterThan(0),
        reason: 'This gate must exercise an actually overflowing calendar',
      );
      final before = scroll.offset;
      await tester.dragFrom(
        tester.getTopLeft(calendar) + const Offset(100, 24),
        const Offset(-160, 0),
      );
      await tester.pumpAndSettle();
      expect(scroll.offset, greaterThan(before));
      debugPrint(
        'Calendar horizontal offset=$before -> ${scroll.offset}; '
        'extent=${scroll.position.maxScrollExtent}',
      );
      final today = clock.read().day;
      await tap(find.byKey(ValueKey('review-day-${today.key}')));
      expect(find.text('已完成 1 项'), findsOneWidget);
      expect(find.text('TEST 大字体阅读与中文 📖'), findsOneWidget);
      await tap(find.byKey(const ValueKey('previous-month')));
      await tap(find.byKey(const ValueKey('next-month')));
      await tap(find.byKey(const ValueKey('review-today')));
      expect(find.text('已完成 1 项'), findsOneWidget);
      expect(await db.customSelect('PRAGMA foreign_key_check').get(), isEmpty);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await db.close();
    }
  });
}
