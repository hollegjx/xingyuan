import 'dart:convert';

// Reconstructed from tool names/statuses, not the missing rejected responses.
const c30Sequences = {
  'R2-S05': ['get_planning_preferences', 'find_free_slots'],
  'R3-S06': ['query_schedule', 'get_planning_preferences'],
  'R3-S10': ['get_planning_preferences', 'find_free_slots'],
};

Map<String, dynamic> c30Reply(String sequence, int turn, String variant) {
  final name = turn < 3
      ? c30Sequences[sequence]![turn - 1]
      : 'submit_plan_draft';
  final args = switch (name) {
    'get_planning_preferences' => <String, Object?>{},
    'query_schedule' => {'from': '2026-10-27', 'to': '2026-10-27'},
    'find_free_slots' => {
      'from': '2026-10-27',
      'to': '2026-10-27',
      'minutes': 30,
      'window': {'start_minute': 540, 'end_minute': 720},
      'daily_cap': null,
    },
    _ => {
      'items': [
        {
          'title': 'Synthetic task',
          'date': '2026-10-27',
          'start_minute': 720,
          'minutes': 30,
        },
      ],
      'note': 'Synthetic draft, not saved. Outside the requested window.',
    },
  };
  final tool =
      turn < 3 || variant == 'mixed_submit' || variant == 'bad_arguments';
  return {
    'choices': [
      {
        'finish_reason': tool ? 'tool_calls' : 'stop',
        'message': {
          'role': 'assistant',
          'content': tool
              ? 'SYNTHETIC_IGNORED_TOOL_COMMENTARY'
              : variant == 'plain_text'
              ? 'PRIVATE_C30_REJECTED_BODY'
              : jsonEncode({
                  'kind': 'question',
                  'text': 'Synthetic clarification.',
                }),
          'provider_extra': 'SYNTHETIC_IGNORED_EXTRA',
          if (tool)
            'tool_calls': [
              {
                'id': 'synthetic_upstream_$turn',
                'type': 'function',
                'function': {
                  'name': name,
                  'arguments': turn == 3 && variant == 'bad_arguments'
                      ? '{PRIVATE_C30_REJECTED_BODY'
                      : jsonEncode(args),
                },
              },
            ],
        },
      },
    ],
    'usage': {
      'prompt_tokens': 100,
      'completion_tokens': 20,
      'total_tokens': 120,
    },
  };
}

Map<String, dynamic> c30Result(String name, String sequence) => switch (name) {
  'get_planning_preferences' => {
    'status': 'ok',
    'data': {'preferences': <Object?>[]},
  },
  'query_schedule' => {
    'status': 'partial',
    'data': {
      'items': [
        {
          'title': 'Synthetic missing duration',
          'date': '2026-10-27',
          'start_minute': 540,
          'minutes': null,
        },
      ],
    },
  },
  'find_free_slots' => {
    'status': 'ok',
    'data': {
      'slots': sequence == 'R3-S10'
          ? <Object?>[]
          : [
              {'date': '2026-10-27', 'start_minute': 600, 'minutes': 30},
            ],
      'unknown_dates': <Object?>[],
    },
  },
  _ => {
    'status': 'ok',
    'data': {'issues': <Object?>[]},
  },
};
