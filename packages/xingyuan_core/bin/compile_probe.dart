import 'dart:convert';

import 'package:xingyuan_core/xingyuan_core.dart';

void main() {
  final request = TurnRequest.fromJson({
    'protocol': assistantProtocol,
    'request_id': 'compile-probe',
    'now': {
      'date': '2026-10-20',
      'time': '21:00',
      'weekday': 2,
      'time_zone': 'Asia/Shanghai',
    },
    'summary': null,
    'messages': [
      {'role': 'user', 'text': '你好'},
    ],
    'settings': {'auto_memory': true},
  });
  final response = TurnResponse.fromJson({
    'protocol': assistantProtocol,
    'request_id': request.requestId,
    'reply': '你好',
    'plan': null,
    'memory_ops': [],
  }, request: request);
  print(
    jsonEncode({'protocol': assistantProtocol, 'valid': response.plan == null}),
  );
}
