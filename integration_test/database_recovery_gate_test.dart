import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/app/app.dart';
import 'package:habit_checkin/app/providers.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/local/open_database.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:integration_test/integration_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;

class _ProbeDatabase extends AppDatabase {
  _ProbeDatabase(super.executor, {required this.failOpening});

  final bool failOpening;
  Future<void>? _closed;

  @override
  Future<void> close() => _closed ??= super.close();

  @override
  MigrationStrategy get migration {
    final original = super.migration;
    return MigrationStrategy(
      onCreate: original.onCreate,
      onUpgrade: original.onUpgrade,
      beforeOpen: (details) async {
        await original.beforeOpen?.call(details);
        if (failOpening) {
          throw StateError('injected device opening check failure');
        }
      },
    );
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();

  testWidgets(
    'native database failure retries through the real app providers',
    (tester) async {
      const run = String.fromEnvironment('RECOVERY_PROBE_RUN');
      expect(
        RegExp(r'^[a-zA-Z0-9-]+$').hasMatch(run),
        isTrue,
        reason:
            'Use a fresh alphanumeric/hyphen token for a separate probe file',
      );
      final name = 'habit_checkin_recovery_gate_$run';
      final clock = DeviceClock();
      await clock.refreshZone();
      final seed = openAppDatabase(name: name);
      final repository = LocalGoalRepository(seed, clock);
      late int id;
      try {
        expect(
          await repository.loadGoals(),
          isEmpty,
          reason: 'Never clear existing probe data; choose a fresh token',
        );
        id = await repository.create(
          const GoalDraft(
            title: 'TEST recovery retained',
            kind: GoalKind.habit,
          ),
        );
        await repository.setCompleted(id, true, expectedDay: clock.read().day);
      } finally {
        await seed.close();
      }

      final connections = <_ProbeDatabase>[];
      try {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              clockProvider.overrideWithValue(clock),
              refreshClockProvider.overrideWithValue(clock.refreshZone),
              databaseFactoryProvider.overrideWithValue(() {
                final db = _ProbeDatabase(
                  driftDatabase(name: name),
                  failOpening: connections.isEmpty,
                );
                connections.add(db);
                return db;
              }),
            ],
            child: const HabitCheckinApp(),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('无法读取本地记录，原有数据未被清空。'), findsOneWidget);
        expect(find.text('还没有目标'), findsNothing);
        await tester.tap(find.text('重试'));
        await tester.pumpAndSettle();
        expect(connections, hasLength(2));
        expect(find.text('TEST recovery retained'), findsOneWidget);
        expect(find.text('今日已完成 1 项'), findsOneWidget);
        await tester.ensureVisible(find.byKey(ValueKey('undo-$id')));
        await tester.tap(find.byKey(ValueKey('undo-$id')));
        await tester.pumpAndSettle();
        expect(find.text('今日已完成 0 项'), findsOneWidget);
        final container = ProviderScope.containerOf(
          tester.element(find.byType(HabitCheckinApp)),
        );
        final db = await container.read(databaseProvider.future);
        expect(
          await db.customSelect('PRAGMA foreign_key_check').get(),
          isEmpty,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        for (final db in connections) {
          await db.close();
        }
      }
      final reopened = openAppDatabase(name: name);
      try {
        final goals = await LocalGoalRepository(reopened, clock).loadGoals();
        expect(goals, hasLength(1));
        expect(goals.single.id, id);
        expect(goals.single.completionOn(clock.read().day), isNull);
      } finally {
        await reopened.close();
      }
    },
  );
}
