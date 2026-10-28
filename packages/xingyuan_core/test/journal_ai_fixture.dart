import 'package:xingyuan_core/xingyuan_core.dart';

Map<String, dynamic> polishFixture() => {
  'protocol': assistantProtocol,
  'request_id': 'polish-synthetic-1',
  'text': '我今天读了一章，想明天再读一点。',
};

Map<String, dynamic> diaryFixture() => {
  'protocol': assistantProtocol,
  'request_id': 'diary-synthetic-1',
  'day': '2026-10-23',
  'entries': [
    {'title': '阅读', 'completed': true, 'text': '读完一章'},
    {'title': '跑步', 'completed': false, 'text': ''},
  ],
  'notes': ['我想晚上早点休息。'],
};
