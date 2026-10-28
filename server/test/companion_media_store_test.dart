import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:test/test.dart';
import 'package:xingyuan_core/xingyuan_core.dart';
import 'package:xingyuan_server/src/companion_photo.dart';
import 'package:xingyuan_server/src/companion_store.dart';
import 'package:xingyuan_server/src/object_store.dart';

import 'support/sharing_fixtures.dart';
import 'support/media_fixtures.dart';

void main() {
  late Directory directory;
  late CompanionStore store;
  late DiskObjectStore objects;
  late String group;
  late String grant;
  late DateTime now;
  Matcher failure(String code) =>
      isA<CompanionFailure>().having((e) => e.code, 'code', code);
  CompanionPhotoUpload upload({String? operation, String? targetGrant}) =>
      CompanionPhotoUpload.fromJson({
        'protocol': companionProtocol,
        'operation_id': operation ?? sharingId(),
        'group_id': group,
        'purpose': 'record',
        'grant_id': targetGrant ?? grant,
        'jpeg_base64': base64Encode(
          img.encodeJpg(img.Image(width: 12, height: 8)),
        ),
      });
  CompanionPhotoRequest request(String id, {String? operation}) =>
      CompanionPhotoRequest.fromJson({
        'protocol': companionProtocol,
        'group_id': group,
        'photo_id': id,
        'operation_id': ?operation,
      }, remove: operation != null);
  Future<CompanionPhotoMetadata> save(CompanionPhotoUpload command) async {
    final reservation = store.reservePhoto('qa-a', command);
    final clean = await sanitizeCompanionPhoto(command.bytes);
    await objects.put(reservation.photoId, clean.bytes);
    return store.finishPhoto('qa-a', reservation, clean);
  }

  void reopen() {
    store.close();
    store = CompanionStore.open('${directory.path}/data.db', now: () => now);
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('media-store-');
    now = DateTime.utc(2026, 10, 21, 10);
    store = CompanionStore.open('${directory.path}/data.db', now: () => now);
    objects = await DiskObjectStore.open('${directory.path}/objects');
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
    'late upload after leave and cleanup cannot leave an orphan file',
    () async {
      final command = upload();
      final reservation = store.reservePhoto('qa-a', command);
      final clean = await sanitizeCompanionPhoto(command.bytes);
      store.execute('qa-b', PairingCommand.leave(sharingId(), group));
      await store.drainPhotoDeletions(objects);
      await objects.put(reservation.photoId, clean.bytes);
      expect(
        () => store.finishPhoto('qa-a', reservation, clean),
        throwsA(failure('pair_unavailable')),
      );
      store.abortPhoto(
        reservation,
        const CompanionFailure(403, 'pair_unavailable'),
      );
      reopen();
      await store.drainPhotoDeletions(objects);
      expect(await objects.keys(), isEmpty);
    },
  );

  test('rejected remove binds payload and rejection across restart', () async {
    final photo = await save(upload());
    final published = publishRecord(group, grant, now, photos: [photo.id]);
    store.executeSharing('qa-a', published);
    final remove = request(photo.id, operation: sharingId());
    expect(
      () => store.removePhoto('qa-a', remove),
      throwsA(failure('photo_attached')),
    );
    reopen();
    expect(
      () => store.removePhoto(
        'qa-a',
        request(sharingId(), operation: remove.operationId),
      ),
      throwsA(failure('operation_conflict')),
    );
    store.executeSharing(
      'qa-a',
      publishRecord(group, grant, now, source: published.sourceId, revision: 1),
    );
    expect(
      () => store.removePhoto('qa-a', remove),
      throwsA(failure('photo_attached')),
    );
  });

  test('rejected upload cannot reuse its operation with a different grant', () {
    final rejected = upload(targetGrant: sharingId());
    expect(
      () => store.reservePhoto('qa-a', rejected),
      throwsA(failure('sharing_unavailable')),
    );
    reopen();
    expect(
      () => store.reservePhoto('qa-a', upload(operation: rejected.operationId)),
      throwsA(failure('operation_conflict')),
    );
  });

  test(
    'staged media is owner-only; active record consent grants partner access',
    () async {
      final command = upload();
      final pending = store.reservePhoto('qa-a', command);
      expect(
        () => store.photoFor('qa-a', request(pending.photoId)),
        throwsA(failure('photo_unavailable')),
      );
      final photo = await save(command);
      expect(
        store.photoFor('qa-a', request(photo.id)).toJson(),
        photo.toJson(),
      );
      for (final label in ['qa-b', 'qa-c']) {
        expect(
          () => store.photoFor(label, request(photo.id)),
          throwsA(isA<CompanionFailure>()),
        );
      }
      expect(
        () => store.reservePhoto('qa-b', upload()),
        throwsA(failure('sharing_unavailable')),
      );
      final record = store.executeSharing(
        'qa-a',
        publishRecord(group, grant, now, photos: [photo.id]),
      );
      expect(store.photoFor('qa-b', request(photo.id)).id, photo.id);
      reopen();
      expect(
        store.reservePhoto('qa-a', command).ready!.toJson(),
        photo.toJson(),
      );
      expect(store.sharedRecord('qa-b', group, record.resourceId).photoIds, [
        photo.id,
      ]);
      expect(
        () => store.reservePhoto(
          'qa-a',
          CompanionPhotoUpload.fromJson({
            ...command.toJson(),
            'jpeg_base64': base64Encode([1, 2, 3]),
          }),
        ),
        throwsA(failure('operation_conflict')),
      );
      final stop = shareCommand(SharingCommandKind.stop, group, {
        'grant_id': grant,
      });
      store.executeSharing('qa-a', stop);
      for (final label in ['qa-a', 'qa-b']) {
        expect(
          () => store.photoFor(label, request(photo.id)),
          throwsA(failure('photo_unavailable')),
        );
      }
      await store.drainPhotoDeletions(objects);
      expect(await objects.keys(), isEmpty);
      expect(
        () => store.reservePhoto('qa-a', command),
        throwsA(isA<CompanionFailure>()),
      );
    },
  );

  test('replacement removes old photo, does not permit reuse across records or grants', () async {
    final first = await save(upload());
    final second = await save(upload());
    final command = publishRecord(group, grant, now, photos: [first.id]);
    store.executeSharing('qa-a', command);
    expect(
      () => store.executeSharing(
        'qa-a',
        publishRecord(group, grant, now, photos: [first.id]),
      ),
      throwsA(failure('photo_unavailable')),
    );
    final otherGrant = store
        .executeSharing(
          'qa-a',
          shareCommand(SharingCommandKind.enable, group, {
            'goal_id': sharingId(),
          }),
        )
        .resourceId;
    expect(
      () => store.executeSharing(
        'qa-a',
        publishRecord(group, otherGrant, now, photos: [second.id]),
      ),
      throwsA(failure('photo_unavailable')),
    );
    store.executeSharing(
      'qa-a',
      publishRecord(
        group,
        grant,
        now,
        source: command.sourceId,
        revision: 1,
        photos: [second.id],
      ),
    );
    await store.drainPhotoDeletions(objects);
    expect(await objects.keys(), [second.id]);
    expect(
      () => store.photoFor('qa-b', request(first.id)),
      throwsA(failure('photo_unavailable')),
    );
    expect(store.photoFor('qa-b', request(second.id)).id, second.id);
  });

  test(
    'staged photo removal is idempotent and cannot affect other operations',
    () async {
      final command = upload();
      final photo = await save(command);
      expect(
        () => store.removePhoto(
          'qa-a',
          request(photo.id, operation: command.operationId),
        ),
        throwsA(failure('operation_conflict')),
      );
      final remove = request(photo.id, operation: sharingId());
      for (var i = 0; i < 5; i++) {
        expect(store.removePhoto('qa-a', remove), remove.toJson());
      }
      reopen();
      expect(store.removePhoto('qa-a', remove), remove.toJson());
      expect(
        () => store.reservePhoto('qa-a', command),
        throwsA(failure('photo_unavailable')),
      );
      expect(
        () => store.execute(
          'qa-a',
          PairingCommand.leave(remove.operationId!, group),
        ),
        throwsA(failure('operation_conflict')),
      );
      expect(
        () => store.executeSharing(
          'qa-a',
          shareCommand(SharingCommandKind.stop, group, {
            'grant_id': grant,
          }, operation: command.operationId),
        ),
        throwsA(failure('operation_conflict')),
      );
      await store.drainPhotoDeletions(objects);
      expect(await objects.keys(), isEmpty);
    },
  );

  test(
    'expiry removes only unattached uploads and preserves consented records',
    () async {
      final attached = await save(upload());
      await save(upload());
      final unfinished = store.reservePhoto('qa-a', upload());
      store.executeSharing(
        'qa-a',
        publishRecord(group, grant, now, photos: [attached.id]),
      );
      now = now.add(const Duration(hours: 24));
      store.expireUnattachedPhotos();
      reopen();
      await store.drainPhotoDeletions(objects);
      expect(await objects.keys(), [attached.id]);
      expect(store.photoFor('qa-b', request(attached.id)).id, attached.id);
      expect(
        () => store.reservePhoto('qa-a', unfinished.request),
        throwsA(failure('photo_unavailable')),
      );
    },
  );

  test('startup reconciliation removes crash orphans and partial files but preserves owned photos', () async {
    final kept = await save(upload());
    final orphan = sharingId();
    await objects.put(
      orphan,
      (await sanitizeCompanionPhoto(upload().bytes)).bytes,
    );
    final partial = File(
      '${objects.directory}/.pending-${sharingId()}-${sharingId()}',
    );
    await partial.writeAsString('SYNTHETIC partial');
    reopen();
    objects = await DiskObjectStore.open(objects.directory);
    await store.reconcilePhotoObjects(objects);
    expect(await objects.keys(includePending: true), [kept.id]);
    expect(await partial.exists(), false);
    expect(store.photoFor('qa-a', request(kept.id)).id, kept.id);
  });

  test('a deletion enqueued during physical cleanup is not lost', () async {
    final command = upload();
    final reservation = store.reservePhoto('qa-a', command);
    final clean = await sanitizeCompanionPhoto(command.bytes);
    store.execute('qa-b', PairingCommand.leave(sharingId(), group));
    final controlled = ControlledObjects(objects);
    var delayed = false;
    controlled.afterDelete = (key) async {
      if (delayed) return;
      delayed = true;
      await objects.put(key, clean.bytes);
      store.abortPhoto(
        reservation,
        const CompanionFailure(403, 'pair_unavailable'),
      );
    };
    await store.drainPhotoDeletions(controlled);
    expect(await objects.keys(), isEmpty);
  });

  test(
    'overlapping cleaners cannot acknowledge a newly recreated deletion job',
    () async {
      final command = upload();
      final reservation = store.reservePhoto('qa-a', command);
      final clean = await sanitizeCompanionPhoto(command.bytes);
      store.execute('qa-b', PairingCommand.leave(sharingId(), group));
      final controlled = ControlledObjects(objects);
      final reached = Completer<void>();
      final firstRelease = Completer<void>();
      final secondRelease = Completer<void>();
      var count = 0;
      controlled.afterDelete = (_) async {
        count++;
        if (count == 1) {
          await firstRelease.future;
        } else if (count == 2) {
          reached.complete();
          await secondRelease.future;
        }
      };
      final first = store.drainPhotoDeletions(controlled);
      final second = store.drainPhotoDeletions(controlled);
      await reached.future;
      firstRelease.complete();
      await first;
      await objects.put(reservation.photoId, clean.bytes);
      store.abortPhoto(
        reservation,
        const CompanionFailure(403, 'pair_unavailable'),
      );
      secondRelease.complete();
      await second;
      expect(await objects.keys(), isEmpty);
    },
  );
}
