import 'dart:convert';

import 'package:test/test.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

void main() {
  String id(int n) =>
      '00000000-0000-4000-8000-${n.toString().padLeft(12, '0')}';
  Map<String, Object?> base([Map<String, Object?> changes = const {}]) => {
    'protocol': companionProtocol,
    'operation_id': id(1),
    'group_id': id(2),
    ...changes,
  };
  Map<String, Object?> send([Map<String, Object?> changes = const {}]) =>
      base({'text': 'SYNTHETIC chat', 'photo_id': null, ...changes});
  Map<String, Object?> message([Map<String, Object?> changes = const {}]) => {
    'id': id(3),
    'author_id': id(4),
    'sequence': 5,
    'created_at': '2026-10-21T10:00:00.000Z',
    'text': 'SYNTHETIC chat',
    'photo_id': null,
    ...changes,
  };
  SharedPageRequest request({int? before, int? revision, bool reply = false}) =>
      SharedPageRequest.fromJson({
        'protocol': companionProtocol,
        'group_id': id(2),
        'before_sequence': before,
        'revision': revision,
        if (reply) 'record_id': id(3),
      }, replies: reply);
  Map<String, Object?> page([Map<String, Object?> changes = const {}]) => {
    'protocol': companionProtocol,
    'group_id': id(2),
    'revision': 6,
    'messages': [message()],
    'next_before': null,
    ...changes,
  };

  test('commands roundtrip with immutable fields and payload-bound hashes', () {
    final cases = {
      ChatCommandKind.send: send(),
      ChatCommandKind.remove: base({'message_id': id(3)}),
    };
    for (final entry in cases.entries) {
      final command = ChatCommand.fromJson(entry.key, entry.value);
      expect(command.toJson(), entry.value);
      expect(jsonDecode(command.fingerprintInput), {
        'kind': entry.key.name,
        ...entry.value,
      });
      entry.value['group_id'] = id(8);
      expect(command.groupId, id(2));
      final output = command.toJson()..['operation_id'] = id(9);
      expect(output, isNot(command.toJson()));
      expect(command.operationId, id(1));
    }
  });

  test(
    'all commands reject forged identities, private fields and wrong types',
    () {
      for (final kind in ChatCommandKind.values) {
        final body = kind == ChatCommandKind.send
            ? send()
            : base({'message_id': id(3)});
        for (final field in [
          'author_id',
          'owner_id',
          'created_at',
          'sequence',
          'notes',
        ]) {
          expect(
            () => ChatCommand.fromJson(kind, {...body, field: 'private'}),
            throwsFormatException,
          );
        }
        for (final changes in <Map<String, Object?>>[
          {'protocol': 'wrong'},
          {'operation_id': 'private-text'},
          {'group_id': null},
          {'group_id': 1},
          if (kind == ChatCommandKind.send) ...[
            {'text': null},
            {'text': 4},
            {'photo_id': []},
            {'photo_id': 'bad'},
            {'message_id': id(3)},
          ] else ...[
            {'message_id': null},
            {'message_id': 'bad'},
            {'text': 'unexpected'},
          ],
        ]) {
          expect(
            () => ChatCommand.fromJson(kind, {...body, ...changes}),
            throwsFormatException,
          );
        }
      }
    },
  );

  test('blank requires a photo; graphemes and whitespace are preserved', () {
    const emoji = '\u{1f469}\u200d\u{1f4bb}';
    for (final text in ['', ' \n ']) {
      expect(
        () => ChatCommand.fromJson(ChatCommandKind.send, send({'text': text})),
        throwsFormatException,
      );
      expect(
        ChatCommand.fromJson(
          ChatCommandKind.send,
          send({'text': text, 'photo_id': id(6)}),
        ).text,
        text,
      );
    }
    for (final text in [' \nSYNTHETIC $emoji\n ', emoji * 1000]) {
      final command = ChatCommand.fromJson(
        ChatCommandKind.send,
        send({'text': text}),
      );
      expect(command.text, text);
      expect(ChatMessage.fromJson(message({'text': text})).text, text);
    }
    for (final text in [emoji * 1001, 'a${'\u0301' * assistantBodyLimit}']) {
      expect(
        () => ChatCommand.fromJson(ChatCommandKind.send, send({'text': text})),
        throwsFormatException,
      );
      expect(
        () => ChatMessage.fromJson(message({'text': text})),
        throwsFormatException,
      );
    }
  });

  test(
    'receipts bind operation, group, removal target and sequence semantics',
    () {
      for (final kind in ChatCommandKind.values) {
        final command = ChatCommand.fromJson(
          kind,
          kind == ChatCommandKind.send ? send() : base({'message_id': id(3)}),
        );
        final body = base({
          'message_id': id(3),
          'sequence': kind == ChatCommandKind.send ? 5 : 0,
        });
        expect(ChatReceipt.fromJson(body, command: command).toJson(), body);
        for (final changes in <Map<String, Object?>>[
          {'protocol': 'wrong'},
          {'operation_id': id(8)},
          {'group_id': id(8)},
          {'message_id': 'bad'},
          {'sequence': -1},
          {'sequence': 9007199254740992},
          {'sequence': 1.5},
          {'sequence': kind == ChatCommandKind.send ? 0 : 5},
          {'text': 'never in receipt'},
          if (kind == ChatCommandKind.remove) {'message_id': id(8)},
        ]) {
          expect(
            () => ChatReceipt.fromJson({...body, ...changes}, command: command),
            throwsFormatException,
          );
        }
      }
    },
  );

  test('message validates identifiers, time, content and sequence', () {
    expect(ChatMessage.fromJson(message()).toJson(), message());
    expect(
      ChatMessage.fromJson(message({'text': '', 'photo_id': id(6)})).photoId,
      id(6),
    );
    for (final changes in <Map<String, Object?>>[
      {'text': ''},
      {'text': ' \n '},
      {'id': 'bad'},
      {'author_id': null},
      {'sequence': 0},
      {'sequence': 9007199254740992},
      {'created_at': '2026-10-21T10:00:00+00:00'},
      {'created_at': 'invalid'},
      {'photo_id': 'bad'},
      {'private_note': 'never allowed'},
    ]) {
      expect(
        () => ChatMessage.fromJson(message(changes)),
        throwsFormatException,
      );
    }
  });

  test('pages are immutable and validate strict revision-bound pagination', () {
    final body = page({'next_before': 5});
    final req = request(before: 8, revision: 6);
    final parsed = ChatPage.fromJson(body, request: req);
    expect(parsed.toJson(), body);
    (body['messages'] as List).clear();
    expect(parsed.messages, hasLength(1));
    expect(() => parsed.messages.clear(), throwsUnsupportedError);
    for (final changes in <Map<String, Object?>>[
      {'protocol': 'wrong'},
      {'group_id': id(8)},
      {'revision': 7},
      {'next_before': 4},
      {'next_before': 0},
      {'messages': [], 'next_before': 5},
      {
        'messages': [message(), message()],
      },
      {
        'messages': [
          message({'sequence': 8}),
        ],
      },
      {
        'messages': [
          message({'sequence': 7}),
        ],
      },
      {
        'messages': [
          message(),
          message({'id': id(9), 'sequence': 6}),
        ],
      },
      {
        'messages': [
          message(),
          message({'id': id(9)}),
        ],
      },
      {
        'messages': [
          message(),
          message({'sequence': 4}),
        ],
      },
      {
        'messages': List.generate(
          21,
          (i) => message({'id': id(i + 10), 'sequence': 30 - i}),
        ),
      },
      {
        'messages': [
          message({'private_note': 'never'}),
        ],
      },
      {'read_by_partner': true},
    ]) {
      expect(
        () => ChatPage.fromJson(page(changes), request: req),
        throwsFormatException,
      );
    }
    expect(
      () => ChatPage.fromJson(page(), request: request(reply: true)),
      throwsFormatException,
    );
    expect(
      ChatPage.fromJson(
        page({'revision': 0, 'messages': []}),
        request: request(),
      ).messages,
      isEmpty,
    );
    expect(() => request(before: 8), throwsFormatException);
    expect(() => request(revision: 6), throwsFormatException);
  });

  test('page rejects an oversized envelope even below its count limit', () {
    const emoji = '\u{1f469}\u200d\u{1f4bb}';
    final body = page({
      'revision': 20,
      'messages': List.generate(
        10,
        (i) => message({
          'id': id(i + 10),
          'sequence': 20 - i,
          'text': emoji * 1000,
        }),
      ),
    });
    expect(
      utf8.encode(jsonEncode(body)).length,
      greaterThan(assistantBodyLimit),
    );
    expect(
      () => ChatPage.fromJson(body, request: request()),
      throwsFormatException,
    );
  });
}
