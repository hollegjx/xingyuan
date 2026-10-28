import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/sync/identity_store.dart';
import 'package:habit_checkin/data/sync/sync_identity.dart';
import 'package:habit_checkin/features/companion/data/companion_service.dart';
import 'package:habit_checkin/features/companion/data/local_chat_store.dart';
import 'package:habit_checkin/features/companion/data/local_pairing_store.dart';
import 'package:habit_checkin/features/companion/data/local_sharing_store.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'support/chat_fixtures.dart';
import 'support/pairing_fixtures.dart';
import 'support/sharing_fixtures.dart' show sharingId;

void main() {
  late ChatFixture f;
  setUp(() async {
    tzdata.initializeTimeZones();
    f = ChatFixture(await Directory.systemTemp.createTemp('chat-store-'));
    await f.open();
  });
  tearDown(() async {
    await f.db.close();
    await f.directory.delete(recursive: true);
  });
  Future<int> draft(String text) async {
    final state = (await f.store.snapshot()).state;
    return f.store.writeDraft(
      text,
      photoId: null,
      expectedRevision: state.draftRevision,
    );
  }

  Future<ChatAttempt> queued(String text, int operation) async {
    final revision = await draft(text);
    return f.store.enqueueSend(
      sharingId(operation),
      expectedDraftRevision: revision,
    );
  }

  Future<ChatAttempt> ready(int operation) async =>
      f.store.prepareRequest(await f.store.begin(sharingId(operation)));
  Future<void> receive(
    List<Map<String, Object?>> rows, {
    int revision = 1,
  }) async {
    final state = (await f.store.snapshot()).state;
    expect(
      await f.store.acceptPages([
        chatPage(rows, revision: revision),
      ], expectedRevision: state.cacheRevision),
      true,
    );
  }

  test('draft text emoji newline and photo persist across reopen; CAS rejects stale editor', () async {
    final photo = chatPhoto(f.store);
    await f.store.writeDraft(
      'SYNTHETIC 👨‍👩‍👧‍👦\n保留草稿',
      photoId: photo.id,
      addedPhoto: photo,
      expectedRevision: 0,
    );
    await f.reopen();
    final before = await f.store.snapshot();
    expect(before.state.draftText, 'SYNTHETIC 👨‍👩‍👧‍👦\n保留草稿');
    expect(before.photo?.id, photo.id);
    await expectLater(
      f.store.writeDraft('stale', photoId: null, expectedRevision: 0),
      throwsA(isA<CompanionServiceFailure>()),
    );
    expect((await f.store.snapshot()).state, before.state);
  });

  test('five enqueue calls clear only captured draft once and freeze one operation', () async {
    final revision = await draft('SYNTHETIC queued');
    final results = await Future.wait(
      List.generate(
        5,
        (_) =>
            f.store.enqueueSend(sharingId(50), expectedDraftRevision: revision),
      ),
    );
    expect(results.map((r) => r.row.sequence).toSet(), hasLength(1));
    await draft('SYNTHETIC next input');
    final attempt = await ready(50);
    expect(await f.store.finish(attempt, chatReceipt(attempt)), true);
    expect((await f.store.snapshot()).state.draftText, 'SYNTHETIC next input');
    final nextRevision = (await f.store.snapshot()).state.draftRevision;
    await expectLater(
      f.store.enqueueSend(sharingId(50), expectedDraftRevision: nextRevision),
      throwsA(isA<CompanionServiceFailure>()),
    );
  });

  test('empty and overlength sends keep the full draft; grapheme boundary is accepted', () async {
    await expectLater(
      f.store.enqueueSend(sharingId(50), expectedDraftRevision: 0),
      throwsA(isA<CompanionServiceFailure>()),
    );
    var revision = await draft('👨‍👩‍👧‍👦' * 1001);
    await expectLater(
      f.store.enqueueSend(sharingId(50), expectedDraftRevision: revision),
      throwsA(isA<CompanionServiceFailure>()),
    );
    expect((await f.store.snapshot()).state.draftText, '👨‍👩‍👧‍👦' * 1001);
    revision = await draft('👨‍👩‍👧‍👦' * 1000);
    await f.store.enqueueSend(sharingId(50), expectedDraftRevision: revision);
    expect((await ready(50)).command.text, '👨‍👩‍👧‍👦' * 1000);
  });

  test('unknown send blocks later sends; reopen and retry retain operation and body', () async {
    await queued('SYNTHETIC first', 50);
    await queued('SYNTHETIC second', 51);
    final first = await ready(50);
    await f.reopen();
    await f.store.recoverInterrupted();
    expect((await f.store.snapshot()).commands.first.row.status, 'uncertain');
    await expectLater(
      f.store.begin(sharingId(51)),
      throwsA(isA<CompanionServiceFailure>()),
    );
    await expectLater(
      f.store.discard(sharingId(50)),
      throwsA(isA<CompanionServiceFailure>()),
    );
    final retry = await ready(50);
    expect(retry.command.toJson(), first.command.toJson());
    expect(retry.row.attempts, 2);
    expect(await f.store.finish(first, chatReceipt(first)), false);
    expect(await f.store.finish(retry, chatReceipt(retry)), true);
    expect((await ready(51)).command.text, 'SYNTHETIC second');
  });

  test('definitive failures and never attempted pending sends can be discarded in order', () async {
    await queued('SYNTHETIC first', 50);
    await queued('SYNTHETIC second', 51);
    final first = await ready(50);
    await f.store.fail(first, const CompanionServiceFailure('invalid_request'));
    await f.store.discard(sharingId(50));
    await f.store.discard(sharingId(51));
    expect((await f.store.snapshot()).commands, isEmpty);
  });

  test(
    'a failed retry cannot downgrade an earlier unknown outcome to discardable',
    () async {
      await queued('SYNTHETIC lost acknowledgement', 50);
      final first = await ready(50);
      await f.store.fail(
        first,
        const CompanionServiceFailure('timeout', outcomeUnknown: true),
      );
      await f.reopen();
      final retry = await ready(50);
      await f.store.fail(retry, const CompanionServiceFailure('network'));
      expect(
        (await f.store.snapshot()).commands.single.row.status,
        'uncertain',
      );
      await expectLater(
        f.store.discard(sharingId(50)),
        throwsA(isA<CompanionServiceFailure>()),
      );
    },
  );

  test('photo upload operation and receipt survive restart and successful receipt is scrubbed after refresh', () async {
    final photo = chatPhoto(f.store);
    await f.store.writeDraft(
      '',
      photoId: photo.id,
      addedPhoto: photo,
      expectedRevision: 0,
    );
    await f.store.enqueueSend(sharingId(50), expectedDraftRevision: 1);
    var attempt = await f.store.begin(sharingId(50));
    final upload = chatUpload(attempt);
    attempt = await f.store.acceptUpload(
      attempt,
      upload,
      chatUploadReceipt(upload),
    );
    await f.reopen();
    await f.store.recoverInterrupted();
    attempt = await ready(50);
    expect(attempt.row.uploadOperationId, upload.operationId);
    expect(attempt.command.photoId, sharingId(40));
    await f.store.finish(attempt, chatReceipt(attempt));
    expect((await f.store.photo(photo.id)).retired, false);
    await receive([
      chatMessageJson(
        id: sharingId(20),
        author: testMemberId,
        text: '',
        photo: sharingId(40),
      ),
    ]);
    expect((await f.store.snapshot()).commands, isEmpty);
    final row = (await f.db.select(f.db.chatCommands).get()).single;
    expect(row.requestJson, isNull);
    expect(row.photoReceiptJson, isNull);
    expect(row.localPhotoId, isNull);
    expect((await f.db.select(f.db.chatPhotos).get()).single.retired, true);
  });

  test(
    'upload acknowledgement rejects different bytes even at the same size',
    () async {
      final bytes = chatJpeg();
      final photo = chatPhoto(f.store, bytes: bytes);
      await f.store.writeDraft(
        '',
        photoId: photo.id,
        addedPhoto: photo,
        expectedRevision: 0,
      );
      await f.store.enqueueSend(sharingId(50), expectedDraftRevision: 1);
      final attempt = await f.store.begin(sharingId(50));
      final changed = Uint8List.fromList(bytes)..[10] = (bytes[10] + 1) % 256;
      final upload = chatUpload(attempt, bytes: changed);
      await expectLater(
        f.store.acceptUpload(attempt, upload, chatUploadReceipt(upload)),
        throwsA(isA<CompanionServiceFailure>()),
      );
      expect(
        (await f.store.snapshot()).commands.single.row.photoReceiptJson,
        isNull,
      );
    },
  );

  test('upload receipt author and operation cannot be substituted', () async {
    final photo = chatPhoto(f.store);
    await f.store.writeDraft(
      '',
      photoId: photo.id,
      addedPhoto: photo,
      expectedRevision: 0,
    );
    await f.store.enqueueSend(sharingId(50), expectedDraftRevision: 1);
    final attempt = await f.store.begin(sharingId(50));
    final upload = chatUpload(attempt);
    await expectLater(
      f.store.acceptUpload(
        attempt,
        upload,
        chatUploadReceipt(upload, author: testPartnerId),
      ),
      throwsA(isA<CompanionServiceFailure>()),
    );
    expect(
      (await f.store.snapshot()).commands.single.row.photoReceiptJson,
      isNull,
    );
  });

  test(
    'full revision-bound pagination persists order and local unread position',
    () async {
      final state = (await f.store.snapshot()).state;
      final newer = chatMessageJson(
        id: sharingId(12),
        sequence: 3,
        author: testMemberId,
      );
      final middle = chatMessageJson(id: sharingId(11), sequence: 2);
      final older = chatMessageJson(sequence: 1);
      expect(
        await f.store.acceptPages([
          chatPage([newer, middle], revision: 3, next: 2),
          chatPage([older], revision: 3, before: 2),
        ], expectedRevision: state.cacheRevision),
        true,
      );
      expect((await f.store.snapshot()).messages.map((m) => m.sequence), [
        1,
        2,
        3,
      ]);
      await f.store.markRead();
      await f.reopen();
      expect((await f.store.snapshot()).state.readSequence, 3);
    },
  );

  test('partial stale foreign-author and changed immutable snapshots never replace cache', () async {
    await receive([chatMessageJson()]);
    final state = (await f.store.snapshot()).state;
    for (final page in [
      chatPage([chatMessageJson(sequence: 2)], revision: 2, next: 2),
      chatPage([chatMessageJson(author: sharingId(99))], revision: 2),
      chatPage([chatMessageJson(text: 'SYNTHETIC changed')], revision: 2),
    ]) {
      await expectLater(
        f.store.acceptPages([page], expectedRevision: state.cacheRevision),
        throwsA(isA<CompanionServiceFailure>()),
      );
    }
    expect(
      await f.store.acceptPages([
        chatPage([], revision: 0),
      ], expectedRevision: state.cacheRevision),
      false,
    );
    expect((await f.store.snapshot()).messages.single.text, 'SYNTHETIC chat');
  });

  test('same revision cannot silently remove an existing message', () async {
    await receive([chatMessageJson()]);
    final state = (await f.store.snapshot()).state;
    await expectLater(
      f.store.acceptPages([
        chatPage([]),
      ], expectedRevision: state.cacheRevision),
      throwsA(isA<CompanionServiceFailure>()),
    );
    expect((await f.store.snapshot()).messages, hasLength(1));
  });

  test('only own cached messages can be removed and stale feed cannot resurrect them', () async {
    final mine = chatMessageJson(author: testMemberId);
    await receive([mine]);
    await f.store.enqueueRemove(sharingId(50), sharingId(10));
    final duplicate = await f.store.enqueueRemove(sharingId(51), sharingId(10));
    expect(duplicate.row.operationId, sharingId(50));
    final attempt = await ready(50);
    await f.store.finish(attempt, chatReceipt(attempt));
    final state = (await f.store.snapshot()).state;
    await expectLater(
      f.store.acceptPages([
        chatPage([mine]),
      ], expectedRevision: state.cacheRevision),
      throwsA(isA<CompanionServiceFailure>()),
    );
    await receive([
      chatMessageJson(id: sharingId(11), sequence: 2),
    ], revision: 3);
    await expectLater(
      f.store.enqueueRemove(sharingId(52), sharingId(11)),
      throwsA(isA<CompanionServiceFailure>()),
    );
  });

  test('unpair clears chat but preserves personal goals and invalidates old attempts', () async {
    await f.goals.create(
      const GoalDraft(title: 'SYNTHETIC private', kind: GoalKind.habit),
    );
    final photo = chatPhoto(f.store);
    await f.store.writeDraft(
      'SYNTHETIC private chat',
      photoId: photo.id,
      addedPhoto: photo,
      expectedRevision: 0,
    );
    await f.store.enqueueSend(sharingId(50), expectedDraftRevision: 1);
    final attempt = await f.store.begin(sharingId(50));
    await f.store.fail(
      attempt,
      const CompanionServiceFailure('network', outcomeUnknown: true),
    );
    final before = await f.pairing.snapshot();
    await f.pairing.acceptState(
      testPairingState(),
      expectedRevision: before.row.stateRevision,
    );
    expect(await f.store.isCurrent(), false);
    for (final table in [
      'chat_states',
      'chat_commands',
      'chat_messages_cache',
    ]) {
      expect(await f.db.customSelect('SELECT * FROM $table').get(), isEmpty);
    }
    expect((await f.db.select(f.db.chatPhotos).get()).single.retired, true);
    expect(
      (await f.goals.loadGoals()).single.titleOn(f.clock.day),
      'SYNTHETIC private',
    );
  });

  test('identity switching isolates caches and never revives an old lease on return', () async {
    await queued('SYNTHETIC guest pending', 50);
    await draft('SYNTHETIC guest draft');
    final old = f.store;
    final identities = IdentityStore(f.db);
    await identities.finish(
      await identities.begin(SyncIdentity.account(sharingId(90))),
    );
    expect(await old.isCurrent(), false);
    await expectLater(old.snapshot(), throwsA(isA<StaleIdentity>()));
    final lease = await identities.active();
    final goals = LocalGoalRepository(
      f.db,
      f.clock,
      owner: lease.identity.owner,
      identityLease: lease,
    );
    final paired = await LocalPairingStore.open(
      goals,
      credentialScope: 'a' * 64,
    );
    expect((await paired.snapshot()).state, isNull);
    await expectLater(
      LocalSharingStore.open(paired),
      throwsA(isA<CompanionServiceFailure>()),
    );
    expect((await f.db.select(f.db.chatCommands).get()).single.owner, 'guest');
    await identities.finish(await identities.begin(SyncIdentity.guest));
    expect(await old.isCurrent(), false);
    await expectLater(
      old.writeDraft('SYNTHETIC stale', photoId: null, expectedRevision: 3),
      throwsA(isA<StaleIdentity>()),
    );
    expect(
      (await f.db.select(f.db.chatStates).get()).single.draftText,
      'SYNTHETIC guest draft',
    );
  });

  test('credential replacement and clearing same group reject stale sessions and content', () async {
    await queued('SYNTHETIC stale', 50);
    final oldStore = f.store;
    await f.db.clearSharingContent(f.store.owner);
    final sharing = await LocalSharingStore.open(f.pairing);
    f.store = await LocalChatStore.open(sharing);
    expect(await oldStore.isCurrent(), false);
    expect((await f.store.snapshot()).commands, isEmpty);
    await draft('SYNTHETIC new draft');
    await LocalPairingStore.open(f.goals, credentialScope: 'b' * 64);
    expect(await f.store.isCurrent(), false);
    expect(await f.db.select(f.db.chatStates).get(), isEmpty);
  });

  test(
    'cache CAS rejects in-flight reads after command receipt changes state',
    () async {
      await queued('SYNTHETIC accepted', 50);
      final before = (await f.store.snapshot()).state;
      final attempt = await ready(50);
      await f.store.finish(attempt, chatReceipt(attempt, sequence: 5));
      expect(
        await f.store.acceptPages([
          chatPage([], revision: 6),
        ], expectedRevision: before.cacheRevision),
        false,
      );
      final now = (await f.store.snapshot()).state;
      expect(
        await f.store.acceptPages([
          chatPage([], revision: 4),
        ], expectedRevision: now.cacheRevision),
        false,
      );
      expect(
        jsonEncode((await f.store.snapshot()).commands.single.command.toJson()),
        contains('SYNTHETIC accepted'),
      );
    },
  );
}
