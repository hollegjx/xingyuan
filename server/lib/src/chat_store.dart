part of 'companion_store.dart';

extension ChatStore on CompanionStore {
  int _chatRevision(String group) =>
      _db.select('SELECT revision FROM chat_state WHERE group_id=?', [
            group,
          ]).singleOrNull?['revision']
          as int? ??
      0;

  int _chatChanged(String group) {
    _db.execute(
      '''INSERT INTO chat_state (group_id,revision) VALUES (?,1)
      ON CONFLICT(group_id) DO UPDATE SET revision=revision+1''',
      [group],
    );
    return _chatRevision(group);
  }

  Row _chatMessage(String group, String id, {String? author}) {
    final row = _db.select(
      'SELECT * FROM chat_messages WHERE id=? AND group_id=?',
      [id, group],
    ).singleOrNull;
    if (row == null || (author != null && row['author_id'] != author)) {
      throw const CompanionFailure(403, 'message_unavailable');
    }
    return row;
  }

  ChatMessage _chatValue(Row row) => ChatMessage.fromJson({
    'id': row['id'],
    'author_id': row['author_id'],
    'sequence': row['sequence'],
    'created_at': _iso(row['created_at'] as int),
    'text': row['text'],
    'photo_id': row['photo_id'],
  });

  ChatPage chatMessages(String device, SharedPageRequest request) =>
      _transaction(() {
        _requireGroup(device, request.groupId);
        if (request.recordId != null) {
          throw const FormatException('Chat page scope');
        }
        final revision = _chatRevision(request.groupId);
        if (request.revision != null && request.revision != revision) {
          throw const CompanionFailure(409, 'snapshot_changed');
        }
        final rows = _db.select(
          '''SELECT * FROM chat_messages WHERE group_id=?
      AND (? IS NULL OR sequence<?) ORDER BY sequence DESC LIMIT ?''',
          [
            request.groupId,
            request.beforeSequence,
            request.beforeSequence,
            companionPageSize + 1,
          ],
        );
        return ChatPage.fromJson(
          _boundedPage(
            request,
            revision,
            'messages',
            rows.map((row) => _chatValue(row).toJson()).toList(),
          ),
          request: request,
        );
      });

  ChatReceipt executeChat(String device, ChatCommand command) {
    final result = _transaction(() {
      final member = _requireGroup(device, command.groupId);
      for (final table in [
        'pairing_operations',
        'sharing_operations',
        'media_operations',
      ]) {
        if (_db.select(
          'SELECT 1 FROM $table WHERE member_id=? AND operation_id=?',
          [member, command.operationId],
        ).isNotEmpty) {
          throw const CompanionFailure(409, 'operation_conflict');
        }
      }
      final fingerprint = _hash(command.fingerprintInput);
      final old = _db.select(
        'SELECT * FROM chat_operations WHERE member_id=? AND operation_id=?',
        [member, command.operationId],
      ).singleOrNull;
      if (old != null) {
        if (old['fingerprint'] != fingerprint) {
          throw const CompanionFailure(409, 'operation_conflict');
        }
        if (old['error_code'] != null) {
          return _ChatOutcome.failure(
            old['status'] as int,
            old['error_code'] as String,
          );
        }
        if (command.kind == ChatCommandKind.send) {
          _chatMessage(
            command.groupId,
            old['message_id'] as String,
            author: member,
          );
        }
        return _ChatOutcome.success(
          old['message_id'] as String,
          old['sequence'] as int,
        );
      }
      late _ChatOutcome outcome;
      _db.execute('SAVEPOINT chat_command');
      try {
        final (id, sequence) = switch (command.kind) {
          ChatCommandKind.send => _sendChat(member, command),
          ChatCommandKind.remove => _removeChat(member, command),
        };
        outcome = _ChatOutcome.success(id, sequence);
      } on CompanionFailure catch (failure) {
        _db.execute('ROLLBACK TO chat_command');
        outcome = _ChatOutcome.failure(failure.status, failure.code);
      } finally {
        _db.execute('RELEASE chat_command');
      }
      _db.execute(
        '''INSERT INTO chat_operations
        (member_id,operation_id,group_id,kind,fingerprint,message_id,sequence,status,error_code,created_at)
        VALUES (?,?,?,?,?,?,?,?,?,?)''',
        [
          member,
          command.operationId,
          command.groupId,
          command.kind.name,
          fingerprint,
          outcome.id,
          outcome.sequence,
          outcome.status,
          outcome.error,
          _time,
        ],
      );
      return outcome;
    });
    if (result.error != null) {
      throw CompanionFailure(result.status, result.error!);
    }
    return ChatReceipt.fromJson({
      'protocol': companionProtocol,
      'operation_id': command.operationId,
      'group_id': command.groupId,
      'message_id': result.id,
      'sequence': result.sequence,
    }, command: command);
  }

