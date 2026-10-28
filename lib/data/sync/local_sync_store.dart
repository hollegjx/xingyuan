import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../shared/app_clock.dart';
import '../local/app_database.dart';
import 'goal_document.dart';
import 'identity_store.dart';
import 'sync_identity.dart';
import 'sync_protocol.dart';

class LocalSyncStore {
  LocalSyncStore(this.db, this.clock);

  final AppDatabase db;
  final AppClock clock;

  Future<List<int>> transferGuest({
    required IdentityLease lease,
    required String transferId,
  }) => db.transaction(() async {
    await IdentityStore(db).require(lease);
    if (lease.identity.isGuest || !SyncIdentity.isUuid(transferId)) {
      throw const FormatException('Invalid guest transfer');
    }
    final previous = await (db.select(
      db.guestTransfers,
    )..where((row) => row.id.equals(transferId))).getSingleOrNull();
    if (previous != null) {
      if (previous.targetOwner != lease.identity.owner) {
        throw const StaleIdentity();
      }
      return (jsonDecode(previous.goalIdsJson) as List).cast<int>();
    }
    final armed =
        await (db.select(db.reminderOccurrences)..where(
              (row) => row.owner.equals('guest') & row.armed.equals(true),
            ))
            .get();
    if (armed.isNotEmpty) {
      throw StateError('Guest reminders must be suspended before transfer');
    }
    final goals =
        await (db.select(db.goals)
              ..where((row) => row.owner.equals('guest'))
              ..orderBy([(row) => OrderingTerm.asc(row.id)]))
            .get();
    for (final goal in goals) {
      final state = await (db.select(
        db.syncStates,
      )..where((row) => row.goalId.equals(goal.id))).getSingleOrNull();
      if (state != null && state.serverRevision != 0) {
        throw StateError('Guest data already has a server revision');
      }
      await (db.update(
            db.goals,
          )..where((row) => row.id.equals(goal.id) & row.owner.equals('guest')))
          .write(GoalsCompanion(owner: Value(lease.identity.owner)));
      await recordMutation(
        goal.id,
        owner: lease.identity.owner,
        kind: SyncOperationKind.importGuest,
      );
    }
    final ids = goals.map((row) => row.id).toList();
    await db
        .into(db.guestTransfers)
        .insert(
          GuestTransfersCompanion.insert(
            id: transferId,
            targetOwner: lease.identity.owner,
            goalIdsJson: jsonEncode(ids),
            createdAt: clock.read().instant.microsecondsSinceEpoch,
          ),
        );
    return List.unmodifiable(ids);
  });

  Future<GoalDocument> readDocument(int id, {required String owner}) =>
      db.transaction(() async {
        final goal =
            await (db.select(db.goals)
                  ..where((row) => row.id.equals(id) & row.owner.equals(owner)))
                .getSingleOrNull();
        if (goal == null) throw StateError('Goal not in this identity');
        final titles = await (db.select(
          db.goalTitles,
        )..where((row) => row.goalId.equals(id))).get();
        final schedules = await (db.select(
          db.goalSchedules,
        )..where((row) => row.goalId.equals(id))).get();
        final checks = await (db.select(
          db.checkIns,
        )..where((row) => row.goalId.equals(id))).get();
        return GoalDocument.fromJson({
          'version': 2,
          'id': goal.globalId,
          'kind': goal.kind,
          'created_day': goal.createdDay,
          'created_at': goal.createdAt,
          'archived_day': goal.archivedDay,
          'archived_at': goal.archivedAt,
          'titles': [
            for (final row in titles)
              {'effective_day': row.effectiveDay, 'title': row.title},
          ],
          'schedules': [
            for (final row in schedules)
              {
                'effective_day': row.effectiveDay,
                'weekdays': row.weekdays,
                'planned_day': row.plannedDay,
                'start_minute': row.startMinute,
                'duration_minutes': row.durationMinutes,
              },
          ],
          'check_ins': [
            for (final row in checks)
              {
                'occurrence_key': row.occurrenceKey,
                'completed': row.completed,
                'completed_day': row.completedDay,
                'completed_at': row.completedAt,
                'zone': row.zone,
                'title_snapshot': row.titleSnapshot,
                'planned_day': row.plannedDay,
              },
          ],
        });
      });

