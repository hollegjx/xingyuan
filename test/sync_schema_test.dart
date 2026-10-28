import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';

const _ownerA = 'user:11111111-1111-4111-8111-111111111111';
const _ownerB = 'user:22222222-2222-4222-8222-222222222222';
const _operationId = '33333333-3333-4333-8333-333333333333';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });
  tearDown(() => db.close());

  Future<int> createGoal({String owner = _ownerA}) => db
      .into(db.goals)
      .insert(
        GoalsCompanion.insert(
          owner: Value(owner),
          kind: 0,
          createdDay: '2026-10-11',
          createdAt: 1,
        ),
      );

  SyncOutboxCompanion operation(int goalId, {String owner = _ownerA}) =>
      SyncOutboxCompanion.insert(
        operationId: _operationId,
        owner: owner,
        goalId: goalId,
        kind: 'edit',
        documentJson: '{}',
        localRevision: 1,
        createdAt: 1,
      );

  test(
    'global IDs are unique and cannot be reused by another local identity',
    () async {
      final first = await createGoal();
      final original = await (db.select(
        db.goals,
      )..where((row) => row.id.equals(first))).getSingle();
      await expectLater(
        db
            .into(db.goals)
            .insert(
              GoalsCompanion.insert(
                globalId: Value(original.globalId),
                owner: const Value(_ownerB),
                kind: 0,
                createdDay: '2026-10-11',
                createdAt: 2,
              ),
            ),
        throwsException,
      );
      expect(await db.select(db.goals).get(), hasLength(1));
    },
  );

  test(
    'outbox rejects another owner even with a valid local goal ID',
    () async {
      final id = await createGoal();
      await expectLater(
        db.transaction(
          () => db.into(db.syncOutbox).insert(operation(id, owner: _ownerB)),
        ),
        throwsException,
      );
      expect(await db.select(db.syncOutbox).get(), isEmpty);
    },
  );

  test(
    'operation IDs are unique and in-flight requests require a base revision',
    () async {
      final id = await createGoal();
      await expectLater(
        db
            .into(db.syncOutbox)
            .insert(operation(id).copyWith(state: const Value('in_flight'))),
        throwsException,
      );
      await db
          .into(db.syncOutbox)
          .insert(
            operation(id).copyWith(
              state: const Value('in_flight'),
              baseRevision: const Value(0),
            ),
          );
      await expectLater(
        db.into(db.syncOutbox).insert(operation(id)),
        throwsException,
      );
      final stored = await db.select(db.syncOutbox).getSingle();
      expect(stored.baseRevision, 0);
      expect(stored.state, 'in_flight');
    },
  );

  test(
    'queued data cannot silently change owner while its operation remains',
    () async {
      final id = await createGoal();
      await db.into(db.syncOutbox).insert(operation(id));
      await expectLater(
        db.transaction(
          () => (db.update(db.goals)..where((row) => row.id.equals(id))).write(
            const GoalsCompanion(owner: Value(_ownerB)),
          ),
        ),
        throwsException,
      );
      expect((await db.select(db.goals).getSingle()).owner, _ownerA);
      expect((await db.select(db.syncOutbox).getSingle()).owner, _ownerA);
    },
  );

  test(
    'conflicts require a real operation and preserve resolution consistency',
    () async {
      final id = await createGoal();
      final conflict = SyncConflictsCompanion.insert(
        owner: _ownerA,
        goalId: id,
        operationId: _operationId,
        baseRevision: 0,
        remoteRevision: 1,
        localJson: '{"synthetic":"local"}',
        remoteJson: '{"synthetic":"remote"}',
        createdAt: 1,
      );
      await expectLater(
        db.into(db.syncConflicts).insert(conflict),
        throwsException,
      );
      await db.into(db.syncOutbox).insert(operation(id));
      final otherId = await createGoal();
      await expectLater(
        db
            .into(db.syncConflicts)
            .insert(conflict.copyWith(goalId: Value(otherId))),
        throwsException,
      );
      await expectLater(
        db
            .into(db.syncConflicts)
            .insert(conflict.copyWith(resolution: const Value('local'))),
        throwsException,
      );
      await db.into(db.syncConflicts).insert(conflict);
      expect(await db.select(db.syncConflicts).get(), hasLength(1));
      await expectLater(
        db.into(db.syncConflicts).insert(conflict),
        throwsException,
      );
    },
  );

  test('sync revisions and identity singleton are constrained', () async {
    final id = await createGoal();
    await expectLater(
      db
          .into(db.syncStates)
          .insert(
            SyncStatesCompanion.insert(
              goalId: Value(id),
              serverRevision: const Value(-1),
            ),
          ),
      throwsException,
    );
    await expectLater(
      db
          .into(db.identityStates)
          .insert(const IdentityStatesCompanion(singleton: Value(2))),
      throwsException,
    );
    expect((await db.select(db.identityStates).getSingle()).owner, 'guest');
  });
}