  (String, int) _sendChat(String member, ChatCommand command) {
    final photoId = command.photoId;
    if (photoId != null) {
      final photo = _db.select('SELECT * FROM companion_photos WHERE id=?', [
        photoId,
      ]).singleOrNull;
      if (photo == null ||
          photo['status'] != 'ready' ||
          photo['purpose'] != 'chat' ||
          photo['group_id'] != command.groupId ||
          photo['author_id'] != member ||
          _db.select('SELECT 1 FROM chat_messages WHERE photo_id=?', [
            photoId,
          ]).isNotEmpty) {
        throw const CompanionFailure(403, 'photo_unavailable');
      }
    }
    final id = _id();
    // Sequence is pair-local and monotonic even if the server clock moves back.
    final sequence = _chatChanged(command.groupId);
    _db.execute(
      '''INSERT INTO chat_messages
      (id,group_id,author_id,sequence,created_at,text,photo_id) VALUES (?,?,?,?,?,?,?)''',
      [id, command.groupId, member, sequence, _time, command.text, photoId],
    );
    final request = SharedPageRequest.fromJson({
      'protocol': companionProtocol,
      'group_id': command.groupId,
      'before_sequence': null,
      'revision': null,
    });
    _boundedPage(request, sequence, 'messages', [
      _chatValue(_chatMessage(command.groupId, id)).toJson(),
    ]);
    return (id, sequence);
  }

  (String, int) _removeChat(String member, ChatCommand command) {
    final row = _chatMessage(
      command.groupId,
      command.messageId!,
      author: member,
    );
    _db.execute('DELETE FROM chat_messages WHERE id=?', [command.messageId]);
    if (row['photo_id'] != null) {
      _db.execute('DELETE FROM companion_photos WHERE id=?', [row['photo_id']]);
    }
    _chatChanged(command.groupId);
    return (command.messageId!, 0);
  }

  void _purgeChat(String group) {
    _db.execute('DELETE FROM chat_messages WHERE group_id=?', [group]);
    _db.execute('DELETE FROM chat_state WHERE group_id=?', [group]);
  }
}

class _ChatOutcome {
  const _ChatOutcome.success(this.id, this.sequence)
    : status = 200,
      error = null;
  const _ChatOutcome.failure(this.status, this.error)
    : id = null,
      sequence = null;
  final String? id;
  final int? sequence;
  final int status;
  final String? error;
}

const _chatSchema = '''
CREATE TABLE chat_state (
  group_id TEXT PRIMARY KEY REFERENCES companion_groups(id),
  revision INTEGER NOT NULL CHECK (revision BETWEEN 0 AND 9007199254740991)
) STRICT;
CREATE TABLE chat_messages (
  id TEXT PRIMARY KEY,
  group_id TEXT NOT NULL REFERENCES companion_groups(id),
  author_id TEXT NOT NULL REFERENCES members(id),
  sequence INTEGER NOT NULL CHECK (sequence BETWEEN 1 AND 9007199254740991),
  created_at INTEGER NOT NULL,
  text TEXT NOT NULL,
  photo_id TEXT UNIQUE REFERENCES companion_photos(id),
  UNIQUE(group_id,sequence)
) STRICT;
CREATE TABLE chat_operations (
  member_id TEXT NOT NULL REFERENCES members(id),
  operation_id TEXT NOT NULL,
  group_id TEXT NOT NULL REFERENCES companion_groups(id),
  kind TEXT NOT NULL CHECK (kind IN ('send','remove')),
  fingerprint TEXT NOT NULL,
  message_id TEXT,
  sequence INTEGER,
  status INTEGER NOT NULL,
  error_code TEXT,
  created_at INTEGER NOT NULL,
  PRIMARY KEY(member_id,operation_id),
  CHECK ((status=200)=(error_code IS NULL)),
  CHECK ((status=200)=(message_id IS NOT NULL)),
  CHECK ((status=200)=(sequence IS NOT NULL))
) STRICT;
''';
