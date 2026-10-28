import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/app/providers.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:habit_checkin/features/reminders/notification_permissions.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'support/ui_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);

  group('iOS permission adapter', () {
    const channel = MethodChannel('dexterous.com/flutter/local_notifications');
    final calls = <MethodCall>[];
    Map<String, bool>? permission;
    Object? initializeFailure;
    late IosNotificationPermissions service;

    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      IOSFlutterLocalNotificationsPlugin.registerWith();
      permission = {'isEnabled': false};
      initializeFailure = null;
      calls.clear();
      service = IosNotificationPermissions();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'initialize' && initializeFailure != null) {
              throw initializeFailure!;
            }
            return switch (call.method) {
              'initialize' => false,
              'checkPermissions' => permission,
              'requestPermissions' => false,
              'openAppNotificationSettings' => true,
              _ => throw StateError('Unexpected notification operation'),
            };
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      debugDefaultTargetPlatformOverride = null;
    });

    test(
      'read initializes without requesting any permission or scheduling',
      () async {
        expect(await service.read(), NotificationAccess.off);
        expect(calls.map((call) => call.method), [
          'initialize',
          'checkPermissions',
        ]);
        final arguments = calls.first.arguments as Map;
        expect(arguments['requestAlertPermission'], isFalse);
        expect(arguments['requestBadgePermission'], isFalse);
        expect(arguments['requestSoundPermission'], isFalse);
        expect(arguments['requestProvisionalPermission'], isFalse);
        expect(arguments['requestCriticalPermission'], isFalse);
      },
    );

    test(
      'authorization and presentation settings are mapped separately',
      () async {
        permission = {'isEnabled': true, 'isAlertEnabled': true};
        expect(await service.read(), NotificationAccess.allowed);
        permission = {'isEnabled': false, 'isProvisionalEnabled': true};
        expect(await service.read(), NotificationAccess.quiet);
        permission = {'isEnabled': true, 'isAlertEnabled': false};
        expect(await service.read(), NotificationAccess.alertsOff);
        permission = {'isEnabled': false, 'isAlertEnabled': true};
        expect(await service.read(), NotificationAccess.off);
        expect(
          calls.where((call) => call.method == 'initialize'),
          hasLength(1),
        );
      },
    );

    test(
      'explicit request rereads state rather than assuming success',
      () async {
        expect(await service.request(), NotificationAccess.off);
        expect(calls.map((call) => call.method), [
          'initialize',
          'requestPermissions',
          'checkPermissions',
        ]);
        expect(await service.openSettings(), isTrue);
        expect(calls.last.method, 'openAppNotificationSettings');
      },
    );

    test(
      'failed initialization is retryable and unreadable status is an error',
      () async {
        initializeFailure = PlatformException(code: 'test_init_failure');
        await expectLater(service.read(), throwsA(isA<PlatformException>()));
        initializeFailure = null;
        expect(await service.read(), NotificationAccess.off);
        expect(
          calls.where((call) => call.method == 'initialize'),
          hasLength(2),
        );
        permission = null;
        await expectLater(service.read(), throwsStateError);
      },
    );
  });

  testUiWidgets('disabled alerts are not reported as denied authorization', (
    tester,
  ) async {
    final app = UiHarness();
    app.permissions.access = NotificationAccess.alertsOff;
    final id = await app.repository.create(
      const GoalDraft(
        title: 'TEST authorized',
        kind: GoalKind.habit,
        reminderEnabled: true,
      ),
    );
    await app.mount(tester);
    await tapVisible(tester, find.byKey(ValueKey('detail-$id')));
    expect(find.text('系统通知提示已关闭'), findsOneWidget);
    expect(find.text('通知未授权，提醒未生效'), findsNothing);
    await goBack(tester);
    await openMenu(tester, '设置');
    expect(find.text('系统已授权，通知提示已关闭'), findsOneWidget);
    expect(find.byKey(const ValueKey('request-permission')), findsNothing);
    await tapVisible(
      tester,
      find.byKey(const ValueKey('open-notification-settings')),
    );
    expect(app.permissions.requests, 0);
    expect(app.permissions.settingsOpens, 1);
    expect(tester.takeException(), isNull);
  });

  test(
    'initial read cannot overwrite a later explicit permission result',
    () async {
      final initial = Completer<NotificationAccess>();
      final requested = Completer<NotificationAccess>();
      final permissions = TestNotificationPermissions();
      permissions.onRead = () => initial.future;
      permissions.onRequest = () => requested.future;
      final container = ProviderContainer(
        overrides: [
          notificationPermissionsProvider.overrideWithValue(permissions),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(notificationAccessProvider.notifier);
      final request = controller.refresh(request: true);
      expect(permissions.requests, 0);
      initial.complete(NotificationAccess.off);
      await Future<void>.delayed(Duration.zero);
      expect(permissions.requests, 1);
      expect(container.read(notificationAccessProvider).isLoading, isTrue);
      requested.complete(NotificationAccess.allowed);
      await request;
      expect(
        container.read(notificationAccessProvider).requireValue,
        NotificationAccess.allowed,
      );
    },
  );

  test(
    'permission provider construction failure does not undo saved goal',
    () async {
      final app = UiHarness();
      final container = ProviderContainer(
        overrides: [
          clockProvider.overrideWithValue(app.clock),
          refreshClockProvider.overrideWithValue(() async {}),
          goalRepositoryProvider.overrideWith((ref) => app.repository),
          notificationPermissionsProvider.overrideWith((ref) {
            throw StateError('injected initialization failure');
          }),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await app.database.close();
      });
      final id = await container
          .read(goalCommandsProvider.notifier)
          .create(
            const GoalDraft(
              title: 'TEST persisted',
              kind: GoalKind.habit,
              reminderEnabled: true,
            ),
          );
      expect((await app.repository.loadGoals()).single.id, id);
      expect(container.read(notificationAccessProvider).hasError, isTrue);
      expect(container.read(goalCommandsProvider), isEmpty);
      await container.read(reminderReportProvider.notifier).refresh();
      expect(container.read(reminderReportProvider).hasError, isTrue);
    },
  );
}
