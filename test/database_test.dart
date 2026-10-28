import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';

GoalsCompanion sampleGoal({int kind = 0}) => GoalsCompanion.insert(
  kind: kind,
  createdDay: '2026-10-09',
  createdAt: DateTime.utc(2026, 10, 9, 9).microsecondsSinceEpoch,
);

void main() {
  late AppDatabase db;

  AppDatabase memoryDatabase() {
    db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    return db;
  }

  test(
    'creates the current schema and enables foreign key enforcement',
    () async {
      memoryDatabase();
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), db.schemaVersion);
      final foreignKeys = await db
          .customSelect('PRAGMA foreign_keys')
          .getSingle();
      expect(foreignKeys.read<int>('foreign_keys'), 1);
      expect(await db.customSelect('PRAGMA foreign_key_check').get(), isEmpty);
    },
  );

  test('database rejects duplicate occurrences and orphan records', () async {
    memoryDatabase();
    final id = await db.into(db.goals).insert(sampleGoal());
    final row = CheckInsCompanion.insert(
      goalId: id,
      goalKind: 0,
      occurrenceKey: '2026-10-09',
      completed: true,
      completedDay: '2026-10-09',
      completedAt: 1,
      zone: 'Asia/Shanghai',
      titleSnapshot: 'TEST reading',
    );
    await db.into(db.checkIns).insert(row);
    await expectLater(db.into(db.checkIns).insert(row), throwsException);
    await expectLater(
      db.into(db.checkIns).insert(row.copyWith(goalId: const Value(99999))),
      throwsException,
    );
    expect(await db.select(db.checkIns).get(), hasLength(1));
  });

  test(
    'single tasks cannot bypass uniqueness using another date or kind',
    () async {
      memoryDatabase();
      final id = await db.into(db.goals).insert(sampleGoal(kind: 1));
      final row = CheckInsCompanion.insert(
        goalId: id,
        goalKind: 1,
        occurrenceKey: 'once',
        completed: true,
        completedDay: '2026-10-09',
        completedAt: 1,
        zone: 'Asia/Shanghai',
        titleSnapshot: 'TEST single task',
      );
      await db.into(db.checkIns).insert(row);
      await expectLater(
        db
            .into(db.checkIns)
            .insert(
              row.copyWith(
                occurrenceKey: const Value('2026-10-10'),
                completedDay: const Value('2026-10-10'),
              ),
            ),
        throwsException,
      );
      await expectLater(
        db
            .into(db.checkIns)
            .insert(
              row.copyWith(
                goalKind: const Value(0),
                occurrenceKey: const Value('2026-10-10'),
                completedDay: const Value('2026-10-10'),
              ),
            ),
        throwsException,
      );
      await expectLater(
        (db.update(db.checkIns)..where((c) => c.goalId.equals(id))).write(
          const CheckInsCompanion(occurrenceKey: Value('2026-10-10')),
        ),
        throwsException,
      );
      expect(await db.select(db.checkIns).get(), hasLength(1));
    },
  );

  test('habit occurrence must match its immutable calendar day', () async {
    memoryDatabase();
    final id = await db.into(db.goals).insert(sampleGoal());
    await expectLater(
      db
          .into(db.checkIns)
          .insert(
            CheckInsCompanion.insert(
              goalId: id,
              goalKind: 0,
              occurrenceKey: '2026-10-09',
              completed: true,
              completedDay: '2026-10-10',
              completedAt: 1,
              zone: 'Asia/Shanghai',
              titleSnapshot: 'TEST invalid date',
            ),
          ),
      throwsException,
    );
  });

  test('transaction failure rolls back all related writes', () async {
    memoryDatabase();
    await expectLater(
      db.transaction(() async {
        final id = await db.into(db.goals).insert(sampleGoal());
        await db
            .into(db.goalTitles)
            .insert(
              GoalTitlesCompanion.insert(
                goalId: id,
                effectiveDay: '2026-10-09',
                title: 'TEST rollback',
              ),
            );
        throw StateError('injected transaction failure');
      }),
      throwsStateError,
    );
    expect(await db.select(db.goals).get(), isEmpty);
    expect(await db.select(db.goalTitles).get(), isEmpty);
  });

  test('existing file survives close and reopen without reset', () async {
    final directory = await Directory.systemTemp.createTemp('habit-db-test-');
    final file = File('${directory.path}/test.sqlite');
    final first = AppDatabase(NativeDatabase(file));
    try {
      final id = await first.into(first.goals).insert(sampleGoal());
      await first.close();
      final reopened = AppDatabase(NativeDatabase(file));
      try {
        final rows = await reopened.select(reopened.goals).get();
        expect(rows.single.id, id);
        expect(rows.single.createdDay, '2026-10-09');
        expect(
          await reopened.customSelect('PRAGMA foreign_key_check').get(),
          isEmpty,
        );
      } finally {
        await reopened.close();
      }
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
