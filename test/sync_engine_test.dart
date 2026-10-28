import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/sync/goal_document.dart';
import 'package:habit_checkin/data/sync/identity_store.dart';
import 'package:habit_checkin/data/sync/local_sync_store.dart';
import 'package:habit_checkin/data/sync/sync_engine.dart';
import 'package:habit_checkin/data/sync/sync_identity.dart';
import 'package:habit_checkin/data/sync/sync_protocol.dart';
import 'package:habit_checkin/data/sync/sync_queue.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:habit_checkin/features/reminders/reminder_coordinator.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'support/memory_sync_remote.dart';
import 'support/sync_fixtures.dart';
import 'support/test_clock.dart';

Future<IdentityLease> _activate(AppDatabase db, SyncIdentity identity) async {
  final store = IdentityStore(db);
  final intent = await store.begin(identity);
  return intent.targetOwner == null ? store.active() : store.finish(intent);
}

class _Device {
  _Device(this.db, this.clock, this.lease, MemorySyncBackend backend) {
    local = LocalSyncStore(db, clock);
    queue = SyncQueue(local);
    repository = LocalGoalRepository(
      db,
      clock,
      owner: lease.identity.owner,
      identityLease: lease,
    );
    remote = MemorySyncRemote(backend, lease.identity);
    engine = SyncEngine(
      queue: queue,
      work: work,
      lease: lease,
      connect: (_) => remote,
    );
  }
  final AppDatabase db;
  final TestClock clock;
  final IdentityLease lease;
  final work = SerialWork();
  late final LocalSyncStore local;
  late final SyncQueue queue;
  late final LocalGoalRepository repository;
  late final MemorySyncRemote remote;
  late final SyncEngine engine;
  Future<List<StoredSyncOperation>> pending() =>
      (db.select(db.syncOutbox)
            ..where(
              (r) =>
                  r.owner.equals(lease.identity.owner) &
                  r.state.isNotValue('superseded'),
            )
            ..orderBy([(r) => OrderingTerm.asc(r.sequence)]))
          .get();
  Future<StoredSyncState> state(int id) =>
      (db.select(db.syncStates)..where((r) => r.goalId.equals(id))).getSingle();
}

