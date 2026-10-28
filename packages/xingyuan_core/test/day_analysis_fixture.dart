import 'package:xingyuan_core/xingyuan_core.dart';

Map<String, dynamic> analysisFixture() => {
  'protocol': assistantProtocol,
  'request_id': 'analysis-synthetic',
  'now': {
    'date': '2026-10-21',
    'time': '21:00',
    'weekday': 3,
    'time_zone': 'Asia/Shanghai',
  },
  'entries': [
    <String, dynamic>{
      'id': 'e1',
      'title': '阅读',
      'planned_time': '20:00',
      'planned_minutes': 20,
      'completed': true,
      'completed_at': '2026-10-21T12:25:00.000Z',
      'text': '读完了一章\n想明天记下一个要点 📚',
    },
  ],
};
