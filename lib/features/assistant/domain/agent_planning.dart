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
  bool get hasUnknownDuration => startMinute != null && minutes == null;
  int? get occupiedEnd =>
      startMinute == null ? null : startMinute! + (minutes ?? 60);

  bool overlaps(AgentScheduleItem other) =>
      date == other.date &&
      startMinute != null &&
      other.startMinute != null &&
      startMinute! < other.occupiedEnd! &&
      other.startMinute! < occupiedEnd!;
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

/// Local conflict references never enter the deployed Agent wire protocol.
Map<String, dynamic> agentResultForWire(
  Object? value,
  String name,
  CalendarDate today, {
  bool allowDuplicate = true,
}) {
  if (value is Map && value['status'] == 'duplicate') {
    if (!allowDuplicate) throw const FormatException('Nested tool cache');
    final map = agentObject(value, {'status', 'original_status', 'result'});
    return validateAgentResult(
      {
        ...map,
        'result': agentResultForWire(
          map['result'],
          name,
          today,
          allowDuplicate: false,
        ),
      },
      name,
      today,
    );
  }
  final map = agentObject(value, {'status', 'data'});
  if ((name != 'validate_plan' && name != 'submit_plan_draft') ||
      map['data'] == null) {
    return validateAgentResult(map, name, today);
  }
  final data = agentObject(map['data'], {'issues'});
  if (data['issues'] is! List) throw const FormatException('Invalid issues');
  final issues = <Map<String, dynamic>>[];
  for (final item in data['issues'] as List) {
    final hasReference = item is Map && item.containsKey('with');
    final issue = agentObject(item, {
      'index',
      'code',
      if (hasReference) 'with',
    });
    if (hasReference) {
      final reference = agentObject(issue['with'], {'title', 'start_minute'});
      final title = reference['title'];
      final start = reference['start_minute'];
      if (issue['code'] != 'unknown_schedule' ||
          title is! String ||
          title.trim().isEmpty ||
          title.characters.length > 60 ||
          start is! int ||
          start < 0 ||
          start > 1439) {
        throw const FormatException('Invalid local conflict reference');
      }
    }
    issues.add({'index': issue['index'], 'code': issue['code']});
  }
  return validateAgentResult(
    {
      ...map,
      'data': {'issues': issues},
    },
    name,
    today,
  );
}

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
  var truncated = false;
  for (var date = from; !date.isAfter(to); date = date.addDays(1)) {
    final rows = schedule.where((row) => row.date == date).toList()
      ..sort(compareAgentSchedule);
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

    for (final row in rows.where((row) => row.startMinute != null)) {
      final start = row.startMinute!;
      final end = row.occupiedEnd!;
      if (end <= cursor || start >= endMinute) continue;
      gap(start < endMinute ? start : endMinute);
      if (end > cursor) cursor = end;
    }
    gap(endMinute);
  }
  return agentResult(truncated ? 'truncated' : 'ok', {
    'slots': slots,
    'unknown_dates': <String>[],
  });
}

class AgentPlanValidation {
  AgentPlanValidation(
    this.issues, {
    Iterable<AgentScheduleItem> unknownSchedule = const [],
  }) : unknownSchedule = List.unmodifiable(unknownSchedule);
  final List<Map<String, dynamic>> issues;
  final List<AgentScheduleItem> unknownSchedule;
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
  final references = <int, AgentScheduleItem>{};
  final unknownSchedule = <AgentScheduleItem>{};
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
    if (existing.any((row) => !row.hasUnknownDuration && item.overlaps(row)) ||
        peers.any((e) => item.overlaps(e.value))) {
      codes[i] ??= 'conflict';
    }
    final total =
        existing.fold(0, (sum, row) => sum + (row.minutes ?? 0)) +
        parsed.values
            .where((row) => row.date == item.date)
            .fold(0, (sum, row) => sum + row.minutes!);
    if (total > (dailyCaps[item.date.key] ?? 1440)) codes[i] ??= 'daily_cap';
    final unknown =
        existing
            .where((row) => row.hasUnknownDuration && item.overlaps(row))
            .toList()
          ..sort(compareAgentSchedule);
    if (unknown.isNotEmpty) {
      codes[i] ??= 'unknown_schedule';
      references[i] = unknown.first;
      unknownSchedule.addAll(unknown);
    }
  }
  return AgentPlanValidation(
    List.unmodifiable([
      for (var i = 0; i < codes.length; i++)
        if (codes[i] != null)
          {
            'index': i,
            'code': codes[i],
            if (codes[i] == 'unknown_schedule')
              'with': {
                'title': references[i]!.title,
                'start_minute': references[i]!.startMinute,
              },
          },
    ]),
    unknownSchedule: unknownSchedule.toList()..sort(compareAgentSchedule),
  );
}
