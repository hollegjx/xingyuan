import 'dart:convert';
import 'dart:io';

import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/app/app.dart';
import 'package:habit_checkin/app/providers.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/local/open_database.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:habit_checkin/features/records/presentation/day_record_page.dart';
import 'package:habit_checkin/features/records/record_providers.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../test/drift/generated/schema_v5.dart' as v5;
import '../test/support/record_fixtures.dart';
import '../test/support/isolated_goal_probe.dart';
import '../test/support/test_clock.dart';
import '../test/support/test_reminder_notifications.dart';
import '../test/support/ui_harness.dart' show TestNotificationPermissions;

// Test simulator only: a unique database and photo directory, synthetic pixels,
// and no model, normal credential, production database or real notification IO.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  const phase = String.fromEnvironment('RECORD_JOURNEY_PHASE');
  const run = String.fromEnvironment('RECORD_JOURNEY_RUN');

  testWidgets('v5 upgrade and local record/photo UI survive separate processes', (
    tester,
  ) async {
    expect(Platform.isIOS, isTrue);
    expect(['seed', 'write', 'reopen'], contains(phase));
    expect(RegExp(r'^[A-Za-z0-9-]{8,60}$').hasMatch(run), isTrue);
    final name = 'habit_checkin_records_$run';
    if (phase == 'seed') {
      final db = v5.DatabaseAtV5(driftDatabase(name: name));
      try {
        expect(await db.customSelect('SELECT * FROM goals').get(), isEmpty);
        await db.transaction(() async {
          for (final statement in [
            "INSERT INTO goals VALUES (1, '22222222-2222-4222-8222-222222222222', 'guest', 0, '2026-10-20', 100, NULL, NULL)",
            "INSERT INTO goal_titles VALUES (1, '2026-10-20', 'TEST record migration')",
            "INSERT INTO goal_schedules VALUES (1, '2026-10-20', 127, NULL, 1140, 30)",
            "INSERT INTO check_ins VALUES (1, 0, '2026-10-20', 1, '2026-10-20', 200, 'America/Los_Angeles', 'TEST original title', NULL)",
            "INSERT INTO goal_reminders VALUES (1, 0, 1200, 2, 0, 'disabled')",
            "INSERT INTO sync_states VALUES (1, 0, 0, NULL, NULL)",
            "INSERT INTO identity_states VALUES (1, 'guest', 7, NULL)",
            "INSERT INTO planning_profiles VALUES ('guest', 'TEST legacy remains', 50)",
            "INSERT INTO assistant_sessions (id, owner, title, created_at, updated_at) VALUES ('session', 'guest', 'TEST', 10, 20)",
            "INSERT INTO assistant_messages (id, session_id, owner, role, content, status, created_at) VALUES ('message', 'session', 'guest', 'user', 'TEST only', 'sent', 20)",
            "INSERT INTO assistant_memories (id, owner, category, content, created_at, updated_at) VALUES ('memory', 'guest', '偏好', 'TEST', 10, 20)",
          ]) {
            await db.customStatement(statement);
          }
          final before = <String, Object?>{};
          final tables = await db
              .customSelect(
                "SELECT name FROM sqlite_schema WHERE type='table' ORDER BY name",
              )
              .get();
          for (final table in tables) {
            final tableName = table.read<String>('name');
            before[tableName] =
                (await db
                        .customSelect(
                          'SELECT * FROM "$tableName" ORDER BY rowid',
                        )
                        .get())
                    .map((row) => row.data)
                    .toList();
          }
          await db.customStatement(
            'CREATE TABLE record_probe (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
          );
          await db.customStatement('INSERT INTO record_probe VALUES (?, ?)', [
            'before',
            jsonEncode(before),
          ]);
        });
      } finally {
        await db.close();
      }
      return;
    }

    final db = openAppDatabase(name: name);
    final clock = TestClock()..location = tz.getLocation('America/Los_Angeles');
    clock.setDay(2026, 10, 21, hour: 23, minute: 58);
    final goals = LocalGoalRepository(db, clock);
    final workspace = await Directory(
      '${(await getApplicationDocumentsDirectory()).path}/record_probe_$run',
    ).create(recursive: true);
    final sample = img.Image(width: 120, height: 80);
    img.fill(sample, color: img.ColorRgb8(24, 140, 120));
    img.fillRect(
      sample,
      x1: 20,
      y1: 20,
      x2: 90,
      y2: 60,
      color: img.ColorRgb8(215, 80, 95),
    );
    sample.exif.gpsIfd
      ..gpsLatitude = 12.34
      ..gpsLatitudeRef = 'N'
      ..gpsLongitude = 56.78
      ..gpsLongitudeRef = 'E';
    final picker = StubRecordPhotoPicker()
      ..onPick = () async => img.encodeJpg(sample);

    Future<void> waitFor(Future<bool> Function() predicate) async {
      final started = Stopwatch()..start();
      while (!await predicate()) {
        if (started.elapsed > const Duration(seconds: 20)) {
          fail('Native record operation timed out');
        }
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }

    Future<void> tap(Finder finder) async {
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
      expect(finder.hitTestable(), findsOneWidget);
      await tester.tap(finder);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }

    Future<void> enter(String value) async {
      final input = find.byKey(const ValueKey('record-text'));
      await tap(input);
      await tester.enterText(input, value);
      await tester.pumpAndSettle();
    }

    try {
      expect(
        (await db.customSelect('PRAGMA user_version').getSingle()).read<int>(
          'user_version',
        ),
        db.schemaVersion,
      );
      if (phase == 'write') {
        final before = jsonDecode(
          (await db
                  .customSelect(
                    "SELECT value FROM record_probe WHERE key='before'",
                  )
                  .getSingle())
              .read<String>('value'),
        ) as Map<String, dynamic>;
        for (final table in before.entries) {
          expect(
            (await db
                    .customSelect('SELECT * FROM "${table.key}" ORDER BY rowid')
                    .get())
                .map((row) => row.data)
                .toList(),
            table.value,
            reason: table.key,
          );
        }
        expect(await db.select(db.dayRecords).get(), isEmpty);
        await goals.create(
          const GoalDraft(
            title: 'TEST midnight draft',
            kind: GoalKind.habit,
            weekdays: 127,
          ),
        );
      }
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            clockProvider.overrideWithValue(clock),
            refreshClockProvider.overrideWithValue(() async {}),
            ...isolatedGoalProbeOverrides(goals: goals, workspace: workspace),
            recordPhotoPickerProvider.overrideWithValue(picker),
            notificationPermissionsProvider.overrideWithValue(
              TestNotificationPermissions(),
            ),
            reminderNotificationsProvider.overrideWithValue(
              TestReminderNotifications(),
            ),
          ],
          child: const HabitCheckinApp(),
        ),
      );
      await waitFor(
        () async => find
            .byKey(ValueKey('record-1-${clock.day.key}'))
            .evaluate()
            .isNotEmpty,
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(HabitCheckinApp)),
      );
      final store = await container.read(dayRecordStoreProvider.future);
      final files = await container.read(recordPhotoFilesProvider.future);
      final originalDay = clock.day;
      if (phase == 'write') {
        await tap(find.byKey(ValueKey('record-1-${originalDay.key}')));
        await waitFor(
          () async =>
              find.byKey(const ValueKey('record-text')).evaluate().isNotEmpty,
        );
        await enter('TEST 跑步后调整计划\n膝盖有点酸');
        await tap(find.byType(BackButton));
        await tap(find.byTooltip('回顾'));
        await tap(find.byTooltip('今天'));
        await tap(find.byKey(ValueKey('record-1-${originalDay.key}')));
        await waitFor(
          () async =>
              find.byKey(const ValueKey('record-text')).evaluate().isNotEmpty,
        );
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('record-text')))
              .controller!
              .text,
          'TEST 跑步后调整计划\n膝盖有点酸',
        );
        for (var i = 1; i <= 2; i++) {
          await tap(find.byKey(const ValueKey('record-library')));
          await waitFor(
            () async =>
                (await store.at(1, originalDay))!.draftPhotos.length == i,
          );
        }
        final draft = (await store.at(1, originalDay))!;
        await tap(
          find.byKey(ValueKey('remove-photo-${draft.draftPhotos.last.id}')),
        );
        await waitFor(
          () async => (await store.at(1, originalDay))!.draftPhotos.length == 1,
        );
        await enter('TEST 文字和照片保存后仍在');
        final save = find.byKey(const ValueKey('save-record'));
        await tester.ensureVisible(save);
        for (var i = 0; i < 5; i++) {
          await tester.tap(save);
        }
        await waitFor(
          () async => find.byType(DayRecordPage).evaluate().isEmpty,
        );
        final saved = (await store.savedOn(originalDay)).single;
        expect(saved.record.revision, 1);
        expect(saved.savedPhotos, hasLength(1));
        expect(
          img
              .decodeJpg(await files.read(saved.savedPhotos.single))!
              .exif
              .gpsIfd
              .values,
          isEmpty,
        );
        await tap(find.byKey(const ValueKey('complete-1')));
        await tap(find.byKey(const ValueKey('undo-1')));
        expect(
          (await store.savedOn(originalDay)).single.record.content,
          'TEST 文字和照片保存后仍在',
        );
        await tap(find.byKey(const ValueKey('detail-1')));
        expect(find.text('TEST 文字和照片保存后仍在'), findsOneWidget);
        await tap(find.byType(BackButton));
        await tap(find.byTooltip('回顾'));
        expect(find.text('TEST 文字和照片保存后仍在'), findsOneWidget);
        await tap(find.byTooltip('今天'));
        await tap(find.byKey(ValueKey('record-2-${originalDay.key}')));
        await waitFor(
          () async =>
              find.byKey(const ValueKey('record-text')).evaluate().isNotEmpty,
        );
        await enter('TEST 跨日草稿不丢失');
        await waitFor(
          () async =>
              (await store.at(2, originalDay))!.record.draftText ==
              'TEST 跨日草稿不丢失',
        );
      } else {
        expect(find.text('TEST 文字和照片保存后仍在'), findsOneWidget);
        final saved = (await store.savedOn(originalDay)).single;
        expect(saved.savedPhotos, hasLength(1));
        final bytes = await files.read(saved.savedPhotos.single);
        expect(img.decodeJpg(bytes)!.exif.gpsIfd.values, isEmpty);
        await tap(find.byKey(ValueKey('photo-${saved.savedPhotos.single.id}')));
        await waitFor(
          () async => find.byType(InteractiveViewer).evaluate().isNotEmpty,
        );
        await tap(find.byType(BackButton));
        await tap(find.byKey(ValueKey('record-2-${originalDay.key}')));
        await waitFor(
          () async =>
              find.byKey(const ValueKey('record-text')).evaluate().isNotEmpty,
        );
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('record-text')))
              .controller!
              .text,
          'TEST 跨日草稿不丢失',
        );
        clock.location = tz.getLocation('Asia/Shanghai');
        await container.read(environmentProvider.notifier).refresh();
        await tap(find.byKey(const ValueKey('save-record')));
        await waitFor(
          () async => find.byType(DayRecordPage).evaluate().isEmpty,
        );
        expect(
          (await store.at(2, originalDay))!.record.content,
          'TEST 跨日草稿不丢失',
        );
        expect(await store.savedOn(clock.day), isEmpty);
      }
      expect(await db.customSelect('PRAGMA foreign_key_check').get(), isEmpty);
      debugPrint(
        'RECORD_JOURNEY phase=$phase passed=true photos=sanitized local_only=true',
      );
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await db.close();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
