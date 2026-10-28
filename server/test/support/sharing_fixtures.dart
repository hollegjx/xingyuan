import 'package:uuid/uuid.dart';
import 'package:xingyuan_core/xingyuan_core.dart';
import 'package:xingyuan_server/src/companion_store.dart';

String sharingId() => const Uuid().v4();

String pairForSharing(
  CompanionStore store, [
  String a = 'qa-a',
  String b = 'qa-b',
]) {
  final invite = store
      .execute(a, PairingCommand.createInvite(sharingId()))
      .state
      .invitation!;
  return store
      .execute(b, PairingCommand.join(sharingId(), invite.code))
      .state
      .group!
      .id;
}

SharingCommand shareCommand(
  SharingCommandKind kind,
  String group,
  Map<String, Object?> fields, {
  String? operation,
}) => SharingCommand.fromJson(kind, {
  'protocol': companionProtocol,
  'group_id': group,
  'operation_id': operation ?? sharingId(),
  ...fields,
});

SharedPageRequest sharePage(
  String group, {
  String? record,
  int? before,
  int? revision,
}) => SharedPageRequest.fromJson({
  'protocol': companionProtocol,
  'group_id': group,
  'before_sequence': before,
  'revision': revision,
  'record_id': ?record,
}, replies: record != null);

SharingCommand publishRecord(
  String group,
  String grant,
  DateTime now, {
  String? operation,
  String? source,
  int revision = 0,
  String text = 'Synthetic shared record',
  DateTime? completedAt,
  bool details = true,
  List<String> photos = const [],
}) => shareCommand(SharingCommandKind.publish, group, {
  'grant_id': grant,
  'source_id': source ?? sharingId(),
  'base_revision': revision,
  'title': 'Synthetic reading',
  'occurred_at': now.toUtc().toIso8601String(),
  'completed_at': completedAt?.toUtc().toIso8601String(),
  'share_details': details,
  'text': text,
  'photo_ids': photos,
}, operation: operation);
