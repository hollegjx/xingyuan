import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/sync/identity_store.dart';
import 'package:habit_checkin/features/companion/data/local_pairing_store.dart';
import 'package:habit_checkin/features/companion/data/local_publication_store.dart';
import 'package:habit_checkin/features/records/data/local_day_record_store.dart';
import 'package:habit_checkin/features/records/presentation/day_record_controller.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'support/publication_fixtures.dart';
import 'support/record_fixtures.dart';

class _SlowStore extends LocalDayRecordStore {
  _SlowStore(super.goals);
  Completer<void>? gate;
  bool fail = false;

  @override
  Future<DayRecordSnapshot> writeDraft(
    String id, {
    required String content,
    required int expectedDraftRevision,
    bool? shareWithPartner,
    RecordSharingConsent? sharingConsent,
  }) async {
    await gate?.future;
    if (fail) throw const FileSystemException('SYNTHETIC disk failure');
    return super.writeDraft(
      id,
      content: content,
      expectedDraftRevision: expectedDraftRevision,
      shareWithPartner: shareWithPartner,
      sharingConsent: sharingConsent,
    );
  }
}

void main() {
  setUpAll(tzdata.initializeTimeZones);
  late PublicationFixture f;
  late _SlowStore store;
  late DayRecordController editor;

  setUp(() async {
    f = PublicationFixture();
    await f.open();
    store = _SlowStore(f.goals);
    editor = DayRecordController(
      store: store,
      files: f.files,
      picker: StubRecordPhotoPicker(),
    );
  });
  tearDown(() async {
    editor.dispose();
    await f.close();
  });

  Future<void> open() =>
      editor.initialize(f.goalId, f.clock.day, editable: true);

  test('credential removal invalidates old requests and survives reopening without losing personal data', () async {
    await f.save(await f.draft('SYNTHETIC saved personal text'));
    final oldPairing = f.pairing;
    final oldSharing = f.sharing;
    await LocalPairingStore.forgetCredential(f.goals, isCurrent: () => false);
    expect(await f.outbox.pending(), hasLength(1));
    expect(await oldPairing.isCurrent(), true);
    await LocalPairingStore.forgetCredential(f.goals, isCurrent: () => true);
    expect(await oldPairing.isCurrent(), false);
    expect(await oldSharing.isCurrent(), false);
    await f.db.close();
    // Reopen only the pairing store: there is deliberately no paired scope.
    f.db = AppDatabase(NativeDatabase(File('${f.directory.path}/data.sqlite')));
    final lease = await IdentityStore(f.db).active();
    final goals = LocalGoalRepository(f.db, f.clock, identityLease: lease);
    final next = await LocalPairingStore.open(
      goals,
      credentialScope: f.credentialScope,
    );
    expect((await next.snapshot()).state, isNull);
    expect(next.generation, greaterThan(oldPairing.generation));
    expect(await f.db.select(f.db.sharingPublications).get(), isEmpty);
    expect(await f.db.select(f.db.recordSharingConsents).get(), isEmpty);
    final record = (await f.db.select(f.db.dayRecords).get()).single;
    expect(record.content, 'SYNTHETIC saved personal text');
    expect(record.shareWithPartner, false);
    expect(record.syncState, 'local');
  });

  for (final shared in [true, false]) {
    test(
      'draft retry preserves explicit sharing choice $shared after disk failure',
      () async {
        await open();
        await editor.setText('SYNTHETIC private choice');
        await editor.setShareDetails(!shared);
        store.fail = true;
        await editor.setShareDetails(shared);
        expect(editor.dirty, true);
        expect(editor.shareDetails, shared);
        expect(await editor.save(), false);
        expect(await f.outbox.pending(), isEmpty);
        store.fail = false;
        await editor.setText(editor.text);
        expect(editor.dirty, false);
        expect(editor.shareDetails, shared);
        expect(await editor.save(), true);
        expect(
          (await f.records.at(f.goalId, f.clock.day))!.record.shareWithPartner,
          shared,
        );
        final pending = await f.outbox.pending();
        expect(pending, shared ? hasLength(1) : isEmpty);
      },
    );
  }

  test(
    'slow text and checkbox writes preserve last choice and save once',
    () async {
      await open();
      store.gate = Completer<void>();
      final edits = [
        editor.setText('SYNTHETIC first'),
        editor.setShareDetails(true),
        editor.setText('SYNTHETIC next'),
        editor.setShareDetails(false),
        editor.setText('SYNTHETIC final'),
      ];
      final saves = List.generate(5, (_) => editor.save());
      expect(editor.text, 'SYNTHETIC final');
      expect(editor.shareDetails, false);
      store.gate!.complete();
      await Future.wait(edits);
      expect((await Future.wait(saves)).where((saved) => saved), hasLength(1));
      final record = (await f.records.at(f.goalId, f.clock.day))!.record;
      expect(record.content, 'SYNTHETIC final');
      expect(record.shareWithPartner, false);
      expect(await f.outbox.pending(), isEmpty);
    },
  );

  test(
    'pre-grant records cannot acquire a sharing checkbox on reopening',
    () async {
      await f.seed(active: false);
      await f.save(
        await f.draft('SYNTHETIC older private record', share: false),
      );
      await f.seed();
      await open();
      expect(editor.canShare, false);
      await editor.setShareDetails(true);
      expect(editor.shareDetails, false);
      await editor.setText('SYNTHETIC still private');
      expect(await editor.save(), true);
      expect(await f.outbox.pending(), isEmpty);
    },
  );

  test('credential replacement while editing preserves text but removes sharing consent', () async {
    await open();
    await editor.setText('SYNTHETIC retain local text');
    await editor.setShareDetails(true);
    await LocalPairingStore.open(f.goals, credentialScope: 'b' * 64);
    for (var i = 0; i < 100 && editor.canShare; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(editor.canShare, false);
    expect(editor.shareDetails, false);
    expect(editor.text, 'SYNTHETIC retain local text');
    expect(await editor.save(), true);
    expect(await f.db.select(f.db.sharingPublications).get(), isEmpty);
    expect(
      (await f.records.at(f.goalId, f.clock.day))!.record.content,
      'SYNTHETIC retain local text',
    );
  });
}
