import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/local/open_database.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:habit_checkin/shared/local_date.dart';
import 'package:integration_test/integration_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import '../test/support/test_clock.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();

  testWidgets('personal repository survives separate iOS app processes', (
    tester,
  ) async {
    const phase = String.fromEnvironment('GOAL_PROBE_PHASE');
    const run = String.fromEnvironment('GOAL_PROBE_RUN');
    expect(phase, anyOf('write', 'read'));
    expect(
      run,
      isNotEmpty,
      reason: 'Use the same new run token for both phases.',
    );
    final db = openAppDatabase(name: 'habit_checkin_goal_gate');
    final clock = TestClock();
    final repository = LocalGoalRepository(db, clock, owner: 'probe-$run');
    final planned = LocalDate(2026, 10, 9);
    final completed = LocalDate(2026, 10, 12);
    try {
      if (phase == 'write') {
        expect(
          await repository.loadGoals(),
          isEmpty,
          reason: 'Choose a fresh run token; never erase an existing database.',
        );
        final habitId = await repository.create(
          const GoalDraft(title: 'TEST initial habit', kind: GoalKind.habit),
        );
        final singleId = await repository.create(
          GoalDraft(
            title: 'TEST single',
            kind: GoalKind.single,
            plannedDay: planned,
          ),
        );
        final archiveId = await repository.create(
          const GoalDraft(title: 'TEST archived', kind: GoalKind.habit),
        );
        await repository.edit(
          habitId,
          const GoalDraft(
            title: 'TEST edited habit',
            kind: GoalKind.habit,
            weekdays: 1 | 4 | 16,
            reminderEnabled: true,
            reminderMinute: 1080,
          ),
        );
        await repository.setCompleted(habitId, true, expectedDay: clock.day);
        await repository.archive(archiveId);
        clock.setDay(2026, 10, 12);
        await repository.setCompleted(singleId, true, expectedDay: clock.day);
        await repository.setCompleted(singleId, false, expectedDay: clock.day);
        await repository.setCompleted(singleId, true, expectedDay: clock.day);
      }
      clock.setDay(2026, 10, 12);
      final goals = await repository.loadGoals();
      expect(goals, hasLength(3));
      final habit = goals.singleWhere(
        (goal) => goal.titleOn(clock.day) == 'TEST edited habit',
      );
      final single = goals.singleWhere((goal) => goal.kind == GoalKind.single);
      final archived = goals.singleWhere((goal) => goal.isArchived);
      expect(habit.scheduleOn(planned).weekdays, 127);
      expect(habit.scheduleOn(planned.addDays(1)).weekdays, 21);
      expect(habit.completionOn(planned), isNotNull);
      expect(habit.reminder.enabled, isTrue);
      expect(habit.reminder.minuteOfDay, 1080);
      expect(habit.reminder.needsReconcile, isTrue);
      expect(single.singleCompletion!.day, completed);
      expect(single.singleCompletion!.plannedDay, planned);
      expect(
        single.completions.where((entry) => entry.completed),
        hasLength(1),
      );
      expect(archived.archivedDay, planned);
      final today = TodayOverview(goals, clock.day);
      expect(today.completed.single.goal.id, single.id);
      expect(today.pending.single.goal.id, habit.id);
      expect(await db.customSelect('PRAGMA foreign_key_check').get(), isEmpty);
    } finally {
      await db.close();
    }
  });
}
