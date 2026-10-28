import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:xingyuan_core/xingyuan_core.dart';
import 'package:xingyuan_server/src/companion_store.dart';

import 'support/sharing_fixtures.dart';

void main() {
  late Directory directory;
  late CompanionStore store;
  late DateTime now;
  late String group;
  late String goal;
  late String grant;
  Matcher failure(String code) =>
      isA<CompanionFailure>().having((e) => e.code, 'code', code);
  SharingReceipt apply(String device, SharingCommand command) =>
      store.executeSharing(device, command);
  void reopen() {
    store.close();
    store = CompanionStore.open('${directory.path}/data.db', now: () => now);
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('sharing-store-');
    now = DateTime.utc(2026, 10, 21, 10);
    store = CompanionStore.open('${directory.path}/data.db', now: () => now);
    group = pairForSharing(store);
    goal = sharingId();
    grant = apply(
      'qa-a',
      shareCommand(SharingCommandKind.enable, group, {'goal_id': goal}),
    ).resourceId;
  });
  tearDown(() async {
    store.close();
    await directory.delete(recursive: true);
  });

  test('default feed is empty and grants are visible only to their owner', () {
    expect(store.sharedFeed('qa-b', sharePage(group)).records, isEmpty);
    expect(
      store.sharingGrants('qa-a', sharePage(group)).grants.single.goalId,
      goal,
    );
    expect(store.sharingGrants('qa-b', sharePage(group)).grants, isEmpty);
    expect(
      () => store.sharedFeed('qa-c', sharePage(group)),
      throwsA(failure('pair_unavailable')),
    );
    expect(
      () => store.sharingGrants('qa-c', sharePage(group)),
      throwsA(failure('pair_unavailable')),
    );
    final repeated = apply(
      'qa-a',
      shareCommand(SharingCommandKind.enable, group, {'goal_id': goal}),
    );
    expect(repeated.resourceId, grant);
  });

  test('history and future events never become shared', () {
    for (final instant in [
      now.subtract(const Duration(milliseconds: 1)),
      now.add(const Duration(milliseconds: 1)),
    ]) {
      expect(
        () => apply('qa-a', publishRecord(group, grant, instant)),
        throwsA(failure('history_not_shareable')),
      );
    }
    expect(
      () => apply(
        'qa-a',
        publishRecord(
          group,
          grant,
          now,
          completedAt: now.subtract(const Duration(seconds: 1)),
        ),
      ),
      throwsA(failure('history_not_shareable')),
    );
    expect(store.sharedFeed('qa-b', sharePage(group)).records, isEmpty);
  });

  test('explicit record details, incomplete expression and completion only remain separate', () {
    final detail = apply('qa-a', publishRecord(group, grant, now));
    final completed = apply(
      'qa-a',
      publishRecord(
        group,
        grant,
        now,
        text: '',
        details: false,
        completedAt: now,
      ),
    );
    final feed = store.sharedFeed('qa-b', sharePage(group));
    expect(feed.records.map((r) => r.id), [
      completed.resourceId,
      detail.resourceId,
    ]);
    expect(feed.records.first.text, isEmpty);
    expect(feed.records.last.completedAt, isNull);
    expect(feed.records.last.text, 'Synthetic shared record');
    expect(jsonEncode(feed.toJson()), isNot(contains(goal)));
    expect(
      () => apply('qa-b', publishRecord(group, grant, now)),
      throwsA(failure('sharing_unavailable')),
    );
    expect(
      () => apply(
        'qa-a',
        publishRecord(group, grant, now, photos: [sharingId()]),
      ),
      throwsA(failure('photo_unavailable')),
    );
  });

  test(
    'durable idempotency and revisions prevent duplicates and lost updates',
    () {
      final command = publishRecord(group, grant, now);
      final first = apply('qa-a', command);
      for (var i = 0; i < 5; i++) {
        expect(apply('qa-a', command).toJson(), first.toJson());
      }
      reopen();
      expect(apply('qa-a', command).toJson(), first.toJson());
      expect(store.sharedFeed('qa-b', sharePage(group)).records, hasLength(1));
      expect(
        () => apply(
          'qa-a',
          publishRecord(group, grant, now, source: command.sourceId),
        ),
        throwsA(failure('revision_conflict')),
      );
      expect(
        () => apply(
          'qa-a',
          publishRecord(
            group,
            grant,
            now,
            operation: command.operationId,
            text: 'changed',
          ),
        ),
        throwsA(failure('operation_conflict')),
      );
      final update = publishRecord(
        group,
        grant,
        now,
        source: command.sourceId,
        revision: 1,
        text: 'Updated',
      );
      expect(apply('qa-a', update).revision, 2);
      expect(
        () => apply(
          'qa-a',
          publishRecord(
            group,
            grant,
            now,
            source: command.sourceId,
            revision: 1,
            text: 'stale',
          ),
        ),
        throwsA(failure('revision_conflict')),
      );
      expect(
        store.sharedRecord('qa-b', group, first.resourceId).text,
        'Updated',
      );
      expect(apply('qa-a', command).revision, 1);
      expect(
        store.sharedRecord('qa-b', group, first.resourceId).text,
        'Updated',
      );
    },
  );

  test('operation IDs cannot cross between pairing and sharing', () {
    final command = publishRecord(group, grant, now);
    apply('qa-a', command);
    expect(
      () => store.execute(
        'qa-a',
        PairingCommand.leave(command.operationId, group),
      ),
      throwsA(failure('operation_conflict')),
    );
    final pairing = PairingCommand.createInvite(sharingId());
    expect(
      () => store.execute('qa-a', pairing),
      throwsA(failure('already_paired')),
    );
    expect(
      () => apply(
        'qa-a',
        publishRecord(group, grant, now, operation: pairing.operationId),
      ),
      throwsA(failure('operation_conflict')),
    );
    expect(store.state('qa-a').group!.id, group);
  });

  test('rejected commands remain payload-bound across retries and restart', () {
    final future = publishRecord(
      group,
      grant,
      now.add(const Duration(seconds: 1)),
    );
    expect(
      () => apply('qa-a', future),
      throwsA(failure('history_not_shareable')),
    );
    expect(
      () => apply(
        'qa-a',
        publishRecord(group, grant, now, operation: future.operationId),
      ),
      throwsA(failure('operation_conflict')),
    );
    now = now.add(const Duration(seconds: 2));
    reopen();
    expect(
      () => apply('qa-a', future),
      throwsA(failure('history_not_shareable')),
    );
    expect(store.sharedFeed('qa-b', sharePage(group)).records, isEmpty);
  });

  test(
    'only authors can remove; replies are shared and deletion is durable',
    () {
      final publish = publishRecord(group, grant, now);
      final record = apply('qa-a', publish).resourceId;
      final reply = shareCommand(SharingCommandKind.reply, group, {
        'record_id': record,
        'text': 'Synthetic support',
      });
      final response = apply('qa-b', reply);
      expect(apply('qa-b', reply).resourceId, response.resourceId);
      expect(
        store
            .sharedReplies('qa-a', sharePage(group, record: record))
            .replies
            .single
            .text,
        'Synthetic support',
      );
      expect(
        () => apply(
          'qa-a',
          shareCommand(SharingCommandKind.deleteReply, group, {
            'reply_id': response.resourceId,
          }),
        ),
        throwsA(failure('reply_unavailable')),
      );
      expect(
        () => apply(
          'qa-b',
          shareCommand(SharingCommandKind.remove, group, {'record_id': record}),
        ),
        throwsA(failure('record_unavailable')),
      );
      final delete = shareCommand(SharingCommandKind.deleteReply, group, {
        'reply_id': response.resourceId,
      });
      apply('qa-b', delete);
      reopen();
      expect(apply('qa-b', delete).resourceId, response.resourceId);
      expect(
        store.sharedReplies('qa-a', sharePage(group, record: record)).replies,
        isEmpty,
      );
      expect(() => apply('qa-b', reply), throwsA(failure('reply_unavailable')));
      final remove = shareCommand(SharingCommandKind.remove, group, {
        'record_id': record,
      });
      apply('qa-a', remove);
      expect(apply('qa-a', remove).resourceId, record);
      expect(
        () => store.sharedRecord('qa-a', group, record),
        throwsA(failure('record_unavailable')),
      );
      expect(
        () => apply('qa-a', publish),
        throwsA(failure('record_unavailable')),
      );
    },
  );

  test('stop sharing erases records and replies; old requests cannot resurrect them', () {
    final publish = publishRecord(group, grant, now);
    final record = apply('qa-a', publish).resourceId;
    final reply = shareCommand(SharingCommandKind.reply, group, {
      'record_id': record,
      'text': 'Synthetic support',
    });
    apply('qa-b', reply);
    final stop = shareCommand(SharingCommandKind.stop, group, {
      'grant_id': grant,
    });
    expect(() => apply('qa-b', stop), throwsA(failure('sharing_unavailable')));
    apply('qa-a', stop);
    expect(store.sharedFeed('qa-b', sharePage(group)).records, isEmpty);
    expect(
      () => store.sharedRecord('qa-b', group, record),
      throwsA(failure('record_unavailable')),
    );
    expect(
      () => store.sharedReplies('qa-b', sharePage(group, record: record)),
      throwsA(failure('record_unavailable')),
    );
    expect(
      () => apply('qa-a', publish),
      throwsA(failure('record_unavailable')),
    );
    expect(
      () => apply('qa-a', publishRecord(group, grant, now)),
      throwsA(failure('sharing_unavailable')),
    );
    expect(() => apply('qa-b', reply), throwsA(failure('reply_unavailable')));
    now = now.add(const Duration(seconds: 1));
    final next = apply(
      'qa-a',
      shareCommand(SharingCommandKind.enable, group, {'goal_id': goal}),
    ).resourceId;
    expect(next, isNot(grant));
    apply('qa-a', stop);
    expect(
      store.sharingGrants('qa-a', sharePage(group)).grants.single.id,
      next,
    );
    expect(
      () => apply(
        'qa-a',
        publishRecord(group, next, now.subtract(const Duration(seconds: 1))),
      ),
      throwsA(failure('history_not_shareable')),
    );
    final db = sqlite3.open(
      '${directory.path}/data.db',
      mode: OpenMode.readOnly,
    );
    try {
      expect(db.select('SELECT * FROM shared_records'), isEmpty);
      expect(db.select('SELECT * FROM shared_replies'), isEmpty);
      expect(
        jsonEncode(db.select('SELECT * FROM sharing_operations')),
        isNot(contains('Synthetic')),
      );
    } finally {
      db.close();
    }
  });

  test('third party and another pair cannot read or mutate any content', () {
    final record = apply('qa-a', publishRecord(group, grant, now)).resourceId;
    final other = pairForSharing(store, 'qa-c', 'qa-d');
    expect(
      () => store.sharedRecord('qa-c', group, record),
      throwsA(failure('pair_unavailable')),
    );
    expect(
      () => store.sharedRecord('qa-c', other, record),
      throwsA(failure('record_unavailable')),
    );
    expect(
      () => store.sharedReplies('qa-c', sharePage(other, record: record)),
      throwsA(failure('record_unavailable')),
    );
    expect(
      () => apply(
        'qa-c',
        shareCommand(SharingCommandKind.reply, other, {
          'record_id': record,
          'text': 'forbidden',
        }),
      ),
      throwsA(failure('record_unavailable')),
    );
    expect(
      () => apply(
        'qa-c',
        shareCommand(SharingCommandKind.stop, other, {'grant_id': grant}),
      ),
      throwsA(failure('sharing_unavailable')),
    );
    expect(
      () => apply('qa-c', publishRecord(other, grant, now)),
      throwsA(failure('sharing_unavailable')),
    );
  });

  test('unpair hard deletes content; old leave and commands cannot affect a new pair', () {
    final publish = publishRecord(group, grant, now);
    final record = apply('qa-a', publish).resourceId;
    apply(
      'qa-b',
      shareCommand(SharingCommandKind.reply, group, {
        'record_id': record,
        'text': 'Synthetic reply',
      }),
    );
    final leave = PairingCommand.leave(sharingId(), group);
    store.execute('qa-b', leave);
    reopen();
    for (final device in ['qa-a', 'qa-b']) {
      expect(
        () => store.sharedFeed(device, sharePage(group)),
        throwsA(failure('pair_unavailable')),
      );
      expect(
        () => store.sharedRecord(device, group, record),
        throwsA(failure('pair_unavailable')),
      );
      expect(
        () => apply(device, publish),
        throwsA(failure('pair_unavailable')),
      );
    }
    final next = pairForSharing(store, 'qa-a', 'qa-c');
    store.execute('qa-b', leave);
    expect(store.state('qa-a').group!.id, next);
    expect(store.sharedFeed('qa-c', sharePage(next)).records, isEmpty);
    final db = sqlite3.open(
      '${directory.path}/data.db',
      mode: OpenMode.readOnly,
    );
    try {
      for (final table in [
        'sharing_grants',
        'shared_records',
        'shared_replies',
      ]) {
        expect(db.select('SELECT * FROM $table'), isEmpty);
      }
    } finally {
      db.close();
    }
  });

  test('stable pagination is ordered and rejects a changed snapshot', () {
    for (var i = 0; i < 25; i++) {
      apply('qa-a', publishRecord(group, grant, now, text: 'Synthetic $i'));
    }
    final first = store.sharedFeed('qa-b', sharePage(group));
    expect(first.records, hasLength(companionPageSize));
    final second = store.sharedFeed(
      'qa-b',
      sharePage(group, before: first.nextBefore, revision: first.revision),
    );
    expect(second.records, hasLength(5));
    expect(second.nextBefore, isNull);
    expect(
      [...first.records, ...second.records].map((r) => r.id).toSet(),
      hasLength(25),
    );
    apply('qa-a', publishRecord(group, grant, now));
    expect(
      () => store.sharedFeed(
        'qa-b',
        sharePage(group, before: first.nextBefore, revision: first.revision),
      ),
      throwsA(failure('snapshot_changed')),
    );
  });

  test(
    'large grapheme records and replies remain within the response byte limit',
    () {
      const grapheme = '\u{1f469}\u200d\u{1f4bb}';
      for (var i = 0; i < 21; i++) {
        apply('qa-a', publishRecord(group, grant, now, text: grapheme * 500));
      }
      final feed = store.sharedFeed('qa-b', sharePage(group));
      expect(feed.records.length, lessThan(companionPageSize));
      expect(feed.records, isNotEmpty);
      expect(
        utf8.encode(jsonEncode(feed.toJson())).length,
        lessThanOrEqualTo(assistantBodyLimit),
      );
      final next = store.sharedFeed(
        'qa-b',
        sharePage(group, before: feed.nextBefore, revision: feed.revision),
      );
      expect(next.records, isNotEmpty);
      expect(next.records.first.sequence, lessThan(feed.records.last.sequence));
      final record = feed.records.first.id;
      for (var i = 0; i < 21; i++) {
        apply(
          'qa-b',
          shareCommand(SharingCommandKind.reply, group, {
            'record_id': record,
            'text': grapheme * 300,
          }),
        );
      }
      final replies = store.sharedReplies(
        'qa-a',
        sharePage(group, record: record),
      );
      expect(replies.replies.length, lessThan(companionPageSize));
      expect(replies.nextBefore, isNotNull);
      expect(
        utf8.encode(jsonEncode(replies.toJson())).length,
        lessThanOrEqualTo(assistantBodyLimit),
      );
      final remainder = store.sharedReplies(
        'qa-a',
        sharePage(
          group,
          record: record,
          before: replies.nextBefore,
          revision: replies.revision,
        ),
      );
      expect(
        [...replies.replies, ...remainder.replies].map((r) => r.id).toSet(),
        hasLength(21),
      );
    },
  );

  test('own grants paginate without exposing the partner grants', () {
    for (var i = 0; i < 24; i++) {
      apply(
        'qa-a',
        shareCommand(SharingCommandKind.enable, group, {
          'goal_id': sharingId(),
        }),
      );
    }
    apply(
      'qa-b',
      shareCommand(SharingCommandKind.enable, group, {'goal_id': sharingId()}),
    );
    final first = store.sharingGrants('qa-a', sharePage(group));
    expect(first.grants, hasLength(20));
    final second = store.sharingGrants(
      'qa-a',
      sharePage(group, before: first.nextBefore, revision: first.revision),
    );
    expect(second.grants, hasLength(5));
    expect(second.nextBefore, isNull);
    expect(store.sharingGrants('qa-b', sharePage(group)).grants, hasLength(1));
  });

  test(
    'online backup restores sharing records, replies and operation receipts',
    () async {
      final command = publishRecord(group, grant, now);
      final record = apply('qa-a', command).resourceId;
      apply(
        'qa-b',
        shareCommand(SharingCommandKind.reply, group, {
          'record_id': record,
          'text': 'Synthetic reply',
        }),
      );
      await store.backupTo('${directory.path}/restored.db');
      final restored = CompanionStore.open(
        '${directory.path}/restored.db',
        now: () => now,
      );
      try {
        expect(
          restored.sharedFeed('qa-b', sharePage(group)).toJson(),
          store.sharedFeed('qa-b', sharePage(group)).toJson(),
        );
        expect(
          restored
              .sharedReplies('qa-a', sharePage(group, record: record))
              .replies
              .single
              .text,
          'Synthetic reply',
        );
        expect(restored.executeSharing('qa-a', command).resourceId, record);
      } finally {
        restored.close();
      }
    },
  );
}
