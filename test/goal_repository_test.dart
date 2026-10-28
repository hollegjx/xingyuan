import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:habit_checkin/shared/local_date.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'support/test_clock.dart';

const habit = GoalDraft(title: 'TEST 阅读', kind: GoalKind.habit);
final ruleError = isA<GoalRuleException>();

GoalDraft single(LocalDate day, {String title = 'TEST 整理资料'}) =>
    GoalDraft(title: title, kind: GoalKind.single, plannedDay: day);

void main() {
  setUpAll(tzdata.initializeTimeZones);

  group('local goal transactions and rules', () {
    late AppDatabase db;
    late TestClock clock;
    late LocalGoalRepository repository;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      clock = TestClock();
      repository = LocalGoalRepository(db, clock);
    });
    tearDown(() => db.close());

    Future<Goal> goal(int id) async =>
        (await repository.loadGoals()).singleWhere((entry) => entry.id == id);
    Future<void> complete(int id, [bool value = true]) =>
        repository.setCompleted(id, value, expectedDay: clock.day);

    test('starts empty and creates only real submitted goals', () async {
      expect(await repository.loadGoals(), isEmpty);
      final id = await repository.create(habit);
      final stored = await goal(id);
      expect(stored.titleOn(clock.day), habit.title);
      expect(stored.reminder.enabled, isFalse);
      expect(stored.reminder.needsReconcile, isFalse);
      expect(stored.reminder.status, 'disabled');
      expect(stored.completions, isEmpty);
      expect((await db.select(db.goalTitles).get()), hasLength(1));
      expect((await db.select(db.goalSchedules).get()), hasLength(1));
      expect((await db.select(db.goalReminders).get()), hasLength(1));
    });

    test(
      'validates grapheme length, whitespace, weekdays, dates and time',
      () async {
        const family = '👨‍👩‍👧‍👦';
        final title = List.filled(60, family).join();
        final id = await repository.create(
          GoalDraft(title: '  $title  ', kind: GoalKind.habit),
        );
        expect((await goal(id)).titleOn(clock.day), title);
        for (final invalid in [
          const GoalDraft(title: '  \n ', kind: GoalKind.habit),
          GoalDraft(title: '$title$family', kind: GoalKind.habit),
          const GoalDraft(title: 'TEST', kind: GoalKind.habit, weekdays: 0),
          const GoalDraft(title: 'TEST', kind: GoalKind.habit, weekdays: 128),
          const GoalDraft(title: 'TEST', kind: GoalKind.single),
          single(clock.day.addDays(-1)),
          const GoalDraft(
            title: 'TEST',
            kind: GoalKind.habit,
            reminderMinute: -1,
          ),
          const GoalDraft(
            title: 'TEST',
            kind: GoalKind.habit,
            reminderMinute: 1440,
          ),
        ]) {
          await expectLater(repository.create(invalid), throwsA(ruleError));
        }
        expect(await repository.loadGoals(), hasLength(1));
      },
    );

    test('identical titles are distinct goals', () async {
      final a = await repository.create(habit);
      final b = await repository.create(habit);
      expect(a, isNot(b));
      await complete(a);
      final overview = TodayOverview(await repository.loadGoals(), clock.day);
      expect(overview.completed.single.goal.id, a);
      expect(overview.pending.single.goal.id, b);
    });

    test(
      'retrying the same edit does not add versions or reconciliation work',
      () async {
        final id = await repository.create(habit);
        const edit = GoalDraft(
          title: 'TEST 重复保存',
          kind: GoalKind.habit,
          weekdays: 1 | 4 | 16,
          reminderEnabled: true,
        );
        await Future.wait(List.generate(8, (_) => repository.edit(id, edit)));
        final stored = await goal(id);
        expect(stored.titles, hasLength(1));
        expect(stored.schedules, hasLength(2));
        expect(stored.reminder.revision, 1);
        expect(await repository.loadGoals(), hasLength(1));
      },
    );

    test('weekdays exclude rests and dates before creation', () async {
      final id = await repository.create(
        const GoalDraft(
          title: 'TEST 一三五',
          kind: GoalKind.habit,
          weekdays: 1 | 4 | 16,
        ),
      );
      var stored = await goal(id);
      expect(stored.isScheduledOn(clock.day), isTrue);
      expect(
        stored.dayView(clock.day.addDays(-1), today: clock.day).status,
        GoalDayStatus.notCreated,
      );
      clock.setDay(2026, 10, 10);
      await expectLater(complete(id), throwsA(ruleError));
      stored = await goal(id);
      expect(
        stored.dayView(clock.day, today: clock.day).status,
        GoalDayStatus.notScheduled,
      );
      clock.setDay(2026, 10, 12);
      await complete(id);
      expect((await goal(id)).completionOn(clock.day), isNotNull);
    });

    test(
      'concurrent completion is idempotent and preserves first timestamp',
      () async {
        final id = await repository.create(habit);
        await Future.wait(List.generate(16, (_) => complete(id)));
        final original = (await goal(id)).completionOn(clock.day)!;
        clock.instant = clock.instant.add(const Duration(hours: 1));
        await complete(id);
        expect(
          (await goal(id)).completionOn(clock.day)!.instant,
          original.instant,
        );
        expect(await db.select(db.checkIns).get(), hasLength(1));
        expect(
          TodayOverview(await repository.loadGoals(), clock.day).completed,
          hasLength(1),
        );
        expect((await goal(id)).reminder.revision, 1);
      },
    );

    test('undo is idempotent and rapid complete/undo/recomplete has a fixed result', () async {
      final id = await repository.create(habit);
      await complete(id);
      await Future.wait(List.generate(8, (_) => complete(id, false)));
      expect(
        TodayOverview(await repository.loadGoals(), clock.day).completed,
        isEmpty,
      );
      await Future.wait([complete(id), complete(id, false), complete(id)]);
      expect(
        TodayOverview(await repository.loadGoals(), clock.day).completed,
        hasLength(1),
      );
      expect(await db.select(db.checkIns).get(), hasLength(1));
    });

    test(
      'past and stale-screen mutations are rejected after midnight',
      () async {
        final id = await repository.create(habit);
        final yesterday = clock.day;
        await complete(id);
        clock.setDay(2026, 10, 10);
        await expectLater(
          repository.setCompleted(id, false, expectedDay: yesterday),
          throwsA(ruleError),
        );
        await expectLater(
          repository.setCompleted(id, true, expectedDay: clock.day.addDays(1)),
          throwsA(ruleError),
        );
        expect((await goal(id)).completionOn(yesterday), isNotNull);
        expect(
          TodayOverview(await repository.loadGoals(), clock.day).completed,
          isEmpty,
        );
        await complete(id);
        expect(
          (await goal(id)).completions.where((entry) => entry.completed),
          hasLength(2),
        );
      },
    );

    test(
      'single future task stays out of today and cannot complete early',
      () async {
        final id = await repository.create(single(clock.day.addDays(2)));
        expect(
          TodayOverview(await repository.loadGoals(), clock.day).pending,
          isEmpty,
        );
        expect(await repository.loadGoals(), hasLength(1));
        await expectLater(complete(id), throwsA(ruleError));
        expect(
          (await goal(id))
              .dayView(clock.day.addDays(2), today: clock.day)
              .status,
          GoalDayStatus.future,
        );
      },
    );

    test(
      'overdue single completes on actual day and stays globally unique',
      () async {
        final planned = clock.day;
        final id = await repository.create(single(planned));
        clock.setDay(2026, 10, 12);
        expect(
          TodayOverview(
            await repository.loadGoals(),
            clock.day,
          ).pending.single.isOverdue,
          isTrue,
        );
        await Future.wait(List.generate(8, (_) => complete(id)));
        var stored = await goal(id);
        expect(stored.singleCompletion!.day, clock.day);
        expect(stored.singleCompletion!.plannedDay, planned);
        expect(
          stored.dayView(planned, today: clock.day).status,
          GoalDayStatus.notRecorded,
        );
        await complete(id, false);
        expect(
          TodayOverview(
            await repository.loadGoals(),
            clock.day,
          ).pending.single.isOverdue,
          isTrue,
        );
        await complete(id);
        final completedDay = clock.day;
        clock.setDay(2026, 10, 13);
        await complete(id);
        await expectLater(complete(id, false), throwsA(ruleError));
        stored = await goal(id);
        expect(stored.singleCompletion!.day, completedDay);
        expect(
          stored.dayView(clock.day, today: clock.day).status,
          GoalDayStatus.completedEarlier,
        );
        expect(
          TodayOverview(await repository.loadGoals(), clock.day).pending,
          isEmpty,
        );
        expect(
          TodayOverview(await repository.loadGoals(), clock.day).completed,
          isEmpty,
        );
        expect(await db.select(db.checkIns).get(), hasLength(1));
      },
    );

    test('recurrence changes apply tomorrow with last edit winning', () async {
      final id = await repository.create(habit);
      final created = clock.day;
      await complete(id);
      await repository.edit(
        id,
        const GoalDraft(title: 'TEST 阅读', kind: GoalKind.habit, weekdays: 1),
      );
      await repository.edit(
        id,
        const GoalDraft(title: 'TEST 阅读', kind: GoalKind.habit, weekdays: 4),
      );
      var stored = await goal(id);
      expect(stored.scheduleOn(created).weekdays, 127);
      expect(stored.scheduleOn(created.addDays(1)).weekdays, 4);
      expect(stored.completionOn(created), isNotNull);
      expect(stored.schedules, hasLength(2));
      clock.setDay(2026, 10, 14);
      stored = await goal(id);
      expect(stored.isScheduledOn(clock.day), isTrue);
      expect(stored.isScheduledOn(LocalDate(2026, 10, 12)), isFalse);
      expect(
        stored.dayView(LocalDate(2026, 10, 10), today: clock.day).status,
        GoalDayStatus.notScheduled,
      );
    });

    test(
      'same-day reverting recurrence does not retain an unwanted next-day rule',
      () async {
        final id = await repository.create(habit);
        await repository.edit(
          id,
          const GoalDraft(title: 'TEST 阅读', kind: GoalKind.habit, weekdays: 1),
        );
        await repository.edit(id, habit);
        expect((await goal(id)).scheduleOn(clock.day.addDays(1)).weekdays, 127);
      },
    );

    test(
      'rename updates today but historical completions retain event title',
      () async {
        final id = await repository.create(habit);
        final created = clock.day;
        await complete(id);
        await repository.edit(
          id,
          const GoalDraft(title: 'TEST 新名称', kind: GoalKind.habit),
        );
        expect(
          (await goal(id)).dayView(created, today: clock.day).title,
          'TEST 新名称',
        );
        clock.setDay(2026, 10, 10);
        var stored = await goal(id);
        expect(stored.dayView(created, today: clock.day).title, habit.title);
        expect(stored.dayView(clock.day, today: clock.day).title, 'TEST 新名称');
        clock.setDay(2026, 10, 11);
        await repository.edit(
          id,
          const GoalDraft(title: 'TEST 后来的名称', kind: GoalKind.habit),
        );
        stored = await goal(id);
        expect(
          stored.dayView(LocalDate(2026, 10, 10), today: clock.day).title,
          'TEST 新名称',
        );
      },
    );

    test(
      'overdue rename keeps plan and rescheduling preserves old overdue facts',
      () async {
        final original = clock.day;
        final id = await repository.create(single(original));
        clock.setDay(2026, 10, 11);
        await repository.edit(id, single(original, title: 'TEST 改名'));
        expect((await goal(id)).scheduleOn(clock.day).plannedDay, original);
        await repository.edit(id, single(clock.day.addDays(2)));
        final stored = await goal(id);
        final yesterday = stored.dayView(
          clock.day.addDays(-1),
          today: clock.day,
        );
        expect(yesterday.isOverdue, isTrue);
        expect(yesterday.schedule.plannedDay, original);
        expect(TodayOverview([stored], clock.day).pending, isEmpty);
        await expectLater(
          repository.edit(id, single(clock.day.addDays(-1))),
          throwsA(ruleError),
        );
      },
    );

    test(
      'completed single may rename but cannot change type or plan without undo',
      () async {
        final id = await repository.create(single(clock.day));
        await complete(id);
        await repository.edit(id, single(clock.day, title: 'TEST 完成后改名'));
        await expectLater(
          repository.edit(id, single(clock.day.addDays(1))),
          throwsA(ruleError),
        );
        await expectLater(repository.edit(id, habit), throwsA(ruleError));
        await complete(id, false);
        await repository.edit(id, single(clock.day.addDays(1)));
        expect(
          TodayOverview(await repository.loadGoals(), clock.day).pending,
          isEmpty,
        );
      },
    );

    test(
      'archiving removes pending and retains read-only completions and history',
      () async {
        const remindedHabit = GoalDraft(
          title: 'TEST archive reminder',
          kind: GoalKind.habit,
          reminderEnabled: true,
        );
        final pending = await repository.create(remindedHabit);
        final done = await repository.create(remindedHabit);
        await complete(done);
        await repository.archive(pending);
        await repository.archive(done);
        await repository.archive(done);
        final overview = TodayOverview(await repository.loadGoals(), clock.day);
        expect(overview.pending, isEmpty);
        expect(overview.completed.single.goal.id, done);
        for (final id in [pending, done]) {
          await expectLater(complete(id), throwsA(ruleError));
          await expectLater(complete(id, false), throwsA(ruleError));
          await expectLater(repository.edit(id, habit), throwsA(ruleError));
          final stored = await goal(id);
          expect(stored.isArchived, isTrue);
          expect(stored.reminder.enabled, isFalse);
          expect(stored.reminder.needsReconcile, isTrue);
          expect(
            stored.dayView(clock.day.addDays(1), today: clock.day).status,
            GoalDayStatus.archived,
          );
        }
        expect(await repository.loadGoals(), hasLength(2));
      },
    );

    test('never-enabled reminders remain disabled after mutations', () async {
      final id = await repository.create(habit);
      await complete(id);
      await complete(id, false);
      await repository.edit(
        id,
        const GoalDraft(
          title: 'TEST renamed',
          kind: GoalKind.habit,
          weekdays: 21,
        ),
      );
      await repository.archive(id);
      final stored = await goal(id);
      expect(stored.reminder.enabled, isFalse);
      expect(stored.reminder.needsReconcile, isFalse);
      expect(stored.reminder.status, 'disabled');
    });

    test(
      'disabled reminder with outstanding work still needs cancellation',
      () async {
        final id = await repository.create(
          const GoalDraft(
            title: 'TEST enabled before',
            kind: GoalKind.habit,
            reminderEnabled: true,
          ),
        );
        await repository.edit(id, habit);
        await complete(id);
        await repository.archive(id);
        final stored = await goal(id);
        expect(stored.reminder.enabled, isFalse);
        expect(stored.reminder.needsReconcile, isTrue);
        expect(stored.reminder.status, 'pending');
      },
    );

    test('local owner is enforced in reads and all mutations', () async {
      final other = LocalGoalRepository(db, clock, owner: 'other-test-owner');
      final mine = await repository.create(habit);
      final theirs = await other.create(habit);
      expect((await repository.loadGoals()).single.id, mine);
      expect((await other.loadGoals()).single.id, theirs);
      await expectLater(repository.edit(theirs, habit), throwsA(ruleError));
      await expectLater(complete(theirs), throwsA(ruleError));
      await expectLater(repository.archive(theirs), throwsA(ruleError));
      expect((await other.loadGoals()).single.isArchived, isFalse);
    });

    test('reminder changes and business writes share a transaction', () async {
      final id = await repository.create(
        const GoalDraft(
          title: 'TEST reminder',
          kind: GoalKind.habit,
          reminderEnabled: true,
          reminderMinute: 600,
        ),
      );
      var stored = await goal(id);
      expect(stored.reminder.status, 'pending');
      expect(stored.reminder.needsReconcile, isTrue);
      await db.customStatement('''
        CREATE TRIGGER test_fail_reminder BEFORE UPDATE ON goal_reminders
        BEGIN SELECT RAISE(ABORT, 'injected write failure'); END
      ''');
      await expectLater(complete(id), throwsException);
      expect((await goal(id)).completions, isEmpty);
      await expectLater(repository.archive(id), throwsException);
      expect((await goal(id)).isArchived, isFalse);
      await db.customStatement('DROP TRIGGER test_fail_reminder');
      await complete(id);
      stored = await goal(id);
      expect(stored.completionOn(clock.day), isNotNull);
      expect(stored.reminder.revision, 1);
      expect(stored.reminder.status, 'pending');
    });

    test('failed creation leaves no partial goal, title or schedule', () async {
      await db.customStatement('''
        CREATE TRIGGER test_fail_create BEFORE INSERT ON goal_reminders
        BEGIN SELECT RAISE(ABORT, 'injected create failure'); END
      ''');
      await expectLater(repository.create(habit), throwsException);
      expect(await repository.loadGoals(), isEmpty);
      expect(await db.select(db.goalTitles).get(), isEmpty);
      expect(await db.select(db.goalSchedules).get(), isEmpty);
      await db.customStatement('DROP TRIGGER test_fail_create');
      expect(await repository.create(habit), isPositive);
    });

    test(
      'watch emits changes to related tables and not just goal rows',
      () async {
        final snapshots = <List<Goal>>[];
        final first = Completer<void>();
        final checked = Completer<void>();
        final subscription = repository.watchGoals().listen((goals) {
          snapshots.add(goals);
          if (!first.isCompleted) first.complete();
          if (goals.any((entry) => entry.completionOn(clock.day) != null) &&
              !checked.isCompleted) {
            checked.complete();
          }
        });
        try {
          await first.future.timeout(const Duration(seconds: 5));
          final id = await repository.create(habit);
          await complete(id);
          await checked.future.timeout(const Duration(seconds: 5));
          expect(snapshots.first, isEmpty);
          expect(snapshots.last.single.completionOn(clock.day), isNotNull);
        } finally {
          await subscription.cancel();
        }
      },
    );

    test(
      'time-zone travel never moves the owned day or duplicates it',
      () async {
        clock.setDay(2026, 10, 8);
        final id = await repository.create(habit);
        clock.setDay(2026, 10, 9, hour: 1);
        await complete(id);
        final eastDay = clock.day;
        final firstInstant = clock.read().instant;
        clock.location = tz.getLocation('America/Los_Angeles');
        expect(clock.day, LocalDate(2026, 10, 8));
        var stored = await goal(id);
        expect(stored.completionOn(eastDay)!.instant, firstInstant);
        expect(stored.completionOn(eastDay)!.zone, 'Asia/Shanghai');
        expect(TodayOverview([stored], clock.day).completed, isEmpty);
        clock.setDay(2026, 10, 9, hour: 8);
        await complete(id);
        stored = await goal(id);
        expect(stored.completionOn(eastDay)!.instant, firstInstant);
        expect(stored.completions, hasLength(1));
      },
    );

    test(
      'completed single does not reappear in today after travelling west',
      () async {
        clock.setDay(2026, 10, 8);
        final planned = clock.day;
        final id = await repository.create(single(planned));
        clock.setDay(2026, 10, 9, hour: 1);
        await complete(id);
        final completedDay = clock.day;
        clock.location = tz.getLocation('America/Los_Angeles');
        expect(clock.day, planned);
        final stored = await goal(id);
        final overview = TodayOverview([stored], clock.day);
        expect(overview.pending, isEmpty);
        expect(overview.completed, isEmpty);
        expect(stored.singleCompletion!.day, completedDay);
        expect(
          stored.dayView(planned, today: completedDay).status,
          GoalDayStatus.notRecorded,
        );
        await complete(id);
        expect((await goal(id)).singleCompletion!.day, completedDay);
      },
    );

    test('leap-day, month and year boundaries keep daily uniqueness', () async {
      clock.setDay(2024, 2, 28);
      final id = await repository.create(habit);
      for (final date in [
        LocalDate(2024, 2, 28),
        LocalDate(2024, 2, 29),
        LocalDate(2024, 3, 1),
        LocalDate(2024, 12, 31),
        LocalDate(2025, 1, 1),
      ]) {
        clock.setDay(date.year, date.month, date.day);
        await complete(id);
        expect(
          TodayOverview(await repository.loadGoals(), clock.day).completed,
          hasLength(1),
        );
      }
      expect((await goal(id)).completions, hasLength(5));
    });
  });

  test(
    'file reopen retains entire offline workflow and reminder preferences',
    () async {
      final directory = await Directory.systemTemp.createTemp('habit-flow-');
      final file = File('${directory.path}/goals.sqlite');
      final clock = TestClock();
      var db = AppDatabase(NativeDatabase(file));
      var repository = LocalGoalRepository(db, clock);
      try {
        final id = await repository.create(habit);
        final one = await repository.create(single(clock.day));
        await repository.edit(
          id,
          const GoalDraft(
            title: 'TEST 持久保存',
            kind: GoalKind.habit,
            weekdays: 1 | 4 | 16,
            reminderEnabled: true,
            reminderMinute: 1080,
          ),
        );
        await repository.setCompleted(id, true, expectedDay: clock.day);
        await repository.archive(one);
        await db.close();
        db = AppDatabase(NativeDatabase(file));
        repository = LocalGoalRepository(db, clock);
        final goals = await repository.loadGoals();
        final habitGoal = goals.singleWhere((goal) => goal.id == id);
        expect(habitGoal.titleOn(clock.day), 'TEST 持久保存');
        expect(habitGoal.scheduleOn(clock.day).weekdays, 127);
        expect(habitGoal.scheduleOn(clock.day.addDays(1)).weekdays, 21);
        expect(habitGoal.reminder.enabled, isTrue);
        expect(habitGoal.reminder.minuteOfDay, 1080);
        expect(habitGoal.reminder.needsReconcile, isTrue);
        expect(habitGoal.completionOn(clock.day), isNotNull);
        expect(goals.singleWhere((goal) => goal.id == one).isArchived, isTrue);
        expect(
          await db.customSelect('PRAGMA foreign_key_check').get(),
          isEmpty,
        );
      } finally {
        await db.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
