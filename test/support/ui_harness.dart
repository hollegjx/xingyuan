import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/app/app.dart';
import 'package:habit_checkin/app/providers.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/features/assistant/assistant_providers.dart';
import 'package:habit_checkin/features/analysis/analysis_providers.dart';
import 'package:habit_checkin/features/assistant/data/assistant_service.dart';
import 'package:habit_checkin/features/assistant/data/device_credential_store.dart';
import 'package:habit_checkin/features/reminders/notification_permissions.dart';
import 'package:habit_checkin/features/records/data/record_photo_files.dart';
import 'package:habit_checkin/features/records/data/record_photo_picker.dart';
import 'package:habit_checkin/features/records/record_providers.dart';
import 'package:habit_checkin/features/companion/companion_providers.dart';
import 'package:habit_checkin/features/companion/data/companion_service.dart';
import 'package:habit_checkin/features/journal/data/journal_photo_files.dart';
import 'package:habit_checkin/features/journal/domain/journal_entry.dart';
import 'package:habit_checkin/features/journal/journal_providers.dart';
import 'package:habit_checkin/features/journal/ai/journal_ai_providers.dart';

import 'legacy_planning/planning_service.dart';
import 'legacy_planning/planning_providers.dart';

import 'test_clock.dart';
import 'test_reminder_notifications.dart';
import 'chat_photo_files.dart';

class TestNotificationPermissions implements NotificationPermissions {
  NotificationAccess access = NotificationAccess.off;
  int reads = 0;
  int requests = 0;
  int settingsOpens = 0;
  Object? failure;
  Future<NotificationAccess> Function()? onRead;
  Future<NotificationAccess> Function()? onRequest;

  @override
  Future<NotificationAccess> read() async {
    reads++;
    if (failure case final error?) throw error;
    return onRead?.call() ?? access;
  }

  @override
  Future<NotificationAccess> request() async {
    requests++;
    if (failure case final error?) throw error;
    return onRequest?.call() ?? access;
  }

  @override
  Future<bool> openSettings() async {
    settingsOpens++;
    if (failure case final error?) throw error;
    return true;
  }
}

class UiHarness {
  UiHarness() {
    repository = LocalGoalRepository(database, clock);
  }

  final database = AppDatabase(NativeDatabase.memory());
  final clock = TestClock();
  final permissions = TestNotificationPermissions();
  final notifications = TestReminderNotifications();
  Object? clockFailure;
  late final LocalGoalRepository repository;
  late final ProviderContainer container;
  late final chatPhotoFiles = MemoryChatPhotoFiles(database);

  Future<void> mount(
    WidgetTester tester, {
    PlanningService? planningService,
    AssistantService? assistantService,
    DayAnalysisService? dayAnalysisService,
    JournalAiService? journalAiService,
    CompanionService? companionService,
    DeviceCredentialStore? assistantCredentials,
    RecordPhotoFiles? recordPhotoFiles,
    RecordPhotoPicker? recordPhotoPicker,
    Map<JournalKind, JournalPhotoFiles> journalPhotoFiles = const {},
    Widget Function(Widget child)? wrapApp,
    bool companionForeground = false,
  }) async {
    addTearDown(() async {
      await database.close();
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWith((ref) => database),
          chatPhotoFilesProvider.overrideWith((ref) {
            ref.onDispose(() => chatPhotoFiles.dispose().ignore());
            return chatPhotoFiles;
          }),
          if (!companionForeground)
            companionForegroundProvider.overrideWithValue(null),
          if (companionService != null)
            companionServiceProvider.overrideWithValue(companionService),
          if (dayAnalysisService != null)
            dayAnalysisServiceProvider.overrideWithValue(dayAnalysisService),
          if (journalAiService != null)
            journalAiServiceProvider.overrideWithValue(journalAiService),
          if (recordPhotoFiles != null)
            recordPhotoFilesProvider.overrideWith((ref) => recordPhotoFiles),
          if (recordPhotoPicker != null)
            recordPhotoPickerProvider.overrideWithValue(recordPhotoPicker),
          for (final entry in journalPhotoFiles.entries)
            journalPhotoFilesProvider(entry.key)
                .overrideWith((ref) => entry.value),
          if (assistantService != null)
            assistantServiceProvider.overrideWithValue(assistantService),
          if (assistantCredentials != null)
            assistantCredentialProvider.overrideWithValue(assistantCredentials),
          if (planningService != null)
            planningServiceProvider.overrideWithValue(planningService),
          clockProvider.overrideWithValue(clock),
          refreshClockProvider.overrideWithValue(() async {
            if (clockFailure case final error?) throw error;
          }),
          goalRepositoryProvider.overrideWith((ref) => repository),
          notificationPermissionsProvider.overrideWithValue(permissions),
          reminderNotificationsProvider.overrideWithValue(notifications),
        ],
        child:
            wrapApp?.call(const HabitCheckinApp()) ?? const HabitCheckinApp(),
      ),
    );
    container = ProviderScope.containerOf(
      tester.element(find.byType(HabitCheckinApp)),
    );
    await tester.pumpAndSettle();
  }
}

Future<void> tapVisible(
  WidgetTester tester,
  Finder finder, {
  bool settle = true,
}) async {
  expect(finder, findsOneWidget);
  await tester.ensureVisible(finder);
  // A tall target can still have its centre off-screen until the scroll from
  // ensureVisible is laid out; only then wait for that frame.
  final screen =
      Offset.zero & tester.view.physicalSize / tester.view.devicePixelRatio;
  if (!screen.contains(tester.getCenter(finder))) await tester.pump();
  expect(finder.hitTestable(), findsOneWidget);
  await tester.tap(finder);
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await pumpWaiting(tester);
  }
}

/// Advance gated network states with a continuous activity indicator. Callers
/// must assert the pending state; ordinary interactions still settle normally.
Future<void> pumpWaiting(WidgetTester tester) async {
  for (var frame = 0; frame < 20; frame++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Settings now live in 我的; goal management is pushed from that tab.
Future<void> openMenu(WidgetTester tester, String label) async {
  if (label == '陪伴') {
    await tapVisible(tester, find.byTooltip('陪伴'));
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      3,
    );
    return;
  }
  await tapVisible(tester, find.byTooltip('我的'));
  if (label != '设置') await tapVisible(tester, find.text(label));
}

/// Leaves the current screen: a pushed page pops; a top-level tab such as
/// 陪伴 has no back button, so leaving it returns to 今天.
Future<void> goBack(WidgetTester tester) {
  final back = find.byType(BackButton);
  if (back.evaluate().isNotEmpty) return tapVisible(tester, back);
  final bar = find.byType(NavigationBar);
  expect(
    bar,
    findsOneWidget,
    reason: 'Only a top-level tab may return to Today without a back button.',
  );
  expect(Navigator.of(tester.element(bar)).canPop(), isFalse);
  expect(tester.widget<NavigationBar>(bar).selectedIndex, isNot(0));
  return tapVisible(tester, find.byTooltip('今天'));
}

void testUiWidgets(
  String description,
  WidgetTesterCallback callback, {
  TestVariant<Object?> variant = const DefaultTestVariant(),
}) {
  testWidgets(description, (tester) async {
    try {
      await callback(tester);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      // Drift releases stream queries on the next event-loop turn.
      await tester.pump(Duration.zero);
    }
  }, variant: variant);
}
