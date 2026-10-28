import 'package:habit_checkin/features/reminders/reminder_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

class TestReminderNotifications implements ReminderNotifications {
  final requests = <int, PendingReminder>{};
  final times = <int, tz.TZDateTime>{};
  final arrivals = <PendingReminder>[];
  final scheduled = <int>[];
  final cancelled = <int>[];
  Object? failure;
  bool ignoreCancel = false;
  bool dropSchedule = false;
  Future<void> Function(int)? onSchedule;

  void _check() {
    if (failure case final error?) throw error;
  }

  @override
  Future<List<PendingReminder>> pending() async {
    _check();
    return requests.values.toList();
  }

  @override
  Future<List<PendingReminder>> delivered() async {
    _check();
    return arrivals.toList();
  }

  @override
  Future<void> schedule(int id, tz.TZDateTime at, String payload) async {
    _check();
    scheduled.add(id);
    if (!dropSchedule) {
      requests[id] = PendingReminder(id, payload);
      times[id] = at;
    }
    await onSchedule?.call(id);
  }

  @override
  Future<void> cancel(int id) async {
    _check();
    cancelled.add(id);
    if (!ignoreCancel) {
      requests.remove(id);
      times.remove(id);
    }
  }
}
