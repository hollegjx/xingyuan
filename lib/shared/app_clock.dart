import 'package:timezone/timezone.dart' as tz;

import 'local_date.dart';

class ClockReading {
  ClockReading({required DateTime instant, required tz.Location location})
    : instant = DateTime.fromMicrosecondsSinceEpoch(
        instant.microsecondsSinceEpoch,
        isUtc: true,
      ),
      localTime = tz.TZDateTime.from(instant, location);

  final DateTime instant;
  final tz.TZDateTime localTime;

  LocalDate get day => LocalDate.fromDateTime(localTime);
  String get zone => localTime.location.name;
}

abstract interface class AppClock {
  ClockReading read();
}

class ZonedClock implements AppClock {
  ZonedClock(this.location, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final tz.Location Function() location;
  final DateTime Function() _now;

  @override
  ClockReading read() => ClockReading(instant: _now(), location: location());
}
