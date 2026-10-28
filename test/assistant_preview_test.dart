import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/assistant/domain/plan_preview.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:habit_checkin/features/goals/domain/goal_timing.dart';
import 'package:habit_checkin/shared/local_date.dart';
import 'package:habit_checkin/shared/presentation.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

final today = CalendarDate.parse('2026-10-20');

PlanTask task({
  String title = '读书',
  String date = '2026-10-20',
  String? time = '19:30',
  int? minutes = 30,
  List<int>? weekdays,
}) => PlanTask.fromJson({
  'title': title,
  if (weekdays == null) 'date': date else 'start_date': date,
  'weekdays': ?weekdays,
  'time': time,
  'minutes': minutes,
}, habit: weekdays != null);

PlanPreview preview(List<PlanTask> tasks) => PlanPreview([
  for (var i = 0; i < tasks.length; i++)
    PreviewItem(id: 'item-$i', task: tasks[i]),
]);

Goal goal({
  int id = 1,
  int? start = 1170,
  int? duration = 30,
  String title = '读书',
  bool archived = false,
  GoalKind kind = GoalKind.habit,
  List<ScheduleVersion>? schedules,
}) => Goal(
  id: id,
  kind: kind,
  createdDay: LocalDate.parse('2026-10-20'),
  createdAt: DateTime.utc(2026, 10, 20),
  archivedDay: archived ? LocalDate.parse('2026-10-20') : null,
  archivedAt: archived ? DateTime.utc(2026, 10, 20, 1) : null,
  titles: [TitleVersion(LocalDate.parse('2026-10-20'), title)],
  schedules:
      schedules ??
      [
        ScheduleVersion(
          effectiveDay: LocalDate.parse('2026-10-20'),
          weekdays: 127,
          startMinute: start,
          durationMinutes: duration,
        ),
      ],
  completions: [],
  reminder: const ReminderState(
    enabled: false,
    minuteOfDay: 1200,
    revision: 0,
    needsReconcile: false,
    status: 'disabled',
  ),
);

