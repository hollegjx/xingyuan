import 'package:xingyuan_assistant_eval/agent_eval/fixtures.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

/// Wire-format fake relay responses, not prewritten evaluation trajectories.
Map<String, Object?> scriptedReply(AgentScenario scenario, int round) {
  final day = object(scenario.data['clock'])['day'] as String;
  final range = {'from': day, 'to': day};
  Map<String, Object?> item(int start, [String title = '合成整理']) => {
    'title': title,
    'date': day,
    'start_minute': start,
    'minutes': 30,
  };
  Map<String, Object?> envelope(
    Map<String, Object?> message,
    String finish,
  ) => {
    'choices': [
      {
        'finish_reason': finish,
        'message': {'role': 'assistant', ...message},
      },
    ],
    'usage': {'prompt_tokens': 10, 'completion_tokens': 10, 'total_tokens': 20},
  };
  Map<String, Object?> text(String value, {bool question = false}) => envelope({
    'content': agentCanonical({
      'kind': question ? 'question' : 'text',
      'text': value,
    }),
  }, 'stop');
  Map<String, Object?> tool(String name, Object args) => envelope({
    'tool_calls': [
      {
        'id': 'synthetic_${scenario.id}_$round',
        'type': 'function',
        'function': {'name': name, 'arguments': agentCanonical(args)},
      },
    ],
  }, 'tool_calls');
  Map<String, Object?> submit(List<Map<String, Object?>> items) =>
      tool('submit_plan_draft', {'items': items, 'note': '这是合成待确认建议。'});

  return switch (scenario.id) {
    'S01' => text('番茄工作法将专注和休息分开，可从短时专注开始。'),
    'S02' => text('先选一件事，减少干扰，并适时休息。'),
    'S03' =>
      round == 1
          ? tool('validate_plan', {
              'items': [item(540)],
            })
          : submit([item(540)]),
    'S04' || 'S17' => round == 1 ? submit([item(540)]) : submit([item(600)]),
    'S05' =>
      round == 1
          ? tool('find_free_slots', {
              ...range,
              'minutes': 30,
              'window': {'start_minute': 540, 'end_minute': 720},
              'daily_cap': 120,
            })
          : round == 2
          ? tool('validate_plan', {
              'items': [item(660), item(690, '合成读书')],
            })
          : text('两项都加上会超过每日上限，要减少一项吗？', question: true),
    'S06' ||
    'S07' => round == 1 ? tool('query_schedule', range) : submit([item(540)]),
    'S08' || 'S09' =>
      round == 1 ? tool('query_schedule', range) : text('无法完整读取安排，不能据此判断空闲。'),
    'S10' =>
      round == 1
          ? tool('query_schedule', range)
          : round == 2
          ? submit([item(540)])
          : text('只读取了部分安排，最终检查发现冲突，需要调整时间。', question: true),
    'S20' => tool('query_schedule', range),
    'S11' => text('你想安排什么事情？', question: true),
    'S12' => text('该日期超出支持范围，需要选择范围内日期吗？', question: true),
    'S13' => tool(
      'query_schedule',
      round.isEven ? {'to': day, 'from': day} : range,
    ),
    'S14' => tool('query_schedule', {
      'from': CalendarDate.parse(day).addDays(round - 1).key,
      'to': CalendarDate.parse(day).addDays(round - 1).key,
    }),
    'S15' || 'S16' => text('合成迟到结果，不应进入会话。'),
    'S18' => submit([item(600)]),
    'S19' => submit([item(600), item(660, '合成读书')]),
    _ => throw StateError('Unsupported scripted scenario'),
  };
}
