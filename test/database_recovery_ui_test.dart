import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/app/app.dart';
import 'package:habit_checkin/app/providers.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'support/test_clock.dart';
import 'support/ui_harness.dart';

class OpeningCheckDatabase extends AppDatabase {
  OpeningCheckDatabase(super.executor, this.shouldFail);

  final bool Function() shouldFail;

  @override
  MigrationStrategy get migration {
    final original = super.migration;
    return MigrationStrategy(
      onCreate: original.onCreate,
      onUpgrade: original.onUpgrade,
      beforeOpen: (details) async {
        if (shouldFail()) {
          throw StateError('injected opening validation failure');
        }
        await original.beforeOpen?.call(details);
      },
    );
  }
}

class UnimplementedMigrationDatabase extends AppDatabase {
  UnimplementedMigrationDatabase(super.executor);

  @override
  int get schemaVersion => super.schemaVersion + 1;
}

class ReadFailure extends QueryInterceptor {
  bool fail = false;

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    if (fail && statement.contains('FROM goals')) {
      throw StateError('injected read failure');
    }
    return executor.runSelect(statement, args);
  }
}

class CloseFailure extends QueryInterceptor {
  bool fail = false;
  bool closed = false;

  @override
  Future<void> close(QueryExecutor inner) async {
    if (fail) throw StateError('injected close failure');
    await inner.close();
    closed = true;
  }
}

void main() {
  setUpAll(tzdata.initializeTimeZones);

  for (final failure in [
    'open',
    'opening check',
    'migration',
    'read',
    'watch',
  ]) {
    testUiWidgets('$failure failure can retry without losing stored data', (
      tester,
    ) async {
      final directory = Directory.systemTemp.createTempSync('habit-recovery-');
      final file = File('${directory.path}/records.sqlite');
      final clock = TestClock();
      final seed = AppDatabase(NativeDatabase(file));
      final repository = LocalGoalRepository(seed, clock);
      final id = await repository.create(
        const GoalDraft(title: 'TEST retained', kind: GoalKind.habit),
      );
      await repository.setCompleted(id, true, expectedDay: clock.day);
      await seed.close();
      var fail = true;
      var connections = 0;
      final reads = ReadFailure()..fail = failure == 'read';
      late AppDatabase activeDatabase;
      addTearDown(() => directory.deleteSync(recursive: true));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            clockProvider.overrideWithValue(clock),
            refreshClockProvider.overrideWithValue(() async {}),
            notificationPermissionsProvider.overrideWithValue(
              TestNotificationPermissions(),
            ),
            databaseFactoryProvider.overrideWithValue(() {
              connections++;
              final QueryExecutor executor = failure == 'open'
                  ? LazyDatabase(() {
                      if (fail) throw StateError('injected opener failure');
                      return NativeDatabase(file);
                    })
                  : NativeDatabase(file).interceptWith(reads);
              final db = failure == 'opening check'
                  ? OpeningCheckDatabase(executor, () => fail)
                  : failure == 'migration' && fail
                  ? UnimplementedMigrationDatabase(executor)
                  : AppDatabase(executor);
              activeDatabase = db;
              return db;
            }),
          ],
          child: const HabitCheckinApp(),
        ),
      );
      await tester.pumpAndSettle();
      if (failure == 'watch') {
        expect(find.text('TEST retained'), findsOneWidget);
        reads.fail = true;
        activeDatabase.notifyUpdates({const TableUpdate('goals')});
        await tester.pumpAndSettle();
      }
      expect(find.text('无法读取本地记录，原有数据未被清空。'), findsOneWidget);
      expect(find.text('还没有目标'), findsNothing);
      fail = false;
      reads.fail = false;
      await tapVisible(tester, find.text('重试'));
      expect(find.text('TEST retained'), findsOneWidget);
      expect(find.text('今日已完成 1 项'), findsOneWidget);
      expect(connections, greaterThan(1));
      await tapVisible(tester, find.byKey(ValueKey('undo-$id')));
      expect(find.text('今日已完成 0 项'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      final reopened = AppDatabase(NativeDatabase(file));
      try {
        final goals = await LocalGoalRepository(reopened, clock).loadGoals();
        expect(goals, hasLength(1));
        expect(goals.single.id, id);
        expect(goals.single.completionOn(clock.day), isNull);
        expect(
          await reopened.customSelect('PRAGMA foreign_key_check').get(),
          isEmpty,
        );
        expect(
          (await reopened.customSelect('PRAGMA user_version').getSingle())
              .read<int>('user_version'),
          reopened.schemaVersion,
        );
      } finally {
        await reopened.close();
      }
      expect(tester.takeException(), isNull);
    });
  }

  test('a failed close is retried before opening another connection', () async {
    final close = CloseFailure();
    var connections = 0;
    final container = ProviderContainer(
      overrides: [
        databaseFactoryProvider.overrideWithValue(() {
          connections++;
          if (connections > 1) expect(close.closed, isTrue);
          return AppDatabase(NativeDatabase.memory().interceptWith(close));
        }),
      ],
    );
    addTearDown(container.dispose);
    await container.read(databaseProvider.future);
    close.fail = true;
    container.invalidate(databaseProvider);
    await expectLater(
      container.read(databaseProvider.future),
      throwsStateError,
    );
    expect(connections, 1);
    close.fail = false;
    container.invalidate(databaseProvider);
    await container.read(databaseProvider.future);
    expect(connections, 2);
  });

  test(
    'retry waits for an in-flight opener and closes its connection first',
    () async {
      final ready = Completer<void>();
      final close = CloseFailure();
      var connections = 0;
      final container = ProviderContainer(
        overrides: [
          databaseFactoryProvider.overrideWithValue(() {
            connections++;
            if (connections > 1) {
              expect(close.closed, isTrue);
              return AppDatabase(NativeDatabase.memory());
            }
            return AppDatabase(
              LazyDatabase(() async {
                await ready.future;
                return NativeDatabase.memory().interceptWith(close);
              }),
            );
          }),
        ],
      );
      addTearDown(container.dispose);
      unawaited(container.read(databaseProvider.future));
      await Future<void>.delayed(Duration.zero);
      expect(connections, 1);
      container.invalidate(databaseProvider);
      final retry = container.read(databaseProvider.future);
      await Future<void>.delayed(Duration.zero);
      expect(connections, 1);
      ready.complete();
      await retry;
      expect(connections, 2);
      expect(close.closed, isTrue);
    },
  );
}
