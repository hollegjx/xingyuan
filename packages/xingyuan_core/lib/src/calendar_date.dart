class CalendarDate implements Comparable<CalendarDate> {
  CalendarDate(this.year, this.month, this.day) {
    final normalized = DateTime.utc(year, month, day);
    if (year < 1 ||
        year > 9999 ||
        normalized.year != year ||
        normalized.month != month ||
        normalized.day != day) {
      throw const FormatException('Invalid calendar date');
    }
  }

  factory CalendarDate.parse(String value) {
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
      throw const FormatException('Expected YYYY-MM-DD');
    }
    final parts = value.split('-').map(int.parse).toList();
    return CalendarDate(parts[0], parts[1], parts[2]);
  }

  final int year;
  final int month;
  final int day;
  int get weekday => DateTime.utc(year, month, day).weekday;
  String get key =>
      '${year.toString().padLeft(4, '0')}-'
      '${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';
  CalendarDate addDays(int days) {
    final result = DateTime.utc(year, month, day).add(Duration(days: days));
    return CalendarDate(result.year, result.month, result.day);
  }

  CalendarDate get monday => addDays(1 - weekday);
  List<CalendarDate> get remainingWeek =>
      List.unmodifiable(List.generate(8 - weekday, addDays));
  List<CalendarDate> get nextWeek =>
      List.unmodifiable(List.generate(7, (index) => monday.addDays(7 + index)));
  @override
  int compareTo(CalendarDate other) => key.compareTo(other.key);
  bool isBefore(CalendarDate other) => compareTo(other) < 0;
  bool isAfter(CalendarDate other) => compareTo(other) > 0;
  @override
  bool operator ==(Object other) => other is CalendarDate && key == other.key;
  @override
  int get hashCode => Object.hash(year, month, day);
  @override
  String toString() => key;
}
