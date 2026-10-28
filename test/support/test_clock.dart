import 'package:habit_checkin/shared/app_clock.dart';
import 'package:habit_checkin/shared/local_date.dart';
import 'package:timezone/timezone.dart' as tz;

class TestClock implements AppClock {
  TestClock()
    : location = tz.getLocation('Asia/Shanghai'),
      instant = DateTime.utc(2026, 10, 9, 4);

  DateTime instant;
  tz.Location location;

  LocalDate get day => read().day;

  void setDay(int year, int month, int day, {int hour = 12, int minute = 0}) {
    instant = tz.TZDateTime(location, year, month, day, hour, minute).toUtc();
  }

  @override
  ClockReading read() => ClockReading(instant: instant, location: location);
}
