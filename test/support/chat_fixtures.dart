import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/sync/identity_store.dart';
import 'package:habit_checkin/features/companion/data/local_chat_store.dart';
import 'package:habit_checkin/features/companion/data/local_pairing_store.dart';
import 'package:habit_checkin/features/companion/data/local_sharing_store.dart';
import 'package:image/image.dart' as img;
import 'package:xingyuan_core/xingyuan_core.dart';

import 'pairing_fixtures.dart';
import 'sharing_fixtures.dart' show sharingId, sharingInstant;
import 'test_clock.dart';

class ChatFixture {
  ChatFixture(this.directory);
  final Directory directory;
  final clock = TestClock()..setDay(2026, 10, 21);
  late AppDatabase db;
  late LocalGoalRepository goals;
  late LocalPairingStore pairing;
  late LocalSharingStore sharing;
  late LocalChatStore store;

  Future<void> open({String credential = 'a'}) async {
    db = AppDatabase(NativeDatabase(File('${directory.path}/chat.sqlite')));
    final lease = await IdentityStore(db).active();
    goals = LocalGoalRepository(
      db,
      clock,
      owner: lease.identity.owner,
      identityLease: lease,
    );
    pairing = await LocalPairingStore.open(
      goals,
      credentialScope: credential * 64,
    );
    final snapshot = await pairing.snapshot();
    if (snapshot.state == null) {
      await pairing.acceptState(
        testPairingState(paired: true),
        expectedRevision: snapshot.row.stateRevision,
      );
    }
    sharing = await LocalSharingStore.open(pairing);
    store = await LocalChatStore.open(sharing);
  }

  Future<void> reopen() async {
    await db.close();
    await open();
  }
}

Map<String, Object?> chatMessageJson({
  String? id,
  String? author,
  int sequence = 1,
  String text = 'SYNTHETIC chat',
  String? photo,
}) => {
  'id': id ?? sharingId(10),
  'author_id': author ?? testPartnerId,
  'sequence': sequence,
  'created_at': sharingInstant,
  'text': text,
  'photo_id': photo,
};

SharedPageRequest chatPageRequest({int? before, int? revision}) =>
    SharedPageRequest.fromJson({
      'protocol': companionProtocol,
      'group_id': testGroupId,
      'before_sequence': before,
      'revision': revision,
    });

ChatPage chatPage(
  List<Map<String, Object?>> messages, {
  int revision = 1,
  int? next,
  int? before,
}) => ChatPage.fromJson(
  {
    'protocol': companionProtocol,
    'group_id': testGroupId,
    'revision': revision,
    'messages': messages,
    'next_before': next,
  },
  request: chatPageRequest(
    before: before,
    revision: before == null ? null : revision,
  ),
);

ChatReceipt chatReceipt(
  ChatAttempt attempt, {
  int sequence = 1,
  String? message,
}) => ChatReceipt.fromJson({
  'protocol': companionProtocol,
  'group_id': testGroupId,
  'operation_id': attempt.row.operationId,
  'message_id':
      message ??
      (attempt.row.kind == 'remove' ? attempt.row.messageId! : sharingId(20)),
  'sequence': attempt.row.kind == 'remove' ? 0 : sequence,
}, command: attempt.command);

Uint8List chatJpeg() => img.encodeJpg(
  img.Image(width: 2, height: 2)..clear(img.ColorRgb8(70, 160, 120)),
);

ChatPhotoInput chatPhoto(
  LocalChatStore store, {
  Uint8List? bytes,
  int id = 30,
}) {
  final jpeg = bytes ?? chatJpeg();
  return ChatPhotoInput(
    id: sharingId(id),
    owner: store.owner,
    sessionId: store.sessionId,
    width: 2,
    height: 2,
    byteCount: jpeg.length,
    sha256: sha256.convert(jpeg).toString(),
  );
}

CompanionPhotoUpload chatUpload(ChatAttempt attempt, {Uint8List? bytes}) =>
    CompanionPhotoUpload.fromJson({
      'protocol': companionProtocol,
      'group_id': testGroupId,
      'operation_id': attempt.row.uploadOperationId,
      'purpose': 'chat',
      'grant_id': null,
      'jpeg_base64': base64Encode(bytes ?? chatJpeg()),
    });

CompanionPhotoReceipt chatUploadReceipt(
  CompanionPhotoUpload request, {
  String author = testMemberId,
}) => CompanionPhotoReceipt.fromJson({
  'protocol': companionProtocol,
  'operation_id': request.operationId,
  'photo': {
    'id': sharingId(40),
    'group_id': testGroupId,
    'author_id': author,
    'purpose': 'chat',
    'grant_id': null,
    'width': 2,
    'height': 2,
    'byte_count': request.bytes.length,
    'sha256': sha256.convert(request.bytes).toString(),
  },
}, request: request);
