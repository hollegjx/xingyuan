import 'package:habit_checkin/data/sync/goal_document.dart';
import 'package:habit_checkin/data/sync/sync_identity.dart';

final accountA = SyncIdentity.account('11111111-1111-4111-8111-111111111111');
final accountB = SyncIdentity.account('22222222-2222-4222-8222-222222222222');
const syntheticGoalUuid = '33333333-3333-4333-8333-333333333333';

Map<String, dynamic> syntheticDocumentJson({String id = syntheticGoalUuid}) => {
  'version': 1,
  'id': id,
  'kind': 0,
  'created_day': '2026-10-09',
  'created_at': 1791522000000000,
  'archived_day': null,
  'archived_at': null,
  'titles': [
    {'effective_day': '2026-10-09', 'title': 'TEST first'},
  ],
  'schedules': [
    {'effective_day': '2026-10-09', 'weekdays': 127, 'planned_day': null},
  ],
  'check_ins': <Map<String, Object?>>[],
};

Map<String, Object?> syntheticCheckIn({
  String day = '2026-10-09',
  bool completed = true,
  int at = 1791522100000000,
  String zone = 'Asia/Shanghai',
}) => {
  'occurrence_key': day,
  'completed': completed,
  'completed_day': day,
  'completed_at': at,
  'zone': zone,
  'title_snapshot': 'TEST first',
  'planned_day': null,
};

GoalDocument syntheticDocument() =>
    GoalDocument.fromJson(syntheticDocumentJson());
