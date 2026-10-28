import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/app/app.dart';
import 'package:habit_checkin/app/providers.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/local/open_database.dart';
import 'package:habit_checkin/data/sync/identity_store.dart';
import 'package:habit_checkin/features/analysis/analysis_providers.dart';
import 'package:habit_checkin/features/assistant/assistant_providers.dart';
import 'package:habit_checkin/features/assistant/data/device_credential_store.dart';
import 'package:habit_checkin/features/companion/companion_providers.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:habit_checkin/features/journal/data/local_journal_store.dart';
import 'package:habit_checkin/features/journal/domain/journal_entry.dart';
import 'package:habit_checkin/features/journal/journal_providers.dart';
import 'package:path_provider/path_provider.dart';
import 'package:integration_test/integration_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:uuid/uuid.dart';

import '../test/support/test_reminder_notifications.dart';
import '../test/support/ui_harness.dart' show TestNotificationPermissions;

class _NoCredential extends DeviceCredentialStore {
  const _NoCredential();

  @override
  Future<String?> read() =>
      throw StateError('Journal must not read a credential');

  @override
  Future<void> save(String input) => throw StateError('No credential writes');

  @override
  Future<void> clear() => throw StateError('No credential deletion');
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

// Dedicated QA simulator only. The host supplies real system input and lock /
// unlock / kill actions. No injected lifecycle events or fake text input.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  binding.shouldPropagateDevicePointerEvents = true;
  tzdata.initializeTimeZones();
  const run = String.fromEnvironment('JOURNAL_LIFECYCLE_RUN');
  const section = String.fromEnvironment('JOURNAL_LIFECYCLE_KIND');
  const phase = String.fromEnvironment('JOURNAL_LIFECYCLE_PHASE');
  const hostWindow = Duration(minutes: 10);
  const baseline = 'SYNTHETIC saved content';
  const text = '合成记录：🙂\n第二行，稍后继续。';

