import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/sync/identity_store.dart';
import 'package:habit_checkin/data/sync/sync_identity.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:habit_checkin/features/planning/data/local_planning_store.dart';
import 'package:habit_checkin/features/planning/domain/daily_plan.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'drift/generated/schema.dart';
import 'support/test_clock.dart';

PlanningRequest requestFor(TestClock clock, {int budget = 30}) =>
    PlanningRequest(
      day: clock.day,
      zone: 'Asia/Shanghai',
      intent: 'TEST 阅读和整理桌面',
      preferences: '每项不超过二十分钟',
      availableMinutes: budget,
    );

List<PlanTask> testTasks() => [
  PlanTask(title: 'TEST 阅读', minutes: 20),
  PlanTask(title: 'TEST 整理桌面', minutes: 10),
];

void main() {
  setUpAll(tzdata.initializeTimeZones);

  test('strict model result rejects extra capabilities and invalid tasks', () {
    final valid =
        jsonDecode(encodePlanTasks(testTasks())) as Map<String, dynamic>;
    expect(parsePlanTasks(valid, 30), hasLength(2));
    for (final json in [
      {...valid, 'owner': 'other-user'},
      {...valid, 'reminder_enabled': true},
      {'tasks': []},
      {
        'tasks': List.filled(7, {'title': 'TEST', 'minutes': 1}),
      },
      {
        'tasks': [
          {'title': 'TEST', 'minutes': '10'},
        ],
      },
      {
        'tasks': [
          {'title': 'TEST', 'minutes': 1.5},
        ],
      },
      {
        'tasks': [
          {'title': '', 'minutes': 1},
        ],
      },
      {
        'tasks': [
          {'title': 'TEST', 'minutes': 0},
        ],
      },
      {
        'tasks': [
          {'title': 'TEST', 'minutes': 31},
        ],
      },
      {
        'tasks': [
          {'title': 'TEST', 'minutes': 1, 'action': 'delete_all'},
        ],
      },
      {
        'tasks': [
          {'title': 'TEST', 'minutes': 1},
          {'title': 'test', 'minutes': 1},
        ],
      },
      {
        'tasks': [
          {'title': 'x' * 61, 'minutes': 1},
        ],
      },
    ]) {
      expect(() => parsePlanTasks(json, 30), throwsA(isA<PlanningException>()));
    }
  });

  test('request carries only explicit data and validates limits and dates', () {
    final request = requestFor(TestClock());
    expect(PlanningRequest.fromJson(request.toJson()).intent, request.intent);
    for (final json in [
      {...request.toJson(), 'day': '2026-02-30'},
      {...request.toJson(), 'available_minutes': 241},
      {...request.toJson(), 'available_minutes': 4},
      {...request.toJson(), 'intent': ''},
      {...request.toJson(), 'preferences': 'x' * 501},
      {...request.toJson(), 'private_notes': 'not allowed'},
    ]) {
      expect(
        () => PlanningRequest.fromJson(json),
        throwsA(isA<PlanningException>()),
      );
    }
  });

  group('local planning transactions', () {
    late AppDatabase db;
    late TestClock clock;
    late LocalGoalRepository goals;
    late LocalPlanningStore store;
    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      clock = TestClock();
      goals = LocalGoalRepository(db, clock);
      store = LocalPlanningStore(goals);
    });
    tearDown(() => db.close());

    test(
      'draft and explicit local memory do not create goals or outbox',
      () async {
        expect(await store.loadPreferences(), '');
        await store.savePreferences('  TEST 晚上有空  ');
        expect(await store.loadPreferences(), 'TEST 晚上有空');
        final plan = await store.saveDraft(requestFor(clock), testTasks());
        expect((await store.latestDraft())?.id, plan.id);
        expect(await goals.loadGoals(), isEmpty);
        expect(await db.select(db.syncOutbox).get(), isEmpty);
        await store.savePreferences('');
        expect(await store.loadPreferences(), '');
      },
    );

    test(
      'confirmation creates private single goals with reminders off',
      () async {
        final original = await goals.create(
          const GoalDraft(title: 'TEST 原有', kind: GoalKind.habit),
        );
        final plan = await store.saveDraft(requestFor(clock), testTasks());
        final edited = [PlanTask(title: 'TEST 确认过的名称', minutes: 15)];
        final ids = await store.apply(plan.id, edited);
        final all = await goals.loadGoals();
        expect(all, hasLength(2));
        expect(all.first.id, original);
        expect(all.last.id, ids.single);
        expect(all.last.titleOn(clock.day), 'TEST 确认过的名称');
        expect(all.last.kind, GoalKind.single);
        expect(all.last.scheduleOn(clock.day).plannedDay, clock.day);
        expect(all.last.reminder.enabled, isFalse);
        expect(all.last.completions, isEmpty);
        expect(await store.latestDraft(), isNull);
        expect(await db.select(db.syncOutbox).get(), isEmpty);
      },
    );

    test(
      'concurrent retries return one receipt and refuse different payload',
      () async {
        final plan = await store.saveDraft(requestFor(clock), testTasks());
        final results = await Future.wait(
          List.generate(8, (_) => store.apply(plan.id, testTasks())),
        );
        for (final ids in results) {
          expect(ids, results.first);
        }
        expect(await goals.loadGoals(), hasLength(2));
        await expectLater(
          store.apply(plan.id, [PlanTask(title: 'TEST 别的版本', minutes: 1)]),
          throwsA(isA<PlanningException>()),
        );
        clock.setDay(2026, 10, 10);
        expect(await store.apply(plan.id, testTasks()), results.first);
      },
    );

    test(
      'expired generation and expired confirmation cannot create goals',
      () async {
        final input = requestFor(clock);
        final plan = await store.saveDraft(input, testTasks());
        clock.setDay(2026, 10, 10);
        await expectLater(
          store.saveDraft(input, testTasks()),
          throwsA(isA<PlanningException>()),
        );
        await expectLater(
          store.apply(plan.id, testTasks()),
          throwsA(isA<PlanningException>()),
        );
        expect(await store.latestDraft(), isNull);
        expect(await goals.loadGoals(), isEmpty);
      },
    );

    test(
      'a failure on the second goal rolls back all goals and receipt',
      () async {
        final plan = await store.saveDraft(requestFor(clock), testTasks());
        await db.customStatement(
          "CREATE TRIGGER planning_failure BEFORE INSERT ON goal_titles "
          "WHEN NEW.title = 'TEST 整理桌面' BEGIN SELECT RAISE(ABORT, 'injected'); END",
        );
        await expectLater(store.apply(plan.id, testTasks()), throwsA(anything));
        expect(await goals.loadGoals(), isEmpty);
        expect(await db.select(db.syncStates).get(), isEmpty);
        expect(await db.select(db.goalTitles).get(), isEmpty);
        expect((await store.latestDraft())?.id, plan.id);
        await db.customStatement('DROP TRIGGER planning_failure');
        expect(await store.apply(plan.id, testTasks()), hasLength(2));
      },
    );

    test(
      'memory and drafts cannot be read or applied by a different owner',
      () async {
        final other = LocalPlanningStore(
          LocalGoalRepository(db, clock, owner: 'other'),
        );
        await store.savePreferences('TEST 私密偏好');
        final plan = await store.saveDraft(requestFor(clock), testTasks());
        expect(await other.loadPreferences(), '');
        expect(await other.latestDraft(), isNull);
        await expectLater(
          other.apply(plan.id, testTasks()),
          throwsA(isA<PlanningException>()),
        );
        expect(await goals.loadGoals(), isEmpty);
      },
    );

    test(
      'account writes join the existing outbox and stale identity is rejected',
      () async {
        final identities = IdentityStore(db);
        final account = SyncIdentity.account(
          '00000000-0000-4000-8000-000000000001',
        );
        final lease = await identities.finish(await identities.begin(account));
        final accountGoals = LocalGoalRepository(
          db,
          clock,
          owner: account.owner,
          identityLease: lease,
        );
        final accountStore = LocalPlanningStore(accountGoals);
        final plan = await accountStore.saveDraft(
          requestFor(clock),
          testTasks(),
        );
        await accountStore.apply(plan.id, testTasks());
        final outbox = await db.select(db.syncOutbox).get();
        expect(outbox, hasLength(2));
        expect(outbox.every((row) => row.owner == account.owner), isTrue);
        await identities.begin(SyncIdentity.guest);
        await expectLater(
          accountStore.loadPreferences(),
          throwsA(isA<StaleIdentity>()),
        );
        await expectLater(
          accountStore.apply(plan.id, testTasks()),
          throwsA(isA<StaleIdentity>()),
        );
        await expectLater(
          accountStore.saveDraft(requestFor(clock), testTasks()),
          throwsA(isA<StaleIdentity>()),
        );
      },
    );
  });

  test(
    'saved memory and confirmation receipt survive database reopen',
    () async {
      final directory = await Directory.systemTemp.createTemp('planning-test-');
      final file = File('${directory.path}/local.sqlite');
      final clock = TestClock();
      var db = AppDatabase(NativeDatabase(file));
      try {
        var store = LocalPlanningStore(LocalGoalRepository(db, clock));
        await store.savePreferences('TEST saved preference');
        final draft = await store.saveDraft(requestFor(clock), testTasks());
        final ids = await store.apply(draft.id, testTasks());
        await db.close();
        db = AppDatabase(NativeDatabase(file));
        store = LocalPlanningStore(LocalGoalRepository(db, clock));
        expect(await store.loadPreferences(), 'TEST saved preference');
        expect(await store.apply(draft.id, testTasks()), ids);
        expect(await store.goals.loadGoals(), hasLength(2));
      } finally {
        await db.close();
        await directory.delete(recursive: true);
      }
    },
  );

  test('v3 migration preserves every old table and adds only empty planning tables', () async {
    final verifier = SchemaVerifier(GeneratedHelper());
    final schema = await verifier.schemaAt(3);
    schema.rawDatabase.execute(
      "INSERT INTO goals (id,global_id,owner,kind,created_day,created_at) "
      "VALUES (1,'00000000-0000-4000-8000-000000000001','guest',0,'2026-10-09',123)",
    );
    schema.rawDatabase.execute(
      "INSERT INTO goal_titles VALUES (1,'2026-10-09','TEST existing')",
    );
    schema.rawDatabase.execute(
      "INSERT INTO goal_schedules VALUES (1,'2026-10-09',127,NULL)",
    );
    schema.rawDatabase.execute(
      "INSERT INTO goal_reminders (goal_id) VALUES (1)",
    );
    final names = schema.rawDatabase
        .select("SELECT name FROM sqlite_master WHERE type='table'")
        .map((row) => row['name'] as String)
        .toList();
    final before = {
      for (final name in names)
        name: schema.rawDatabase
            .select('SELECT * FROM "$name"')
            .map((row) => Map<String, Object?>.from(row))
            .toList(),
    };
    final db = AppDatabase(schema.newConnection());
    try {
      await verifier.migrateAndValidate(db, db.schemaVersion);
      for (final entry in before.entries) {
        expect(
          (await db.customSelect('SELECT * FROM "${entry.key}"').get())
              .map(
                (row) => {
                  for (final column in entry.value.first.keys)
                    column: row.data[column],
                },
              )
              .toList(),
          entry.value,
        );
      }
      expect(await db.select(db.planningProfiles).get(), isEmpty);
      expect(await db.select(db.planningDrafts).get(), isEmpty);
      expect(await db.customSelect('PRAGMA foreign_key_check').get(), isEmpty);
    } finally {
      await db.close();
      schema.close();
    }
  });
}
