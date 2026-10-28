import 'package:characters/characters.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

/// A schedule projection deliberately contains no IDs, notes or completion text.
class AgentScheduleItem {
  const AgentScheduleItem({
    required this.title,
    required this.date,
    required this.startMinute,
    required this.minutes,
  });

  final String title;
  final CalendarDate date;
  final int? startMinute;
  final int? minutes;
  bool get incomplete => startMinute == null || minutes == null;
  Map<String, dynamic> toJson() => {
    'title': title,
    'date': date.key,
    'start_minute': startMinute,
    'minutes': minutes,
  };
}

int compareAgentSchedule(AgentScheduleItem a, AgentScheduleItem b) {
  final day = a.date.key.compareTo(b.date.key);
  if (day != 0) return day;
  final time = (a.startMinute ?? 1440).compareTo(b.startMinute ?? 1440);
  if (time != 0) return time;
  final title = a.title.compareTo(b.title);
  return title != 0 ? title : (a.minutes ?? 0).compareTo(b.minutes ?? 0);
}

Map<String, dynamic> agentResult(String status, Object? data) => {
  'status': status,
  'data': data,
};

Map<String, dynamic> findAgentFreeSlots({
  required List<AgentScheduleItem> schedule,
  required CalendarDate from,
  required CalendarDate to,
  required int minutes,
  int startMinute = 0,
  int endMinute = 1440,
  int? dailyCap,
  Map<String, int> dailyCaps = const {},
}) {
  if (from.isAfter(to) ||
      minutes < 5 ||
      minutes > 480 ||
      startMinute < 0 ||
      startMinute >= endMinute ||
      endMinute > 1440 ||
      (dailyCap != null && (dailyCap < 5 || dailyCap > 1440))) {
    throw const FormatException('Invalid free-slot range');
  }
  final slots = <Map<String, dynamic>>[];
  final unknown = <String>[];
  var truncated = false;
  for (var date = from; !date.isAfter(to); date = date.addDays(1)) {
    final rows = schedule.where((row) => row.date == date).toList()
      ..sort(compareAgentSchedule);
    if (rows.any((row) => row.incomplete)) unknown.add(date.key);
    var used = rows.fold(0, (sum, row) => sum + (row.minutes ?? 0));
    final priorCap = dailyCaps[date.key] ?? 1440;
    final cap = dailyCap != null && dailyCap < priorCap ? dailyCap : priorCap;
    var cursor = startMinute;
    void gap(int end) {
      while (cursor + minutes <= end && used + minutes <= cap) {
        if (slots.length == 20) {
          truncated = true;
          break;
        }
        slots.add({
          'date': date.key,
          'start_minute': cursor,
          'minutes': minutes,
        });
        cursor += minutes;
        used += minutes;
      }
    }

    for (final row in rows.where((row) => !row.incomplete)) {
      final start = row.startMinute!;
      final end = start + row.minutes!;
      if (end <= cursor || start >= endMinute) continue;
      gap(start < endMinute ? start : endMinute);
      if (end > cursor) cursor = end;
    }
    gap(endMinute);
  }
  return agentResult(
    truncated
        ? 'truncated'
        : unknown.isNotEmpty
        ? 'partial'
        : 'ok',
    {'slots': slots, 'unknown_dates': unknown},
  );
}

class AgentPlanValidation {
  AgentPlanValidation(this.issues);
  final List<Map<String, dynamic>> issues;
  bool get hasErrors => issues.any((row) => row['code'] != 'unknown_schedule');
  Set<int> get partialIndexes => {
    for (final row in issues)
      if (row['code'] == 'unknown_schedule') row['index'] as int,
  };
  String get status => hasErrors
      ? 'invalid'
      : issues.isEmpty
      ? 'ok'
      : 'partial';
  Map<String, dynamic> toJson() => agentResult(status, {'issues': issues});
}

/// Checks the full local schedule, never a capped model-facing projection.
/// One highest-priority issue per item bounds the result without hiding validity.
AgentPlanValidation validateAgentPlan({
  required List<Map<String, dynamic>> items,
  required List<AgentScheduleItem> schedule,
  required CalendarDate today,
  Map<String, int> dailyCaps = const {},
}) {
  if (items.isEmpty || items.length > 14) {
    throw const FormatException('Invalid plan item count');
  }
  final codes = List<String?>.filled(items.length, null);
  final parsed = <int, AgentScheduleItem>{};
  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    try {
      agentObject(item, {'title', 'date', 'start_minute', 'minutes'});
      final title = item['title'];
      final start = item['start_minute'];
      final minutes = item['minutes'];
      if (title is! String ||
          title.trim().isEmpty ||
          title.characters.length > 60 ||
          start is! int ||
          minutes is! int ||
          start < 0 ||
          start > 1439 ||
          minutes < 5 ||
          minutes > 480 ||
          start + minutes > 1440 ||
          item['date'] is! String) {
        throw const FormatException();
      }
      final date = CalendarDate.parse(item['date'] as String);
      parsed[i] = AgentScheduleItem(
        title: title.trim(),
        date: date,
        startMinute: start,
        minutes: minutes,
      );
      if (date.isBefore(today) || date.isAfter(today.addDays(14))) {
        codes[i] = 'date_range';
      }
    } on FormatException {
      codes[i] = 'invalid_field';
    }
  }
  bool overlaps(AgentScheduleItem a, AgentScheduleItem b) =>
      !a.incomplete &&
      !b.incomplete &&
      a.startMinute! < b.startMinute! + b.minutes! &&
      b.startMinute! < a.startMinute! + a.minutes!;
  for (final entry in parsed.entries) {
    final i = entry.key;
    final item = entry.value;
    final existing = schedule.where((row) => row.date == item.date);
    final peers = parsed.entries.where(
      (e) => e.key != i && e.value.date == item.date,
    );
    if (existing.any((row) => row.title.trim() == item.title) ||
        peers.any((e) => e.value.title == item.title)) {
      codes[i] ??= 'duplicate';
    }
    if (existing.any((row) => overlaps(item, row)) ||
        peers.any((e) => overlaps(item, e.value))) {
      codes[i] ??= 'conflict';
    }
    final total =
        existing.fold(0, (sum, row) => sum + (row.minutes ?? 0)) +
        parsed.values
            .where((row) => row.date == item.date)
            .fold(0, (sum, row) => sum + row.minutes!);
    if (total > (dailyCaps[item.date.key] ?? 1440)) codes[i] ??= 'daily_cap';
    if (existing.any((row) => row.incomplete)) codes[i] ??= 'unknown_schedule';
  }
  return AgentPlanValidation(
    List.unmodifiable([
      for (var i = 0; i < codes.length; i++)
        if (codes[i] != null) {'index': i, 'code': codes[i]},
    ]),
  );
}
