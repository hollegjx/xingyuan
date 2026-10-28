import 'dart:convert';

import 'package:characters/characters.dart';

import '../../features/goals/domain/goal.dart';
import '../../features/goals/domain/goal_timing.dart';
import '../../shared/local_date.dart';
import 'sync_identity.dart';

/// The cloud allowlist deliberately excludes owners, reminders and local IDs.
class GoalDocument {
  GoalDocument._({
    required this.id,
    required this.kind,
    required this.createdDay,
    required this.createdAt,
    required this.archivedDay,
    required this.archivedAt,
    required List<TitleVersion> titles,
    required List<ScheduleVersion> schedules,
    required List<Completion> checkIns,
    this.sourceVersion = 2,
  }) : titles = List.unmodifiable(titles),
       schedules = List.unmodifiable(schedules),
       checkIns = List.unmodifiable(checkIns);

  factory GoalDocument.decode(String source) {
    try {
      return GoalDocument.fromJson(jsonDecode(source));
    } on FormatException {
      // jsonDecode errors can contain the source, including personal content.
      throw const FormatException('Invalid goal document');
    }
  }

  factory GoalDocument.fromJson(Object? value) {
    final json = _object(value, {
      'version',
      'id',
      'kind',
      'created_day',
      'created_at',
      'archived_day',
      'archived_at',
      'titles',
      'schedules',
      'check_ins',
    });
    final version = _integer(json['version']);
    if (version != 1 && version != 2) _invalid();
    final id = _string(json['id']);
    if (!SyncIdentity.isUuid(id)) _invalid();
    final kindIndex = _integer(json['kind']);
    if (kindIndex != 0 && kindIndex != 1) _invalid();
    final kind = GoalKind.values[kindIndex];
    final createdDay = _date(json['created_day']);
    final createdAt = _instant(json['created_at']);
    final archivedDay = _optionalDate(json['archived_day']);
    final archivedAt = json['archived_at'] == null
        ? null
        : _instant(json['archived_at']);
    if ((archivedDay == null) != (archivedAt == null)) _invalid();

    final titles = <TitleVersion>[];
    for (final entry in _list(json['titles'])) {
      final row = _object(entry, {'effective_day', 'title'});
      titles.add(
        TitleVersion(_date(row['effective_day']), _title(row['title'])),
      );
    }
    titles.sort((a, b) => a.effectiveDay.compareTo(b.effectiveDay));
    final schedules = <ScheduleVersion>[];
    for (final entry in _list(json['schedules'])) {
      final row = _object(entry, {
        'effective_day',
        'weekdays',
        'planned_day',
        if (version == 2) 'start_minute',
        if (version == 2) 'duration_minutes',
      });
      final weekdays = _integer(row['weekdays']);
      final plannedDay = _optionalDate(row['planned_day']);
      if (kind == GoalKind.habit
          ? weekdays < 1 || weekdays > 127 || plannedDay != null
          : weekdays != 0 || plannedDay == null) {
        _invalid();
      }
      final start = row['start_minute'] == null
          ? null
          : _integer(row['start_minute']);
      final duration = row['duration_minutes'] == null
          ? null
          : _integer(row['duration_minutes']);
      try {
        GoalTiming(startMinute: start, durationMinutes: duration);
      } on FormatException {
        _invalid();
      }
      schedules.add(
        ScheduleVersion(
          effectiveDay: _date(row['effective_day']),
          weekdays: weekdays,
          plannedDay: plannedDay,
          startMinute: start,
          durationMinutes: duration,
        ),
      );
    }
    schedules.sort((a, b) => a.effectiveDay.compareTo(b.effectiveDay));
    if (titles.isEmpty ||
        schedules.isEmpty ||
        !titles.any((row) => row.effectiveDay == createdDay) ||
        !schedules.any((row) => row.effectiveDay == createdDay)) {
      _invalid();
    }
    _requireUnique(titles.map((row) => row.effectiveDay.key));
    _requireUnique(schedules.map((row) => row.effectiveDay.key));

    final checkIns = <Completion>[];
    for (final entry in _list(json['check_ins'])) {
      final row = _object(entry, {
        'occurrence_key',
        'completed',
        'completed_day',
        'completed_at',
        'zone',
        'title_snapshot',
        'planned_day',
      });
      final day = _date(row['completed_day']);
      final occurrence = _string(row['occurrence_key']);
      final plannedDay = _optionalDate(row['planned_day']);
      if (kind == GoalKind.habit
          ? occurrence != day.key || plannedDay != null
          : occurrence != 'once' || plannedDay == null) {
        _invalid();
      }
      final completed = row['completed'];
      if (completed is! bool) _invalid();
      final zone = _string(row['zone']);
      if (zone.isEmpty || zone.length > 255) _invalid();
      checkIns.add(
        Completion(
          occurrenceKey: occurrence,
          completed: completed,
          day: day,
          instant: _instant(row['completed_at']),
          zone: zone,
          title: _title(row['title_snapshot']),
          plannedDay: plannedDay,
        ),
      );
    }
    checkIns.sort((a, b) => a.occurrenceKey.compareTo(b.occurrenceKey));
    _requireUnique(checkIns.map((row) => row.occurrenceKey));
    return GoalDocument._(
      id: id,
      kind: kind,
      createdDay: createdDay,
      createdAt: createdAt,
      archivedDay: archivedDay,
      archivedAt: archivedAt,
      titles: titles,
      schedules: schedules,
      checkIns: checkIns,
      sourceVersion: version,
    );
  }

