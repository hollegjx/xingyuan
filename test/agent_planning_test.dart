import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/assistant/domain/agent_planning.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

final today = CalendarDate.parse('2026-10-28');
AgentScheduleItem busy(
  int? start,
  int? minutes, {
  int day = 0,
  String title = 'TEST busy',
}) => AgentScheduleItem(
  title: title,
  date: today.addDays(day),
  startMinute: start,
  minutes: minutes,
);
Map<String, dynamic> item(
  int start,
  int minutes, {
  int day = 0,
  String title = 'TEST new',
}) => {
  'title': title,
  'date': today.addDays(day).key,
  'start_minute': start,
  'minutes': minutes,
};

void main() {
  Map<String, dynamic> slots(
    List<AgentScheduleItem> rows, {
    int minutes = 30,
    int start = 540,
    int end = 720,
    int days = 0,
    int? cap,
  }) => findAgentFreeSlots(
    schedule: rows,
    from: today,
    to: today.addDays(days),
    minutes: minutes,
    startMinute: start,
    endMinute: end,
    dailyCap: cap,
  );
  List<dynamic> values(Map<String, dynamic> result, String key) =>
      (result['data'] as Map)[key] as List;

  test('half-open adjacency, merged overlapping blocks and sorted gaps', () {
    final result = slots([busy(630, 30), busy(600, 45), busy(540, 30)]);
    expect(result['status'], 'ok');
    expect(values(result, 'slots'), [
      {'date': today.key, 'start_minute': 570, 'minutes': 30},
      {'date': today.key, 'start_minute': 660, 'minutes': 30},
      {'date': today.key, 'start_minute': 690, 'minutes': 30},
    ]);
  });

  test('minutes fit whole slots, neither crosses midnight nor window', () {
    expect(values(slots([], start: 1380, end: 1440, minutes: 45), 'slots'), [
      {'date': today.key, 'start_minute': 1380, 'minutes': 45},
    ]);
    expect(
      values(slots([], start: 1410, end: 1440, minutes: 45), 'slots'),
      isEmpty,
    );
    expect(() => slots([], start: 1430, end: 1450), throwsFormatException);
  });

  test('daily cap counts scheduled duration even outside search window', () {
    final result = slots([busy(300, 60), busy(null, 30)], cap: 120);
    expect(result['status'], 'partial');
    expect(values(result, 'slots'), hasLength(1));
    expect(values(result, 'unknown_dates'), [today.key]);
    expect(values(slots([busy(300, 120)], cap: 120), 'slots'), isEmpty);
  });

  test(
    'missing either field remains unknown; a known next day stays complete',
    () {
      final result = slots([busy(null, 30), busy(620, null)], days: 1);
      expect(result['status'], 'partial');
      expect(values(result, 'unknown_dates'), [today.key]);
      expect(values(result, 'slots').last['date'], today.addDays(1).key);
    },
  );

  test(
    '20 is complete, 21 truncates; unknown dates beyond cap are retained',
    () {
      expect(slots([], start: 0, end: 600)['status'], 'ok');
      final result = slots(
        [busy(null, null, day: 14)],
        start: 0,
        end: 1440,
        days: 14,
      );
      expect(result['status'], 'truncated');
      expect(values(result, 'slots'), hasLength(20));
      expect(values(result, 'unknown_dates'), [today.addDays(14).key]);
    },
  );

  test('slot output is deterministic under every input order', () {
    final rows = [busy(600, 45), busy(540, 30), busy(630, 60)];
    final expected = slots(rows);
    expect(slots(rows.reversed.toList()), expected);
    expect(slots([rows[1], rows[2], rows[0]]), expected);
  });

  AgentPlanValidation validate(
    List<Map<String, dynamic>> items, {
    List<AgentScheduleItem> schedule = const [],
    Map<String, int> caps = const {},
  }) => validateAgentPlan(
    items: items,
    schedule: schedule,
    today: today,
    dailyCaps: caps,
  );

  test('inclusive today through plus14 and exclusive midnight bound', () {
    expect(validate([item(0, 30), item(1410, 30, day: 14)]).status, 'ok');
    expect(validate([item(0, 30, day: -1), item(0, 30, day: 15)]).issues, [
      {'index': 0, 'code': 'date_range'},
      {'index': 1, 'code': 'date_range'},
    ]);
    expect(validate([item(1430, 30)]).issues.single['code'], 'invalid_field');
  });

  test(
    'known schedule and internal conflict mark exact items; touching is legal',
    () {
      expect(
        validate(
          [item(600, 30)],
          schedule: [busy(570, 30), busy(630, 30)],
        ).status,
        'ok',
      );
      expect(
        validate(
          [item(600, 30)],
          schedule: [busy(629, 30)],
        ).issues.single['code'],
        'conflict',
      );
      final result = validate([
        item(600, 45, title: 'TEST A'),
        item(630, 30, title: 'TEST B'),
      ]);
      expect(result.issues, [
        {'index': 0, 'code': 'conflict'},
        {'index': 1, 'code': 'conflict'},
      ]);
    },
  );

  test('duplicates use normalized title and date, not unique time or casing tricks', () {
    expect(
      validate([item(600, 30), item(660, 30, title: ' TEST new ')]).issues,
      [
        {'index': 0, 'code': 'duplicate'},
        {'index': 1, 'code': 'duplicate'},
      ],
    );
    expect(
      validate(
        [item(600, 30)],
        schedule: [busy(500, 30, title: 'TEST new')],
      ).status,
      'invalid',
    );
    expect(validate([item(600, 30), item(600, 30, day: 1)]).status, 'ok');
  });

  test(
    'daily cap applies to sum of candidates and existing scheduled minutes',
    () {
      final result = validate(
        [item(600, 30), item(660, 30, title: 'TEST second')],
        schedule: [busy(300, 60)],
        caps: {today.key: 90},
      );
      expect(result.issues.every((row) => row['code'] == 'daily_cap'), isTrue);
      expect(
        validate(
          [item(600, 30)],
          schedule: [busy(300, 60)],
          caps: {today.key: 90},
        ).status,
        'ok',
      );
    },
  );

  test(
    'partial is per affected item; hard errors cannot be masked by unknowns',
    () {
      final result = validate(
        [item(600, 30), item(600, 30, day: 1)],
        schedule: [busy(null, null)],
      );
      expect(result.status, 'partial');
      expect(result.partialIndexes, {0});
      expect(
        validate(
          [item(600, 30)],
          schedule: [busy(null, null), busy(600, 30)],
        ).status,
        'invalid',
      );
    },
  );

  test(
    'all14 items checked against full schedule after the transport60 cap',
    () {
      final schedule = [
        for (var i = 0; i < 61; i++) busy(null, null, title: 'TEST $i'),
        busy(600, 30),
      ];
      final result = validate([
        for (var i = 0; i < 14; i++) item(600, 30, title: 'TEST candidate$i'),
      ], schedule: schedule);
      expect(result.status, 'invalid');
      expect(result.issues, hasLength(14));
      expect(result.issues.every((row) => row['code'] == 'conflict'), isTrue);
      validateAgentResult(result.toJson(), 'validate_plan', today);
    },
  );

  test('field schema, graphemes and issue indexes are strict', () {
    for (final bad in [
      {...item(0, 30), 'owner': 'foreign'},
      {...item(0, 30), 'title': ''},
      {...item(0, 30), 'date': '2026-02-30'},
      {...item(0, 30), 'start_minute': 1.5},
      {...item(0, 30), 'minutes': null},
      item(-1, 30),
      item(0, 481),
    ]) {
      expect(validate([bad]).issues.single, {
        'index': 0,
        'code': 'invalid_field',
      });
    }
    expect(validate([item(0, 30, title: '👩‍💻' * 60)]).status, 'ok');
    expect(validate([item(0, 30, title: '👩‍💻' * 61)]).status, 'invalid');
    expect(() => validate([]), throwsFormatException);
    expect(
      () => validate(List.generate(15, (_) => item(0, 30))),
      throwsFormatException,
    );
  });
}
