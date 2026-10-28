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
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:timezone/data/latest.dart' as tzdata;

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
      throw StateError('The lifecycle probe cannot save credentials');

  @override
  Future<void> clear() async =>
      throw StateError('The lifecycle probe cannot clear credentials');
}

class _LifecycleLog extends WidgetsBindingObserver {
  _LifecycleLog(this.file);

  final File file;
  final events = <String>[];

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    events.add(state.name);
    file.writeAsStringSync(jsonEncode(events), flush: true);
  }

  bool resumedAfterPause(int start) {
    final observed = events.skip(start).toList();
    final paused = observed.indexOf('paused');
    return paused >= 0 && observed.skip(paused + 1).contains('resumed');
  }
}

// QA simulator only. The host types with the system keyboard, locks/unlocks
// the device, and terminates the App at the final marker. No lifecycle event
// or text input is synthesized by this test. Network services are fixtures.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  tzdata.initializeTimeZones();
  const run = String.fromEnvironment('LIFECYCLE_RUN');
  const section = String.fromEnvironment('LIFECYCLE_SECTION');
  const phase = String.fromEnvironment('LIFECYCLE_PHASE');
  const drafts = {
    'pairing': 'ABCD',
    'reply': 'SYNTHETIC reply draft\ncontinue later',
    'chat': 'SYNTHETIC chat draft\ncontinue later',
  };
  const keys = {
    'pairing': 'pairing-code-input',
    'reply': 'sharing-reply-input',
    'chat': 'chat-input',
  };

  testWidgets('system lock and cold-launch draft recovery $section/$phase', (
    tester,
  ) async {
    expect(Platform.isIOS, true);
    expect(RegExp(r'^[a-z0-9-]{8,40}$').hasMatch(run), true);
    expect(drafts.keys, contains(section));
    expect({'arm', 'reopen'}, contains(phase));
    expect(binding.testTextInput.isRegistered, false);
    final documents = await getApplicationDocumentsDirectory();
    final workspace = await Directory(
      '${documents.path}/lifecycle_${run}_$section',
    ).create(recursive: true);
    final output = Directory('${workspace.path}/$phase');
    expect(await output.exists(), false, reason: 'Use a fresh run');
    await output.create();
    final lifecycle = _LifecycleLog(File('${output.path}/lifecycle.json'));
    binding.addObserver(lifecycle);
    final db = openAppDatabase(name: 'habit_checkin_lifecycle_${run}_$section');
    final clock = DeviceClock();
    await clock.refreshZone();
    final goals = LocalGoalRepository(db, clock);
    final service = TestChatService()
      ..current = testPairingState(paired: section != 'pairing');
    final capture = GlobalKey();
    final input = find.byKey(ValueKey<String>(keys[section]!));
    final text = drafts[section]!;
    var lockEvents = <String>[];

    Future<void> waitFor(Future<bool> Function() ready) async {
      final elapsed = Stopwatch()..start();
      while (!await ready()) {
        if (elapsed.elapsed > const Duration(minutes: 3)) {
          fail('Host interaction or native state did not arrive');
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
          capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
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
      if (phase == 'arm') {
        expect(await goals.loadGoals(), isEmpty);
        final id = await goals.create(
          const GoalDraft(title: 'SYNTHETIC lifecycle', kind: GoalKind.habit),
        );
        await goals.setCompleted(id, true, expectedDay: clock.read().day);
      }
      final goal = (await goals.loadGoals()).single;
      expect(goal.titleOn(clock.read().day), 'SYNTHETIC lifecycle');
      service.seed(
        (await db.select(db.goals).get()).single.globalId,
        partner: true,
      );
      service.incoming('SYNTHETIC existing chat');
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
            refreshClockProvider.overrideWithValue(clock.refreshZone),
            notificationPermissionsProvider.overrideWithValue(
              TestNotificationPermissions(),
            ),
            reminderNotificationsProvider.overrideWithValue(
              TestReminderNotifications(),
            ),
          ],
          child: RepaintBoundary(key: capture, child: const HabitCheckinApp()),
        ),
      );
      await waitFor(() async => find.byTooltip('陪伴').evaluate().isNotEmpty);
      await tap(find.byTooltip('陪伴'));
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        3,
      );
      if (section != 'pairing') {
        final key = section == 'chat' ? 'open-chat' : 'open-sharing';
        await waitFor(
          () async => find.byKey(ValueKey(key)).evaluate().isNotEmpty,
        );
        await tap(find.byKey(ValueKey(key)));
        if (section == 'reply') {
          final replies = find.byKey(ValueKey('open-replies-$testRecordId'));
          await waitFor(() async => replies.evaluate().isNotEmpty);
          await tap(replies);
        }
      }
      await waitFor(() async => input.evaluate().isNotEmpty);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(HabitCheckinApp)),
      );
      Future<String?> persistedDraft() async => switch (section) {
        'pairing' => (await (await container.read(
          pairingControllerProvider.future,
        )).store.snapshot()).row.draftCode,
        'reply' => (await (await container.read(
          sharingControllerProvider.future,
        )).store.draft(testRecordId))?.content,
        _ => (await (await container.read(
          chatControllerProvider.future,
        )).store.snapshot()).state.draftText,
      };
      String visibleDraft() => tester.widget<TextField>(input).controller!.text;

      if (phase == 'arm') {
        expect(visibleDraft(), '');
        await tap(input);
        debugPrint('LIFECYCLE_READY_TO_TYPE $run $section');
        await waitFor(
          () async =>
              input.evaluate().isNotEmpty &&
              visibleDraft() == text &&
              await persistedDraft() == text,
        );
        expect(binding.testTextInput.isRegistered, false);
        await shot('before-lock');
        final start = lifecycle.events.length;
        debugPrint('LIFECYCLE_READY_TO_LOCK $run $section');
        // A pump would wait for a frame while iOS has suspended rendering.
        final elapsed = Stopwatch()..start();
        while (!lifecycle.resumedAfterPause(start)) {
          if (elapsed.elapsed > const Duration(minutes: 3)) {
            fail('An actual pause followed by resume was not observed');
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        lockEvents = lifecycle.events.skip(start).toList();
        await tester.pumpAndSettle();
        expect(visibleDraft(), text);
        expect(await persistedDraft(), text);
        await shot('after-unlock');
      } else {
        expect(visibleDraft(), text);
        expect(await persistedDraft(), text);
        await shot('cold-reopen');
      }
      expect(service.commands, isEmpty);
      expect(service.sharedCommands, isEmpty);
      expect(service.chatCommands, isEmpty);
      expect((await db.select(db.checkIns).get()).single.completed, true);
      expect(await db.customSelect('PRAGMA foreign_key_check').get(), isEmpty);
      expect(tester.takeException(), isNull);
      await File('${output.path}/report.json').writeAsString(
        jsonEncode({
          'run': run,
          'section': section,
          'phase': phase,
          'draft_preserved': true,
          'personal_checkin_preserved': true,
          'write_commands': 0,
          'system_text_input': !binding.testTextInput.isRegistered,
          'lifecycle': lifecycle.events,
          'lock_lifecycle': lockEvents,
          'clock_zone': clock.read().zone,
        }),
        flush: true,
      );
      if (phase == 'arm') {
        debugPrint('LIFECYCLE_READY_TO_KILL $run $section');
        await Future<void>.delayed(const Duration(minutes: 3));
        fail('The host did not terminate the armed simulator App');
      }
    } finally {
      binding.removeObserver(lifecycle);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await db.close();
    }
  }, timeout: const Timeout(Duration(minutes: 8)));
}
