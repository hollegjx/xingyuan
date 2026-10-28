import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/sync/goal_document.dart';
import 'package:habit_checkin/data/sync/local_sync_store.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'support/sync_fixtures.dart';
import 'support/test_clock.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);
  late AppDatabase db;
  late TestClock clock;
  late LocalGoalRepository goals;
  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    clock = TestClock();
    goals = LocalGoalRepository(db, clock, owner: accountA.owner);
  });
  tearDown(() => db.close());

  GoalDraft draft({int? time, int? minutes, GoalKind kind = GoalKind.habit}) =>
      GoalDraft(
        title: 'TEST time',
        kind: kind,
        plannedDay: kind == GoalKind.single ? clock.day : null,
        startMinute: time,
        durationMinutes: minutes,
      );
  Future<Goal> onlyGoal() async => (await goals.loadGoals()).single;

  test(
    'habit timing changes tomorrow and same-day replay is idempotent',
    () async {
      final day = clock.day;
      final id = await goals.create(draft(time: 420, minutes: 30));
      await goals.setCompleted(id, true, expectedDay: day);
      await goals.edit(id, draft(time: 1140, minutes: 60));
      await goals.edit(id, draft(time: 1140, minutes: 60));
      var goal = await onlyGoal();
      expect(goal.scheduleOn(day).startMinute, 420);
      expect(goal.scheduleOn(day).durationMinutes, 30);
      expect(goal.scheduleOn(day.addDays(1)).startMinute, 1140);
      expect(goal.schedules, hasLength(2));
      expect(goal.completionOn(day), isNotNull);
      expect(await db.select(db.syncOutbox).get(), hasLength(3));
      clock.setDay(2026, 10, 10);
      await goals.edit(id, draft());
      goal = await onlyGoal();
      expect(goal.scheduleOn(clock.day).startMinute, 1140);
      expect(goal.scheduleOn(clock.day.addDays(1)).startMinute, isNull);
      expect(goal.scheduleOn(clock.day.addDays(1)).durationMinutes, isNull);
      expect(goal.scheduleOn(day).durationMinutes, 30);
    },
  );

  test('single timing edits and clearing take effect today', () async {
    final id = await goals.create(
      draft(time: 420, minutes: 30, kind: GoalKind.single),
    );
    await goals.edit(id, draft(time: 1200, minutes: 45, kind: GoalKind.single));
    var goal = await onlyGoal();
    expect(goal.scheduleOn(clock.day).timing.label, '20:00 · 45 分钟');
    expect(goal.schedules, hasLength(1));
    await goals.edit(id, draft(kind: GoalKind.single));
    goal = await onlyGoal();
    expect(goal.scheduleOn(clock.day).timing.label, isEmpty);
    expect(goal.reminder.enabled, isFalse);
  });

  test('invalid timing never writes a goal, schedule or upload', () async {
    for (final item in [
      draft(time: -1),
      draft(time: 1440),
      draft(minutes: 4),
      draft(minutes: 481),
      draft(time: 1430, minutes: 30),
    ]) {
      await expectLater(goals.create(item), throwsA(isA<GoalRuleException>()));
    }
    expect(await goals.loadGoals(), isEmpty);
    expect(await db.select(db.syncOutbox).get(), isEmpty);
    final id = await goals.create(draft(time: 1430, minutes: 10));
    final before = await LocalSyncStore(
      db,
      clock,
    ).readDocument(id, owner: accountA.owner);
    await expectLater(
      goals.edit(id, draft(time: 1430, minutes: 11)),
      throwsA(isA<GoalRuleException>()),
    );
    expect(
      (await LocalSyncStore(
        db,
        clock,
      ).readDocument(id, owner: accountA.owner)).encode(),
      before.encode(),
    );
    expect(await db.select(db.syncOutbox).get(), hasLength(1));
  });

  test('v2 outbox and server-document restore retain timing without local reminder', () async {
    final id = await goals.create(draft(time: 1200, minutes: 30));
    final operation = await db.select(db.syncOutbox).getSingle();
    final document = GoalDocument.decode(operation.documentJson);
    expect(document.sourceVersion, 2);
    expect(document.schedules.single.startMinute, 1200);
    expect(document.schedules.single.durationMinutes, 30);
    final other = AppDatabase(NativeDatabase.memory());
    try {
      final restoredId = await LocalSyncStore(
        other,
        clock,
      ).applyDocument(document, owner: accountA.owner);
      final restored = (await LocalGoalRepository(
        other,
        clock,
        owner: accountA.owner,
      ).loadGoals()).single;
      expect(restored.id, restoredId);
      expect(restored.scheduleOn(clock.day).timing.label, '20:00 · 30 分钟');
      expect(restored.reminder.enabled, isFalse);
      expect(await other.select(other.syncOutbox).get(), isEmpty);
      expect(
        (await LocalSyncStore(
          db,
          clock,
        ).readDocument(id, owner: accountA.owner)).encode(),
        document.encode(),
      );
    } finally {
      await other.close();
    }
  });

  test('old v1 wire snapshots cannot silently clear stored timing', () async {
    final id = await goals.create(draft(time: 1200, minutes: 30));
    final store = LocalSyncStore(db, clock);
    final before = await store.readDocument(id, owner: accountA.owner);
    final value = before.toJson()..['version'] = 1;
    for (final row in value['schedules'] as List) {
      (row as Map).remove('start_minute');
      row.remove('duration_minutes');
    }
    final old = GoalDocument.fromJson(value);
    expect(old.retainingHistoryFrom(before).encode(), before.encode());
    await expectLater(
      store.applyDocument(old, owner: accountA.owner),
      throwsException,
    );
    expect(
      (await store.readDocument(id, owner: accountA.owner)).encode(),
      before.encode(),
    );
  });

  test(
    'time, minutes and explicit clearing persist over new SQLite connections',
    () async {
      final directory = await Directory.systemTemp.createTemp('goal-timing-');
      final file = File('${directory.path}/timing.sqlite');
      var local = AppDatabase(NativeDatabase(file));
      try {
        var repository = LocalGoalRepository(local, clock);
        final id = await repository.create(
          draft(time: 1170, minutes: 30, kind: GoalKind.single),
        );
        await local.close();
        local = AppDatabase(NativeDatabase(file));
        repository = LocalGoalRepository(local, clock);
        expect(
          (await repository.loadGoals()).single
              .scheduleOn(clock.day)
              .timing
              .label,
          '19:30 · 30 分钟',
        );
        await repository.edit(id, draft(kind: GoalKind.single));
        await local.close();
        local = AppDatabase(NativeDatabase(file));
        repository = LocalGoalRepository(local, clock);
        expect(
          (await repository.loadGoals()).single
              .scheduleOn(clock.day)
              .timing
              .label,
          isEmpty,
        );
      } finally {
        await local.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
