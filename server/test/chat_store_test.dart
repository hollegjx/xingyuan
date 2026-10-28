import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:xingyuan_core/xingyuan_core.dart';
import 'package:xingyuan_server/src/companion_photo.dart';
import 'package:xingyuan_server/src/companion_store.dart';
import 'package:xingyuan_server/src/object_store.dart';

import 'support/chat_fixtures.dart';
import 'support/media_fixtures.dart';
import 'support/sharing_fixtures.dart';

void main() {
  late Directory directory;
  late CompanionStore store;
  late DiskObjectStore objects;
  late DateTime now;
  late String group;
  String getPath() => '${directory.path}/data.db';
  Matcher failure(String code) =>
      isA<CompanionFailure>().having((e) => e.code, 'code', code);
  void reopen() {
    store.close();
    store = CompanionStore.open(getPath(), now: () => now);
  }

  Future<String> upload({
    String label = 'qa-a',
    String? grant,
    String? target,
  }) async {
    final command = mediaUpload(target ?? group, grant);
    final reservation = store.reservePhoto(label, command);
    final clean = await sanitizeCompanionPhoto(command.bytes);
    await objects.put(reservation.photoId, clean.bytes);
    return store.finishPhoto(label, reservation, clean).id;
  }

  ChatReceipt send(ChatCommand command, {String label = 'qa-a'}) =>
      store.executeChat(label, command);
  ChatPage page({String label = 'qa-b'}) =>
      store.chatMessages(label, sharePage(group));
  List<Map<String, Object?>> rows(String table) {
    final db = sqlite3.open(getPath(), mode: OpenMode.readOnly);
    try {
      return db
          .select('SELECT * FROM $table ORDER BY rowid')
          .map((r) => Map<String, Object?>.from(r))
          .toList();
    } finally {
      db.close();
    }
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('chat-store-');
    now = DateTime.utc(2026, 10, 21, 10);
    store = CompanionStore.open(getPath(), now: () => now);
    objects = await DiskObjectStore.open('${directory.path}/objects');
    group = pairForSharing(store);
  });
  tearDown(() async {
    store.close();
    await directory.delete(recursive: true);
  });

  test('both authors share a stable sequence independent of wall clock', () {
    expect(page().messages, isEmpty);
    expect(page().revision, 0);
    final a = send(chatSend(group));
    now = now.subtract(const Duration(days: 1));
    final b = send(chatSend(group, text: 'SYNTHETIC B'), label: 'qa-b');
    expect([a.sequence, b.sequence], [1, 2]);
    final received = page();
    expect(received.messages.map((m) => m.id), [b.messageId, a.messageId]);
    expect(
      received.messages.first.createdAt.isBefore(
        received.messages.last.createdAt,
      ),
      true,
    );
    expect(received.messages.map((m) => m.authorId), [
      store.state('qa-b').memberId,
      store.state('qa-a').memberId,
    ]);
    expect(page(label: 'qa-a').toJson(), received.toJson());
    expect(store.sharingGrants('qa-a', sharePage(group)).revision, 0);
  });

  test(
    'five retries and restart have one effect and bind unchanged content',
    () {
      final command = chatSend(group);
      final accepted = send(command);
      for (var i = 0; i < 5; i++) {
        expect(send(command).toJson(), accepted.toJson());
      }
      reopen();
      expect(send(command).toJson(), accepted.toJson());
      expect(page().messages, hasLength(1));
      expect(page().revision, 1);
      expect(
        () => send(
          chatSend(group, operation: command.operationId, text: 'changed'),
        ),
        throwsA(failure('operation_conflict')),
      );
      expect(
        () => send(
          chatRemove(group, accepted.messageId, operation: command.operationId),
        ),
        throwsA(failure('operation_conflict')),
      );
      expect(rows('chat_operations'), hasLength(1));
      expect(
        jsonEncode(rows('chat_operations')),
        isNot(contains(command.text)),
      );
    },
  );

  test('operation IDs are scoped to members, not shared between partners', () {
    final command = chatSend(group);
    final a = send(command);
    final b = send(command, label: 'qa-b');
    expect(a.messageId, isNot(b.messageId));
    expect(page().messages, hasLength(2));
    expect(send(command).messageId, a.messageId);
    expect(send(command, label: 'qa-b').messageId, b.messageId);
  });

  test(
    'deletion is author-only, durable and never resurrected by a send retry',
    () {
      final command = chatSend(group);
      final accepted = send(command);
      final remove = chatRemove(group, accepted.messageId);
      expect(
        () => send(remove, label: 'qa-b'),
        throwsA(failure('message_unavailable')),
      );
      expect(page().messages, hasLength(1));
      final removed = send(remove);
      expect(removed.sequence, 0);
      expect(page().revision, 2);
      reopen();
      expect(send(remove).toJson(), removed.toJson());
      expect(() => send(command), throwsA(failure('message_unavailable')));
      expect(
        () => send(remove, label: 'qa-b'),
        throwsA(failure('message_unavailable')),
      );
      expect(
        () =>
            send(chatRemove(group, sharingId(), operation: remove.operationId)),
        throwsA(failure('operation_conflict')),
      );
      expect(page().messages, isEmpty);
      expect(page().revision, 2);
      expect(send(chatSend(group)).sequence, 3);
    },
  );

  test(
    'rejected upload attachment remains rejected after the upload completes',
    () async {
      final uploadCommand = mediaUpload(group, null);
      final reservation = store.reservePhoto('qa-a', uploadCommand);
      final command = chatSend(group, photo: reservation.photoId);
      expect(() => send(command), throwsA(failure('photo_unavailable')));
      expect(page().revision, 0);
      final clean = await sanitizeCompanionPhoto(uploadCommand.bytes);
      await objects.put(reservation.photoId, clean.bytes);
      store.finishPhoto('qa-a', reservation, clean);
      reopen();
      expect(() => send(command), throwsA(failure('photo_unavailable')));
      expect(
        () => send(chatSend(group, operation: command.operationId)),
        throwsA(failure('operation_conflict')),
      );
      expect(page().messages, isEmpty);
      send(chatSend(group, photo: reservation.photoId));
      expect(page().messages.single.photoId, reservation.photoId);
    },
  );

  test(
    'operation IDs cannot cross chat, pairing, sharing, resolution or media',
    () {
      final command = chatSend(group);
      send(command);
      final grantCommand = shareCommand(SharingCommandKind.enable, group, {
        'goal_id': sharingId(),
      }, operation: command.operationId);
      expect(
        () => store.executeSharing('qa-a', grantCommand),
        throwsA(failure('operation_conflict')),
      );
      expect(
        () => store.execute(
          'qa-a',
          PairingCommand.leave(command.operationId, group),
        ),
        throwsA(failure('operation_conflict')),
      );
      expect(
        () => store.reservePhoto(
          'qa-a',
          mediaUpload(group, null, operation: command.operationId),
        ),
        throwsA(failure('operation_conflict')),
      );
      expect(
        () => store.removePhoto(
          'qa-a',
          mediaRequest(group, sharingId(), operation: command.operationId),
        ),
        throwsA(failure('operation_conflict')),
      );
      expect(
        () => store.resolvePublication(
          'qa-a',
          PublicationResolveRequest.fromJson({
            'protocol': companionProtocol,
            'operation_id': command.operationId,
            'group_id': group,
            'fingerprint': 'a' * 64,
          }),
        ),
        throwsA(failure('operation_conflict')),
      );
      final pairCommand = PairingCommand.createInvite(sharingId());
      expect(
        () => store.execute('qa-a', pairCommand),
        throwsA(failure('already_paired')),
      );
      final sharing = shareCommand(SharingCommandKind.enable, group, {
        'goal_id': sharingId(),
      });
      store.executeSharing('qa-a', sharing);
      final media = mediaUpload(group, null);
      store.reservePhoto('qa-a', media);
      for (final operation in [
        pairCommand.operationId,
        sharing.operationId,
        media.operationId,
      ]) {
        expect(
          () => send(chatSend(group, operation: operation)),
          throwsA(failure('operation_conflict')),
        );
      }
      expect(page().messages, hasLength(1));
      expect(store.state('qa-a').group!.id, group);
    },
  );

  test('ready chat photo must belong to this author, purpose and pair and be unused', () async {
    final grant = store
        .executeSharing(
          'qa-a',
          shareCommand(SharingCommandKind.enable, group, {
            'goal_id': sharingId(),
          }),
        )
        .resourceId;
    final own = await upload();
    final partner = await upload(label: 'qa-b');
    final record = await upload(grant: grant);
    final other = pairForSharing(store, 'qa-c', 'qa-d');
    final outside = await upload(label: 'qa-c', target: other);
    for (final photo in [sharingId(), partner, record, outside]) {
      expect(
        () => send(chatSend(group, photo: photo)),
        throwsA(failure('photo_unavailable')),
      );
    }
    expect(page().revision, 0);
    send(chatSend(group, photo: own, text: ''));
    expect(
      () => send(chatSend(group, photo: own)),
      throwsA(failure('photo_unavailable')),
    );
    expect(page().revision, 1);
    expect(page().messages.single.photoId, own);
  });

  test('chat link grants photo access and protects it from expiry and independent removal', () async {
    final photo = await upload();
    final staged = await upload();
    expect(
      () => store.photoFor('qa-b', mediaRequest(group, photo)),
      throwsA(failure('photo_unavailable')),
    );
    final accepted = send(chatSend(group, photo: photo));
    expect(store.photoFor('qa-b', mediaRequest(group, photo)).id, photo);
    expect(
      () => store.removePhoto(
        'qa-a',
        mediaRequest(group, photo, operation: sharingId()),
      ),
      throwsA(failure('photo_attached')),
    );
    now = now.add(const Duration(days: 2));
    store.expireUnattachedPhotos();
    await store.drainPhotoDeletions(objects);
    expect(await objects.keys(), [photo]);
    expect(
      () => store.photoFor('qa-a', mediaRequest(group, staged)),
      throwsA(failure('photo_unavailable')),
    );
    send(chatRemove(group, accepted.messageId));
    reopen();
    for (final label in ['qa-a', 'qa-b']) {
      expect(
        () => store.photoFor(label, mediaRequest(group, photo)),
        throwsA(failure('photo_unavailable')),
      );
    }
    await store.drainPhotoDeletions(objects);
    expect(await objects.keys(), isEmpty);
  });

  test(
    'third-party reads, foreign messages and old-pair commands are isolated',
    () {
      final accepted = send(chatSend(group));
      final other = pairForSharing(store, 'qa-c', 'qa-d');
      expect(
        () => store.chatMessages('qa-c', sharePage(group)),
        throwsA(failure('pair_unavailable')),
      );
      expect(
        () => send(chatSend(group), label: 'qa-c'),
        throwsA(failure('pair_unavailable')),
      );
      expect(
        () => send(chatRemove(group, accepted.messageId), label: 'qa-c'),
        throwsA(failure('pair_unavailable')),
      );
      expect(
        () => send(chatRemove(other, accepted.messageId), label: 'qa-c'),
        throwsA(failure('message_unavailable')),
      );
      expect(store.chatMessages('qa-c', sharePage(other)).messages, isEmpty);
      expect(
        () => store.chatMessages('qa-a', sharePage(group, record: sharingId())),
        throwsFormatException,
      );
      expect(page().messages, hasLength(1));
    },
  );

  test('unpair erases chat and photos but keeps the other pair and old receipts inert', () async {
    final photo = await upload();
    final command = chatSend(group, photo: photo);
    final accepted = send(command);
    final other = pairForSharing(store, 'qa-c', 'qa-d');
    final otherCommand = chatSend(other, text: 'SYNTHETIC other pair');
    send(otherCommand, label: 'qa-c');
    final leave = PairingCommand.leave(sharingId(), group);
    store.execute('qa-b', leave);
    reopen();
    await store.drainPhotoDeletions(objects);
    expect(await objects.keys(), isEmpty);
    for (final label in ['qa-a', 'qa-b']) {
      expect(() => page(label: label), throwsA(failure('pair_unavailable')));
      expect(
        () => send(command, label: label),
        throwsA(failure('pair_unavailable')),
      );
      expect(
        () => send(chatRemove(group, accepted.messageId), label: label),
        throwsA(failure('pair_unavailable')),
      );
    }
    final next = pairForSharing(store, 'qa-a', 'qa-e');
    store.execute('qa-b', leave);
    expect(store.state('qa-a').group!.id, next);
    expect(store.chatMessages('qa-e', sharePage(next)).messages, isEmpty);
    expect(
      store.chatMessages('qa-c', sharePage(other)).messages.single.text,
      otherCommand.text,
    );
    expect(rows('chat_state').map((r) => r['group_id']), [other]);
    expect(rows('chat_messages').map((r) => r['group_id']), [other]);
    expect(jsonEncode(rows('chat_operations')), isNot(contains('SYNTHETIC')));
  });

  test('count-bound pages retain ordering and fail when snapshot changes', () {
    final accepted = <ChatReceipt>[];
    for (var i = 0; i < 25; i++) {
      accepted.add(
        send(
          chatSend(group, text: 'SYNTHETIC $i'),
          label: i.isEven ? 'qa-a' : 'qa-b',
        ),
      );
    }
    final first = page();
    expect(first.messages, hasLength(companionPageSize));
    final request = sharePage(
      group,
      before: first.nextBefore,
      revision: first.revision,
    );
    final rest = store.chatMessages('qa-b', request);
    expect(rest.messages, hasLength(5));
    expect(rest.nextBefore, isNull);
    expect(
      [...first.messages, ...rest.messages].map((m) => m.id),
      accepted.reversed.map((r) => r.messageId),
    );
    send(chatRemove(group, accepted.first.messageId));
    expect(
      () => store.chatMessages('qa-b', request),
      throwsA(failure('snapshot_changed')),
    );
    final updated = page();
    expect(updated.revision, 26);
    send(chatSend(group));
    expect(
      () => store.chatMessages(
        'qa-b',
        sharePage(
          group,
          before: updated.nextBefore,
          revision: updated.revision,
        ),
      ),
      throwsA(failure('snapshot_changed')),
    );
  });

  test(
    'byte-bound pagination includes every large-grapheme message exactly once',
    () {
      const emoji = '\u{1f469}\u200d\u{1f4bb}';
      for (var i = 0; i < 21; i++) {
        send(chatSend(group, text: emoji * 1000));
      }
      final ids = <String>[];
      var received = page();
      expect(received.messages.length, lessThan(companionPageSize));
      while (true) {
        expect(received.messages, isNotEmpty);
        expect(
          utf8.encode(jsonEncode(received.toJson())).length,
          lessThanOrEqualTo(assistantBodyLimit),
        );
        ids.addAll(received.messages.map((m) => m.id));
        if (received.nextBefore == null) break;
        received = store.chatMessages(
          'qa-b',
          sharePage(
            group,
            before: received.nextBefore,
            revision: received.revision,
          ),
        );
      }
      expect(ids, hasLength(21));
      expect(ids.toSet(), hasLength(21));
    },
  );

  test('online SQLite backup restores messages, receipt replay and deletion metadata', () async {
    final photo = await upload();
    final command = chatSend(group, photo: photo);
    final accepted = send(command);
    final deleted = send(chatSend(group));
    final remove = chatRemove(group, deleted.messageId);
    send(remove);
    final rejected = chatSend(group, photo: sharingId());
    expect(() => send(rejected), throwsA(failure('photo_unavailable')));
    final snapshot = page().toJson();
    await store.backupTo('${directory.path}/restored.db');
    final restored = CompanionStore.open(
      '${directory.path}/restored.db',
      now: () => now,
    );
    try {
      expect(
        restored.chatMessages('qa-b', sharePage(group)).toJson(),
        snapshot,
      );
      expect(restored.executeChat('qa-a', command).toJson(), accepted.toJson());
      expect(restored.executeChat('qa-a', remove).messageId, deleted.messageId);
      expect(
        () => restored.executeChat('qa-a', rejected),
        throwsA(failure('photo_unavailable')),
      );
      expect(restored.photoFor('qa-b', mediaRequest(group, photo)).id, photo);
    } finally {
      restored.close();
    }
  });

  test(
    'oversized response rolls back the message, revision and receipt together',
    () {
      final small = chatSend(group, text: 'a');
      final overhead = utf8.encode(jsonEncode(small.toJson())).length;
      final text = 'a${'\u0301' * ((assistantBodyLimit - overhead) ~/ 2)}';
      final command = chatSend(group, text: text);
      expect(
        utf8.encode(jsonEncode(command.toJson())).length,
        lessThanOrEqualTo(assistantBodyLimit),
      );
      expect(() => send(command), throwsFormatException);
      expect(page().messages, isEmpty);
      expect(page().revision, 0);
      expect(rows('chat_operations'), isEmpty);
      reopen();
      expect(page().messages, isEmpty);
      expect(send(chatSend(group)).sequence, 1);
    },
  );
}
