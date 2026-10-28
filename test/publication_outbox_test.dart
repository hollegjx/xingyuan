import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/companion/data/companion_service.dart';
import 'package:habit_checkin/features/companion/data/local_pairing_store.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:xingyuan_core/xingyuan_core.dart';

import 'support/pairing_fixtures.dart';
import 'support/publication_fixtures.dart';
import 'support/sharing_fixtures.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);
  late PublicationFixture f;
  Matcher failure(String code) =>
      isA<CompanionServiceFailure>().having((e) => e.code, 'code', code);
  setUp(() async {
    f = PublicationFixture();
    await f.open();
  });
  tearDown(() => f.close());

  test('queue remains reactive when sharing scope is watched first', () async {
    final scopeReady = Completer<void>();
    final scope = f.sharing.watchCurrent().listen((_) {
      if (!scopeReady.isCompleted) scopeReady.complete();
    });
    await scopeReady.future;
    final queueReady = Completer<void>();
    final changed = Completer<void>();
    final queue = f.outbox.watchPending().listen((rows) {
      if (!queueReady.isCompleted) queueReady.complete();
      if (rows.isNotEmpty && !changed.isCompleted) changed.complete();
    });
    try {
      await queueReady.future;
      await f.save(await f.draft('SYNTHETIC watched'));
      await changed.future.timeout(const Duration(seconds: 1));
    } finally {
      await queue.cancel();
      await scope.cancel();
    }
  });

  test(
    'frozen text and operation survive interruption without automatic resend',
    () async {
      await f.save(await f.draft('SYNTHETIC shared text'));
      var attempt = await f.begin();
      expect(attempt.row.attempts, 1);
      attempt = await f.outbox.freeze(attempt);
      final original = attempt.command!.toJson();
      await f.reopen();
      await f.outbox.recoverInterrupted();
      final pending = (await f.outbox.pending()).single;
      expect(pending.row.status, 'uncertain');
      await expectLater(f.begin(), throwsA(failure('operation_pending')));
      final retry = await f.outbox.freeze(await f.begin(retry: true));
      expect(retry.command!.toJson(), original);
      expect(retry.row.attempts, 2);
      expect(await f.outbox.finish(attempt, f.receipt(attempt)), false);
      final revision = (await f.sharing.currentState()).cacheRevision;
      expect(await f.outbox.finish(retry, f.receipt(retry)), true);
      expect(
        (await f.sharing.currentState()).cacheRevision,
        greaterThan(revision),
      );
      expect(
        (await f.records.at(f.goalId, f.clock.day))!.record.syncState,
        'confirmed',
      );
      expect(await f.outbox.pending(), isEmpty);
      expect(
        (await f.db.select(f.db.sharingPublicationSources).get())
            .single
            .remoteRevision,
        1,
      );
      final settled =
          (await f.db.select(f.db.sharingPublications).get()).single;
      expect(settled.requestJson, isNull);
      expect(settled.content, isEmpty);
      expect(jsonDecode(settled.receiptJson!)['outcome'], 'server');
    },
  );

  test(
    'receipt never confirms a newer saved revision or erases a newer draft',
    () async {
      await f.save(await f.draft('SYNTHETIC first'));
      final first = await f.outbox.freeze(await f.begin());
      await f.save(await f.draft('SYNTHETIC second'));
      await f.draft('SYNTHETIC unsaved');
      expect(await f.outbox.finish(first, f.receipt(first)), true);
      var record = (await f.records.at(f.goalId, f.clock.day))!.record;
      expect(record.syncState, 'pending');
      expect(record.content, 'SYNTHETIC second');
      expect(record.draftText, 'SYNTHETIC unsaved');
      final second = await f.outbox.freeze(await f.begin());
      expect(second.command!.baseRevision, 1);
      expect(second.command!.text, 'SYNTHETIC second');
      await f.outbox.finish(second, f.receipt(second));
      record = (await f.records.at(f.goalId, f.clock.day))!.record;
      expect(record.syncState, 'confirmed');
      expect(record.draftText, 'SYNTHETIC unsaved');
    },
  );

  test(
    'superseded unknown body needs resolution before its successor may start',
    () async {
      await f.save(await f.draft('SYNTHETIC withdrawn'));
      final first = await f.outbox.freeze(await f.begin());
      await f.deleteRecord();
      final successor = (await f.outbox.pending()).last;
      await expectLater(
        f.outbox.begin(successor.row.operationId),
        throwsA(failure('operation_pending')),
      );
      await expectLater(
        f.outbox.freeze(first),
        throwsA(failure('publication_superseded')),
      );
      await expectLater(
        f.outbox.supersede(first),
        throwsA(failure('operation_pending')),
      );
      await f.outbox.supersede(first, resolution: f.cancelled(first));
      final removal = await f.begin();
      expect(removal.source.remoteId, isNull);
      await f.outbox.settleLocalRemoval(removal);
      expect(await f.outbox.pending(), isEmpty);
      final rows = await f.db.select(f.db.sharingPublications).get();
      expect(rows.map((r) => jsonDecode(r.receiptJson!)['outcome']), [
        'superseded',
        'local',
      ]);
      expect(
        rows.every((r) => r.requestJson == null && r.content.isEmpty),
        true,
      );
      expect(
        (await f.records.at(f.goalId, f.clock.day))!.record.syncState,
        'local',
      );
    },
  );

  test(
    'already applied old publication is acknowledged then explicitly removed',
    () async {
      await f.save(await f.draft('SYNTHETIC first'));
      final first = await f.outbox.freeze(await f.begin());
      await f.deleteRecord();
      await f.outbox.finish(first, f.receipt(first));
      final removal = await f.outbox.freeze(await f.begin());
      expect(removal.command!.recordId, sharingId(50));
      await f.outbox.finish(removal, f.receipt(removal));
      final source =
          (await f.db.select(f.db.sharingPublicationSources).get()).single;
      expect(source.remoteId, isNull);
      expect(source.remoteRevision, 0);
      expect(
        (await f.records.at(f.goalId, f.clock.day))!.record.deletedAt,
        isNotNull,
      );
    },
  );

  test('photo receipt persists with original upload ID and server reencoded digest', () async {
    await f.save(await f.addPhoto(await f.draft('SYNTHETIC picture')));
    var first = await f.begin();
    final photo = (await f.outbox.photos(first)).single;
    await expectLater(
      f.outbox.freeze(first),
      throwsA(failure('photo_unavailable')),
    );
    final request = await f.upload(first, photo);
    await expectLater(
      f.outbox.acceptPhoto(
        first,
        request,
        f.photoReceipt(request, author: testPartnerId),
      ),
      throwsA(failure('invalid_response')),
    );
    final receipt = f.photoReceipt(request);
    expect(receipt.photo.sha256, isNot(photo.photo.sha256));
    await f.outbox.acceptPhoto(first, request, receipt);
    await f.reopen();
    await f.outbox.recoverInterrupted();
    first = await f.begin(retry: true);
    final restored = (await f.outbox.photos(first)).single;
    expect(restored.row.uploadOperationId, request.operationId);
    expect(restored.remote!.id, receipt.photo.id);
    await expectLater(
      f.outbox.acceptPhoto(
        first,
        request,
        f.photoReceipt(request, remote: sharingId(71)),
      ),
      throwsA(failure('invalid_response')),
    );
    first = await f.outbox.freeze(first);
    expect(first.command!.photoIds, [receipt.photo.id]);
    await f.outbox.finish(first, f.receipt(first));
    expect(await f.db.select(f.db.sharingPublicationPhotos).get(), isEmpty);
    expect(
      (await f.records.at(f.goalId, f.clock.day))!.savedPhotos,
      hasLength(1),
    );
    expect(await f.files.read(photo.photo), isNotEmpty);
  });

  test('started upload without frozen record can be superseded and releases only detached files', () async {
    await f.save(await f.addPhoto(await f.draft('SYNTHETIC old photo')));
    final first = await f.begin();
    final photo = (await f.outbox.photos(first)).single.photo;
    await f.deleteRecord();
    await f.files.clean(f.records);
    expect(await f.files.read(photo), isNotEmpty);
    await f.outbox.supersede(first);
    await f.files.clean(f.records);
    expect(await f.db.select(f.db.recordPhotos).get(), isEmpty);
    await f.outbox.settleLocalRemoval(await f.begin());
    expect(await f.outbox.pending(), isEmpty);
  });

  test(
    'late failures cannot regress a newer attempt or newer local saved record',
    () async {
      await f.save(await f.draft('SYNTHETIC first'));
      final first = await f.outbox.freeze(await f.begin());
      await f.outbox.fail(
        first,
        const CompanionServiceFailure('timeout', outcomeUnknown: true),
      );
      final retry = await f.begin(retry: true);
      expect(
        await f.outbox.fail(first, const CompanionServiceFailure('network')),
        false,
      );
      await f.save(await f.draft('SYNTHETIC next'));
      await f.outbox.fail(
        retry,
        const CompanionServiceFailure('PRIVATE ERROR', outcomeUnknown: true),
      );
      expect((await f.outbox.pending()).first.row.errorCode, 'unavailable');
      expect(
        (await f.records.at(f.goalId, f.clock.day))!.record.syncState,
        'pending',
      );
    },
  );

  test(
    'withdrawal rejects stale attempts without changing personal data',
    () async {
      await f.save(await f.draft('SYNTHETIC retained'));
      final first = await f.outbox.freeze(await f.begin());
      await f.seed(active: false);
      expect(await f.outbox.isCurrent(first), false);
      expect(await f.outbox.finish(first, f.receipt(first)), false);
      expect(await f.outbox.pending(), isEmpty);
      final own = (await f.records.at(f.goalId, f.clock.day))!.record;
      expect(own.content, 'SYNTHETIC retained');
      expect(own.shareWithPartner, false);
      expect(own.syncState, 'local');
    },
  );

  test(
    'cancelled head can settle for a successor but can never resend',
    () async {
      await f.save(await f.draft('SYNTHETIC cancelled'));
      final first = await f.outbox.freeze(await f.begin());
      await f.outbox.fail(
        first,
        const CompanionServiceFailure('publication_cancelled'),
      );
      await f.reopen();
      final cancelled = (await f.outbox.pending()).single;
      await expectLater(
        f.begin(retry: true),
        throwsA(failure('publication_cancelled')),
      );
      await f.deleteRecord();
      await f.outbox.supersede(cancelled, resolution: f.cancelled(cancelled));
      await f.outbox.settleLocalRemoval(await f.begin());
      expect(await f.outbox.pending(), isEmpty);
    },
  );

  test('credential replacement rejects all old attempt operations', () async {
    await f.save(await f.draft('SYNTHETIC retained'));
    final first = await f.outbox.freeze(await f.begin());
    await LocalPairingStore.open(f.goals, credentialScope: 'b' * 64);
    expect(await f.outbox.isCurrent(first), false);
    await expectLater(
      f.outbox.finish(first, f.receipt(first)),
      throwsA(failure('discarded')),
    );
    expect(await f.db.select(f.db.sharingPublications).get(), isEmpty);
    final own = (await f.records.at(f.goalId, f.clock.day))!.record;
    expect(own.content, 'SYNTHETIC retained');
    expect(own.shareWithPartner, false);
  });

  SharingCommand removal() =>
      SharingCommand.fromJson(SharingCommandKind.remove, {
        'protocol': companionProtocol,
        'operation_id': sharingId(101),
        'group_id': testGroupId,
        'record_id': sharingId(50),
      });

  Future<void> published() async {
    await f.goals.setCompleted(f.goalId, true, expectedDay: f.clock.day);
    await f.save(await f.addPhoto(await f.draft('SYNTHETIC saved')));
    var first = await f.begin();
    final photo = (await f.outbox.photos(first)).single;
    final upload = await f.upload(first, photo);
    await f.outbox.acceptPhoto(first, upload, f.photoReceipt(upload));
    first = await f.outbox.freeze(first);
    await f.outbox.finish(first, f.receipt(first));
    await f.seed(feed: [syntheticSharedRecord(id: sharingId(50))]);
  }

  test('manual deletion cannot overtake unresolved publications', () async {
    await published();
    await f.save(await f.draft('SYNTHETIC newer'));
    await expectLater(
      f.sharing.enqueue(removal()),
      throwsA(failure('operation_pending')),
    );
    expect((await f.outbox.pending()).single.row.content, 'SYNTHETIC newer');
    expect(await f.db.select(f.db.sharingCommands).get(), isEmpty);
  });

  test('pending feed deletion blocks republishing; receipt preserves personal text and photos', () async {
    await published();
    await f.sharing.enqueue(removal());
    await f.save(await f.draft('SYNTHETIC kept locally', share: false));
    expect(await f.outbox.pending(), isEmpty);
    final removing = await f.sharing.begin(removal().operationId);
    await f.sharing.finish(
      removing,
      SharingReceipt.fromJson({
        'protocol': companionProtocol,
        'operation_id': removal().operationId,
        'group_id': testGroupId,
        'resource_id': sharingId(50),
        'revision': 0,
      }, command: removal()),
    );
    expect(await f.db.select(f.db.sharingPublicationSources).get(), isEmpty);
    await f.save(await f.draft('SYNTHETIC still private', share: false));
    expect(await f.outbox.pending(), isEmpty);
    final own = (await f.records.at(f.goalId, f.clock.day))!;
    expect(own.record.content, 'SYNTHETIC still private');
    expect(own.savedPhotos, hasLength(1));
    expect(own.record.syncState, 'local');
    expect(await f.files.read(own.savedPhotos.single), isNotEmpty);
  });

  test('remote disappearance invalidates queued updates and share consent, not own content', () async {
    await published();
    await f.save(await f.draft('SYNTHETIC pending update'));
    var update = await f.begin();
    for (final photo in await f.outbox.photos(update)) {
      final upload = await f.upload(update, photo);
      await f.outbox.acceptPhoto(update, upload, f.photoReceipt(upload));
    }
    update = await f.outbox.freeze(update);
    await f.sharing.forgetRecord(sharingId(50));
    expect(await f.outbox.pending(), isEmpty);
    expect(await f.outbox.isCurrent(update), false);
    expect(await f.outbox.finish(update, f.receipt(update)), false);
    final own = (await f.records.at(f.goalId, f.clock.day))!;
    expect(own.record.content, 'SYNTHETIC pending update');
    expect(own.record.shareWithPartner, false);
    expect(own.savedPhotos, hasLength(1));
  });

  test('settling completion-only publication retains captured completion eligibility', () async {
    await f.goals.setCompleted(f.goalId, true, expectedDay: f.clock.day);
    final first = await f.outbox.freeze(await f.begin());
    await f.outbox.finish(first, f.receipt(first));
    await f.save(await f.draft('SYNTHETIC personal note', share: false));
    final second = (await f.outbox.pending()).single;
    expect(second.row.completedAt, first.row.completedAt);
    expect(second.row.shareDetails, false);
    expect(second.row.content, isEmpty);
  });
}
