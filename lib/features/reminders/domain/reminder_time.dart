import 'package:timezone/timezone.dart' as tz;

import '../../../shared/local_date.dart';

/// Resolve a wall-clock minute without normalizing a DST gap to a later offset.
tz.TZDateTime? resolveReminderTime({
  required LocalDate day,
  required int minuteOfDay,
  required tz.Location location,
}) {
  if (minuteOfDay < 0 || minuteOfDay >= 1440) {
    throw ArgumentError.value(minuteOfDay, 'minuteOfDay');
  }
  final offsets = location.zones.map((zone) => zone.offset).toSet();
  for (var minute = minuteOfDay; minute < 1440; minute++) {
    final wallTime = DateTime.utc(
      day.year,
      day.month,
      day.day,
      minute ~/ 60,
      minute % 60,
    );
    tz.TZDateTime? earliest;
    // Round-trip possible offsets. Both folds may match; retain the first.
    for (final offset in offsets) {
      final candidate = tz.TZDateTime.from(wallTime.subtract(offset), location);
      if (LocalDate.fromDateTime(candidate) == day &&
          candidate.hour == minute ~/ 60 &&
          candidate.minute == minute % 60 &&
          (earliest == null || candidate.isBefore(earliest))) {
        earliest = candidate;
      }
    }
    if (earliest != null) return earliest;
  }
  // A skipped calendar date must not produce a next-day notification.
  return null;
}

tz.TZDateTime? futureReminderTime({
  required LocalDate day,
  required int minuteOfDay,
  required tz.Location location,
  required DateTime now,
}) {
  final candidate = resolveReminderTime(
    day: day,
    minuteOfDay: minuteOfDay,
    location: location,
  );
  return candidate != null && candidate.isAfter(now) ? candidate : null;
}