void main() {
  test('optional timing accepts boundaries but rejects midnight overrun', () {
    expect(GoalTiming().label, '');
    expect(GoalTiming(startMinute: 0).label, '00:00');
    expect(GoalTiming(startMinute: 1439).label, '23:59');
    expect(GoalTiming(durationMinutes: 5).label, '5 分钟');
    expect(GoalTiming(durationMinutes: 480).label, '480 分钟');
    expect(
      GoalTiming(startMinute: 1170, durationMinutes: 30).label,
      '19:30 · 30 分钟',
    );
    expect(
      GoalTiming(startMinute: 1435, durationMinutes: 5).label,
      '23:55 · 5 分钟',
    );
    for (final start in [-1, 1440]) {
      expect(() => GoalTiming(startMinute: start), throwsFormatException);
    }
    for (final duration in [4, 481]) {
      expect(
        () => GoalTiming(durationMinutes: duration),
        throwsFormatException,
      );
    }
    expect(
      () => GoalTiming(startMinute: 1436, durationMinutes: 5),
      throwsFormatException,
    );
  });

  test('overlap is symmetric, touching intervals do not overlap', () {
    final reading = GoalTiming(startMinute: 1170, durationMinutes: 60);
    for (final start in [1170, 1200, 1229]) {
      final point = GoalTiming(startMinute: start);
      expect(reading.overlaps(point), isTrue);
      expect(point.overlaps(reading), isTrue);
    }
    for (final start in [1169, 1230]) {
      final point = GoalTiming(startMinute: start);
      expect(reading.overlaps(point), isFalse);
      expect(point.overlaps(reading), isFalse);
    }
    expect(reading.overlaps(GoalTiming(durationMinutes: 60)), isFalse);
    expect(
      GoalTiming(startMinute: 1170).overlaps(GoalTiming(startMinute: 1171)),
      isFalse,
    );
  });

  test('today sorts by effective time, with stable ties and untimed last', () {
    final overview = TodayOverview([
      goal(id: 1, start: null),
      goal(id: 2, start: 1200),
      goal(id: 3, start: 420),
      goal(id: 4, start: 1200),
      goal(id: 5, start: null),
    ], LocalDate.parse(today.key));
    expect(overview.pending.map((view) => view.goal.id), [3, 2, 4, 1, 5]);
  });

  test('historical timing remains versioned and uses shared labels', () {
    final first = ScheduleVersion(
      effectiveDay: LocalDate.parse('2026-10-20'),
      weekdays: 127,
      startMinute: 1170,
      durationMinutes: 30,
    );
    final next = ScheduleVersion(
      effectiveDay: LocalDate.parse('2026-10-21'),
      weekdays: 127,
      startMinute: 1200,
      durationMinutes: 60,
    );
    final stored = goal(schedules: [first, next]);
    expect(
      stored.scheduleOn(LocalDate.parse('2026-10-20')).timing.label,
      '19:30 · 30 分钟',
    );
    expect(
      stored.scheduleOn(LocalDate.parse('2026-10-21')).timing.label,
      '20:00 · 60 分钟',
    );
    expect(scheduleLabel(GoalKind.habit, first), '每天 · 19:30 · 30 分钟');
  });

  test('proposal starts with reminders off and immutable items', () {
    final parsed = PlanProposal.fromJson({
      'tasks': [task().toJson()],
      'habits': [
        task(weekdays: [1, 3, 5]).toJson(),
      ],
    }, today: today);
    final result = PlanPreview.fromProposal(parsed);
    expect(result.items.map((item) => item.reminder), [false, false]);
    expect(result.items.map((item) => item.id), ['task-0', 'habit-0']);
    expect(() => result.items.clear(), throwsUnsupportedError);
    expect(PlanPreview.decode(result.encode()).encode(), result.encode());
  });

  test('edits preserve identity and clear reminder when time is removed', () {
    final initial = preview([task()]).setReminder('item-0', true);
    final changed = initial.replace('item-0', task(title: '整理', time: null));
    expect(changed.items.single.id, 'item-0');
    expect(changed.items.single.task.title, '整理');
    expect(changed.items.single.task.minutes, 30);
    expect(changed.items.single.reminder, false);
    expect(initial.items.single.reminder, true);
    expect(() => changed.setReminder('item-0', true), throwsFormatException);
    expect(() => changed.replace('missing', task()), throwsFormatException);
    expect(() => changed.remove('missing'), throwsFormatException);
  });

  test(
    'bulk reminder choice and clear times leave dates and minutes intact',
    () {
      final selected = preview([task(), task(time: null)])
          .enableTimedReminders();
      expect(selected.items.map((item) => item.reminder), [true, false]);
      final cleared = selected.clearTimes();
      expect(cleared.items.map((item) => item.task.time), [null, null]);
      expect(cleared.items.map((item) => item.task.minutes), [30, 30]);
      expect(cleared.items.map((item) => item.task.date), [today, today]);
      expect(cleared.items.map((item) => item.reminder), [false, false]);
      expect(cleared.remove('item-0').items, hasLength(1));
      expect(
        () => cleared
            .remove('item-0')
            .remove('item-1')
            .validateForConfirmation(today),
        throwsFormatException,
      );
    },
  );

  test(
    'same title and overlapping time only warn, never block confirmation',
    () {
      final value = preview([task()]);
      final warnings = value.inspect(today: today, goals: [goal()]);
      expect(warnings.map((issue) => issue.kind), [
        PreviewIssueKind.sameTitle,
        PreviewIssueKind.timeOverlap,
      ]);
      expect(warnings.every((issue) => !issue.blocksConfirmation), true);
      expect(warnings.every((issue) => issue.existingGoalId == 1), true);
      expect(value.validateForConfirmation(today).tasks, hasLength(1));
      expect(
        value.inspect(today: today, goals: [goal(archived: true)]),
        isEmpty,
      );
    },
  );

  test('habit conflicts respect weekdays and actual schedule versions', () {
    final value = preview([
      task(weekdays: [3], time: '20:00', title: '跑步'),
    ]);
    final existing = goal(
      schedules: [
        ScheduleVersion(
          effectiveDay: LocalDate.parse('2026-10-20'),
          weekdays: 127,
          startMinute: 1170,
          durationMinutes: 30,
        ),
        ScheduleVersion(
          effectiveDay: LocalDate.parse('2026-10-28'),
          weekdays: 127,
          startMinute: 1200,
          durationMinutes: 30,
        ),
      ],
    );
    final warnings = value.inspect(today: today, goals: [existing]);
    expect(warnings, hasLength(1));
    expect(warnings.single.date.key, '2026-10-28');
    expect(warnings.single.kind, PreviewIssueKind.timeOverlap);
  });

  test('single-task conflicts do not repeat after their planned date', () {
    final existing = goal(
      kind: GoalKind.single,
      schedules: [
        ScheduleVersion(
          effectiveDay: LocalDate.parse(today.key),
          weekdays: 0,
          plannedDay: LocalDate.parse('2026-10-21'),
          startMinute: 1170,
          durationMinutes: 30,
        ),
      ],
    );
    final value = preview([task(date: '2026-10-21'), task(date: '2026-10-22')]);
    final warnings = value.inspect(today: today, goals: [existing]);
    expect(warnings.map((issue) => issue.itemId).toSet(), {'item-0'});
    expect(warnings.map((issue) => issue.kind).toSet(), {
      PreviewIssueKind.sameTitle,
      PreviewIssueKind.timeOverlap,
    });

    final later = today.addDays(2);
    final overdue = preview([
      task(date: later.key),
      task(date: later.addDays(1).key),
    ]).inspect(today: later, goals: [existing]);
    expect(overdue.map((issue) => issue.itemId).toSet(), {'item-0'});
  });

  test(
    'midnight confirmation keeps dates, rejects expired without rewriting',
    () {
      final value = preview([task(date: '2026-10-21')]);
      final snapshot = value.encode();
      expect(
        value.validateForConfirmation(today.addDays(1)).tasks.single.date.key,
        '2026-10-21',
      );
      expect(
        () => value.validateForConfirmation(today.addDays(2)),
        throwsFormatException,
      );
      expect(
        value.inspect(today: today.addDays(2), goals: []).single.kind,
        PreviewIssueKind.expired,
      );
      expect(value.encode(), snapshot);
      expect(
        value
            .replace('item-0', task(date: '2026-10-22'))
            .validateForConfirmation(today.addDays(2))
            .tasks
            .single
            .date
            .key,
        '2026-10-22',
      );
    },
  );

  test(
    'habit start cannot silently change after midnight or move to future',
    () {
      final original = preview([
        task(weekdays: [1, 3, 5]),
      ]);
      expect(
        () => original.validateForConfirmation(today.addDays(1)),
        throwsFormatException,
      );
      final future = original.replace(
        'item-0',
        task(date: '2026-10-21', weekdays: [1, 3, 5]),
      );
      expect(
        future.inspect(today: today, goals: []).single.kind,
        PreviewIssueKind.habitStart,
      );
      expect(
        () => future.validateForConfirmation(today),
        throwsFormatException,
      );
    },
  );

  test('edited previews keep original date/count caps', () {
    final far = preview([task(date: '2026-11-03')]);
    expect(
      far.inspect(today: today, goals: []).single.kind,
      PreviewIssueKind.tooFar,
    );
    expect(() => far.validateForConfirmation(today), throwsFormatException);
    expect(
      () =>
          preview(List.generate(13, (_) => task()))
              .validateForConfirmation(today),
      throwsFormatException,
    );
    expect(
      () =>
          preview(List.generate(6, (_) => task(weekdays: [3])))
              .validateForConfirmation(today),
      throwsFormatException,
    );
  });

  test('invalid stored preview fails without exposing private source', () {
    for (final source in [
      '{"private":"sensitive',
      '[{"id":"a","habit":false,"reminder":false,"task":{},"extra":1}]',
    ]) {
      try {
        PlanPreview.decode(source);
        fail('Must reject malformed preview');
      } on FormatException catch (error) {
        expect(error.source, isNull);
        expect(error.message, '无法读取计划预览');
      }
    }
    expect(
      () => PlanPreview([
        PreviewItem(id: 'same', task: task()),
        PreviewItem(id: 'same', task: task()),
      ]),
      throwsFormatException,
    );
  });
}
