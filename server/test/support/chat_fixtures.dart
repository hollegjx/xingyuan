import 'package:xingyuan_core/xingyuan_core.dart';

import 'sharing_fixtures.dart';

ChatCommand chatSend(
  String group, {
  String text = 'SYNTHETIC chat',
  String? photo,
  String? operation,
}) => ChatCommand.fromJson(ChatCommandKind.send, {
  'protocol': companionProtocol,
  'operation_id': operation ?? sharingId(),
  'group_id': group,
  'text': text,
  'photo_id': photo,
});

ChatCommand chatRemove(String group, String message, {String? operation}) =>
    ChatCommand.fromJson(ChatCommandKind.remove, {
      'protocol': companionProtocol,
      'operation_id': operation ?? sharingId(),
      'group_id': group,
      'message_id': message,
    });
