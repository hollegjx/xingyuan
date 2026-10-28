import 'package:test/test.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

void main() {
  String id(int n) =>
      '00000000-0000-4000-8000-${n.toString().padLeft(12, '0')}';
  const instant = '2026-10-21T10:00:00.000Z';
  Map<String, Object?> base([Map<String, Object?> fields = const {}]) => {
    'protocol': companionProtocol,
    'group_id': id(1),
    'operation_id': id(2),
    ...fields,
  };
  Map<String, Object?> publish([Map<String, Object?> changes = const {}]) =>
      base({
        'grant_id': id(3),
        'source_id': id(4),
        'base_revision': 0,
        'title': 'Synthetic reading',
        'occurred_at': instant,
        'completed_at': instant,
        'share_details': false,
        'text': '',
        'photo_ids': <String>[],
        ...changes,
      });
  SharingCommand parse(Map<String, Object?> value) =>
      SharingCommand.fromJson(SharingCommandKind.publish, value);
  Map<String, Object?> record([Map<String, Object?> changes = const {}]) => {
    'id': id(5),
    'author_id': id(6),
    'grant_id': id(3),
    'sequence': 4,
    'revision': 1,
    'title': 'Synthetic reading',
    'occurred_at': instant,
    'completed_at': instant,
    'text': '',
    'photo_ids': <String>[],
    ...changes,
  };
  SharedPageRequest page({int? before, int? revision, bool replies = false}) =>
      SharedPageRequest.fromJson({
        'protocol': companionProtocol,
        'group_id': id(1),
        'before_sequence': before,
        'revision': revision,
        if (replies) 'record_id': id(5),
      }, replies: replies);

  test('all sharing commands roundtrip and reject extra private fields', () {
    final cases = {
      SharingCommandKind.enable: base({'goal_id': id(3)}),
      SharingCommandKind.stop: base({'grant_id': id(3)}),
      SharingCommandKind.publish: publish(),
      SharingCommandKind.remove: base({'record_id': id(5)}),
      SharingCommandKind.reply: base({
        'record_id': id(5),
        'text': 'Synthetic encouragement',
      }),
      SharingCommandKind.deleteReply: base({'reply_id': id(7)}),
    };
    for (final entry in cases.entries) {
      expect(
        SharingCommand.fromJson(entry.key, entry.value).toJson(),
        entry.value,
      );
      for (final field in [
        'member_id',
        'owner_id',
        'planned_at',
        'reminder',
        'notes',
      ]) {
        expect(
          () => SharingCommand.fromJson(entry.key, {
            ...entry.value,
            field: 'private',
          }),
          throwsFormatException,
        );
      }
      expect(
        () => SharingCommand.fromJson(entry.key, {
          ...entry.value,
          'operation_id': 'private-text',
        }),
        throwsFormatException,
      );
    }
  });

  test('record details require opt in, and absence is not progress', () {
    expect(
      () => parse(publish({'text': 'private note'})),
      throwsFormatException,
    );
    expect(
      () => parse(
        publish({
          'photo_ids': [id(8)],
        }),
      ),
      throwsFormatException,
    );
    expect(() => parse(publish({'completed_at': null})), throwsFormatException);
    expect(
      () => parse(
        publish({'completed_at': null, 'share_details': true, 'text': ' \n '}),
      ),
      throwsFormatException,
    );
    expect(
      parse(
        publish({
          'completed_at': null,
          'share_details': true,
          'text': 'Adjusted today',
        }),
      ).completedAt,
      isNull,
    );
    expect(
      parse(
        publish({
          'completed_at': null,
          'share_details': true,
          'photo_ids': [id(8)],
        }),
      ).photoIds,
      [id(8)],
    );
  });

  test(
    'graphemes, newlines and exact limits are retained without trimming',
    () {
      const grapheme = '\u{1f469}\u200d\u{1f4bb}';
      final full = grapheme * 500;
      expect(parse(publish({'share_details': true, 'text': full})).text, full);
      expect(
        () => parse(publish({'share_details': true, 'text': '$full!'})),
        throwsFormatException,
      );
      const text = ' \nSynthetic \u{1f44d}\n ';
      expect(parse(publish({'share_details': true, 'text': text})).text, text);
      final reply = base({'record_id': id(5), 'text': grapheme * 300});
      expect(
        SharingCommand.fromJson(SharingCommandKind.reply, reply).text,
        grapheme * 300,
      );
      for (final invalid in ['', ' \n ', grapheme * 301]) {
        expect(
          () => SharingCommand.fromJson(SharingCommandKind.reply, {
            ...reply,
            'text': invalid,
          }),
          throwsFormatException,
        );
      }
    },
  );

  test('photo IDs, title, completion time and revisions are validated', () {
    expect(
      () => parse(
        publish({
          'share_details': true,
          'photo_ids': [id(8), id(8)],
        }),
      ),
      throwsFormatException,
    );
    expect(
      () => parse(
        publish({
          'share_details': true,
          'photo_ids': [id(8), id(9), id(10), id(11)],
        }),
      ),
      throwsFormatException,
    );
    expect(() => parse(publish({'title': 'x' * 101})), throwsFormatException);
    expect(() => parse(publish({'base_revision': -1})), throwsFormatException);
    expect(
      () => parse(publish({'completed_at': '2026-10-21T11:00:00.000Z'})),
      throwsFormatException,
    );
    expect(
      () => parse(publish({'occurred_at': '2026-10-21T10:00:00+00:00'})),
      throwsFormatException,
    );
    expect(
      () => parse(
        publish({
          'share_details': true,
          'text': 'a${'\u0301' * assistantBodyLimit}',
        }),
      ),
      throwsFormatException,
    );
  });

  test('receipt cannot acknowledge a different operation or group', () {
    final command = parse(publish());
    final receipt = {
      'protocol': companionProtocol,
      'operation_id': id(2),
      'group_id': id(1),
      'resource_id': id(5),
      'revision': 1,
    };
    expect(
      SharingReceipt.fromJson(receipt, command: command).resourceId,
      id(5),
    );
    expect(
      () => SharingReceipt.fromJson({
        ...receipt,
        'operation_id': id(9),
      }, command: command),
      throwsFormatException,
    );
    expect(
      () => SharingReceipt.fromJson({
        ...receipt,
        'group_id': id(9),
      }, command: command),
      throwsFormatException,
    );
  });

  test('receipt resource and revision must match command semantics', () {
    final cases = {
      SharingCommandKind.enable: base({'goal_id': id(3)}),
      SharingCommandKind.stop: base({'grant_id': id(3)}),
      SharingCommandKind.publish: publish({'base_revision': 4}),
      SharingCommandKind.remove: base({'record_id': id(3)}),
      SharingCommandKind.reply: base({'record_id': id(3), 'text': 'SYNTHETIC'}),
      SharingCommandKind.deleteReply: base({'reply_id': id(3)}),
    };
    for (final entry in cases.entries) {
      final command = SharingCommand.fromJson(entry.key, entry.value);
      final version = switch (entry.key) {
        SharingCommandKind.publish => 5,
        SharingCommandKind.reply => 1,
        _ => 0,
      };
      final body = base({'resource_id': id(3), 'revision': version});
      expect(SharingReceipt.fromJson(body, command: command).revision, version);
      expect(
        () => SharingReceipt.fromJson({
          ...body,
          'revision': version + 1,
        }, command: command),
        throwsFormatException,
      );
      if ({
        SharingCommandKind.stop,
        SharingCommandKind.remove,
        SharingCommandKind.deleteReply,
      }.contains(entry.key)) {
        expect(
          () => SharingReceipt.fromJson({
            ...body,
            'resource_id': id(9),
          }, command: command),
          throwsFormatException,
        );
      }
    }
  });

  test(
    'feed rejects duplicate, unsorted, stale and mismatched page results',
    () {
      final request = page(before: 10, revision: 5);
      final body = {
        'protocol': companionProtocol,
        'group_id': id(1),
        'revision': 5,
        'records': [record()],
        'next_before': 4,
      };
      expect(SharedFeedPage.fromJson(body, request: request).toJson(), body);
      for (final changes in <Map<String, Object?>>[
        {'revision': 6},
        {'group_id': id(9)},
        {'next_before': 3},
        {
          'records': [record(), record()],
        },
        {
          'records': [
            record({'sequence': 10}),
          ],
        },
        {
          'records': [
            record(),
            record({'id': id(9), 'sequence': 5}),
          ],
        },
        {
          'records': [
            record({'private_note': 'never allowed'}),
          ],
        },
      ]) {
        expect(
          () =>
              SharedFeedPage.fromJson({...body, ...changes}, request: request),
          throwsFormatException,
        );
      }
      expect(() => page(before: 10), throwsFormatException);
      expect(() => page(revision: 5), throwsFormatException);
    },
  );

  test('reply pagination is bound to the requested record', () {
    final reply = {
      'id': id(7),
      'record_id': id(5),
      'author_id': id(6),
      'sequence': 1,
      'text': 'Synthetic reply',
      'created_at': instant,
    };
    final body = {
      'protocol': companionProtocol,
      'group_id': id(1),
      'record_id': id(5),
      'revision': 1,
      'replies': [reply],
      'next_before': null,
    };
    expect(
      SharedRepliesPage.fromJson(
        body,
        request: page(replies: true),
      ).replies.single.text,
      'Synthetic reply',
    );
    expect(
      () => SharedRepliesPage.fromJson({
        ...body,
        'replies': [
          {...reply, 'record_id': id(9)},
        ],
      }, request: page(replies: true)),
      throwsFormatException,
    );
  });

  test('own grants are paginated and validate unique goals', () {
    final grant = {
      'id': id(3),
      'goal_id': id(4),
      'enabled_at': instant,
      'sequence': 2,
    };
    final body = {
      'protocol': companionProtocol,
      'group_id': id(1),
      'revision': 1,
      'grants': [grant],
      'next_before': null,
    };
    expect(
      SharingGrants.fromJson(body, request: page()).grants.single.goalId,
      id(4),
    );
    expect(
      () => SharingGrants.fromJson({
        ...body,
        'grants': [
          grant,
          {...grant, 'id': id(9), 'sequence': 1},
        ],
      }, request: page()),
      throwsFormatException,
    );
  });
}
