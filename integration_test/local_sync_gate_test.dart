import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/local/open_database.dart';
import 'package:habit_checkin/data/sync/goal_document.dart';
import 'package:habit_checkin/data/sync/identity_store.dart';
import 'package:habit_checkin/data/sync/local_sync_store.dart';
import 'package:habit_checkin/data/sync/sync_engine.dart';
import 'package:habit_checkin/data/sync/sync_identity.dart';
import 'package:habit_checkin/data/sync/sync_protocol.dart';
import 'package:habit_checkin/data/sync/sync_queue.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:habit_checkin/features/reminders/reminder_coordinator.dart';
import 'package:integration_test/integration_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import '../test/support/memory_sync_remote.dart';
import '../test/support/sync_fixtures.dart';
import '../test/support/test_clock.dart';

Future<IdentityLease> _activate(AppDatabase db) async {
  final identities = IdentityStore(db);
  final intent = await identities.begin(accountA);
  return intent.targetOwner == null
      ? identities.active()
      : identities.finish(intent);
}

Future<void> _save(AppDatabase db, String key, String value) =>
    db.customStatement('INSERT INTO sync_probe VALUES (?, ?)', [key, value]);

Future<String> _read(AppDatabase db, String key) async {
  final row = await db
      .customSelect(
        'SELECT value FROM sync_probe WHERE key = ?',
        variables: [Variable.withString(key)],
      )
      .getSingle();
  return row.read<String>('value');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  // Two separate synthetic replica files, never the production database.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  testWidgets(
    'native outbox replay and replica restoration survive separate processes',
    (tester) async {
      const run = String.fromEnvironment('LOCAL_SYNC_RUN');
      const phase = String.fromEnvironment('LOCAL_SYNC_PHASE');
      expect(RegExp(r'^[a-zA-Z0-9-]+$').hasMatch(run), isTrue);
      expect(phase, anyOf('arm', 'replay', 'reopen'));
      final a = openAppDatabase(name: 'habit_checkin_local_sync_${run}_a');
      AppDatabase? b;
      final clock = TestClock();
      try {
        final local = LocalSyncStore(a, clock);
        if (phase == 'arm') {
          expect(
            await a.select(a.goals).get(),
            isEmpty,
            reason: 'Choose a fresh run token',
          );
          await a.customStatement(
            'CREATE TABLE sync_probe (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
          );
          final lease = await _activate(a);
          final repository = LocalGoalRepository(
            a,
            clock,
            owner: accountA.owner,
            identityLease: lease,
          );
          final backend = MemorySyncBackend();
          final remote = MemorySyncRemote(backend, accountA)
            ..afterPush = (_, _) async =>
                throw const SyncFailure(SyncFailureKind.network);
          final engine = SyncEngine(
            queue: SyncQueue(local),
            work: SerialWork(),
            lease: lease,
            connect: (_) => remote,
          );
          final id = await repository.create(
            const GoalDraft(title: 'TEST native seed', kind: GoalKind.habit),
          );
          expect((await engine.run()).status, SyncRunStatus.failed);
          expect(backend.receipts, hasLength(1));
          await _save(
            a,
            'server_committed_request',
            backend.attempts.single.encode(),
          );
          await repository.edit(
            id,
            const GoalDraft(title: 'TEST native pending', kind: GoalKind.habit),
          );
          await repository.setCompleted(id, true, expectedDay: clock.day);
          final operations = await (a.select(
            a.syncOutbox,
          )..orderBy([(r) => OrderingTerm.asc(r.sequence)])).get();
          expect(operations, hasLength(3));
          await _save(
            a,
            'operation_ids',
            jsonEncode(operations.map((r) => r.operationId).toList()),
          );
          await _save(
            a,
            'expected_document',
            (await local.readDocument(id, owner: accountA.owner)).encode(),
          );
          expect((await a.select(a.syncStates).getSingle()).serverRevision, 0);
        } else if (phase == 'replay') {
          final lease = await IdentityStore(a).active();
          expect(lease.identity, accountA);
          final operations = await (a.select(
            a.syncOutbox,
          )..orderBy([(r) => OrderingTerm.asc(r.sequence)])).get();
          expect(
            operations.map((r) => r.operationId).toList(),
            jsonDecode(await _read(a, 'operation_ids')),
          );
          final saved = jsonDecode(
            await _read(a, 'server_committed_request'),
          ) as Map<String, dynamic>;
          // Reconstruct only the persisted test substitute's pre-crash receipt.
          // This is not a live server or a claim of real cloud deduplication.
          final backend = MemorySyncBackend();
          backend.apply(
            SyncRequest(
              identity: accountA,
              operationId: saved['operation_id'] as String,
              kind: SyncOperationKind.parse(saved['kind'] as String),
              baseRevision: saved['base_revision'] as int,
              document: GoalDocument.fromJson(saved['document']),
            ),
          );
          final remote = MemorySyncRemote(backend, accountA);
          final engine = SyncEngine(
            queue: SyncQueue(local),
            work: SerialWork(),
            lease: lease,
            connect: (_) => remote,
          );
          expect(
            (await engine.run(forceRetry: true)).status,
            SyncRunStatus.synced,
          );
          expect(backend.attempts[0].encode(), backend.attempts[1].encode());
          expect(backend.receipts, hasLength(3));
          expect(await a.select(a.syncOutbox).get(), isEmpty);
          final goal = await a.select(a.goals).getSingle();
          expect(
            (await local.readDocument(goal.id, owner: accountA.owner)).encode(),
            await _read(a, 'expected_document'),
          );
          expect((await a.select(a.syncStates).getSingle()).serverRevision, 3);

          b = openAppDatabase(name: 'habit_checkin_local_sync_${run}_b');
          expect(
            await b.select(b.goals).get(),
            isEmpty,
            reason: 'Never replace an existing replica',
          );
          final guestId = await LocalGoalRepository(b, clock).create(
            const GoalDraft(title: 'TEST retained guest', kind: GoalKind.habit),
          );
          final secondLease = await _activate(b);
          final secondLocal = LocalSyncStore(b, clock);
          final secondRemote = MemorySyncRemote(backend, accountA);
          final second = SyncEngine(
            queue: SyncQueue(secondLocal),
            work: SerialWork(),
            lease: secondLease,
            connect: (_) => secondRemote,
          );
          expect((await second.run()).status, SyncRunStatus.synced);
          final restored = await (b.select(
            b.goals,
          )..where((r) => r.owner.equals(accountA.owner))).getSingle();
          expect(restored.id, isNot(guestId));
          expect(
            (await secondLocal.readDocument(
              restored.id,
              owner: accountA.owner,
            )).encode(),
            await _read(a, 'expected_document'),
          );
          expect(
            (await (b.select(
              b.goalReminders,
            )..where((r) => r.goalId.equals(restored.id))).getSingle()).enabled,
            isFalse,
          );
          expect(secondRemote.pushes, 0);
          await _save(a, 'replay_done', '3');
        } else {
          expect(await _read(a, 'replay_done'), '3');
          final expected = await _read(a, 'expected_document');
          b = openAppDatabase(name: 'habit_checkin_local_sync_${run}_b');
          for (final database in [a, b]) {
            expect((await IdentityStore(database).active()).identity, accountA);
            final goal = await (database.select(
              database.goals,
            )..where((r) => r.owner.equals(accountA.owner))).getSingle();
            expect(
              (await LocalSyncStore(
                database,
                clock,
              ).readDocument(goal.id, owner: accountA.owner)).encode(),
              expected,
            );
            expect(await database.select(database.syncOutbox).get(), isEmpty);
            final state = await (database.select(
              database.syncStates,
            )..where((r) => r.goalId.equals(goal.id))).getSingle();
            expect(state.serverRevision, 3);
            expect(state.lastSyncedAt, isNotNull);
            expect(
              await database.customSelect('PRAGMA foreign_key_check').get(),
              isEmpty,
            );
          }
          expect(await b.select(b.reminderOccurrences).get(), isEmpty);
        }
        // Synthetic phase/counters only; no account, token or goal content.
        // ignore: avoid_print
        print('LOCAL_SYNC phase=$phase native=true isolated=true passed=true');
      } finally {
        await a.close();
        await b?.close();
      }
    },
  );
}