  final String id;
  final GoalKind kind;
  final LocalDate createdDay;
  final DateTime createdAt;
  final LocalDate? archivedDay;
  final DateTime? archivedAt;
  final List<TitleVersion> titles;
  final List<ScheduleVersion> schedules;
  final List<Completion> checkIns;
  final int sourceVersion;

  Map<String, Object?> toJson({bool preserveWireVersion = false}) => {
    'version': preserveWireVersion ? sourceVersion : 2,
    'id': id,
    'kind': kind.index,
    'created_day': createdDay.key,
    'created_at': createdAt.microsecondsSinceEpoch,
    'archived_day': archivedDay?.key,
    'archived_at': archivedAt?.microsecondsSinceEpoch,
    'titles': [
      for (final row in titles)
        {'effective_day': row.effectiveDay.key, 'title': row.title},
    ],
    'schedules': [
      for (final row in schedules)
        {
          'effective_day': row.effectiveDay.key,
          'weekdays': row.weekdays,
          'planned_day': row.plannedDay?.key,
          if (!preserveWireVersion || sourceVersion == 2)
            'start_minute': row.startMinute,
          if (!preserveWireVersion || sourceVersion == 2)
            'duration_minutes': row.durationMinutes,
        },
    ],
    'check_ins': [
      for (final row in checkIns)
        {
          'occurrence_key': row.occurrenceKey,
          'completed': row.completed,
          'completed_day': row.day.key,
          'completed_at': row.instant.microsecondsSinceEpoch,
          'zone': row.zone,
          'title_snapshot': row.title,
          'planned_day': row.plannedDay?.key,
        },
    ],
  };

  String encode() => jsonEncode(toJson());

  bool hasSameOrigin(GoalDocument other) =>
      id == other.id &&
      kind == other.kind &&
      createdDay == other.createdDay &&
      createdAt == other.createdAt;

  /// Missing history keys are retained, never interpreted as deletions.
  GoalDocument retainingHistoryFrom(GoalDocument previous) {
    if (!hasSameOrigin(previous)) _invalid();
    return GoalDocument._(
      id: id,
      kind: kind,
      createdDay: createdDay,
      createdAt: createdAt,
      archivedDay: archivedDay,
      archivedAt: archivedAt,
      titles: _merge(previous.titles, titles, (row) => row.effectiveDay.key),
      schedules: _merge(previous.schedules, [
        for (final row in schedules)
          if (sourceVersion == 1)
            ScheduleVersion(
              effectiveDay: row.effectiveDay,
              weekdays: row.weekdays,
              plannedDay: row.plannedDay,
              startMinute: previous.schedules
                  .where((old) => old.effectiveDay == row.effectiveDay)
                  .firstOrNull
                  ?.startMinute,
              durationMinutes: previous.schedules
                  .where((old) => old.effectiveDay == row.effectiveDay)
                  .firstOrNull
                  ?.durationMinutes,
            )
          else
            row,
      ], (row) => row.effectiveDay.key),
      checkIns: _merge(previous.checkIns, checkIns, (row) => row.occurrenceKey),
    );
  }

  /// Device clocks cannot turn identical completion results into a conflict.
  bool hasSameResult(GoalDocument other) {
    Map<String, Object?> semantics(GoalDocument document) {
      final value = document.toJson();
      value['check_ins'] = [
        for (final row in document.checkIns)
          if (row.completed)
            {
              'occurrence_key': row.occurrenceKey,
              'completed_day': row.day.key,
              'title_snapshot': row.title,
              'planned_day': row.plannedDay?.key,
            },
      ];
      return value;
    }

    return jsonEncode(semantics(this)) == jsonEncode(semantics(other));
  }

  static List<T> _merge<T>(
    List<T> previous,
    List<T> current,
    String Function(T) key,
  ) {
    final byKey = {for (final row in previous) key(row): row};
    for (final row in current) {
      byKey[key(row)] = row;
    }
    final keys = byKey.keys.toList()..sort();
    return [for (final key in keys) byKey[key]!];
  }
}

Never _invalid() => throw const FormatException('Invalid goal document');

Map<String, dynamic> _object(Object? value, Set<String> keys) {
  if (value is! Map<String, dynamic> ||
      value.length != keys.length ||
      !value.keys.every(keys.contains)) {
    _invalid();
  }
  return value;
}

List<dynamic> _list(Object? value) {
  if (value is! List) _invalid();
  return value;
}

String _string(Object? value) {
  if (value is! String) _invalid();
  return value;
}

int _integer(Object? value) {
  if (value is! int) _invalid();
  return value;
}

String _title(Object? value) {
  final text = _string(value);
  if (text.trim().isEmpty || text.characters.length > 60) _invalid();
  return text;
}

LocalDate _date(Object? value) {
  try {
    return LocalDate.parse(_string(value));
  } on FormatException {
    _invalid();
  } on ArgumentError {
    _invalid();
  }
}

LocalDate? _optionalDate(Object? value) => value == null ? null : _date(value);

DateTime _instant(Object? value) {
  final micros = _integer(value);
  if (micros.abs() > 9007199254740991) _invalid();
  return DateTime.fromMicrosecondsSinceEpoch(micros, isUtc: true);
}

void _requireUnique(Iterable<String> values) {
  if (values.toSet().length != values.length) _invalid();
}
