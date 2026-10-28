import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/sync/identity_store.dart';
import 'package:habit_checkin/features/assistant/data/local_proposal_store.dart';
import 'package:habit_checkin/features/assistant/domain/plan_preview.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:habit_checkin/features/reminders/notification_permissions.dart';
import 'package:habit_checkin/features/reminders/reminder_coordinator.dart';
import 'package:habit_checkin/features/reminders/reminder_notifications.dart';
import 'package:habit_checkin/features/reminders/reminder_payload.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'support/assistant_fixtures.dart';
import 'support/sync_fixtures.dart';
import 'support/test_clock.dart';
import 'support/test_reminder_notifications.dart';
import 'support/ui_harness.dart';

class CrossingMidnightRepository extends LocalGoalRepository {
  CrossingMidnightRepository(super.db, TestClock super.clock);
  @override
  Future<int> create(GoalDraft draft) async {
    final id = await super.create(draft);
    (clock as TestClock).setDay(2026, 10, 10);
    return id;
  }
}

void main() {
  setUpAll(tzdata.initializeTimeZones);
  late AppDatabase db;
  late TestClock clock;
  late LocalGoalRepository goals;
  late LocalProposalStore store;
  late TestReminderNotifications platform;
  late TestNotificationPermissions permissions;
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    clock = TestClock();
    goals = LocalGoalRepository(db, clock);
    store = LocalProposalStore(goals);
    platform = TestReminderNotifications();
    permissions = TestNotificationPermissions()
      ..access = NotificationAccess.allowed;
    await seedAssistantReply(db);
  });
  tearDown(() => db.close());

  Future<String> save(PlanPreview preview) => store.saveDraft(
    sessionId: 'test-session',
    messageId: 'test-message',
    preview: preview,
  );

  test('batch undo preserves day records even without a check-in', () async {
    final preview = syntheticPreview();
    final proposal = await save(preview);
    final ids = await store.apply(proposal, preview);
    await db
        .into(db.dayRecords)
        .insert(
          DayRecordsCompanion.insert(
            id: '88888888-8888-4888-8888-888888888888',
            goalId: ids.first,
            owner: 'guest',
            day: clock.day.key,
            content: const Value('TEST private record'),
            savedAt: const Value(100),
            createdAt: 100,
            updatedAt: 100,
          ),
        );
    expect(await db.select(db.checkIns).get(), isEmpty);
    final plan = await store.previewUndo(proposal);
    expect(plan.items.first.disposition, isNot(UndoDisposition.deleted));
    final result = await store.undo(proposal);
    expect(result.items.last.disposition, UndoDisposition.deleted);
    expect((await goals.loadGoals()).single.id, ids.first);
    expect(
      (await db.select(db.dayRecords).get()).single.content,
      'TEST private record',
    );
    expect(await db.customSelect('PRAGMA foreign_key_check').get(), isEmpty);
  });
  ReminderCoordinator coordinator([LocalGoalRepository? repository]) =>
      ReminderCoordinator(
        repository: repository ?? goals,
        clock: clock,
        permissions: permissions,
        notifications: platform,
      );

  test('edited drafts persist while preserving item ownership and receipt immutability', () async {
    final original = syntheticPreview();
    final id = await save(original);
    final edited = original.clearTimes().remove('item-1');
    await store.editDraft(id, edited);
    expect((await store.read(id)).itemsJson, edited.encode());
    expect(await goals.loadGoals(), isEmpty);
    await expectLater(
      store.editDraft(id, original),
      throwsA(isA<GoalRuleException>()),
    );
    await expectLater(
      store.editDraft(id, syntheticPreview(count: 1, habit: true)),
      throwsA(isA<GoalRuleException>()),
    );
    final ids = await store.apply(id, edited);
    expect(ids, hasLength(1));
    await expectLater(
      store.editDraft(id, edited),
      throwsA(isA<GoalRuleException>()),
    );
    expect(await store.apply(id, edited), ids);
  });

  test('draft has no goals; confirmation atomically saves timing and a stable receipt', () async {
    final preview = syntheticPreview();
    final id = await save(preview);
    expect(await goals.loadGoals(), isEmpty);
    expect(await db.select(db.syncOutbox).get(), isEmpty);
    final responses = await Future.wait(
      List.generate(6, (_) => store.apply(id, preview)),
    );
    expect(
      responses.every((ids) => ids.join(',') == responses.first.join(',')),
      isTrue,
    );
    final created = await goals.loadGoals();
    expect(created, hasLength(2));
    expect(created.first.scheduleOn(clock.day).timing.label, '19:00 · 30 分钟');
    expect(
      created.every(
        (goal) => !goal.reminder.enabled && goal.completions.isEmpty,
      ),
      isTrue,
    );
    expect((await store.read(id)).status, 'applied');
    clock.setDay(2026, 10, 10);
    expect(await store.apply(id, preview), responses.first);
    await expectLater(
      store.apply(id, preview.clearTimes()),
      throwsA(isA<GoalRuleException>()),
    );
    expect(await goals.loadGoals(), hasLength(2));
  });

  test('habit weekdays and explicit reminder choices are preserved without permission request', () async {
    final preview = syntheticPreview(habit: true).setReminder('item-0', true);
    final id = await save(preview);
    permissions.access = NotificationAccess.off;
    await store.apply(id, preview);
    final created = await goals.loadGoals();
    expect(
      created.every(
        (goal) =>
            goal.kind == GoalKind.habit &&
            goal.scheduleOn(clock.day).weekdays == 21,
      ),
      isTrue,
    );
    expect(created.first.reminder.enabled, isTrue);
    expect(created.first.reminder.minuteOfDay, 1140);
    expect(created.last.reminder.enabled, isFalse);
    await coordinator().reconcile();
    expect(platform.requests, isEmpty);
    expect(permissions.requests, 0);
  });

  test(
    'invalid or expired previews cannot create, and no unknown items are added',
    () async {
      final preview = syntheticPreview();
      final id = await save(preview);
      await expectLater(
        store.apply(id, PlanPreview([])),
        throwsFormatException,
      );
      await expectLater(
        store.apply(id, syntheticPreview(count: 3)),
        throwsA(isA<GoalRuleException>()),
      );
      clock.setDay(2026, 10, 10);
      await expectLater(store.apply(id, preview), throwsFormatException);
      expect((await store.read(id)).status, 'draft');
      expect(await goals.loadGoals(), isEmpty);
    },
  );

  test(
    'a formerly tomorrow task keeps its absolute date across midnight',
    () async {
      final preview = syntheticPreview(day: '2026-10-10');
      final id = await save(preview);
      clock.setDay(2026, 10, 10);
      await store.apply(id, preview);
      expect(
        (await goals.loadGoals()).every(
          (goal) => goal.scheduleOn(clock.day).plannedDay == clock.day,
        ),
        isTrue,
      );
    },
  );

  test(
    'mid-transaction midnight revalidation rolls back the first created goal',
    () async {
      store = LocalProposalStore(CrossingMidnightRepository(db, clock));
      final preview = syntheticPreview(count: 1);
      final id = await save(preview);
      await expectLater(store.apply(id, preview), throwsFormatException);
      expect(await goals.loadGoals(), isEmpty);
      expect(await db.select(db.goalSchedules).get(), isEmpty);
      expect((await store.read(id)).status, 'draft');
    },
  );

  test('second goal failure rolls back goals, schedules, reminders, outbox and receipt', () async {
    goals = LocalGoalRepository(db, clock, owner: accountA.owner);
    store = LocalProposalStore(goals);
    await seedAssistantReply(db, owner: accountA.owner, id: 'account');
    final preview = syntheticPreview();
    final id = await store.saveDraft(
      sessionId: 'account-session',
      messageId: 'account-message',
      preview: preview,
    );
    await db.customStatement(
      "CREATE TRIGGER fail_second BEFORE INSERT ON goal_titles WHEN new.title = 'TEST item 1' BEGIN SELECT RAISE(ABORT, 'TEST injected'); END",
    );
    await expectLater(store.apply(id, preview), throwsException);
    expect(await goals.loadGoals(), isEmpty);
    expect(await db.select(db.goalSchedules).get(), isEmpty);
    expect(await db.select(db.goalReminders).get(), isEmpty);
    expect(await db.select(db.syncStates).get(), isEmpty);
    expect(await db.select(db.syncOutbox).get(), isEmpty);
    expect((await store.read(id)).appliedGoalIdsJson, isNull);
  });

  test(
    'foreign owner and stale identity cannot read, apply or undo a receipt',
    () async {
      final preview = syntheticPreview();
      final id = await save(preview);
      final other = LocalProposalStore(
        LocalGoalRepository(db, clock, owner: accountA.owner),
      );
      await expectLater(other.read(id), throwsA(isA<GoalRuleException>()));
      await expectLater(
        other.apply(id, preview),
        throwsA(isA<GoalRuleException>()),
      );
      await expectLater(other.undo(id), throwsA(isA<GoalRuleException>()));
      final identities = IdentityStore(db);
      final lease = await identities.active();
      final stale = LocalProposalStore(
        LocalGoalRepository(db, clock, identityLease: lease),
      );
      await identities.begin(accountA);
      await expectLater(
        stale.apply(id, preview),
        throwsA(isA<StaleIdentity>()),
      );
      await expectLater(stale.previewUndo(id), throwsA(isA<StaleIdentity>()));
      await expectLater(stale.undo(id), throwsA(isA<StaleIdentity>()));
      expect(await goals.loadGoals(), isEmpty);
    },
  );

  test('undo retains any check-in, including undone history, and deletes only untouched goals', () async {
    final preview = syntheticPreview(count: 3, reminders: true);
    final id = await save(preview);
    final ids = await store.apply(id, preview);
    await goals.setCompleted(ids[0], true, expectedDay: clock.day);
    await goals.setCompleted(ids[1], true, expectedDay: clock.day);
    await goals.setCompleted(ids[1], false, expectedDay: clock.day);
    await coordinator().reconcile();
    final before = await store.previewUndo(id);
    expect(before.items.map((item) => item.disposition), [
      UndoDisposition.keptHistory,
      UndoDisposition.keptHistory,
      UndoDisposition.deleted,
    ]);
    expect(await goals.loadGoals(), hasLength(3));
    final result = await store.undo(id);
    expect(result.encode(), before.encode());
    expect((await goals.loadGoals()).map((goal) => goal.id), ids.take(2));
    expect(await db.select(db.checkIns).get(), hasLength(2));
    expect(await db.select(db.reminderCancellations).get(), hasLength(1));
    await coordinator().reconcile();
    expect(await db.select(db.reminderCancellations).get(), isEmpty);
    expect(platform.requests, hasLength(1));
    expect(await db.customSelect('PRAGMA foreign_key_check').get(), isEmpty);
    expect((await store.undo(id)).encode(), result.encode());
    await expectLater(
      store.apply(id, preview),
      throwsA(isA<GoalRuleException>()),
    );
  });

  test('undo removes pending account uploads; uploaded or ambiguous ones are archived', () async {
    goals = LocalGoalRepository(db, clock, owner: accountA.owner);
    store = LocalProposalStore(goals);
    await seedAssistantReply(db, owner: accountA.owner, id: 'account');
    final preview = syntheticPreview(count: 3);
    final id = await store.saveDraft(
      sessionId: 'account-session',
      messageId: 'account-message',
      preview: preview,
    );
    final ids = await store.apply(id, preview);
    await (db.update(
      db.syncStates,
    )..where((row) => row.goalId.equals(ids[1]))).write(
      const SyncStatesCompanion(
        serverRevision: Value(1),
        confirmedJson: Value('{}'),
      ),
    );
    await (db.update(
      db.syncOutbox,
    )..where((row) => row.goalId.equals(ids[2]))).write(
      const SyncOutboxCompanion(
        state: Value('in_flight'),
        attempts: Value(1),
        baseRevision: Value(0),
      ),
    );
    final result = await store.undo(id);
    expect(result.items.map((item) => item.disposition), [
      UndoDisposition.deleted,
      UndoDisposition.archivedSynced,
      UndoDisposition.archivedSynced,
    ]);
    expect((await goals.loadGoals()).every((goal) => goal.isArchived), isTrue);
    final outbox = await db.select(db.syncOutbox).get();
    expect(outbox.any((row) => row.goalId == ids.first), isFalse);
    expect(outbox.where((row) => row.kind == 'archive'), hasLength(2));
    expect(outbox.any((row) => row.state == 'in_flight'), isTrue);
    final count = outbox.length;
    await store.undo(id);
    expect(await db.select(db.syncOutbox).get(), hasLength(count));
  });

  test('undo failure rolls back deletions, notification intents and receipt', () async {
    final preview = syntheticPreview(reminders: true);
    final id = await save(preview);
    final ids = await store.apply(id, preview);
    await coordinator().reconcile();
    await db.customStatement(
      "CREATE TRIGGER fail_undo BEFORE DELETE ON goals WHEN old.id = ${ids.last} BEGIN SELECT RAISE(ABORT, 'TEST injected'); END",
    );
    await expectLater(store.undo(id), throwsException);
    expect(await goals.loadGoals(), hasLength(2));
    expect(await db.select(db.reminderOccurrences).get(), hasLength(2));
    expect(await db.select(db.reminderCancellations).get(), isEmpty);
    expect((await store.read(id)).status, 'applied');
    expect(platform.cancelled, isEmpty);
  });

  test(
    'cancellation failure is retryable even after all goals have disappeared',
    () async {
      final preview = syntheticPreview(reminders: true);
      final id = await save(preview);
      await store.apply(id, preview);
      await coordinator().reconcile();
      await store.undo(id);
      platform.ignoreCancel = true;
      await expectLater(coordinator().reconcile(), throwsStateError);
      expect(await db.select(db.reminderCancellations).get(), hasLength(2));
      platform.ignoreCancel = false;
      await coordinator().reconcile();
      expect(platform.requests, isEmpty);
      expect(await db.select(db.reminderCancellations).get(), isEmpty);
      expect(await goals.loadGoals(), isEmpty);
      final count = platform.cancelled.length;
      await store.undo(id);
      await coordinator().reconcile();
      expect(platform.cancelled, hasLength(count));
    },
  );

  test(
    'undo cancels an old system payload after an interrupted reschedule',
    () async {
      final preview = syntheticPreview(count: 1, reminders: true);
      final proposal = await save(preview);
      final ids = await store.apply(proposal, preview);
      await coordinator().reconcile();
      final old = platform.requests.values.single;
      await goals.edit(
        ids.single,
        GoalDraft(
          title: 'TEST changed time',
          kind: GoalKind.single,
          plannedDay: clock.day,
          startMinute: 1200,
          durationMinutes: 30,
          reminderEnabled: true,
          reminderMinute: 1200,
        ),
      );
      platform.onSchedule = (id) async {
        // Emulate a stale system request surviving an ambiguous replacement.
        platform.requests[id] = old;
      };
      await expectLater(coordinator().reconcile(), throwsStateError);
      expect(platform.requests.values.single.payload, old.payload);
      await store.undo(proposal);
      final intent = await db.select(db.reminderCancellations).getSingle();
      expect(intent.payload, isNot(old.payload));
      platform.onSchedule = null;
      await coordinator().reconcile();
      expect(platform.requests, isEmpty);
      expect(await db.select(db.reminderCancellations).get(), isEmpty);
    },
  );

  test(
    'queued cancellation never removes a foreign same-ID notification',
    () async {
      final preview = syntheticPreview(count: 1, reminders: true);
      final id = await save(preview);
      await store.apply(id, preview);
      await coordinator().reconcile();
      await store.undo(id);
      final notificationId = platform.requests.keys.single;
      platform.requests[notificationId] = PendingReminder(
        notificationId,
        'TEST foreign',
      );
      await expectLater(coordinator().reconcile(), throwsStateError);
      expect(platform.cancelled, isEmpty);
      expect(platform.requests, hasLength(1));
      expect(await db.select(db.reminderCancellations).get(), hasLength(1));
    },
  );

  test('cancellation ownership requires all stable fields despite clock or zone changes', () {
    final payload = <String, Object?>{
      'source': 'habit-reminder-v1',
      'owner': 'guest',
      'id': 42,
      'goal': 3,
      'day': '2026-10-09',
      'at': 123,
      'zone': 'Asia/Shanghai',
    };
    final expected = jsonEncode(payload);
    expect(
      sameReminderOccurrence(
        jsonEncode({...payload, 'at': 456, 'zone': 'Asia/Tokyo'}),
        expected,
        42,
      ),
      isTrue,
    );
    for (final field in ['source', 'owner', 'id', 'goal', 'day']) {
      expect(
        sameReminderOccurrence(
          jsonEncode({...payload, field: 'foreign'}),
          expected,
          42,
        ),
        isFalse,
      );
      final missing = Map<String, Object?>.of(payload)..remove(field);
      expect(
        sameReminderOccurrence(jsonEncode(missing), expected, 42),
        isFalse,
      );
    }
    expect(sameReminderOccurrence(expected, expected, 43), isFalse);
    expect(sameReminderOccurrence(null, expected, 42), isFalse);
    expect(sameReminderOccurrence('bad json', expected, 42), isFalse);
  });

  test(
    'identity suspension drains deleted-goal intents before untracked checks',
    () async {
      final preview = syntheticPreview(reminders: true);
      final id = await save(preview);
      await store.apply(id, preview);
      await coordinator().reconcile();
      await store.undo(id);
      await IdentityStore(db).begin(accountA);
      await coordinator().suspendIdentity();
      expect(platform.requests, isEmpty);
      expect(await db.select(db.reminderCancellations).get(), isEmpty);
    },
  );

  test('database reopening retains apply/undo receipts and interrupted platform cancellations', () async {
    final directory = await Directory.systemTemp.createTemp('proposal-reopen-');
    final file = File('${directory.path}/app.sqlite');
    var local = AppDatabase(NativeDatabase(file));
    try {
      await seedAssistantReply(local);
      var repository = LocalGoalRepository(local, clock);
      var proposals = LocalProposalStore(repository);
      final preview = syntheticPreview(reminders: true);
      final id = await proposals.saveDraft(
        sessionId: 'test-session',
        messageId: 'test-message',
        preview: preview,
      );
      final ids = await proposals.apply(id, preview);
      await coordinator(repository).reconcile();
      await local.close();
      local = AppDatabase(NativeDatabase(file));
      repository = LocalGoalRepository(local, clock);
      proposals = LocalProposalStore(repository);
      expect(await proposals.apply(id, preview), ids);
      final result = await proposals.undo(id);
      expect(
        await local.select(local.reminderCancellations).get(),
        hasLength(2),
      );
      await local.close();
      local = AppDatabase(NativeDatabase(file));
      repository = LocalGoalRepository(local, clock);
      proposals = LocalProposalStore(repository);
      expect((await proposals.undo(id)).encode(), result.encode());
      await coordinator(repository).reconcile();
      expect(await repository.loadGoals(), isEmpty);
      expect(platform.requests, isEmpty);
      expect(await local.select(local.reminderCancellations).get(), isEmpty);
    } finally {
      await local.close();
      await directory.delete(recursive: true);
    }
  });
}
