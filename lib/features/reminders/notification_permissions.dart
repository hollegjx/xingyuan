import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import 'reminder_notifications.dart';

enum NotificationAccess { allowed, quiet, alertsOff, off }

abstract interface class NotificationPermissions {
  Future<NotificationAccess> read();
  Future<NotificationAccess> request();
  Future<bool> openSettings();
}

class IosNotificationPermissions
    implements NotificationPermissions, ReminderNotifications {
  IosNotificationPermissions({
    FlutterLocalNotificationsPlugin? plugin,
    this.onNotification,
  }) : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  final void Function()? onNotification;
  Future<void>? _initializing;

  IOSFlutterLocalNotificationsPlugin get _ios =>
      _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >() ??
      (throw StateError('iOS notification implementation is unavailable'));

  Future<void> _initialize() => _initializing ??= _ios
      .initialize(
        settings: const DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
        onDidReceiveNotificationResponse: (_) => onNotification?.call(),
      )
      // iOS returns false when initialization requests no permissions.
      .then<void>((_) async {
        if (onNotification != null) {
          final launch = await _ios.getNotificationAppLaunchDetails();
          if (launch?.didNotificationLaunchApp == true) onNotification!();
        }
      })
      .onError<Object>((error, stack) {
        _initializing = null;
        Error.throwWithStackTrace(error, stack);
      });

  @override
  Future<NotificationAccess> read() async {
    await _initialize();
    final permission = await _ios.checkPermissions();
    if (permission == null) {
      throw StateError('Notification permission could not be read');
    }
    if (permission.isProvisionalEnabled) return NotificationAccess.quiet;
    if (!permission.isEnabled) return NotificationAccess.off;
    return permission.isAlertEnabled
        ? NotificationAccess.allowed
        : NotificationAccess.alertsOff;
  }

  @override
  Future<NotificationAccess> request() async {
    await _initialize();
    await _ios.requestPermissions(alert: true, sound: true);
    return read();
  }

  @override
  Future<bool> openSettings() async {
    await _initialize();
    return await _ios.openAppNotificationSettings() ?? false;
  }

  @override
  Future<List<PendingReminder>> pending() async {
    await _initialize();
    return [
      for (final item in await _ios.pendingNotificationRequests())
        PendingReminder(item.id, item.payload),
    ];
  }

  @override
  Future<List<PendingReminder>> delivered() async {
    await _initialize();
    return [
      for (final item in await _ios.getActiveNotifications())
        if (item.id != null) PendingReminder(item.id!, item.payload),
    ];
  }

  @override
  Future<void> schedule(int id, tz.TZDateTime at, String payload) async {
    await _initialize();
    await _ios.zonedSchedule(
      id: id,
      title: '星愿',
      body: '有一项计划待完成',
      // Resolve local gaps/folds ourselves and send one absolute occurrence.
      scheduledDate: tz.TZDateTime.from(at, tz.UTC),
      notificationDetails: const DarwinNotificationDetails(
        presentAlert: true,
        presentSound: true,
        presentBadge: false,
      ),
      payload: payload,
    );
  }

  @override
  Future<void> cancel(int id) async {
    await _initialize();
    await _ios.cancel(id: id);
  }
}