  testWidgets('journal system input and cold draft $section/$phase', (
    tester,
  ) async {
    expect(Platform.isIOS, isTrue);
    expect(RegExp(r'^[a-z0-9-]{8,40}$').hasMatch(run), isTrue);
    expect({'quickNote', 'diary'}, contains(section));
    expect({'arm', 'reopen'}, contains(phase));
    expect(binding.testTextInput.isRegistered, isFalse);
    final kind = JournalKind.values.byName(section);
    final documents = await getApplicationDocumentsDirectory();
    final workspace = await Directory(
      '${documents.path}/journal_lifecycle_${run}_$section',
    ).create(recursive: true);
    final output = Directory('${workspace.path}/$phase');
    expect(await output.exists(), isFalse, reason: 'Use a fresh run');
    await output.create();
    final lifecycle = _LifecycleLog(File('${output.path}/lifecycle.json'));
    binding.addObserver(lifecycle);
    final db = openAppDatabase(name: 'journal_lifecycle_${run}_$section');
    final clock = DeviceClock();
    await clock.refreshZone();
    final lease = await IdentityStore(db).active();
    final goals = LocalGoalRepository(
      db,
      clock,
      owner: lease.identity.owner,
      identityLease: lease,
    );
    final LocalJournalStore store = kind == JournalKind.quickNote
        ? LocalQuickNoteStore(goals)
        : LocalDiaryStore(goals);
    final input = find.byKey(const ValueKey('journal-text'));
    final lockEvents = <String>[];
    Future<void> waitFor(Future<bool> Function() ready) async {
      final elapsed = Stopwatch()..start();
      while (!await ready()) {
        if (elapsed.elapsed > hostWindow) {
          fail('Host interaction or native state did not arrive');
        }
        await tester.pump(const Duration(milliseconds: 100));
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
    }

    String visibleText() => tester.widget<TextField>(input).controller!.text;
    Future<JournalEntry> row() async => (await store.list()).single.entry;
    try {
      if (phase == 'arm') {
        expect(await store.list(), isEmpty);
        var value = switch (store) {
          LocalQuickNoteStore notes => await notes.beginDraft(),
          LocalDiaryStore diary => await diary.beginDraft(clock.read().day),
          _ => throw StateError('Unsupported kind'),
        };
        value = await store.writeDraft(
          value.entry.id,
          content: baseline,
          expectedDraftRevision: value.entry.draftRevision,
        );
        await store.save(
          value.entry.id,
          operationId: const Uuid().v4(),
          expectedRevision: value.entry.revision,
          expectedDraftRevision: value.entry.draftRevision,
        );
        final id = await goals.create(
          const GoalDraft(
            title: 'SYNTHETIC journal gate',
            kind: GoalKind.habit,
          ),
        );
        await goals.setCompleted(id, true, expectedDay: clock.read().day);
      }
      final original = await row();
      expect(original.content, baseline);
      expect(original.revision, 1);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWith((ref) => db),
            goalRepositoryProvider.overrideWith((ref) => goals),
            journalPhotoRootProvider.overrideWith(
              (ref) => Directory('${workspace.path}/photos'),
            ),
            assistantCredentialProvider.overrideWithValue(
              const _NoCredential(),
            ),
            companionForegroundProvider.overrideWithValue(null),
            clockProvider.overrideWithValue(clock),
            refreshClockProvider.overrideWithValue(clock.refreshZone),
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
      final entry = find.byKey(ValueKey('journal-entry-${original.id}'));
      await waitFor(() async => entry.evaluate().isNotEmpty);
      await tap(entry);
      await waitFor(() async => input.evaluate().isNotEmpty);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(HabitCheckinApp)),
      );
      if (phase == 'arm') {
        expect(visibleText(), baseline);
        await tap(input);
        debugPrint('JOURNAL_READY_TO_TYPE $run $section');
        await waitFor(
          () async => visibleText() == text && (await row()).draftText == text,
        );
        await waitFor(() async => tester.view.viewInsets.bottom > 0);
        expect(binding.testTextInput.isRegistered, isFalse);
        debugPrint('JOURNAL_READY_TO_DISMISS $run $section');
        await waitFor(
          () async =>
              !tester.widget<TextField>(input).focusNode!.hasFocus &&
              tester.view.viewInsets.bottom == 0,
        );
        expect(visibleText(), text);
        // Return and switch tabs before reopening the exact saved row.
        await tap(find.byType(BackButton));
        await tap(find.byTooltip('我的'));
        await tap(find.byTooltip('今天'));
        await tap(entry);
        expect(visibleText(), text);
        expect((await row()).content, baseline);
        await tap(input);
        await waitFor(() async => tester.view.viewInsets.bottom > 0);
        final start = lifecycle.events.length;
        debugPrint('JOURNAL_READY_TO_LOCK $run $section');
        final elapsed = Stopwatch()..start();
        while (!lifecycle.resumedAfterPause(start)) {
          if (elapsed.elapsed > hostWindow) {
            fail('Actual pause/resume not observed');
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        lockEvents.addAll(lifecycle.events.skip(start));
        await tester.pumpAndSettle();
        expect(visibleText(), text);
        expect((await row()).draftText, text);
        expect((await row()).content, baseline);
      } else {
        expect(visibleText(), text);
        expect((await row()).draftText, text);
        final save = find.byKey(const ValueKey('save-journal'));
        await tester.ensureVisible(save);
        await tester.pumpAndSettle();
        final position = tester.getCenter(save);
        for (var i = 0; i < 5; i++) {
          await tester.tapAt(position);
        }
        await tester.pumpAndSettle();
        expect(input, findsNothing);
        final saved = await store.savedOn(clock.read().day);
        expect(saved, hasLength(1));
        expect(saved.single.entry.content, text);
        expect(saved.single.entry.revision, 2);
        expect(saved.single.entry.draftText, isNull);
      }
      expect(container.exists(assistantConversationProvider), isFalse);
      expect(container.exists(assistantServiceProvider), isFalse);
      expect(container.exists(dayAnalysisControllerProvider), isFalse);
      expect(container.exists(pairingControllerProvider), isFalse);
      expect(container.exists(chatControllerProvider), isFalse);
      expect((await db.select(db.checkIns).get()).single.completed, isTrue);
      expect(await db.customSelect('PRAGMA foreign_key_check').get(), isEmpty);
      expect(tester.takeException(), isNull);
      await File('${output.path}/report.json').writeAsString(
        jsonEncode({
          'run': run,
          'kind': section,
          'phase': phase,
          'system_text_input': !binding.testTextInput.isRegistered,
          'software_keyboard_and_outside_dismissal': phase == 'arm',
          'return_tab_and_lock_draft_preserved': phase == 'arm',
          'cold_draft_and_five_save_taps': phase == 'reopen',
          'saved_content_separate_from_draft': true,
          'network_providers_created': false,
          'personal_checkin_preserved': true,
          'lifecycle': lifecycle.events,
          'lock_lifecycle': lockEvents,
          'clock_zone': clock.read().zone,
        }),
        flush: true,
      );
      if (phase == 'arm') {
        debugPrint('JOURNAL_READY_TO_KILL $run $section');
        await Future<void>.delayed(hostWindow);
        fail('Host did not terminate the armed simulator App');
      }
    } finally {
      binding.removeObserver(lifecycle);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await db.close();
    }
  }, timeout: const Timeout(Duration(minutes: 35)));
}
