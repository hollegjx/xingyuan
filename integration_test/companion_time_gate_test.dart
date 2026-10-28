import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/app/app.dart';
import 'package:habit_checkin/app/providers.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/local/open_database.dart';
import 'package:habit_checkin/features/assistant/assistant_providers.dart';
import 'package:habit_checkin/features/assistant/data/device_credential_store.dart';
import 'package:habit_checkin/features/companion/companion_providers.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:habit_checkin/features/records/record_providers.dart';
import 'package:habit_checkin/shared/app_clock.dart';
import 'package:habit_checkin/shared/presentation.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:xingyuan_core/xingyuan_core.dart';

import '../test/support/chat_service.dart';
import '../test/support/pairing_fixtures.dart';
import '../test/support/sharing_fixtures.dart';
import '../test/support/test_reminder_notifications.dart';
import '../test/support/ui_harness.dart' show TestNotificationPermissions;

class _SyntheticCredential extends DeviceCredentialStore {
  const _SyntheticCredential();

  @override
  Future<String?> read() async => 'a' * 43;

  @override
  Future<void> save(String input) async =>
      throw StateError('The time probe cannot save credentials');

  @override
  Future<void> clear() async =>
      throw StateError('The time probe cannot clear credentials');
}

// Launch each phase in a fresh process with SIMCTL_CHILD_TZ set by the host.
// Only this process changes zone; the clock advances synthetically by a minute.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  tzdata.initializeTimeZones();
  const run = String.fromEnvironment('TIME_RUN');
  const phase = String.fromEnvironment('TIME_PHASE');
  const zone = String.fromEnvironment('TIME_ZONE');
  final before = DateTime.utc(2026, 10, 22, 6, 59, 30);
  final after = DateTime.utc(2026, 10, 22, 7, 0, 30);
  final expires = DateTime.utc(2026, 10, 22, 7, 5);
  final seeding = phase == 'la-seed';
  final losAngeles = zone == 'America/Los_Angeles';

  for (final section in ['pairing', 'reply', 'chat']) {
    testWidgets('native time display and stored UTC $section/$phase', (
      tester,
    ) async {
      expect(Platform.isIOS, true);
      expect(RegExp(r'^[a-z0-9-]{8,40}$').hasMatch(run), true);
      expect({'la-seed', 'shanghai-reopen', 'la-reopen'}, contains(phase));
      expect({'America/Los_Angeles', 'Asia/Shanghai'}, contains(zone));
      final device = DeviceClock();
      await device.refreshZone();
      debugPrint(
        'TIME_ZONE_PROBE ${jsonEncode({'requested': zone, 'environment': Platform.environment['TZ'], 'native': device.read().zone, 'offset': before.toLocal().timeZoneOffset.inMinutes})}',
      );
      expect(device.read().zone, zone);
      final location = tz.getLocation(zone);
      for (final instant in [before, after, expires]) {
        final expected = tz.TZDateTime.from(instant, location);
        final actual = instant.toLocal();
        expect(actual.timeZoneOffset, expected.timeZoneOffset);
        expect(
          [actual.year, actual.month, actual.day, actual.hour, actual.minute],
          [
            expected.year,
            expected.month,
            expected.day,
            expected.hour,
            expected.minute,
          ],
        );
      }

      final documents = await getApplicationDocumentsDirectory();
      final workspace = await Directory(
        '${documents.path}/companion_time_${run}_$section',
      ).create(recursive: true);
      final output = Directory('${workspace.path}/$phase');
      expect(await output.exists(), false, reason: 'Use a fresh run');
      await output.create();
      final db = openAppDatabase(name: 'habit_checkin_time_${run}_$section');
      var now = before;
      final clock = ZonedClock(() => location, now: () => now);
      final goals = LocalGoalRepository(db, clock);
      final service = TestChatService()
        ..current = section == 'pairing'
            ? PairingState.fromJson({
                ...testPairingState(invited: true).toJson(),
                'invitation': {
                  'id': testInviteId,
                  'code': 'ABCDEFGH',
                  'expires_at': expires.toIso8601String(),
                },
              })
            : testPairingState(paired: true);
      final capture = GlobalKey();
      final personalFile = File('${workspace.path}/personal.json');
      final cacheFile = File('${workspace.path}/utc-cache.json');
      final cacheQueries = switch (section) {
        'pairing' => {
          'pairing':
              'SELECT owner, credential_scope, generation, state_json, '
              'draft_code, draft_revision FROM pairing_states ORDER BY owner',
        },
        'reply' => {
          for (final table in [
            'shared_records_cache',
            'shared_replies_cache',
            'sharing_drafts',
          ])
            table: 'SELECT * FROM $table ORDER BY rowid',
        },
        _ => {
          'messages': 'SELECT * FROM chat_messages_cache ORDER BY rowid',
          'draft':
              'SELECT owner, session_id, draft_text, draft_photo_id, '
              'draft_revision FROM chat_states ORDER BY owner',
        },
      };
      Future<Map<String, Object?>> storedCache() async => {
        for (final entry in cacheQueries.entries)
          entry.key: (await db.customSelect(entry.value).get())
              .map((row) => row.data)
              .toList(),
      };

      Future<Map<String, Object?>> personal() async => {
        for (final table in [
          'goals',
          'goal_titles',
          'goal_schedules',
          'check_ins',
        ])
          table:
              (await db
                      .customSelect('SELECT * FROM $table ORDER BY rowid')
                      .get())
                  .map((row) => row.data)
                  .toList(),
      };

      Future<void> waitFor(bool Function() ready) async {
        final elapsed = Stopwatch()..start();
        while (!ready()) {
          if (elapsed.elapsed > const Duration(seconds: 20)) {
            fail('Native page did not become ready');
          }
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }

      Future<void> tap(Finder target) async {
        await tester.ensureVisible(target);
        await tester.pumpAndSettle();
        expect(target.hitTestable(), findsOneWidget);
        await tester.tap(target);
        await tester.pumpAndSettle();
      }

      Future<void> shot(String name) async {
        await tester.pumpAndSettle();
        final boundary =
            capture.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        try {
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('${output.path}/$name.png')
              .writeAsBytes(bytes!.buffer.asUint8List(), flush: true);
        } finally {
          image.dispose();
        }
      }

      try {
        if (seeding) {
          expect(await goals.loadGoals(), isEmpty);
          final id = await goals.create(
            const GoalDraft(title: 'SYNTHETIC time', kind: GoalKind.habit),
          );
          await goals.setCompleted(id, true, expectedDay: clock.read().day);
          await personalFile.writeAsString(
            jsonEncode(await personal()),
            flush: true,
          );
        }
        expect(await personal(), jsonDecode(await personalFile.readAsString()));
        if (!seeding) {
          expect(
            await storedCache(),
            jsonDecode(await cacheFile.readAsString()),
          );
        }
        final goal = (await db.select(db.goals).get()).single;
        service.seed(goal.globalId, partner: true);
        service.sharedRecords.single['occurred_at'] = after.toIso8601String();
        service.sharedRecords.single['completed_at'] = before.toIso8601String();
        SharedRecord.fromJson(service.sharedRecords.single);
        service.sharedReplies.addAll([
          for (final (index, instant) in [before, after].indexed)
            {
              'id': sharingId(100 + index),
              'record_id': testRecordId,
              'author_id': testPartnerId,
              'sequence': index + 1,
              'text': 'SYNTHETIC time reply $index',
              'created_at': instant.toIso8601String(),
            },
        ]);
        for (final (index, instant) in [before, after].indexed) {
          service.incoming('SYNTHETIC time chat $index');
          service.chats.last['created_at'] = instant.toIso8601String();
        }
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              databaseProvider.overrideWith((ref) => db),
              goalRepositoryProvider.overrideWith((ref) => goals),
              recordPhotoRootProvider.overrideWith(
                (ref) => Directory('${workspace.path}/record_photos'),
              ),
              assistantCredentialProvider.overrideWithValue(
                const _SyntheticCredential(),
              ),
              companionServiceProvider.overrideWithValue(service),
              clockProvider.overrideWithValue(clock),
              refreshClockProvider.overrideWithValue(() async {}),
              notificationPermissionsProvider.overrideWithValue(
                TestNotificationPermissions(),
              ),
              reminderNotificationsProvider.overrideWithValue(
                TestReminderNotifications(),
              ),
            ],
            child: RepaintBoundary(
              key: capture,
              child: const HabitCheckinApp(),
            ),
          ),
        );
        await waitFor(() => find.byTooltip('陪伴').evaluate().isNotEmpty);
        await tap(find.byTooltip('陪伴'));
        expect(
          tester
              .widget<NavigationBar>(find.byType(NavigationBar))
              .selectedIndex,
          3,
        );
        final container = ProviderScope.containerOf(
          tester.element(find.byType(HabitCheckinApp)),
        );
        if (section != 'pairing') {
          final key = section == 'chat' ? 'open-chat' : 'open-sharing';
          await waitFor(() => find.byKey(ValueKey(key)).evaluate().isNotEmpty);
          await tap(find.byKey(ValueKey(key)));
          if (section == 'reply') {
            final replies = find.byKey(ValueKey('open-replies-$testRecordId'));
            await waitFor(() => replies.evaluate().isNotEmpty);
            await tap(replies);
          }
        }
        final ready = section == 'pairing'
            ? find.text('ABCDEFGH')
            : find.text('SYNTHETIC time $section 1');
        await waitFor(() => ready.evaluate().isNotEmpty);

        void checkTimes() {
          final pastLabel = losAngeles
              ? '${now == before ? '今天' : '昨天'} 23:59'
              : '今天 14:59';
          final nextLabel = losAngeles
              ? '${now == before ? '10月22日' : '今天'} 00:00'
              : '今天 15:00';
          if (section == 'pairing') {
            expect(
              find.text('有效期至 10月22日 ${losAngeles ? '00:05' : '15:05'}'),
              findsOneWidget,
            );
          } else {
            // The same UTC minute crosses midnight only in Los Angeles.
            // Shanghai must keep one divider, not one timestamp per bubble.
            expect(
              tester
                  .widgetList<ChatTimeDivider>(find.byType(ChatTimeDivider))
                  .map((divider) => divider.label)
                  .toList(),
              losAngeles
                  ? [
                      now == before ? '23:59' : '昨天 23:59',
                      now == before ? '10月22日 00:00' : '00:00',
                    ]
                  : ['14:59'],
            );
            expect(find.text('TA · $pastLabel'), findsNothing);
            expect(
              find.text('TA · $nextLabel'),
              section == 'reply' ? findsOneWidget : findsNothing,
              reason: 'Only the shared-record header keeps its author/time',
            );
            if (section == 'reply') {
              expect(find.text('已完成 · $pastLabel'), findsOneWidget);
            }
          }
        }

        final input = find.byKey(
          ValueKey(switch (section) {
            'pairing' => 'pairing-code-input',
            'reply' => 'sharing-reply-input',
            _ => 'chat-input',
          }),
        );
        final draft = section == 'pairing' ? 'ABCD' : 'SYNTHETIC time draft';
        if (seeding) {
          await tester.ensureVisible(input);
          await tester.enterText(input, draft);
          await tester.pumpAndSettle();
        }
        expect(tester.widget<TextField>(input).controller!.text, draft);
        checkTimes();
        await shot('before-midnight');
        final dayBefore = clock.read().day.toString();
        now = after;
        await container.read(environmentProvider.notifier).refresh();
        await tester.pumpAndSettle();
        expect(clock.read().day.toString(), '2026-10-22');
        expect(dayBefore, losAngeles ? '2026-10-21' : '2026-10-22');
        checkTimes();
        expect(tester.widget<TextField>(input).controller!.text, draft);
        await shot('after-midnight');

        final cache = await storedCache();
        if (seeding) {
          await cacheFile.writeAsString(jsonEncode(cache), flush: true);
        } else {
          expect(cache, jsonDecode(await cacheFile.readAsString()));
        }
        expect(await personal(), jsonDecode(await personalFile.readAsString()));
        expect(service.commands, isEmpty);
        expect(service.sharedCommands, isEmpty);
        expect(service.chatCommands, isEmpty);
        expect(
          await db.customSelect('PRAGMA foreign_key_check').get(),
          isEmpty,
        );
        await File('${output.path}/report.json').writeAsString(
          jsonEncode({
            'run': run,
            'phase': phase,
            'section': section,
            'native_zone': device.read().zone,
            'native_offset_minutes': before.toLocal().timeZoneOffset.inMinutes,
            'process_timezone_only': true,
            'synthetic_clock': true,
            'day_before': dayBefore,
            'day_after': clock.read().day.toString(),
            'utc_cache_unchanged': !seeding,
            'draft_preserved': true,
            'personal_unchanged': true,
            'write_commands': 0,
          }),
          flush: true,
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await db.close();
      }
    });
  }
}
