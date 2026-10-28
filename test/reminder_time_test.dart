import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/reminders/domain/reminder_time.dart';
import 'package:habit_checkin/shared/local_date.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

void main() {
  setUpAll(tzdata.initializeTimeZones);

  test('ordinary time preserves the requested local date and minute', () {
    final time = resolveReminderTime(
      day: LocalDate(2026, 10, 9),
      minuteOfDay: 1200,
      location: tz.getLocation('Asia/Shanghai'),
    )!;
    expect(time.hour, 20);
    expect(time.minute, 0);
    expect(
      time.toUtc().isAtSameMomentAs(DateTime.utc(2026, 10, 9, 12)),
      isTrue,
    );
  });

  test(
    'spring gap resolves to first valid minute, not same minute next hour',
    () {
      final time = resolveReminderTime(
        day: LocalDate(2026, 3, 8),
        minuteOfDay: 150,
        location: tz.getLocation('America/New_York'),
      )!;
      expect(time.hour, 3);
      expect(time.minute, 0);
      expect(time.isAtSameMomentAs(DateTime.utc(2026, 3, 8, 7)), isTrue);
    },
  );

  test('fall fold chooses the first occurrence only', () {
    final location = tz.getLocation('America/New_York');
    final day = LocalDate(2026, 11, 1);
    final time = resolveReminderTime(
      day: day,
      minuteOfDay: 90,
      location: location,
    )!;
    expect(time.isAtSameMomentAs(DateTime.utc(2026, 11, 1, 5, 30)), isTrue);
    expect(
      futureReminderTime(
        day: day,
        minuteOfDay: 90,
        location: location,
        now: DateTime.utc(2026, 11, 1, 5, 45),
      ),
      isNull,
      reason: 'Do not use the second fold to send another reminder.',
    );
  });

  test('half-hour daylight gap uses the next valid local minute', () {
    final time = resolveReminderTime(
      day: LocalDate(2026, 10, 4),
      minuteOfDay: 130,
      location: tz.getLocation('Australia/Lord_Howe'),
    )!;
    expect(time.hour, 2);
    expect(time.minute, 30);
  });

  test('a wholly skipped local date does not spill into the next date', () {
    expect(
      resolveReminderTime(
        day: LocalDate(2011, 12, 30),
        minuteOfDay: 1200,
        location: tz.getLocation('Pacific/Apia'),
      ),
      isNull,
    );
  });

  test('elapsed and exact-current times are not sent retroactively', () {
    final location = tz.getLocation('Asia/Shanghai');
    final day = LocalDate(2026, 10, 9);
    for (final now in [
      DateTime.utc(2026, 10, 9, 12),
      DateTime.utc(2026, 10, 9, 12, 1),
    ]) {
      expect(
        futureReminderTime(
          day: day,
          minuteOfDay: 1200,
          location: location,
          now: now,
        ),
        isNull,
      );
    }
    expect(
      futureReminderTime(
        day: day,
        minuteOfDay: 1200,
        location: location,
        now: DateTime.utc(2026, 10, 9, 11, 59),
      ),
      isNotNull,
    );
  });

  test('invalid reminder times are not silently normalized', () {
    for (final minute in [-1, 1440]) {
      expect(
        () => resolveReminderTime(
          day: LocalDate(2026, 10, 9),
          minuteOfDay: minute,
          location: tz.UTC,
        ),
        throwsArgumentError,
      );
    }
  });
}
