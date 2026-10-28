import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/sync/identity_store.dart';
import 'package:habit_checkin/data/sync/sync_identity.dart';
import 'package:habit_checkin/features/companion/data/companion_service.dart';
import 'package:habit_checkin/features/companion/data/local_pairing_store.dart';
import 'package:habit_checkin/features/companion/data/local_sharing_store.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:uuid/uuid.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

import 'support/test_clock.dart';

void main() {
  String id(int n) =>
      '00000000-0000-4000-8000-${n.toString().padLeft(12, '0')}';
  const instant = '2026-10-21T10:00:00.000Z';
  late Directory directory;
  late AppDatabase db;
  late LocalGoalRepository goals;
  late LocalPairingStore pairing;
  late LocalSharingStore store;
  late String goalId;
  PairingState pair({bool active = true, String? group}) =>
      PairingState.fromJson({
        'protocol': companionProtocol,
        'member_id': id(1),
        'invitation': null,
        'group': active
            ? {'id': group ?? id(3), 'partner_id': id(2), 'paired_at': instant}
            : null,
      });
  SharedPageRequest page({int? before, int? revision, String? record}) =>
      SharedPageRequest.fromJson({
        'protocol': companionProtocol,
        'group_id': id(3),
        'before_sequence': before,
        'revision': revision,
        'record_id': ?record,
      }, replies: record != null);
  Map<String, Object?> grant() => {
    'id': id(4),
    'goal_id': goalId,
    'sequence': 1,
    'enabled_at': instant,
  };
  Map<String, Object?> record({
    int version = 1,
    String text = 'SYNTHETIC shared',
    String? author,
  }) => {
    'id': id(5),
    'author_id': author ?? id(1),
    'grant_id': id(4),
    'sequence': 1,
    'revision': version,
    'title': 'SYNTHETIC title',
    'occurred_at': instant,
    'completed_at': null,
    'text': text,
    'photo_ids': <String>[],
  };
  SharingGrants grants(int revision) => SharingGrants.fromJson({
    'protocol': companionProtocol,
    'group_id': id(3),
    'revision': revision,
    'grants': [grant()],
    'next_before': null,
  }, request: page());
  SharedFeedPage feed(
    int revision, {
    List<Map<String, Object?>>? records,
    int? next,
  }) => SharedFeedPage.fromJson({
    'protocol': companionProtocol,
    'group_id': id(3),
    'revision': revision,
    'records': records ?? [record()],
    'next_before': next,
  }, request: page());
  SharedRepliesPage replies(int revision) => SharedRepliesPage.fromJson({
    'protocol': companionProtocol,
    'group_id': id(3),
    'record_id': id(5),
    'revision': revision,
    'next_before': null,
    'replies': [
      {
        'id': id(6),
        'record_id': id(5),
        'author_id': id(2),
        'sequence': 1,
        'text': 'SYNTHETIC reply',
        'created_at': instant,
      },
    ],
  }, request: page(record: id(5)));
  SharingCommand command(
    SharingCommandKind kind,
    Map<String, Object?> fields, {
    String? operation,
  }) => SharingCommand.fromJson(kind, {
    'protocol': companionProtocol,
    'group_id': id(3),
    'operation_id': operation ?? const Uuid().v4(),
    ...fields,
  });
  SharingCommand reply(String text, {String? operation}) => command(
    SharingCommandKind.reply,
    {'record_id': id(5), 'text': text},
    operation: operation,
  );
  SharingReceipt receipt(SharingAttempt attempt) => SharingReceipt.fromJson({
    'protocol': companionProtocol,
    'operation_id': attempt.command.operationId,
    'group_id': id(3),
    'resource_id': attempt.command.kind == SharingCommandKind.stop
        ? id(4)
        : id(7),
    'revision': attempt.command.kind == SharingCommandKind.stop ? 0 : 1,
  }, command: attempt.command);
  Future<void> bind() async {
    final lease = await IdentityStore(db).active();
    goals = LocalGoalRepository(
      db,
      TestClock()..setDay(2026, 10, 21),
      owner: lease.identity.owner,
      identityLease: lease,
    );
    pairing = await LocalPairingStore.open(goals, credentialScope: 'a' * 64);
  }

  Future<void> seed({int revision = 1}) async {
    final before = (await store.snapshot()).state.cacheRevision;
    expect(
      await store.acceptSnapshot(
        grantPages: [grants(revision)],
        feedPages: [feed(revision)],
        expectedRevision: before,
      ),
      true,
    );
  }

  Matcher failed(String code) =>
      isA<CompanionServiceFailure>().having((e) => e.code, 'code', code);
  setUpAll(tzdata.initializeTimeZones);
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('sharing-local-');
    db = AppDatabase(NativeDatabase(File('${directory.path}/data.sqlite')));
    await bind();
    await goals.create(
      const GoalDraft(title: 'SYNTHETIC personal', kind: GoalKind.habit),
    );
    goalId = (await db.select(db.goals).get()).single.globalId;
    await pairing.acceptState(pair(), expectedRevision: 0);
    store = await LocalSharingStore.open(pairing);
    await seed();
  });
  tearDown(() async {
    await db.close();
    await directory.delete(recursive: true);
  });

  test(
    'cache drafts and frozen interrupted commands survive file reopen',
    () async {
      await store.writeDraft(
        id(5),
        'SYNTHETIC\n\u{1f44d}',
        expectedRevision: 0,
      );
      final queued = await store.enqueue(reply('SYNTHETIC\n\u{1f44d}'));
      final first = await store.begin(queued.command.operationId);
      await db.close();
      db = AppDatabase(NativeDatabase(File('${directory.path}/data.sqlite')));
      await bind();
      store = await LocalSharingStore.open(pairing);
      await store.recoverInterrupted();
      expect((await store.draft(id(5)))!.content, 'SYNTHETIC\n\u{1f44d}');
      final snapshot = await store.snapshot();
      expect(snapshot.records.single.text, 'SYNTHETIC shared');
      expect(snapshot.commands.single.row.status, 'uncertain');
      expect(snapshot.commands.single.command.toJson(), first.command.toJson());
      final retry = await store.begin(first.command.operationId);
      expect(retry.row.attempts, 2);
      expect(await store.finish(first, receipt(first)), false);
      expect(await store.finish(retry, receipt(retry)), true);
      expect((await store.draft(id(5)))!.content, isEmpty);
      expect((await store.snapshot()).commands, isEmpty);
      expect((await store.enqueue(retry.command)).row.status, 'succeeded');
    },
  );

  test(
    'five same-ID enqueues produce one command and reject changed payload',
    () async {
      final request = reply('SYNTHETIC one');
      final queued = await Future.wait(
        List.generate(5, (_) => store.enqueue(request)),
      );
      expect(queued.map((q) => q.row.sequence).toSet(), hasLength(1));
      await expectLater(
        store.enqueue(reply('changed', operation: request.operationId)),
        throwsA(failed('operation_conflict')),
      );
      await store.begin(request.operationId);
      await expectLater(
        store.begin(request.operationId),
        throwsA(failed('operation_pending')),
      );
      expect((await store.snapshot()).commands, hasLength(1));
    },
  );

  test('reply acknowledgement never erases a newer draft and stale CAS is rejected', () async {
    await store.writeDraft(id(5), 'SYNTHETIC first', expectedRevision: 0);
    final queued = await store.enqueue(reply('SYNTHETIC first'));
    final attempt = await store.begin(queued.command.operationId);
    await store.writeDraft(id(5), 'SYNTHETIC second', expectedRevision: 1);
    await expectLater(
      store.writeDraft(id(5), 'stale', expectedRevision: 1),
      throwsA(failed('draft_conflict')),
    );
    expect(await store.finish(attempt, receipt(attempt)), true);
    expect((await store.draft(id(5)))!.content, 'SYNTHETIC second');
    await expectLater(
      store.writeDraft(id(5), 'x' * 10001, expectedRevision: 2),
      throwsA(failed('request_too_large')),
    );
  });

  test(
    'incomplete mismatched and foreign-author snapshots leave cache untouched',
    () async {
      final before = (await store.snapshot()).state.cacheRevision;
      for (final pages in [
        [feed(2, next: 1)],
        [feed(3)],
        [
          feed(2, records: [record(author: id(99))]),
        ],
      ]) {
        await expectLater(
          store.acceptSnapshot(
            grantPages: [grants(2)],
            feedPages: pages,
            expectedRevision: before,
          ),
          throwsA(anything),
        );
        expect((await store.snapshot()).state.cacheRevision, before);
        expect(
          (await store.snapshot()).records.single.text,
          'SYNTHETIC shared',
        );
      }
    },
  );

  test(
    'record identity and revision cannot regress in a newer global snapshot',
    () async {
      var revision = (await store.snapshot()).state.cacheRevision;
      await store.acceptSnapshot(
        grantPages: [grants(2)],
        feedPages: [
          feed(2, records: [record(version: 2, text: 'new')]),
        ],
        expectedRevision: revision,
      );
      revision = (await store.snapshot()).state.cacheRevision;
      for (final row in [
        record(),
        record(version: 2, text: 'changed without revision'),
        record(version: 3, author: id(2)),
      ]) {
        await expectLater(
          store.acceptSnapshot(
            grantPages: [grants(3)],
            feedPages: [
              feed(3, records: [row]),
            ],
            expectedRevision: revision,
          ),
          throwsA(failed('invalid_response')),
        );
      }
      expect((await store.snapshot()).records.single.text, 'new');
    },
  );

  test('complete multi-page snapshots preserve drafts and reject stale local revisions', () async {
    await store.writeDraft(
      id(5),
      'SYNTHETIC retained draft',
      expectedRevision: 0,
    );
    final firstGrants = SharingGrants.fromJson({
      ...grants(2).toJson(),
      'next_before': 1,
    }, request: page());
    final lastGrants = SharingGrants.fromJson({
      ...grants(2).toJson(),
      'grants': <Object>[],
    }, request: page(before: 1, revision: 2));
    final firstFeed = feed(
      2,
      next: 2,
      records: [
        {
          ...record(author: id(2)),
          'id': id(10),
          'sequence': 2,
          'grant_id': id(40),
        },
      ],
    );
    final lastFeed = SharedFeedPage.fromJson(
      feed(2).toJson(),
      request: page(before: 2, revision: 2),
    );
    final before = (await store.snapshot()).state.cacheRevision;
    expect(
      await store.acceptSnapshot(
        grantPages: [firstGrants, lastGrants],
        feedPages: [firstFeed, lastFeed],
        expectedRevision: before,
      ),
      true,
    );
    expect((await store.snapshot()).records.map((r) => r.id), [id(10), id(5)]);
    expect((await store.draft(id(5)))!.content, 'SYNTHETIC retained draft');
    expect(
      await store.acceptSnapshot(
        grantPages: [grants(2)],
        feedPages: [feed(2)],
        expectedRevision: before,
      ),
      false,
    );
    await expectLater(
      store.enqueue(command(SharingCommandKind.remove, {'record_id': id(10)})),
      throwsA(failed('record_unavailable')),
    );
    await expectLater(
      store.enqueue(command(SharingCommandKind.enable, {'goal_id': id(99)})),
      throwsA(failed('sharing_unavailable')),
    );
  });

  test(
    'a newer reply snapshot prevents older feed state from being accepted',
    () async {
      await store.acceptReplies(id(5), [
        replies(4),
      ], expectedRevision: (await store.snapshot()).state.cacheRevision);
      expect((await store.replies(id(5))).single.text, 'SYNTHETIC reply');
      expect(
        await store.acceptSnapshot(
          grantPages: [grants(3)],
          feedPages: [feed(3)],
          expectedRevision: (await store.snapshot()).state.cacheRevision,
        ),
        false,
      );
    },
  );

  test(
    'removed feed records clear replies drafts and associated queued writes',
    () async {
      await store.acceptReplies(id(5), [
        replies(2),
      ], expectedRevision: (await store.snapshot()).state.cacheRevision);
      await store.writeDraft(
        id(5),
        'SYNTHETIC private draft',
        expectedRevision: 0,
      );
      final queued = await store.enqueue(reply('SYNTHETIC private draft'));
      final pending = await store.begin(queued.command.operationId);
      await store.acceptSnapshot(
        grantPages: [grants(3)],
        feedPages: [feed(3, records: [])],
        expectedRevision: (await store.snapshot()).state.cacheRevision,
      );
      expect(await db.select(db.sharedRepliesCache).get(), isEmpty);
      expect(await db.select(db.sharingDrafts).get(), isEmpty);
      expect((await store.snapshot()).commands, isEmpty);
      expect(await store.finish(pending, receipt(pending)), false);
      expect(
        (await goals.loadGoals()).single.titleOn(goals.clock.read().day),
        'SYNTHETIC personal',
      );
    },
  );

  test('unpair and credential change atomically clear remote data and invalidate old stores', () async {
    for (final change in ['unpair', 'credential']) {
      await store.writeDraft(
        id(5),
        'SYNTHETIC retained until leave',
        expectedRevision: 0,
      );
      final queued = await store.enqueue(reply('SYNTHETIC queued'));
      final attempt = await store.begin(queued.command.operationId);
      final old = store;
      if (change == 'unpair') {
        await pairing.acceptState(
          pair(active: false),
          expectedRevision: (await pairing.snapshot()).row.stateRevision,
        );
      } else {
        await LocalPairingStore.open(goals, credentialScope: 'b' * 64);
      }
      for (final table in [
        'sharing_states',
        'sharing_grants_cache',
        'shared_records_cache',
        'shared_replies_cache',
        'sharing_drafts',
        'sharing_commands',
      ]) {
        expect(
          await db.customSelect('SELECT * FROM $table').get(),
          isEmpty,
          reason: table,
        );
      }
      expect(await old.isCurrent(), false);
      await expectLater(
        old.finish(attempt, receipt(attempt)),
        throwsA(failed('discarded')),
      );
      expect(await goals.loadGoals(), hasLength(1));
      if (change == 'unpair') {
        await pairing.acceptState(
          pair(),
          expectedRevision: (await pairing.snapshot()).row.stateRevision,
        );
        store = await LocalSharingStore.open(pairing);
        await seed();
      }
    }
  });

  test(
    'identity change exposes no other owner cache or queued content',
    () async {
      await store.writeDraft(
        id(5),
        'SYNTHETIC guest only',
        expectedRevision: 0,
      );
      final identities = IdentityStore(db);
      await identities.finish(
        await identities.begin(SyncIdentity.account(id(90))),
      );
      expect(await store.isCurrent(), false);
      await bind();
      expect((await pairing.snapshot()).state, isNull);
      await expectLater(
        LocalSharingStore.open(pairing),
        throwsA(failed('pair_unavailable')),
      );
      final rows = await db.customSelect('SELECT * FROM sharing_drafts').get();
      expect(rows.single.read<String>('owner'), 'guest');
    },
  );

  test(
    'cleared sharing sessions never revive when the same pair returns',
    () async {
      final oldStore = store;
      final queued = await store.enqueue(reply('SYNTHETIC old attempt'));
      final attempt = await store.begin(queued.command.operationId);
      await pairing.forgetRemote();
      expect(await oldStore.isCurrent(), false);
      await pairing.acceptState(
        pair(),
        expectedRevision: (await pairing.snapshot()).row.stateRevision,
      );
      store = await LocalSharingStore.open(pairing);
      await seed();
      await store.enqueue(queued.command);
      final newAttempt = await store.begin(queued.command.operationId);
      expect(await oldStore.isCurrent(), false);
      await expectLater(
        oldStore.writeDraft(id(5), 'SYNTHETIC stale', expectedRevision: 0),
        throwsA(failed('discarded')),
      );
      expect(await store.finish(attempt, receipt(attempt)), false);
      expect(await store.finish(newAttempt, receipt(newAttempt)), true);
    },
  );

  test(
    'immutable grants and replies cannot change under existing IDs',
    () async {
      final changedGrant = SharingGrants.fromJson({
        ...grants(2).toJson(),
        'grants': [
          {...grant(), 'enabled_at': '2026-10-21T09:00:00.000Z'},
        ],
      }, request: page());
      await expectLater(
        store.acceptSnapshot(
          grantPages: [changedGrant],
          feedPages: [feed(2)],
          expectedRevision: (await store.snapshot()).state.cacheRevision,
        ),
        throwsA(failed('invalid_response')),
      );
      await store.acceptReplies(id(5), [
        replies(2),
      ], expectedRevision: (await store.snapshot()).state.cacheRevision);
      final changedReply = SharedRepliesPage.fromJson({
        ...replies(3).toJson(),
        'replies': [
          {...replies(3).replies.single.toJson(), 'text': 'changed'},
        ],
      }, request: page(record: id(5)));
      await expectLater(
        store.acceptReplies(id(5), [
          changedReply,
        ], expectedRevision: (await store.snapshot()).state.cacheRevision),
        throwsA(failed('invalid_response')),
      );
      expect((await store.replies(id(5))).single.text, 'SYNTHETIC reply');
    },
  );

  test(
    'failure keeps immutable payload and sanitizes untrusted error text',
    () async {
      final queued = await store.enqueue(reply('SYNTHETIC retry'));
      final attempt = await store.begin(queued.command.operationId);
      expect(
        await store.fail(
          attempt,
          const CompanionServiceFailure('PRIVATE ERROR', outcomeUnknown: true),
        ),
        true,
      );
      final old = (await store.snapshot()).commands.single;
      expect(old.row.errorCode, 'unavailable');
      expect(old.row.status, 'uncertain');
      final retry = await store.begin(queued.command.operationId);
      expect(retry.command.toJson(), queued.command.toJson());
      expect(
        await store.fail(attempt, const CompanionServiceFailure('network')),
        false,
      );
      expect(
        jsonEncode(
          (await db.select(db.sharingCommands).get())
              .map((r) => r.toJson())
              .toList(),
        ),
        isNot(contains('PRIVATE ERROR')),
      );
    },
  );

  test('confirmed publication cancellation survives reopening and cannot be begun again', () async {
    final queued = await store.enqueue(
      command(SharingCommandKind.publish, {
        'grant_id': id(4),
        'source_id': id(30),
        'base_revision': 0,
        'title': 'SYNTHETIC cancelled title',
        'occurred_at': instant,
        'completed_at': null,
        'share_details': true,
        'text': 'SYNTHETIC cancelled content',
        'photo_ids': <String>[],
      }),
    );
    final attempt = await store.begin(queued.command.operationId);
    await store.fail(
      attempt,
      const CompanionServiceFailure('publication_cancelled'),
    );
    final cancelled = (await store.snapshot()).commands.single;
    expect(cancelled.row.status, 'failed');
    expect(cancelled.row.errorCode, 'publication_cancelled');
    await db.close();
    db = AppDatabase(NativeDatabase(File('${directory.path}/data.sqlite')));
    await bind();
    store = await LocalSharingStore.open(pairing);
    await expectLater(
      store.begin(queued.command.operationId),
      throwsA(failed('publication_cancelled')),
    );
    expect((await store.snapshot()).commands.single.row.attempts, 1);
  });

  test(
    'stopping a grant clears pending publications and their private payloads',
    () async {
      final publication = await store.enqueue(
        command(SharingCommandKind.publish, {
          'grant_id': id(4),
          'source_id': id(30),
          'base_revision': 0,
          'title': 'SYNTHETIC pending title',
          'occurred_at': instant,
          'completed_at': null,
          'share_details': true,
          'text': 'SYNTHETIC pending details',
          'photo_ids': <String>[],
        }),
      );
      final pending = await store.begin(publication.command.operationId);
      final stop = await store.enqueue(
        command(SharingCommandKind.stop, {'grant_id': id(4)}),
      );
      final stopping = await store.begin(stop.command.operationId);
      expect(await store.finish(stopping, receipt(stopping)), true);
      expect((await store.snapshot()).commands, isEmpty);
      expect((await store.snapshot()).records, isEmpty);
      expect((await store.snapshot()).grants, isEmpty);
      expect(await store.finish(pending, receipt(pending)), false);
      final rows = await db.select(db.sharingCommands).get();
      expect(rows, hasLength(1));
      expect(rows.single.operationId, stop.command.operationId);
      expect(rows.single.status, 'succeeded');
      expect(await goals.loadGoals(), hasLength(1));
    },
  );

  test(
    'reply deletion is linked to its cached record for revocation cleanup',
    () async {
      final ownReply = SharedRepliesPage.fromJson({
        ...replies(2).toJson(),
        'replies': [
          {...replies(2).replies.single.toJson(), 'author_id': id(1)},
        ],
      }, request: page(record: id(5)));
      await store.acceptReplies(id(5), [
        ownReply,
      ], expectedRevision: (await store.snapshot()).state.cacheRevision);
      final queued = await store.enqueue(
        command(SharingCommandKind.deleteReply, {'reply_id': id(6)}),
      );
      await store.acceptSnapshot(
        grantPages: [grants(3)],
        feedPages: [feed(3, records: [])],
        expectedRevision: (await store.snapshot()).state.cacheRevision,
      );
      expect((await store.snapshot()).commands, isEmpty);
      await expectLater(
        store.begin(queued.command.operationId),
        throwsA(failed('operation_pending')),
      );
    },
  );
}
