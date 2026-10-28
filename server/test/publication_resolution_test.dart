import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
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
  late String grant;
  Matcher failure(String code) =>
      isA<CompanionFailure>().having((e) => e.code, 'code', code);
  PublicationResolveRequest request(SharingCommand command) =>
      PublicationResolveRequest.fromJson({
        'protocol': companionProtocol,
        'group_id': command.groupId,
        'operation_id': command.operationId,
        'fingerprint': sha256
            .convert(utf8.encode(command.fingerprintInput))
            .toString(),
      });
  void reopen() {
    store.close();
    store = CompanionStore.open('${directory.path}/data.db', now: () => now);
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'publication-resolution-',
    );
    now = DateTime.utc(2026, 10, 21, 10);
    store = CompanionStore.open('${directory.path}/data.db', now: () => now);
    group = pairForSharing(store);
    grant = store
        .executeSharing(
          'qa-a',
          shareCommand(SharingCommandKind.enable, group, {
            'goal_id': sharingId(),
          }),
        )
        .resourceId;
  });
  tearDown(() async {
    store.close();
    await directory.delete(recursive: true);
  });

  test(
    'sealed absent publication stays rejected after reopen and backup restore',
    () async {
      final command = publishRecord(group, grant, now);
      final value = request(command);
      final result = store.resolvePublication('qa-a', value).toJson();
      expect(result['error_code'], 'publication_cancelled');
      for (var i = 0; i < 5; i++) {
        expect(store.resolvePublication('qa-a', value).toJson(), result);
      }
      reopen();
      expect(store.resolvePublication('qa-a', value).toJson(), result);
      expect(
        () => store.executeSharing('qa-a', command),
        throwsA(failure('publication_cancelled')),
      );
      await store.backupTo('${directory.path}/restored.db');
      final restored = CompanionStore.open(
        '${directory.path}/restored.db',
        now: () => now,
      );
      try {
        expect(restored.resolvePublication('qa-a', value).toJson(), result);
        expect(
          () => restored.executeSharing('qa-a', command),
          throwsA(failure('publication_cancelled')),
        );
        expect(restored.sharedFeed('qa-b', sharePage(group)).records, isEmpty);
      } finally {
        restored.close();
      }
      final db = sqlite3.open(
        '${directory.path}/data.db',
        mode: OpenMode.readOnly,
      );
      try {
        final rows = db.select(
          'SELECT * FROM sharing_operations WHERE operation_id=?',
          [command.operationId],
        );
        expect(rows, hasLength(1));
        expect(jsonEncode(rows), isNot(contains(command.text)));
        expect(jsonEncode(rows), isNot(contains(command.title)));
      } finally {
        db.close();
      }
    },
  );

  test('original receipt survives later edit removal and stopped sharing without resurrection', () {
    final command = publishRecord(group, grant, now);
    final value = request(command);
    final original = store.executeSharing('qa-a', command);
    store.executeSharing(
      'qa-a',
      publishRecord(
        group,
        grant,
        now,
        source: command.sourceId,
        revision: 1,
        text: 'Synthetic newer text',
      ),
    );
    reopen();
    expect(
      store.resolvePublication('qa-a', value).receipt!.toJson(),
      original.toJson(),
    );
    expect(
      store.sharedFeed('qa-b', sharePage(group)).records.single.revision,
      2,
    );
    store.executeSharing(
      'qa-a',
      shareCommand(SharingCommandKind.remove, group, {
        'record_id': original.resourceId,
      }),
    );
    expect(
      store.resolvePublication('qa-a', value).receipt!.toJson(),
      original.toJson(),
    );
    expect(store.sharedFeed('qa-b', sharePage(group)).records, isEmpty);
    store.executeSharing(
      'qa-a',
      shareCommand(SharingCommandKind.stop, group, {'grant_id': grant}),
    );
    reopen();
    expect(
      store.resolvePublication('qa-a', value).receipt!.toJson(),
      original.toJson(),
    );
    expect(store.sharedFeed('qa-b', sharePage(group)).records, isEmpty);
  });

  test(
    'original rejections remain definitive after their preconditions change',
    () {
      final future = publishRecord(
        group,
        grant,
        now.add(const Duration(seconds: 1)),
      );
      final cases = <SharingCommand, String>{
        future: 'history_not_shareable',
        publishRecord(group, sharingId(), now): 'sharing_unavailable',
        publishRecord(group, grant, now, revision: 1): 'revision_conflict',
        publishRecord(group, grant, now, photos: [sharingId()]):
            'photo_unavailable',
      };
      for (final entry in cases.entries) {
        expect(
          () => store.executeSharing('qa-a', entry.key),
          throwsA(failure(entry.value)),
        );
      }
      now = now.add(const Duration(seconds: 2));
      reopen();
      for (final entry in cases.entries) {
        expect(
          store.resolvePublication('qa-a', request(entry.key)).errorCode,
          entry.value,
        );
        expect(
          () => store.executeSharing('qa-a', entry.key),
          throwsA(failure(entry.value)),
        );
      }
      expect(store.sharedFeed('qa-b', sharePage(group)).records, isEmpty);
    },
  );

  test(
    'different fingerprint cannot overwrite a pending cancellation or success',
    () {
      for (final applied in [false, true]) {
        final command = publishRecord(group, grant, now);
        if (applied) store.executeSharing('qa-a', command);
        final value = request(command);
        final original = store.resolvePublication('qa-a', value).toJson();
        final mismatch = PublicationResolveRequest.fromJson({
          ...value.toJson(),
          'fingerprint': 'f' * 64,
        });
        expect(
          () => store.resolvePublication('qa-a', mismatch),
          throwsA(failure('operation_conflict')),
        );
        final altered = SharingCommand.fromJson(SharingCommandKind.publish, {
          ...command.toJson(),
          'text': 'Synthetic changed',
        });
        expect(
          () => store.executeSharing('qa-a', altered),
          throwsA(failure('operation_conflict')),
        );
        expect(store.resolvePublication('qa-a', value).toJson(), original);
      }
    },
  );

  test(
    'operation ID collisions cannot cross pairing sharing and media ledgers',
    () {
      final sharing = shareCommand(SharingCommandKind.enable, group, {
        'goal_id': sharingId(),
      });
      store.executeSharing('qa-a', sharing);
      final pairing = PairingCommand.createInvite(sharingId());
      expect(
        () => store.execute('qa-a', pairing),
        throwsA(failure('already_paired')),
      );
      final media = CompanionPhotoUpload.fromJson({
        'protocol': companionProtocol,
        'operation_id': sharingId(),
        'group_id': group,
        'purpose': 'record',
        'grant_id': grant,
        'jpeg_base64': base64Encode([0xff, 0xd8, 0xff, 0xd9]),
      });
      store.reservePhoto('qa-a', media);
      for (final operation in [
        sharing.operationId,
        pairing.operationId,
        media.operationId,
      ]) {
        final value = request(
          publishRecord(group, grant, now, operation: operation),
        );
        expect(
          () => store.resolvePublication('qa-a', value),
          throwsA(failure('operation_conflict')),
        );
      }
      final cancelled = publishRecord(group, grant, now);
      store.resolvePublication('qa-a', request(cancelled));
      expect(
        () => store.execute(
          'qa-a',
          PairingCommand.leave(cancelled.operationId, group),
        ),
        throwsA(failure('operation_conflict')),
      );
      expect(
        () => store.reservePhoto(
          'qa-a',
          CompanionPhotoUpload.fromJson({
            ...media.toJson(),
            'operation_id': cancelled.operationId,
          }),
        ),
        throwsA(failure('operation_conflict')),
      );
      expect(store.state('qa-a').group!.id, group);
    },
  );

  test('receipts and cancellation are scoped to the authenticated member', () {
    final command = publishRecord(group, grant, now);
    final original = store.executeSharing('qa-a', command);
    final value = request(command);
    final partner = store.resolvePublication('qa-b', value);
    expect(partner.receipt, isNull);
    expect(partner.errorCode, 'publication_cancelled');
    expect(
      store.resolvePublication('qa-a', value).receipt!.toJson(),
      original.toJson(),
    );
    final pending = publishRecord(group, grant, now);
    store.resolvePublication('qa-b', request(pending));
    expect(store.executeSharing('qa-a', pending).revision, 1);
    final other = pairForSharing(store, 'qa-c', 'qa-d');
    expect(
      () => store.resolvePublication('qa-c', value),
      throwsA(failure('pair_unavailable')),
    );
    expect(
      () => store.resolvePublication(
        'qa-a',
        PublicationResolveRequest.fromJson({
          ...value.toJson(),
          'group_id': other,
        }),
      ),
      throwsA(failure('pair_unavailable')),
    );
  });

  test('unpaired and later repaired members cannot recover old receipts', () {
    final command = publishRecord(group, grant, now);
    store.executeSharing('qa-a', command);
    final value = request(command);
    store.execute('qa-b', PairingCommand.leave(sharingId(), group));
    expect(
      () => store.resolvePublication('qa-a', value),
      throwsA(failure('pair_unavailable')),
    );
    final newGroup = pairForSharing(store);
    reopen();
    expect(
      () => store.resolvePublication('qa-a', value),
      throwsA(failure('pair_unavailable')),
    );
    expect(
      () => store.resolvePublication(
        'qa-a',
        PublicationResolveRequest.fromJson({
          ...value.toJson(),
          'group_id': newGroup,
        }),
      ),
      throwsA(failure('operation_conflict')),
    );
    expect(store.sharedFeed('qa-b', sharePage(newGroup)).records, isEmpty);
  });
}
