import 'dart:convert';
import 'dart:math';

import 'package:xingyuan_core/xingyuan_core.dart';

Map<String, Object?> diaryPayloadOfSize(
  int byteCount, {
  String unit = 'a',
  List<Map<String, Object?>> entries = const [],
}) {
  final notes = <String>[unit * 1000];
  final body = <String, Object?>{
    'protocol': assistantProtocol,
    'request_id': '11111111-1111-4111-8111-111111111111',
    'day': '2026-10-23',
    'entries': entries,
    'notes': notes,
  };
  var remaining = byteCount - utf8.encode(jsonEncode(body)).length;
  if (remaining < 0) throw ArgumentError('Fixture exceeds requested size');
  while (remaining > 0) {
    // Every further JSON string needs a comma and two quotes.
    var length = min(1000, remaining - 3);
    final tail = remaining - 3 - length;
    if (tail > 0 && tail < 3) length -= 3 - tail;
    if (length < 0) throw ArgumentError('Fixture cannot fill byte budget');
    notes.add('a' * length);
    remaining -= length + 3;
  }
  return body;
}
