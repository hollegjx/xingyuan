import 'package:habit_checkin/features/companion/data/companion_service.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

import 'chat_fixtures.dart';
import 'pairing_fixtures.dart';
import 'publication_service.dart';
import 'sharing_fixtures.dart' show sharingId;

class TestChatService extends TestPublicationService
    implements CompanionChatService {
  final chats = <Map<String, Object?>>[];
  final chatCommands = <ChatCommand>[];
  final chatReceipts = <String, ChatReceipt>{};
  int chatRevision = 0;
  int chatReads = 0;
  Future<void>? chatGate;
  Future<void>? chatReadGate;
  CompanionServiceFailure? chatFailure;
  CompanionServiceFailure? chatReadFailure;
  CompanionServiceFailure? chatAfterCommitFailure;

  void incoming(String text, {String? photo}) {
    chats.add(
      chatMessageJson(
        id: sharingId(2000 + ++chatRevision),
        sequence: chatRevision,
        text: text,
        photo: photo,
      ),
    );
  }

  @override
  Future<ChatReceipt> executeChat(
    ChatCommand command, {
    required CompanionAccess access,
    CompanionCancellation? cancellation,
  }) async {
    chatCommands.add(command);
    await chatGate;
    if (chatFailure case final failure?) throw failure;
    final receipt = chatReceipts.putIfAbsent(command.operationId, () {
      String id;
      if (command.kind == ChatCommandKind.send) {
        id = sharingId(2000 + ++chatRevision);
        chats.add(
          chatMessageJson(
            id: id,
            author: testMemberId,
            sequence: chatRevision,
            text: command.text!,
            photo: command.photoId,
          ),
        );
      } else {
        id = command.messageId!;
        chats.removeWhere((r) => r['id'] == id);
        chatRevision++;
      }
      return ChatReceipt.fromJson({
        'protocol': companionProtocol,
        'group_id': command.groupId,
        'operation_id': command.operationId,
        'message_id': id,
        'sequence': command.kind == ChatCommandKind.send ? chatRevision : 0,
      }, command: command);
    });
    if (chatAfterCommitFailure case final failure?) throw failure;
    return receipt;
  }

  @override
  Future<ChatPage> messages(
    SharedPageRequest request, {
    required CompanionAccess access,
    CompanionCancellation? cancellation,
  }) async {
    chatReads++;
    await chatReadGate;
    if (chatReadFailure case final failure?) throw failure;
    final remaining = chats.reversed
        .where(
          (m) =>
              request.beforeSequence == null ||
              (m['sequence']! as int) < request.beforeSequence!,
        )
        .toList();
    final page = remaining.take(companionPageSize).toList();
    return ChatPage.fromJson({
      'protocol': companionProtocol,
      'group_id': request.groupId,
      'revision': chatRevision,
      'messages': page,
      'next_before': remaining.length > page.length
          ? page.last['sequence']
          : null,
    }, request: request);
  }
}
