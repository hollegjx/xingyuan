import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/reminders/notification_permissions.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);
  const channel = MethodChannel('dexterous.com/flutter/local_notifications');
  final calls = <MethodCall>[];
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    IOSFlutterLocalNotificationsPlugin.registerWith();
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return switch (call.method) {
            'initialize' => false,
            'getNotificationAppLaunchDetails' => {
              'notificationLaunchedApp': true,
              'notificationResponse': {
                'notificationResponseType': 0,
                'payload': 'invalid-or-archived',
              },
            },
            'pendingNotificationRequests' => [
              {'id': 23, 'payload': 'owned'},
            ],
            'getActiveNotifications' => [
              {'id': 24, 'payload': 'delivered'},
            ],
            'checkPermissions' => {'isEnabled': false},
            'zonedSchedule' || 'cancel' => null,
            _ => throw StateError('Unexpected ${call.method}'),
          };
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('one-shot UTC schedule, generic content, pending/delivered and targeted cancel', () async {
    final service = IosNotificationPermissions();
    final at = tz.TZDateTime(
      tz.getLocation('Asia/Shanghai'),
      2090,
      5,
      6,
      8,
      30,
    );
    await service.schedule(23, at, 'owned');
    final args = calls.last.arguments as Map;
    expect(args['title'], '星愿');
    expect(args['body'], '有一项计划待完成');
    expect(args['payload'], 'owned');
    expect(args['timeZoneName'], 'Etc/UTC');
    expect(args['scheduledDateTime'], startsWith('2090-05-06T00:30:00'));
    expect(args.containsKey('matchDateTimeComponents'), isFalse);
    expect((await service.pending()).single.id, 23);
    expect((await service.delivered()).single.id, 24);
    await service.cancel(23);
    expect(calls.last.method, 'cancel');
    expect(calls.last.arguments, 23);
    expect(calls.any((call) => call.method == 'cancelAll'), isFalse);
    expect(calls.any((call) => call.method == 'requestPermissions'), isFalse);
  });

  test(
    'cold notification launch is handled once, without requiring valid payload',
    () async {
      var opens = 0;
      final service = IosNotificationPermissions(onNotification: () => opens++);
      await service.read();
      await service.pending();
      expect(opens, 1);
      expect(calls.where((c) => c.method == 'initialize'), hasLength(1));
    },
  );
}
