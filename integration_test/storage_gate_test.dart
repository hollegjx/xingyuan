import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/data/local/open_database.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('G1 persistent database across separate app processes', (
    tester,
  ) async {
    const phase = String.fromEnvironment('STORAGE_PROBE_PHASE');
    expect(
      phase,
      anyOf('write', 'read'),
      reason: 'Run once with write, then a separate process with read.',
    );
    final db = openAppDatabase(name: 'habit_checkin_storage_gate');
    try {
      if (phase == 'write') {
        await db
            .into(db.goals)
            .insertOnConflictUpdate(
              GoalsCompanion.insert(
                id: const Value(1),
                kind: 0,
                createdDay: '2026-10-09',
                createdAt: 1,
              ),
            );
        await db
            .into(db.goalTitles)
            .insertOnConflictUpdate(
              GoalTitlesCompanion.insert(
                goalId: 1,
                effectiveDay: '2026-10-09',
                title: 'TEST persistent storage',
              ),
            );
      }
      final row = await (db.select(
        db.goalTitles,
      )..where((row) => row.goalId.equals(1))).getSingle();
      expect(row.title, 'TEST persistent storage');
      expect(await db.customSelect('PRAGMA foreign_key_check').get(), isEmpty);
    } finally {
      await db.close();
    }
  });
}
