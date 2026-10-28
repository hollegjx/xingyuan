import 'dart:convert';

import 'package:drift/drift.dart' show Variable;
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/app/providers.dart';
import 'package:habit_checkin/data/local/open_database.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/features/assistant/data/local_memory_store.dart';
import 'package:habit_checkin/features/assistant/data/local_proposal_store.dart';
import 'package:habit_checkin/features/assistant/domain/plan_preview.dart';
import 'package:habit_checkin/features/reminders/notification_permissions.dart';
import 'package:habit_checkin/features/reminders/reminder_coordinator.dart';
import 'package:integration_test/integration_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:xingyuan_core/xingyuan_core.dart';

import '../test/drift/generated/schema_v4.dart' as v4;
import '../test/support/assistant_fixtures.dart';
import '../test/support/assistant_migration_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();

  testWidgets('isolated v4 migration and crash-recoverable proposal undo', (
    tester,
  ) async {
    const phase = String.fromEnvironment('ASSISTANT_STORAGE_PHASE');
    const run = String.fromEnvironment('ASSISTANT_STORAGE_RUN');
    const longPreference = bool.fromEnvironment(
      'ASSISTANT_STORAGE_LONG_PROFILE',
    );
    final preference = longPreference
        ? assistantLongMigrationPreference()
        : 'TEST 夜晚读书';
    expect(
      phase,
      anyOf('seed', 'migrate', 'verify-migration', 'upgrade', 'reopen'),
    );
    expect(RegExp(r'^[a-zA-Z0-9-]{1,80}$').hasMatch(run), isTrue);
    final name = 'habit_checkin_assistant_storage_$run';
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Text('TEST assistant storage gate')),
      ),
    );
    if (phase == 'seed') {
      final db = v4.DatabaseAtV4(driftDatabase(name: name));
      try {
        expect(
          await db.customSelect('SELECT * FROM goals').get(),
          isEmpty,
          reason: 'Fresh run token required; never replace probe records',
        );
        await db.transaction(() async {
          for (final statement in assistantMigrationStatements) {
            await db.customStatement(statement);
          }
          await db.customStatement(
            "INSERT INTO planning_profiles VALUES ('guest', ?, 800)",
            [preference],
          );
          final tables = await db
              .customSelect(
                "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name",
              )
              .get();
          final snapshot = <String, Object?>{};
          for (final table in tables) {
            final tableName = table.read<String>('name');
            snapshot[tableName] =
                (await db
                        .customSelect(
                          'SELECT * FROM "$tableName" ORDER BY rowid',
                        )
                        .get())
                    .map((row) => row.data)
                    .toList();
          }
          await db.customStatement(
            'CREATE TABLE assistant_probe (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
          );
          await db.customStatement(
            'INSERT INTO assistant_probe VALUES (?, ?)',
            ['before', jsonEncode(snapshot)],
          );
        });
        expect(
          (await db.customSelect('PRAGMA user_version').getSingle()).read<int>(
            'user_version',
          ),
          4,
        );
      } finally {
        await db.close();
      }
    } else {
      final db = openAppDatabase(name: name);
      final clock = DeviceClock();
      await clock.refreshZone();
      final repository = LocalGoalRepository(
        db,
        clock,
        owner: 'assistant-$run',
      );
      final store = LocalProposalStore(repository);
      final platform = IosNotificationPermissions();
      final coordinator = ReminderCoordinator(
        repository: repository,
        clock: clock,
        permissions: platform,
        notifications: platform,
      );
      Future<String> stored(String key) async =>
          (await db
                  .customSelect(
                    'SELECT value FROM assistant_probe WHERE key = ?',
                    variables: [Variable.withString(key)],
                  )
                  .getSingle())
              .read<String>('value');
      Future<void> verifyLegacySnapshot() async {
        final snapshot =
            jsonDecode(await stored('before')) as Map<String, dynamic>;
        for (final table in snapshot.entries) {
          final expected = table.value as List;
          final actual = await db
              .customSelect('SELECT * FROM "${table.key}" ORDER BY rowid')
              .get();
          expect(actual, hasLength(expected.length));
          for (var i = 0; i < actual.length; i++) {
            expect({
              for (final key in (expected[i] as Map).keys)
                key: actual[i].data[key],
            }, expected[i]);
          }
        }
      }

      try {
        expect(
          (await db.customSelect('PRAGMA user_version').getSingle()).read<int>(
            'user_version',
          ),
          db.schemaVersion,
        );
        expect(
          await db.customSelect('PRAGMA foreign_key_check').get(),
          isEmpty,
        );
        expect(
          (await db.select(db.assistantMemories).get())
              .map((row) => row.sourceLabel)
              .toList(),
          List.filled(longPreference ? 4 : 2, '旧版偏好'),
        );
        if (phase == 'migrate' || phase == 'verify-migration') {
          await verifyLegacySnapshot();
          final memories = LocalMemoryStore(LocalGoalRepository(db, clock));
          final rows = await memories.list();
          expect(rows, hasLength(longPreference ? 3 : 1));
          expect(rows.map((row) => row.content).join(), preference);
          expect(
            (await memories.forRequest())!.map((row) => row.text).join(),
            preference,
          );
          for (final row in rows) {
            expect(row.content.characters.length, inInclusiveRange(1, 200));
            expect(row.owner, 'guest');
            expect(row.category, '偏好');
            expect(row.sourceLabel, '旧版偏好');
            expect(row.createdAt, 800);
            expect(row.updatedAt, 800);
          }
          final current = jsonEncode(rows.map((row) => row.toJson()).toList());
          final prior = await db
              .customSelect(
                "SELECT value FROM assistant_probe WHERE key = 'migration_memories'",
              )
              .getSingleOrNull();
          if (phase == 'migrate' && prior == null) {
            await db.customStatement(
              'INSERT INTO assistant_probe VALUES (?, ?)',
              ['migration_memories', current],
            );
          } else {
            expect(prior, isNotNull, reason: 'Run migrate before verification');
            expect(prior!.read<String>('value'), current);
          }
          expect(
            (await db.customSelect('PRAGMA integrity_check').getSingle())
                .read<String>('integrity_check'),
            'ok',
          );
          // This separate phase makes no notification-platform calls.
          // ignore: avoid_print
          print(
            'ASSISTANT_STORAGE phase=$phase passed synthetic-only=true '
            'long-profile=$longPreference notifications-not-run=true',
          );
          return;
        }
        var access = await platform.read();
        if (access == NotificationAccess.off &&
            const bool.fromEnvironment(
              'ASSISTANT_STORAGE_REQUEST_PERMISSION',
            )) {
          access = await platform.request();
        }
        expect(
          access,
          anyOf(NotificationAccess.allowed, NotificationAccess.quiet),
          reason: 'Simulator permission required; a prompt requires the explicit probe define',
        );
        if (phase == 'upgrade') {
          await verifyLegacySnapshot();
          expect(
            await platform.pending(),
            isEmpty,
            reason: 'Never clear unrelated system notifications',
          );
          expect(await platform.delivered(), isEmpty);
          final now = clock.read();
          final time = now.localTime.hour * 60 + now.localTime.minute + 30;
          expect(
            time,
            lessThan(1410),
            reason: 'Do not run this short probe near midnight',
          );
          final preview = PlanPreview([
            for (var i = 0; i < 3; i++)
              PreviewItem(
                id: 'item-$i',
                reminder: true,
                task: PlanTask.fromJson({
                  'title': 'TEST native $i',
                  'date': now.day.key,
                  'time': formatMinute(time),
                  'minutes': 10,
                }, habit: false),
              ),
          ]);
          await seedAssistantReply(db, owner: repository.owner);
          final id = await store.saveDraft(
            sessionId: 'test-session',
            messageId: 'test-message',
            preview: preview,
          );
          final ids = await store.apply(id, preview);
          expect(await store.apply(id, preview), ids);
          await coordinator.reconcile();
          expect(await platform.pending(), hasLength(3));
          await repository.setCompleted(ids.first, true, expectedDay: now.day);
          await repository.setCompleted(ids.first, false, expectedDay: now.day);
          final result = await store.undo(id);
          expect(result.items.map((item) => item.disposition), [
            UndoDisposition.keptHistory,
            UndoDisposition.deleted,
            UndoDisposition.deleted,
          ]);
          expect(await db.select(db.reminderCancellations).get(), hasLength(2));
          expect(await platform.pending(), hasLength(3));
          await db.customStatement(
            'INSERT INTO assistant_probe VALUES (?, ?)',
            ['proposal', id],
          );
          await db.customStatement(
            'INSERT INTO assistant_probe VALUES (?, ?)',
            ['undo', result.encode()],
          );
          await db.customStatement(
            'INSERT INTO assistant_probe VALUES (?, ?)',
            ['timing', '$time'],
          );
          // Intentionally leave only these test notifications to exercise the
          // commit/platform gap in the next, independent application process.
        } else {
          final id = await stored('proposal');
          expect((await store.undo(id)).encode(), await stored('undo'));
          final goals = await repository.loadGoals();
          expect(goals, hasLength(1));
          expect(
            goals.single.scheduleOn(clock.read().day).startMinute,
            int.parse(await stored('timing')),
          );
          expect(goals.single.scheduleOn(clock.read().day).durationMinutes, 10);
          expect(await db.select(db.reminderCancellations).get(), hasLength(2));
          expect(await platform.pending(), hasLength(3));
          await coordinator.reconcile();
          expect(await db.select(db.reminderCancellations).get(), isEmpty);
          expect(await platform.pending(), hasLength(1));
          await repository.archive(goals.single.id);
          await coordinator.reconcile();
          expect(await platform.pending(), isEmpty);
          expect(await platform.delivered(), isEmpty);
        }
        expect(
          await db.customSelect('PRAGMA foreign_key_check').get(),
          isEmpty,
        );
      } finally {
        await db.close();
      }
    }
    // ignore: avoid_print
    print('ASSISTANT_STORAGE phase=$phase passed synthetic-only=true');
  });
}
