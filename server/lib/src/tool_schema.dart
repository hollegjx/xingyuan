Map<String, Object?> _object(Map<String, Object?> properties) => {
  'type': 'object',
  'properties': properties,
  'required': properties.keys.toList(),
  'additionalProperties': false,
};
const _nullableTime = {
  'type': ['string', 'null'],
  'pattern': r'^([01][0-9]|2[0-3]):[0-5][0-9]$',
};
const _date = {'type': 'string', 'pattern': r'^\d{4}-\d{2}-\d{2}$'};
const _minutes = {
  'type': ['integer', 'null'],
  'minimum': 5,
  'maximum': 480,
};
const _title = {'type': 'string', 'minLength': 1, 'maxLength': 60};

Map<String, Object?> get assistantTurnSchema => _object({
  'reply': {'type': 'string', 'minLength': 1},
  'plan': {
    'anyOf': [
      {'type': 'null'},
      _object({
        'tasks': {
          'type': 'array',
          'maxItems': 40,
          'items': _object({
            'title': _title,
            'date': _date,
            'time': _nullableTime,
            'minutes': _minutes,
          }),
        },
        'habits': {
          'type': 'array',
          'maxItems': 5,
          'items': _object({
            'title': _title,
            'start_date': _date,
            'weekdays': {
              'type': 'array',
              'minItems': 1,
              'maxItems': 7,
              'items': {'type': 'integer', 'minimum': 1, 'maximum': 7},
            },
            'time': _nullableTime,
            'minutes': _minutes,
          }),
        },
      }),
    ],
  },
  'memory_ops': {
    'type': 'array',
    'maxItems': 5,
    'items': _object({
      'op': {
        'type': 'string',
        'enum': ['add', 'update', 'delete'],
      },
      'id': {
        'type': ['string', 'null'],
      },
      'category': {
        'type': ['string', 'null'],
        'enum': ['作息', '偏好', '目标与背景', '近期约束', '其他', null],
      },
      'text': {
        'type': ['string', 'null'],
        'minLength': 1,
        'maxLength': 200,
      },
      'expires_on': {
        'type': ['string', 'null'],
        'pattern': r'^\d{4}-\d{2}-\d{2}$',
      },
    }),
  },
});

Map<String, Object?> get assistantSummarySchema => _object({
  'summary': {'type': 'string', 'minLength': 1, 'maxLength': 1500},
});

Map<String, Object?> assistantTurnSchemaFor({required bool diaryProposals}) {
  if (!diaryProposals) return assistantTurnSchema;
  final properties = Map<String, Object?>.from(
    assistantTurnSchema['properties']! as Map,
  );
  properties['diary'] = {
    'anyOf': [
      {'type': 'null'},
      _object({
        'date': {
          'type': ['string', 'null'],
          'pattern': r'^\d{4}-\d{2}-\d{2}$',
        },
        'content': {'type': 'string', 'minLength': 1, 'maxLength': 5000},
      }),
    ],
  };
  return _object(properties);
}

Map<String, Object?> get polishNoteSchema => _object({
  'rewrite': {'type': 'string', 'minLength': 1, 'maxLength': 1000},
  'tips': {
    'type': 'array',
    'minItems': 1,
    'maxItems': 2,
    'items': {'type': 'string', 'minLength': 1, 'maxLength': 100},
  },
});

Map<String, Object?> get generateDiarySchema => _object({
  'status': {
    'type': 'string',
    'enum': ['draft', 'insufficient_material'],
  },
  'draft': {'type': 'string', 'maxLength': 1500},
});

Map<String, Object?> dayAnalysisSchema({bool withNotes = false}) => _object({
  'summary': {'type': 'string', 'minLength': 1, 'maxLength': 180},
  'suggestions': {
    'type': 'array',
    'minItems': withNotes ? 1 : 0,
    'maxItems': 2,
    'items': {'type': 'string', 'minLength': 1, 'maxLength': 100},
  },
});
