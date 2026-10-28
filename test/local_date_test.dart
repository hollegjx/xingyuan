import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/shared/local_date.dart';

void main() {
  test('calendar arithmetic survives month, year and leap boundaries', () {
    expect(LocalDate(2024, 2, 28).addDays(1), LocalDate(2024, 2, 29));
    expect(LocalDate(2024, 2, 29).addDays(1), LocalDate(2024, 3, 1));
    expect(LocalDate(2025, 2, 28).addDays(1), LocalDate(2025, 3, 1));
    expect(LocalDate(2026, 12, 31).addDays(1), LocalDate(2027, 1, 1));
    expect(LocalDate(2026, 1, 1).addDays(-1), LocalDate(2025, 12, 31));
    expect(LocalDate(2026, 10, 9).weekday, DateTime.friday);
  });

  test('date keys round-trip and sort by calendar date', () {
    final day = LocalDate(2026, 10, 9);
    expect(day.key, '2026-10-09');
    expect(LocalDate.parse(day.key), day);
    expect(day.isBefore(day.addDays(1)), isTrue);
    expect(day.isAfter(day.addDays(-1)), isTrue);
  });

  test('invalid dates cannot be silently normalized', () {
    expect(() => LocalDate(2025, 2, 29), throwsArgumentError);
    expect(() => LocalDate(2026, 13, 1), throwsArgumentError);
    expect(() => LocalDate(2026, 10, 0), throwsArgumentError);
    expect(() => LocalDate.parse('2026-2-9'), throwsFormatException);
  });
}
