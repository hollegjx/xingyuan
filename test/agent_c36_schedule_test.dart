import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/assistant/data/agent_tool_executor.dart';
import 'package:habit_checkin/features/assistant/domain/agent_planning.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

final _today = CalendarDate.parse('2026-10-30');

AgentScheduleItem _row(
  int? start,
  int? minutes, {
  String title = 'TEST busy',
}) => AgentScheduleItem(
  title: title,
  date: _today,
  startMinute: start,
  minutes: minutes,
);

Map<String, dynamic> _item(int start, {String title = 'TEST plan'}) => {
  'title': title,
  'date': _today.key,
  'start_minute': start,
  'minutes': 30,
};

class _Source implements AgentDataSource {
  _Source(this.rows);
  final List<AgentScheduleItem> rows;
  bool allowed = true;
  int reads = 0;
  @override
  Future<bool> authorize(String tool) async => allowed;
  @override
  Future<List<String>> preferences() async => [];
  @override
  Future<List<AgentScheduleItem>> schedule(
    CalendarDate from,
    CalendarDate to,
  ) async {
    reads++;
    return rows;
  }
}

void main() {
  // C36 owner decision: untimed work is flexible; only timed unknown duration
  // reserves 60 minutes and warns about actual overlaps.
  Map<String, dynamic> slots(
    List<AgentScheduleItem> rows, {
    int start = 360,
    int end = 600,
    int? cap,
  }) => findAgentFreeSlots(
    schedule: rows,
    from: _today,
    to: _today,
    minutes: 30,
    startMinute: start,
    endMinute: end,
    dailyCap: cap,
  );
  AgentPlanValidation validate(
    List<AgentScheduleItem> rows,
    int start, {
    Map<String, int> caps = const {},
  }) => validateAgentPlan(
    items: [_item(start)],
    schedule: rows,
    today: _today,
    dailyCaps: caps,
  );

  for (final minutes in <int?>[null, 30]) {
    test(
      'C36 untimed duration $minutes leaves slots and validation complete',
      () {
        final rows = [_row(null, minutes)];
        final result = slots(rows);
        expect(result['status'], 'ok');
        expect((result['data'] as Map)['unknown_dates'], isEmpty);
        expect((result['data'] as Map)['slots'], hasLength(8));
        expect(validate(rows, 450).issues, isEmpty);
        validateAgentResult(result, 'find_free_slots', _today);
      },
    );
  }

  test('C36 untimed known minutes still count toward both daily caps', () {
    final rows = [_row(null, 60)];
    expect(
      ((slots(rows, cap: 90)['data'] as Map)['slots'] as List),
      hasLength(1),
    );
    expect(
      validate(rows, 450, caps: {_today.key: 89}).issues.single['code'],
      'daily_cap',
    );
    expect(validate(rows, 450, caps: {_today.key: 90}).issues, isEmpty);
  });

  test('C36 missing duration reserves exactly a half-open hour without unknown dates', () {
    final result = slots([_row(420, null)]);
    expect(result['status'], 'ok');
    expect((result['data'] as Map)['unknown_dates'], isEmpty);
    expect(
      ((result['data'] as Map)['slots'] as List).map((s) => s['start_minute']),
      [360, 390, 480, 510, 540, 570],
    );
    expect(validate([_row(420, null)], 390).issues, isEmpty);
    expect(validate([_row(420, null)], 480).issues, isEmpty);
    expect(validate([_row(420, null)], 540).issues, isEmpty);
  });

  for (final start in [391, 420, 450, 479]) {
    test(
      'C36 overlapping candidate $start reports a partial with reference',
      () {
        final result = validate([_row(420, null, title: 'TEST run')], start);
        expect(result.status, 'partial');
        expect(result.hasErrors, isFalse);
        expect(result.issues.single, {
          'index': 0,
          'code': 'unknown_schedule',
          'with': {'title': 'TEST run', 'start_minute': 420},
        });
        agentResultForWire(result.toJson(), 'validate_plan', _today);
        agentResultForWire(result.toJson(), 'submit_plan_draft', _today);
      },
    );
  }

  test(
    'C36 earliest actual overlap is deterministic, ignoring earlier nonoverlap',
    () {
      final rows = [
        _row(440, null, title: 'TEST later'),
        _row(420, null, title: 'TEST first'),
        _row(300, null),
      ];
      final result = validate(rows, 450);
      expect(result.issues.single['with'], {
        'title': 'TEST first',
        'start_minute': 420,
      });
      expect(validate(rows.reversed.toList(), 450).toJson(), result.toJson());
    },
  );

  test('C36 late unknown duration blocks to midnight but not the next day', () {
    final result = slots([_row(1410, null)], start: 1380, end: 1440);
    expect(result['status'], 'ok');
    expect(
      ((result['data'] as Map)['slots'] as List).single['start_minute'],
      1380,
    );
    final next = {..._item(0), 'date': _today.addDays(1).key};
    expect(
      validateAgentPlan(
        items: [next],
        schedule: [_row(1410, null)],
        today: _today,
      ).issues,
      isEmpty,
    );
  });

  test(
    'C36 hard conflict and duplicate keep priority over unknown overlap',
    () {
      for (final pair in [
        ('conflict', _row(450, 30)),
        ('duplicate', _row(null, null, title: 'TEST plan')),
      ]) {
        final result = validate([_row(420, null), pair.$2], 450);
        expect(result.issues.single, {'index': 0, 'code': pair.$1});
      }
    },
  );

  for (final name in ['query_schedule', 'validate_plan', 'submit_plan_draft']) {
    test(
      'C36 $name accepts untimed work through the strict executor',
      () async {
        final source = _Source([_row(null, 30)]);
        final executor = AgentToolExecutor(source: source, today: _today);
        final args = name == 'query_schedule'
            ? <String, dynamic>{'from': _today.key, 'to': _today.key}
            : <String, dynamic>{
                'items': [_item(450)],
                if (name == 'submit_plan_draft') 'note': 'TEST draft',
              };
        final call = AgentToolCall.parse({
          'id': agentCallId('test_c36', 1),
          'type': 'function',
          'function': {'name': name, 'arguments': agentCanonical(args)},
        }, _today);
        expect(
          (await executor.execute(call))['status'],
          name == 'query_schedule' ? 'partial' : 'ok',
        );
        source.allowed = false;
        expect(
          (await executor.execute(call))['original_status'],
          'not_authorized',
        );
        expect(source.reads, 1);
      },
    );
  }

  test(
    'C37 local reference is strict, stripped on wire and legacy-compatible',
    () {
      Map<String, dynamic> result(Map<String, dynamic> issue) =>
          agentResult('partial', {
            'issues': [issue],
          });
      final old = {'index': 0, 'code': 'unknown_schedule'};
      validateAgentResult(result(old), 'validate_plan', _today);
      final current = {
        ...old,
        'with': {'title': 'TEST run', 'start_minute': 420},
      };
      final before = agentCanonical(current);
      expect(
        agentResultForWire(result(current), 'validate_plan', _today),
        result(old),
      );
      expect(agentCanonical(current), before);
      expect(
        () => validateAgentResult(result(current), 'validate_plan', _today),
        throwsFormatException,
      );
      for (final bad in [
        null,
        {'title': '', 'start_minute': 420},
        {'title': 'x' * 61, 'start_minute': 420},
        {'title': 'TEST run', 'start_minute': null},
        {'title': 'TEST run', 'start_minute': 1440},
        {'title': 'TEST run', 'start_minute': -1},
        {'title': 'TEST run', 'start_minute': 420.5},
        {'title': 'TEST run', 'start_minute': 420, 'private': 'TEST hidden'},
      ]) {
        expect(
          () => agentResultForWire(
            result({...old, 'with': bad}),
            'validate_plan',
            _today,
          ),
          throwsFormatException,
        );
      }
      expect(
        () => agentResultForWire(
          agentResult('invalid', {
            'issues': [
              {...current, 'code': 'conflict'},
            ],
          }),
          'validate_plan',
          _today,
        ),
        throwsFormatException,
      );
    },
  );

  test('C37 projection rejects extra local fields and nested duplicates', () {
    final local = validate([_row(420, null)], 450).toJson();
    final issue = (local['data'] as Map)['issues'][0] as Map<String, dynamic>;
    for (final invalid in [
      {...local, 'private': 'TEST hidden'},
      {
        ...local,
        'data': {...local['data'] as Map, 'private': 'TEST hidden'},
      },
      {
        ...local,
        'data': {
          'issues': [
            {...issue, 'private': 'TEST hidden'},
          ],
        },
      },
      {...local, 'status': null},
      {'status': 'duplicate', 'original_status': 'ok', 'result': local},
      {
        'status': 'duplicate',
        'original_status': 'duplicate',
        'result': {
          'status': 'duplicate',
          'original_status': 'partial',
          'result': local,
        },
      },
    ]) {
      expect(
        () => agentResultForWire(invalid, 'validate_plan', _today),
        throwsFormatException,
      );
    }
  });
}
