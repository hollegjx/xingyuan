part of 'protocol.dart';

enum ChatCommandKind { send, remove }

const chatCommandRoutes = {
  '/v1/companion/chat/send': ChatCommandKind.send,
  '/v1/companion/chat/remove': ChatCommandKind.remove,
};
const chatMessagesRoute = '/v1/companion/chat/list';

class ChatCommand {
  ChatCommand._(
    this.kind,
    this.operationId,
    this.groupId,
    this.text,
    this.photoId,
    this.messageId,
  );

  factory ChatCommand.fromJson(ChatCommandKind kind, Object? value) {
    _bodySize(value);
    final sending = kind == ChatCommandKind.send;
    final map = _object(value, {
      'protocol',
      'operation_id',
      'group_id',
      if (sending) ...{'text', 'photo_id'} else 'message_id',
    });
    _checkCompanionProtocol(map['protocol']);
    final text = sending ? _text(map['text'], 1000, empty: true) : null;
    final photo = sending && map['photo_id'] != null
        ? _companionId(map['photo_id'])
        : null;
    if (sending && text!.trim().isEmpty && photo == null) {
      _invalid('empty chat');
    }
    return ChatCommand._(
      kind,
      _companionId(map['operation_id']),
      _companionId(map['group_id']),
      text,
      photo,
      sending ? null : _companionId(map['message_id']),
    );
  }

  final ChatCommandKind kind;
  final String operationId;
  final String groupId;
  final String? text;
  final String? photoId;
  final String? messageId;
  String get fingerprintInput => jsonEncode({'kind': kind.name, ...toJson()});
  Map<String, Object?> toJson() => {
    'protocol': companionProtocol,
    'operation_id': operationId,
    'group_id': groupId,
    if (kind == ChatCommandKind.send) ...{
      'text': text,
      'photo_id': photoId,
    } else
      'message_id': messageId,
  };
}

class ChatReceipt {
  ChatReceipt._(this.operationId, this.groupId, this.messageId, this.sequence);
  factory ChatReceipt.fromJson(Object? value, {required ChatCommand command}) {
    final map = _object(value, {
      'protocol',
      'operation_id',
      'group_id',
      'message_id',
      'sequence',
    });
    _checkCompanionProtocol(map['protocol']);
    final message = _companionId(map['message_id']);
    final sequence = _integer(map['sequence'], 0, _maxSequence);
    if (_companionId(map['operation_id']) != command.operationId ||
        _companionId(map['group_id']) != command.groupId ||
        (command.kind == ChatCommandKind.send
            ? sequence == 0
            : sequence != 0 || message != command.messageId)) {
      _invalid('chat receipt');
    }
    return ChatReceipt._(
      command.operationId,
      command.groupId,
      message,
      sequence,
    );
  }
  final String operationId;
  final String groupId;
  final String messageId;
  final int sequence;
  Map<String, Object?> toJson() => {
    'protocol': companionProtocol,
    'operation_id': operationId,
    'group_id': groupId,
    'message_id': messageId,
    'sequence': sequence,
  };
}

class ChatMessage {
  ChatMessage._(
    this.id,
    this.authorId,
    this.sequence,
    this.createdAt,
    this.text,
    this.photoId,
  );
  factory ChatMessage.fromJson(Object? value) {
    _bodySize(value);
    final map = _object(value, {
      'id',
      'author_id',
      'sequence',
      'created_at',
      'text',
      'photo_id',
    });
    final text = _text(map['text'], 1000, empty: true);
    final photo = map['photo_id'] == null
        ? null
        : _companionId(map['photo_id']);
    if (text.trim().isEmpty && photo == null) _invalid('empty chat');
    return ChatMessage._(
      _companionId(map['id']),
      _companionId(map['author_id']),
      _integer(map['sequence'], 1, _maxSequence),
      _companionInstant(map['created_at']),
      text,
      photo,
    );
  }
  final String id;
  final String authorId;
  final int sequence;
  final DateTime createdAt;
  final String text;
  final String? photoId;
  Map<String, Object?> toJson() => {
    'id': id,
    'author_id': authorId,
    'sequence': sequence,
    'created_at': createdAt.toIso8601String(),
    'text': text,
    'photo_id': photoId,
  };
}

class ChatPage {
  ChatPage._(this.groupId, this.revision, this.messages, this.nextBefore);
  factory ChatPage.fromJson(
    Object? value, {
    required SharedPageRequest request,
  }) {
    _bodySize(value);
    final map = _object(value, {
      'protocol',
      'group_id',
      'revision',
      'messages',
      'next_before',
    });
    _checkCompanionProtocol(map['protocol']);
    if (request.recordId != null ||
        _companionId(map['group_id']) != request.groupId) {
      _invalid('chat group');
    }
    final revision = _integer(map['revision'], 0, _maxSequence);
    final messages = _list(
      map['messages'],
      companionPageSize,
    ).map(ChatMessage.fromJson).toList();
    if (messages.any((message) => message.sequence > revision)) {
      _invalid('chat sequence');
    }
    final next = map['next_before'] == null
        ? null
        : _integer(map['next_before'], 1, _maxSequence);
    _checkPage(
      request,
      revision,
      messages.map((m) => m.id).toList(),
      messages.map((m) => m.sequence).toList(),
      next,
    );
    return ChatPage._(
      request.groupId,
      revision,
      List.unmodifiable(messages),
      next,
    );
  }
  final String groupId;
  final int revision;
  final List<ChatMessage> messages;
  final int? nextBefore;
  Map<String, Object?> toJson() => {
    'protocol': companionProtocol,
    'group_id': groupId,
    'revision': revision,
    'messages': messages.map((m) => m.toJson()).toList(),
    'next_before': nextBefore,
  };
}
