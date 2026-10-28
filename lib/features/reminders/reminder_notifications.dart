import 'package:timezone/timezone.dart' as tz;

class PendingReminder {
  const PendingReminder(this.id, this.payload);

  final int id;
  final String? payload;
}

abstract interface class ReminderNotifications {
  Future<List<PendingReminder>> pending();
  Future<List<PendingReminder>> delivered();
  Future<void> schedule(int id, tz.TZDateTime at, String payload);
  Future<void> cancel(int id);
}
