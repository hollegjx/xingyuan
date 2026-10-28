import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
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
  late LocalGoalRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    clock = TestClock();
    repo = LocalGoalRepository(db, clock, owner: accountA.owner);
  });
  tearDown(() => db.close());

  GoalDraft draft({String title = 'TEST queued', bool reminder = false}) =>
      GoalDraft(
        title: title,
        kind: GoalKind.habit,
        reminderEnabled: reminder,
        reminderMinute: 1200,
      );

  Future<List<StoredSyncOperation>> operations() => (db.select(
    db.syncOutbox,
  )..orderBy([(r) => OrderingTerm.asc(r.sequence)])).get();

  Future<void> rejectQueue() => db.customStatement(
    "CREATE TRIGGER reject_queue BEFORE INSERT ON sync_outbox "
    "BEGIN SELECT RAISE(ABORT, 'synthetic outbox failure'); END",
  );

  test('guest and legacy identities never produce uploads', () async {
    for (final owner in ['guest', 'synthetic-owner']) {
      final local = LocalGoalRepository(db, clock, owner: owner);
      final id = await local.create(draft());
      await local.edit(id, draft(title: 'TEST renamed'));
      await local.setCompleted(id, true, expectedDay: clock.day);
      await local.setCompleted(id, false, expectedDay: clock.day);
      await local.archive(id);
    }
    expect(await operations(), isEmpty);
    expect(
      (await db.select(db.syncStates).get()).every(
        (s) => s.localRevision == 5 && s.serverRevision == 0,
      ),
      isTrue,
    );
  });

  test(
    'account mutations append immutable snapshots in the same transaction',
    () async {
      final id = await repo.create(draft(reminder: true));
      await repo.edit(id, draft(title: 'TEST renamed', reminder: true));
      await repo.setCompleted(id, true, expectedDay: clock.day);
      await repo.setCompleted(id, false, expectedDay: clock.day);
      await repo.archive(id);
      final rows = await operations();
      expect(rows.map((r) => r.kind), [
        'create',
        'edit',
        'set_completed',
        'set_uncompleted',
        'archive',
      ]);
      expect(rows.map((r) => r.localRevision), [1, 2, 3, 4, 5]);
      expect(rows.map((r) => r.operationId).toSet(), hasLength(5));
      expect(
        rows.every(
          (r) =>
              r.owner == accountA.owner &&
              r.baseRevision == null &&
              r.attempts == 0,
        ),
        isTrue,
      );
      final documents = rows
          .map((r) => GoalDocument.decode(r.documentJson))
          .toList();
      expect(documents.first.titles.single.title, 'TEST queued');
      expect(documents.first.checkIns, isEmpty);
      expect(documents[2].checkIns.single.completed, isTrue);
      expect(documents[3].checkIns.single.completed, isFalse);
      expect(documents.last.archivedDay, clock.day);
      expect(documents.every((d) => !d.encode().contains('reminder')), isTrue);
      expect(documents.map((d) => d.id).toSet(), hasLength(1));
      final state = await db.select(db.syncStates).getSingle();
      expect(state.serverRevision, 0);
      expect(state.confirmedJson, isNull);
      expect(state.lastSyncedAt, isNull);
    },
  );

  test(
    'reminder-only changes and duplicate taps do not enqueue cloud operations',
    () async {
      final id = await repo.create(draft());
      await repo.edit(id, draft(reminder: true));
      await repo.edit(id, draft(reminder: true));
      expect(await operations(), hasLength(1));
      await repo.setCompleted(id, true, expectedDay: clock.day);
      await repo.setCompleted(id, true, expectedDay: clock.day);
      await repo.setCompleted(id, false, expectedDay: clock.day);
      await repo.setCompleted(id, false, expectedDay: clock.day);
      await repo.archive(id);
      await repo.archive(id);
      expect(await operations(), hasLength(4));
      expect((await db.select(db.syncStates).getSingle()).localRevision, 4);
    },
  );

  test('outbox creation failure rolls back every new business row', () async {
    await rejectQueue();
    await expectLater(repo.create(draft(reminder: true)), throwsException);
    expect(await db.select(db.goals).get(), isEmpty);
    expect(await db.select(db.goalTitles).get(), isEmpty);
    expect(await db.select(db.goalSchedules).get(), isEmpty);
    expect(await db.select(db.goalReminders).get(), isEmpty);
    expect(await db.select(db.syncStates).get(), isEmpty);
    expect(await operations(), isEmpty);
  });

  test('outbox failure rolls back edit, completion, archive and reminder revisions', () async {
    final id = await repo.create(draft());
    await rejectQueue();
    await expectLater(
      repo.edit(id, draft(title: 'TEST failed', reminder: true)),
      throwsException,
    );
    await expectLater(
      repo.setCompleted(id, true, expectedDay: clock.day),
      throwsException,
    );
    await expectLater(repo.archive(id), throwsException);
    final goal = (await repo.loadGoals()).single;
    expect(goal.titles.single.title, 'TEST queued');
    expect(goal.completions, isEmpty);
    expect(goal.isArchived, isFalse);
    expect(goal.reminder.revision, 0);
    expect(goal.reminder.enabled, isFalse);
    expect((await db.select(db.syncStates).getSingle()).localRevision, 1);
    expect(await operations(), hasLength(1));
  });

  test(
    'history exports are owner-scoped and keep overdue and false event data',
    () async {
      final id = await repo.create(
        GoalDraft(
          title: 'TEST single',
          kind: GoalKind.single,
          plannedDay: clock.day,
        ),
      );
      clock.setDay(2026, 10, 11);
      await repo.setCompleted(id, true, expectedDay: clock.day);
      await repo.setCompleted(id, false, expectedDay: clock.day);
      final store = LocalSyncStore(db, clock);
      await expectLater(
        store.readDocument(id, owner: accountB.owner),
        throwsStateError,
      );
      final document = await store.readDocument(id, owner: accountA.owner);
      expect(document.checkIns.single.completed, isFalse);
      expect(document.checkIns.single.day.key, '2026-10-11');
      expect(document.checkIns.single.plannedDay!.key, '2026-10-09');
      expect(document.checkIns.single.occurrenceKey, 'once');
    },
  );

  test(
    'queue IDs and captured payloads survive a file database reopen',
    () async {
      await db.close();
      final directory = await Directory.systemTemp.createTemp('local-outbox-');
      final file = File('${directory.path}/test.sqlite');
      final first = AppDatabase(NativeDatabase(file));
      late List<String> before;
      try {
        final repository = LocalGoalRepository(
          first,
          clock,
          owner: accountA.owner,
        );
        final id = await repository.create(draft());
        await repository.setCompleted(id, true, expectedDay: clock.day);
        before = (await first.select(first.syncOutbox).get())
            .map((r) => '${r.operationId}:${r.documentJson}')
            .toList();
      } finally {
        await first.close();
      }
      final reopened = AppDatabase(NativeDatabase(file));
      try {
        expect(
          (await reopened.select(reopened.syncOutbox).get()).map(
            (r) => '${r.operationId}:${r.documentJson}',
          ),
          before,
        );
        expect(
          await reopened.customSelect('PRAGMA foreign_key_check').get(),
          isEmpty,
        );
      } finally {
        await reopened.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