  /// Call inside the same transaction as the completed business mutation.
  Future<String?> recordMutation(
    int id, {
    required String owner,
    required SyncOperationKind kind,
  }) => db.transaction(() async {
    final goal =
        await (db.select(db.goals)
              ..where((row) => row.id.equals(id) & row.owner.equals(owner)))
            .getSingleOrNull();
    if (goal == null) throw StateError('Goal not in this identity');
    await db
        .into(db.syncStates)
        .insert(
          SyncStatesCompanion.insert(goalId: Value(id)),
          mode: InsertMode.insertOrIgnore,
        );
    final state = await (db.select(
      db.syncStates,
    )..where((row) => row.goalId.equals(id))).getSingle();
    final revision = state.localRevision + 1;
    await (db.update(db.syncStates)..where((row) => row.goalId.equals(id)))
        .write(SyncStatesCompanion(localRevision: Value(revision)));
    final identity = SyncIdentity.tryParse(owner);
    if (identity == null || identity.isGuest) return null;
    final document = await readDocument(id, owner: owner);
    final operationId = const Uuid().v4();
    await db
        .into(db.syncOutbox)
        .insert(
          SyncOutboxCompanion.insert(
            operationId: operationId,
            owner: owner,
            goalId: id,
            kind: kind.wireName,
            documentJson: document.encode(),
            localRevision: revision,
            createdAt: clock.read().instant.microsecondsSinceEpoch,
          ),
        );
    if (kind != SyncOperationKind.resolveConflict) {
      await (db.update(db.syncConflicts)..where(
            (row) =>
                row.goalId.equals(id) &
                row.owner.equals(owner) &
                row.resolvedAt.isNull(),
          ))
          .write(SyncConflictsCompanion(localJson: Value(document.encode())));
    }
    return operationId;
  });

  /// Applies a canonical server document without writing a new upload.
  Future<int> applyDocument(
    GoalDocument document, {
    required String owner,
  }) => db.transaction(() async {
    final existing = await (db.select(
      db.goals,
    )..where((row) => row.globalId.equals(document.id))).getSingleOrNull();
    if (existing != null && existing.owner != owner) {
      throw const SyncFailure(SyncFailureKind.denied);
    }
    if (existing != null) {
      final before = await readDocument(existing.id, owner: owner);
      if (!document.hasSameOrigin(before) ||
          document.retainingHistoryFrom(before).encode() != document.encode() ||
          (before.archivedDay != null && document.archivedDay == null)) {
        throw const SyncFailure(SyncFailureKind.invalidData);
      }
      if (before.encode() == document.encode()) return existing.id;
    }
    final int id;
    if (existing == null) {
      id = await db
          .into(db.goals)
          .insert(
            GoalsCompanion.insert(
              globalId: Value(document.id),
              owner: Value(owner),
              kind: document.kind.index,
              createdDay: document.createdDay.key,
              createdAt: document.createdAt.microsecondsSinceEpoch,
              archivedDay: Value(document.archivedDay?.key),
              archivedAt: Value(document.archivedAt?.microsecondsSinceEpoch),
            ),
          );
      await db
          .into(db.goalReminders)
          .insert(
            GoalRemindersCompanion.insert(
              goalId: Value(id),
              needsReconcile: const Value(false),
            ),
          );
      await db
          .into(db.syncStates)
          .insert(SyncStatesCompanion.insert(goalId: Value(id)));
    } else {
      id = existing.id;
      await (db.update(db.goals)..where((row) => row.id.equals(id))).write(
        GoalsCompanion(
          archivedDay: Value(document.archivedDay?.key),
          archivedAt: Value(document.archivedAt?.microsecondsSinceEpoch),
        ),
      );
      final reminder = await (db.select(
        db.goalReminders,
      )..where((row) => row.goalId.equals(id))).getSingle();
      final dirty =
          reminder.enabled ||
          reminder.needsReconcile ||
          reminder.status != 'disabled';
      await (db.update(
        db.goalReminders,
      )..where((row) => row.goalId.equals(id))).write(
        GoalRemindersCompanion(
          enabled: Value(document.archivedDay == null && reminder.enabled),
          revision: Value(reminder.revision + 1),
          needsReconcile: Value(dirty),
          status: Value(dirty ? 'pending' : 'disabled'),
        ),
      );
    }
    for (final row in document.titles) {
      await db
          .into(db.goalTitles)
          .insertOnConflictUpdate(
            GoalTitlesCompanion.insert(
              goalId: id,
              effectiveDay: row.effectiveDay.key,
              title: row.title,
            ),
          );
    }
    for (final row in document.schedules) {
      await db
          .into(db.goalSchedules)
          .insertOnConflictUpdate(
            GoalSchedulesCompanion.insert(
              goalId: id,
              effectiveDay: row.effectiveDay.key,
              weekdays: row.weekdays,
              plannedDay: Value(row.plannedDay?.key),
              startMinute: Value(row.startMinute),
              durationMinutes: Value(row.durationMinutes),
            ),
          );
    }
    for (final row in document.checkIns) {
      await db
          .into(db.checkIns)
          .insertOnConflictUpdate(
            CheckInsCompanion.insert(
              goalId: id,
              goalKind: document.kind.index,
              occurrenceKey: row.occurrenceKey,
              completed: row.completed,
              completedDay: row.day.key,
              completedAt: row.instant.microsecondsSinceEpoch,
              zone: row.zone,
              titleSnapshot: row.title,
              plannedDay: Value(row.plannedDay?.key),
            ),
          );
    }
    return id;
  });
}
