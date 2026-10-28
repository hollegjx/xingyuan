import 'dart:convert';

import '../../data/local/app_database.dart';

String reminderPayload(StoredReminderOccurrence row) => jsonEncode({
  'source': 'habit-reminder-v1',
  'owner': row.owner,
  'id': row.id,
  'goal': row.goalId,
  'day': row.day,
  'at': row.fireAt,
  'zone': row.zone,
});

bool sameReminderOccurrence(String? actual, String expected, int id) {
  if (actual == null) return false;
  try {
    final candidate = jsonDecode(actual);
    final journal = jsonDecode(expected);
    if (candidate is! Map<String, dynamic> ||
        journal is! Map<String, dynamic>) {
      return false;
    }
    // The clock/zone may differ after an interrupted reschedule. Only these
    // stable ownership fields identify the occurrence whose intent was saved.
    return journal['source'] == 'habit-reminder-v1' &&
        journal['id'] == id &&
        [
          'source',
          'owner',
          'id',
          'goal',
          'day',
        ].every((key) => candidate[key] == journal[key]);
  } on FormatException {
    return false;
  }
}