void main() {
  setUpAll(() {
    tzdata.initializeTimeZones();
    // Each simulated device uses an independent executor/database file.
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });
  tearDownAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = false);
  late MemorySyncBackend backend;
  late List<AppDatabase> databases;
  late _Device first;

  Future<_Device> device({SyncIdentity? identity, File? file}) async {
    final db = AppDatabase(
      file == null ? NativeDatabase.memory() : NativeDatabase(file),
    );
    databases.add(db);
    return _Device(
      db,
      TestClock(),
      await _activate(db, identity ?? accountA),
      backend,
    );
  }

  setUp(() async {
    backend = MemorySyncBackend();
    databases = [];
    first = await device();
  });
  tearDown(() async {
    for (final db in databases) {
      await db.close();
    }
  });
  GoalDraft draft({
    String title = 'TEST synced',
    bool reminder = false,
    int weekdays = 127,
  }) => GoalDraft(
    title: title,
    kind: GoalKind.habit,
    reminderEnabled: reminder,
    weekdays: weekdays,
  );

  Future<_Device> restored() async {
    final second = await device();
    expect((await second.engine.run()).status, SyncRunStatus.synced);
    return second;
  }

  Future<StoredSyncConflict> unresolved(_Device d) => (d.db.select(
    d.db.syncConflicts,
  )..where((r) => r.resolvedAt.isNull())).getSingle();

  test('guest mode never initializes the remote connection', () async {
    final guest = await device(identity: SyncIdentity.guest);
    await guest.repository.create(draft());
    final engine = SyncEngine(
      queue: guest.queue,
      work: guest.work,
      lease: guest.lease,
      connect: (_) => throw StateError('Guest must not connect'),
    );
    expect((await engine.run()).status, SyncRunStatus.localOnly);
    expect(backend.attempts, isEmpty);
    expect(backend.pulls, 0);
  });

  test('offline create edit complete undo archive upload sequentially after recovery', () async {
    final id = await first.repository.create(draft());
    await first.repository.edit(id, draft(title: 'TEST edited'));
    await first.repository.setCompleted(id, true, expectedDay: first.clock.day);
    await first.repository.setCompleted(
      id,
      false,
      expectedDay: first.clock.day,
    );
    await first.repository.archive(id);
    first.remote.failure = const SyncFailure(SyncFailureKind.network);
    final failure = await first.engine.run();
    expect(failure.status, SyncRunStatus.failed);
    expect(failure.pending, 5);
    expect((await first.repository.loadGoals()).single.isArchived, isTrue);
    expect((await first.state(id)).serverRevision, 0);
    first.remote.failure = null;
    final result = await first.engine.run(forceRetry: true);
    expect(result.status, SyncRunStatus.synced);
    expect(await first.pending(), isEmpty);
    expect(backend.receipts, hasLength(5));
    expect(backend.attempts.map((r) => r.baseRevision), [0, 1, 2, 3, 4]);
    expect(
      backend.goals.values.single.document.checkIns.single.completed,
      isFalse,
    );
    expect(backend.goals.values.single.document.archivedDay, first.clock.day);
    expect((await first.state(id)).serverRevision, 5);
    expect((await first.state(id)).lastSyncedAt, isNotNull);
  });

  test('lost acknowledgment freezes request and does not overwrite a later local edit', () async {
    final id = await first.repository.create(draft());
    var lose = true;
    first.remote.afterPush = (request, reply) async {
      if (lose) {
        lose = false;
        throw const SyncFailure(SyncFailureKind.network);
      }
      return reply;
    };
    expect((await first.engine.run()).status, SyncRunStatus.failed);
    final frozen = backend.attempts.single.encode();
    await first.repository.edit(id, draft(title: 'TEST newer local'));
    first.remote.beforePush = (request) async {
      if (request.kind == SyncOperationKind.edit) {
        expect(
          (await first.repository.loadGoals()).single.titles.single.title,
          'TEST newer local',
        );
      }
    };
    expect(
      (await first.engine.run(forceRetry: true)).status,
      SyncRunStatus.synced,
    );
    expect(backend.attempts[1].encode(), frozen);
    expect(backend.attempts.last.baseRevision, 1);
    expect(backend.receipts, hasLength(2));
    expect(
      backend.goals.values.single.document.titles.single.title,
      'TEST newer local',
    );
    expect(await first.pending(), isEmpty);
  });

  test('reopened file replays the same operation after server commit without local ack', () async {
    final directory = await Directory.systemTemp.createTemp('sync-replay-');
    final file = File('${directory.path}/test.sqlite');
    final before = await device(file: file);
    await before.repository.create(draft());
    before.remote.afterPush = (_, _) async =>
        throw const SyncFailure(SyncFailureKind.timeout);
    expect((await before.engine.run()).status, SyncRunStatus.failed);
    final request = backend.attempts.single.encode();
    await before.db.close();
    databases.remove(before.db);
    final reopened = await device(file: file);
    try {
      expect(
        (await reopened.engine.run(forceRetry: true)).status,
        SyncRunStatus.synced,
      );
      expect(backend.attempts.last.encode(), request);
      expect(backend.receipts, hasLength(1));
      expect(await reopened.pending(), isEmpty);
    } finally {
      await reopened.db.close();
      databases.remove(reopened.db);
      await directory.delete(recursive: true);
    }
  });

  test('timeout can commit late and still deduplicates on retry', () async {
    await first.repository.create(draft());
    final release = Completer<void>();
    final committed = Completer<void>();
    first.remote.beforePush = (_) => release.future;
    first.remote.afterPush = (_, reply) async {
      if (!committed.isCompleted) committed.complete();
      return reply;
    };
    final engine = SyncEngine(
      queue: first.queue,
      work: first.work,
      lease: first.lease,
      connect: (_) => first.remote,
      requestTimeout: const Duration(milliseconds: 10),
    );
    final result = await engine.run();
    expect(result.failure, SyncFailureKind.timeout);
    expect(await first.pending(), hasLength(1));
    release.complete();
    await committed.future;
    expect(
      (await first.engine.run(forceRetry: true)).status,
      SyncRunStatus.synced,
    );
    expect(backend.receipts, hasLength(1));
    expect(backend.attempts[0].encode(), backend.attempts[1].encode());
  });

  test('authentication failure pauses and the same account resumes without losing operations', () async {
    await first.repository.create(draft());
    first.remote.failure = const SyncFailure(SyncFailureKind.authentication);
    expect((await first.engine.run()).status, SyncRunStatus.needsLogin);
    expect(await first.pending(), hasLength(1));
    expect((await first.engine.run()).status, SyncRunStatus.needsLogin);
    expect(first.remote.pushes, 1);
    first.remote.failure = null;
    expect(
      (await first.engine.run(forceRetry: true)).status,
      SyncRunStatus.synced,
    );
    expect(backend.receipts, hasLength(1));
  });

  test('switching identity during a request rejects the late response and preserves its queue', () async {
    await first.repository.create(draft());
    final started = Completer<void>();
    final release = Completer<void>();
    first.remote.beforePush = (_) async {
      started.complete();
      await release.future;
    };
    final running = first.engine.run();
    await started.future;
    final b = await _activate(first.db, accountB);
    release.complete();
    expect((await running).status, SyncRunStatus.stale);
    expect(await first.pending(), hasLength(1));
    final second = _Device(first.db, first.clock, b, backend);
    expect((await second.engine.run()).status, SyncRunStatus.synced);
    expect(await second.repository.loadGoals(), isEmpty);
    expect(second.remote.pushes, 0);
    final again = _Device(
      first.db,
      first.clock,
      await _activate(first.db, accountA),
      backend,
    );
    expect(
      (await again.engine.run(forceRetry: true)).status,
      SyncRunStatus.synced,
    );
    expect(await again.pending(), isEmpty);
    expect(backend.receipts, hasLength(1));
  });

  test('same-day same completion and undo on two devices are idempotent despite clocks', () async {
    final id = await first.repository.create(draft());
    await first.engine.run();
    final second = await restored();
    final otherId = (await second.repository.loadGoals()).single.id;
    for (final completed in [true, false]) {
      first.clock.instant = first.clock.instant.add(const Duration(seconds: 1));
      second.clock.instant = second.clock.instant.add(
        const Duration(seconds: 2),
      );
      await first.repository.setCompleted(
        id,
        completed,
        expectedDay: first.clock.day,
      );
      await second.repository.setCompleted(
        otherId,
        completed,
        expectedDay: second.clock.day,
      );
      expect((await first.engine.run()).status, SyncRunStatus.synced);
      expect((await second.engine.run()).status, SyncRunStatus.synced);
    }
    expect(backend.goals.values.single.revision, 3);
    expect(await second.db.select(second.db.syncConflicts).get(), isEmpty);
    expect(
      backend.goals.values.single.document.checkIns.single.completed,
      isFalse,
    );
    expect(
      (await second.local.readDocument(
        otherId,
        owner: accountA.owner,
      )).encode(),
      backend.goals.values.single.document.encode(),
    );
  });

  test('conflict preserves both versions and newer work while other goals continue', () async {
    final id = await first.repository.create(draft());
    await first.engine.run();
    final second = await restored();
    final otherId = (await second.repository.loadGoals()).single.id;
    await first.repository.edit(id, draft(title: 'TEST server choice'));
    await second.repository.edit(otherId, draft(title: 'TEST local choice'));
    await second.repository.setCompleted(
      otherId,
      true,
      expectedDay: second.clock.day,
    );
    await second.repository.create(draft(title: 'TEST independent'));
    await first.engine.run();
    final result = await second.engine.run();
    expect(result.status, SyncRunStatus.conflict);
    expect(backend.goals, hasLength(2));
    var conflict = await unresolved(second);
    expect(
      GoalDocument.decode(conflict.localJson).checkIns.single.completed,
      isTrue,
    );
    expect(
      GoalDocument.decode(conflict.remoteJson).titles.single.title,
      'TEST server choice',
    );
    final revision = (await second.state(otherId)).localRevision;
    await second.repository.edit(otherId, draft(title: 'TEST latest local'));
    await expectLater(
      second.queue.resolve(
        lease: second.lease,
        conflictId: conflict.id,
        choice: ConflictChoice.local,
        expectedLocalRevision: revision,
        expectedRemoteRevision: conflict.remoteRevision,
      ),
      throwsStateError,
    );
    conflict = await unresolved(second);
    expect(
      GoalDocument.decode(conflict.localJson).titles.single.title,
      'TEST latest local',
    );
    final resolution = await second.queue.resolve(
      lease: second.lease,
      conflictId: conflict.id,
      choice: ConflictChoice.local,
      expectedLocalRevision: (await second.state(otherId)).localRevision,
      expectedRemoteRevision: conflict.remoteRevision,
    );
    expect(resolution.operationId, isNot(conflict.operationId));
    expect((await second.engine.run()).status, SyncRunStatus.synced);
    final kept = await second.db.select(second.db.syncConflicts).getSingle();
    expect(kept.localJson, conflict.localJson);
    expect(kept.remoteJson, conflict.remoteJson);
    expect(kept.resolvedAt, isNotNull);
    expect(
      (await second.db.select(second.db.syncOutbox).get()).every(
        (r) => r.state == 'superseded',
      ),
      isTrue,
    );
    await first.engine.run();
    expect(
      (await first.local.readDocument(
        id,
        owner: accountA.owner,
      )).titles.single.title,
      'TEST latest local',
    );
  });

  test('server advances during conflict resolution and requires a new explicit decision', () async {
    final id = await first.repository.create(draft());
    await first.engine.run();
    final second = await restored();
    final otherId = (await second.repository.loadGoals()).single.id;
    await first.repository.edit(id, draft(title: 'TEST remote one'));
    await first.engine.run();
    await second.repository.edit(otherId, draft(title: 'TEST local'));
    await second.engine.run();
    final conflict = await unresolved(second);
    await second.queue.resolve(
      lease: second.lease,
      conflictId: conflict.id,
      choice: ConflictChoice.local,
      expectedLocalRevision: (await second.state(otherId)).localRevision,
      expectedRemoteRevision: conflict.remoteRevision,
    );
    await first.repository.edit(id, draft(title: 'TEST remote two'));
    await first.engine.run();
    expect((await second.engine.run()).status, SyncRunStatus.conflict);
    final next = await unresolved(second);
    expect(next.id, isNot(conflict.id));
    expect(next.remoteRevision, 3);
    final originalLocal = next.localJson;
    await second.queue.resolve(
      lease: second.lease,
      conflictId: next.id,
      choice: ConflictChoice.remote,
      expectedLocalRevision: (await second.state(otherId)).localRevision,
      expectedRemoteRevision: next.remoteRevision,
    );
    expect((await second.engine.run()).status, SyncRunStatus.synced);
    final all = await second.db.select(second.db.syncConflicts).get();
    expect(all, hasLength(2));
    expect(all.singleWhere((r) => r.id == next.id).localJson, originalLocal);
    expect(
      (await second.local.readDocument(
        otherId,
        owner: accountA.owner,
      )).titles.single.title,
      'TEST remote two',
    );
  });

  test('archive conflict cannot revive a goal without trustworthy pre-archive proof', () async {
    final id = await first.repository.create(draft());
    await first.engine.run();
    final second = await restored();
    final otherId = (await second.repository.loadGoals()).single.id;
    await first.repository.archive(id);
    await first.engine.run();
    await second.repository.edit(
      otherId,
      draft(title: 'TEST offline edit', reminder: true),
    );
    expect((await second.engine.run()).status, SyncRunStatus.conflict);
    final conflict = await unresolved(second);
    final result = await second.queue.resolve(
      lease: second.lease,
      conflictId: conflict.id,
      choice: ConflictChoice.local,
      expectedLocalRevision: (await second.state(otherId)).localRevision,
      expectedRemoteRevision: conflict.remoteRevision,
    );
    expect(result.archivePreserved, isTrue);
    expect((await second.engine.run()).status, SyncRunStatus.synced);
    expect((await second.repository.loadGoals()).single.isArchived, isTrue);
    expect(
      (await second.repository.loadGoals()).single.reminder.enabled,
      isFalse,
    );
    expect(backend.goals.values.single.document.archivedDay, isNotNull);
    expect(
      backend.goals.values.single.document.titles.single.title,
      'TEST offline edit',
    );
  });

  test('pull never overwrites pending work and older snapshots cannot lower revision', () async {
    final id = await first.repository.create(draft());
    await first.engine.run();
    final old = await first.remote.pull();
    await first.repository.edit(id, draft(title: 'TEST pending'));
    await first.queue.mergePull(first.lease, old);
    expect(
      (await first.repository.loadGoals()).single.titles.single.title,
      'TEST pending',
    );
    expect(await first.pending(), hasLength(1));
    await first.engine.run();
    await first.queue.mergePull(first.lease, old);
    expect((await first.state(id)).serverRevision, 2);
    expect(
      (await first.repository.loadGoals()).single.titles.single.title,
      'TEST pending',
    );
  });

  test('restoration keeps complete history and uses new local IDs with reminders off', () async {
    final habit = await first.repository.create(draft(reminder: true));
    final single = await first.repository.create(
      GoalDraft(
        title: 'TEST overdue',
        kind: GoalKind.single,
        plannedDay: first.clock.day,
        reminderEnabled: true,
      ),
    );
    await first.repository.setCompleted(
      habit,
      true,
      expectedDay: first.clock.day,
    );
    first.clock.setDay(2026, 10, 10);
    await first.repository.edit(
      habit,
      draft(title: 'TEST renamed', weekdays: 15, reminder: true),
    );
    await first.repository.setCompleted(
      habit,
      true,
      expectedDay: first.clock.day,
    );
    await first.repository.setCompleted(
      habit,
      false,
      expectedDay: first.clock.day,
    );
    first.clock.setDay(2026, 10, 11);
    await first.repository.setCompleted(
      single,
      true,
      expectedDay: first.clock.day,
    );
    await first.repository.archive(single);
    expect((await first.engine.run()).status, SyncRunStatus.synced);
    final guest = await device(identity: SyncIdentity.guest);
    final guestId = await guest.repository.create(
      draft(title: 'TEST keep guest'),
    );
    final second = _Device(
      guest.db,
      guest.clock,
      await _activate(guest.db, accountA),
      backend,
    );
    final pushes = backend.attempts.length;
    expect((await second.engine.run()).status, SyncRunStatus.synced);
    final goals = await second.repository.loadGoals();
    expect(goals, hasLength(2));
    expect(goals.every((g) => g.id != guestId && !g.reminder.enabled), isTrue);
    expect(
      await second.db.select(second.db.reminderOccurrences).get(),
      isEmpty,
    );
    for (final goal in goals) {
      final doc = await second.local.readDocument(
        goal.id,
        owner: accountA.owner,
      );
      expect(doc.encode(), backend.goals[doc.id]!.document.encode());
    }
    expect(backend.attempts.length, pushes);
    expect(
      goals
          .singleWhere((g) => g.kind == GoalKind.single)
          .singleCompletion!
          .plannedDay!
          .key,
      '2026-10-09',
    );
  });

  test('truncated or mixed-owner snapshots roll back instead of partially importing', () async {
    final remote = RemoteGoal(
      identity: accountA,
      revision: 1,
      document: syntheticDocument(),
    );
    await expectLater(
      first.queue.mergePull(
        first.lease,
        RemoteSnapshot(identity: accountA, goals: [remote], totalCount: 1001),
      ),
      throwsA(isA<SyncFailure>()),
    );
    final foreign = RemoteGoal(
      identity: accountB,
      revision: 1,
      document: GoalDocument.fromJson(
        syntheticDocumentJson(id: '44444444-4444-4444-8444-444444444444'),
      ),
    );
    await expectLater(
      first.queue.mergePull(
        first.lease,
        RemoteSnapshot(
          identity: accountA,
          goals: [remote, foreign],
          totalCount: 2,
        ),
      ),
      throwsA(isA<SyncFailure>()),
    );
    expect(await first.repository.loadGoals(), isEmpty);
    expect(await first.db.select(first.db.syncStates).get(), isEmpty);
  });

  test(
    'wrong-owner acknowledgments are rejected and never mark local work synced',
    () async {
      final id = await first.repository.create(draft());
      first.remote.afterPush = (request, reply) async => SyncAccepted(
        request.operationId,
        RemoteGoal(
          identity: accountB,
          revision: reply.goal.revision,
          document: reply.goal.document,
        ),
      );
      expect((await first.engine.run()).status, SyncRunStatus.failed);
      expect((await first.state(id)).serverRevision, 0);
      expect(await first.pending(), hasLength(1));
      expect(
        (await first.db.select(first.db.goals).getSingle()).owner,
        accountA.owner,
      );
    },
  );

  test(
    'completion from an older device conflicts with a newer explicit undo',
    () async {
      final id = await first.repository.create(draft());
      await first.engine.run();
      final second = await restored();
      final otherId = (await second.repository.loadGoals()).single.id;
      await first.repository.setCompleted(
        id,
        true,
        expectedDay: first.clock.day,
      );
      await second.repository.setCompleted(
        otherId,
        true,
        expectedDay: second.clock.day,
      );
      await second.engine.run();
      await second.repository.setCompleted(
        otherId,
        false,
        expectedDay: second.clock.day,
      );
      await second.engine.run();
      expect((await first.engine.run()).status, SyncRunStatus.conflict);
      final conflict = await unresolved(first);
      expect(
        GoalDocument.decode(conflict.localJson).checkIns.single.completed,
        isTrue,
      );
      expect(
        GoalDocument.decode(conflict.remoteJson).checkIns.single.completed,
        isFalse,
      );
      expect(
        (await first.repository.loadGoals()).single.completionOn(
          first.clock.day,
        ),
        isNotNull,
      );
    },
  );

  test('concurrent triggers share one worker and never claim synced before acknowledgment', () async {
    final id = await first.repository.create(draft());
    final started = Completer<void>();
    final release = Completer<void>();
    first.remote.beforePush = (_) async {
      started.complete();
      await release.future;
    };
    final one = first.engine.run();
    await started.future;
    final two = first.engine.run();
    expect(identical(one, two), isTrue);
    expect(
      (await first.queue.result(first.lease, pulled: false)).status,
      SyncRunStatus.pending,
    );
    expect((await first.state(id)).lastSyncedAt, isNull);
    release.complete();
    expect((await one).status, SyncRunStatus.synced);
    expect((await two).status, SyncRunStatus.synced);
    expect(first.remote.pushes, 1);
    expect(backend.receipts, hasLength(1));
  });

  test(
    'local acknowledgment failure rolls back and replays the server receipt',
    () async {
      final id = await first.repository.create(draft());
      await first.db.customStatement(
        "CREATE TRIGGER fail_ack BEFORE UPDATE ON sync_states "
        "WHEN NEW.server_revision > OLD.server_revision "
        "BEGIN SELECT RAISE(ABORT, 'synthetic acknowledgment failure'); END",
      );
      await expectLater(first.engine.run(), throwsException);
      expect((await first.state(id)).serverRevision, 0);
      expect(await first.pending(), hasLength(1));
      expect(backend.receipts, hasLength(1));
      await first.db.customStatement('DROP TRIGGER fail_ack');
      expect((await first.engine.run()).status, SyncRunStatus.synced);
      expect(backend.attempts[0].encode(), backend.attempts[1].encode());
      expect(backend.receipts, hasLength(1));
    },
  );

  test(
    'acknowledgment cannot silently omit a false historical record',
    () async {
      final id = await first.repository.create(draft());
      await first.repository.setCompleted(
        id,
        true,
        expectedDay: first.clock.day,
      );
      await first.repository.setCompleted(
        id,
        false,
        expectedDay: first.clock.day,
      );
      first.remote.afterPush = (request, reply) async {
        if (request.kind != SyncOperationKind.setUncompleted) return reply;
        return SyncAccepted(
          request.operationId,
          RemoteGoal(
            identity: accountA,
            revision: reply.goal.revision,
            document: GoalDocument.fromJson({
              ...reply.goal.document.toJson(),
              'check_ins': [],
            }),
          ),
        );
      };
      expect((await first.engine.run()).status, SyncRunStatus.failed);
      expect((await first.state(id)).serverRevision, 2);
      expect(await first.pending(), hasLength(1));
      expect(
        (await first.local.readDocument(
          id,
          owner: accountA.owner,
        )).checkIns.single.completed,
        isFalse,
      );
      first.remote.afterPush = null;
      expect(
        (await first.engine.run(forceRetry: true)).status,
        SyncRunStatus.synced,
      );
    },
  );

  test('pull cannot replace another local owner or silently lose known server records', () async {
    final guest = await device(identity: SyncIdentity.guest);
    final id = await guest.repository.create(draft());
    final document = await guest.local.readDocument(id, owner: 'guest');
    final lease = await _activate(guest.db, accountA);
    final queue = SyncQueue(guest.local);
    await expectLater(
      queue.mergePull(
        lease,
        RemoteSnapshot(
          identity: accountA,
          totalCount: 1,
          goals: [
            RemoteGoal(identity: accountA, revision: 1, document: document),
          ],
        ),
      ),
      throwsA(isA<SyncFailure>()),
    );
    expect((await guest.db.select(guest.db.goals).getSingle()).owner, 'guest');
    await first.repository.create(draft());
    await first.engine.run();
    await expectLater(
      first.queue.mergePull(
        first.lease,
        RemoteSnapshot(identity: accountA, goals: [], totalCount: 0),
      ),
      throwsA(isA<SyncFailure>()),
    );
    expect(await first.repository.loadGoals(), hasLength(1));
  });

  test('same operation ID with changed payload is rejected by the remote contract substitute', () async {
    await first.repository.create(draft());
    await first.engine.run();
    final request = backend.attempts.single;
    final value = request.document.toJson();
    value['titles'] = [
      {
        'effective_day': request.document.createdDay.key,
        'title': 'TEST illegal replacement',
      },
    ];
    final changed = SyncRequest(
      identity: request.identity,
      operationId: request.operationId,
      kind: request.kind,
      baseRevision: request.baseRevision,
      document: GoalDocument.fromJson(value),
    );
    await expectLater(first.remote.push(changed), throwsA(isA<SyncFailure>()));
    expect(
      backend.goals.values.single.document.titles.single.title,
      'TEST synced',
    );
    expect(backend.receipts, hasLength(1));
  });

  test('reminder callback failure does not roll back confirmed sync or reopen uploads', () async {
    await first.repository.create(draft());
    final engine = SyncEngine(
      queue: first.queue,
      work: first.work,
      lease: first.lease,
      connect: (_) => first.remote,
      onLocalApplied: () async =>
          throw StateError('synthetic reminder failure'),
    );
    expect((await engine.run()).status, SyncRunStatus.synced);
    expect(await first.pending(), isEmpty);
    expect(backend.receipts, hasLength(1));
  });

  test('manual retry respects server Retry-After and does not spin', () async {
    await first.repository.create(draft());
    first.remote.failure = const SyncFailure(
      SyncFailureKind.rateLimited,
      retryAfter: Duration(minutes: 10),
    );
    expect((await first.engine.run()).status, SyncRunStatus.failed);
    first.remote.failure = null;
    expect(
      (await first.engine.run(forceRetry: true)).status,
      SyncRunStatus.failed,
    );
    expect(first.remote.pushes, 1);
    first.clock.instant = first.clock.instant.add(const Duration(minutes: 10));
    expect((await first.engine.run()).status, SyncRunStatus.synced);
    expect(backend.receipts, hasLength(1));
  });
}
