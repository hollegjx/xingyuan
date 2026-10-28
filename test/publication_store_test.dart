import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/sync/identity_store.dart';
import 'package:habit_checkin/data/sync/sync_identity.dart';
import 'package:habit_checkin/features/companion/data/local_pairing_store.dart';
import 'package:habit_checkin/features/companion/data/local_sharing_store.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:habit_checkin/features/records/data/local_day_record_store.dart';
import 'package:habit_checkin/features/records/data/record_photo.dart';
import 'package:habit_checkin/features/records/data/record_photo_files.dart';
import 'package:image/image.dart' as img;
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:uuid/uuid.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

import 'support/test_clock.dart';

String id(int n) => '00000000-0000-4000-8000-${n.toString().padLeft(12, '0')}';

void main() {
  late Directory directory;
  late AppDatabase db;
  late TestClock clock;
  late LocalGoalRepository goals;
  late LocalDayRecordStore records;
  late LocalPairingStore pairing;
  late LocalSharingStore sharing;
  late int goalId;
  late String globalId;
  late String enabledAt;

  Future<void> bind() async {
    final lease = await IdentityStore(db).active();
    goals = LocalGoalRepository(db, clock, identityLease: lease);
    records = LocalDayRecordStore(goals);
    pairing = await LocalPairingStore.open(goals, credentialScope: 'a' * 64);
  }

  Future<void> seed({int grant = 4, bool active = true}) async {
    final request = SharedPageRequest.fromJson({
      'protocol': companionProtocol,
      'group_id': id(3),
      'before_sequence': null,
      'revision': null,
    });
    final previous = (await sharing.snapshot()).state;
    final revision = (previous.serverRevision ?? 0) + 1;
    await sharing.acceptSnapshot(
      grantPages: [
        SharingGrants.fromJson({
          'protocol': companionProtocol,
          'group_id': id(3),
          'revision': revision,
          'next_before': null,
          'grants': [
            if (active)
              {
                'id': id(grant),
                'goal_id': globalId,
                'sequence': grant,
                'enabled_at': enabledAt,
              },
          ],
        }, request: request),
      ],
      feedPages: [
        SharedFeedPage.fromJson({
          'protocol': companionProtocol,
          'group_id': id(3),
          'revision': revision,
          'next_before': null,
          'records': <Object?>[],
        }, request: request),
      ],
      expectedRevision: previous.cacheRevision,
    );
  }

  Future<List<Map<String, Object?>>> queue() async =>
      (await db
              .customSelect(
                'SELECT * FROM sharing_publications ORDER BY sequence',
              )
              .get())
          .map((r) => r.data)
          .toList();

  Future<DayRecordSnapshot> save(DayRecordSnapshot draft) => records.save(
    draft.record.id,
    operationId: const Uuid().v4(),
    expectedRevision: draft.record.revision,
    expectedDraftRevision: draft.record.draftRevision,
  );

  Future<DayRecordSnapshot> draftWithConsent({
    String text = 'SYNTHETIC shared',
  }) async {
    final draft = await records.beginDraft(goalId, clock.day);
    return records.writeDraft(
      draft.record.id,
      content: text,
      expectedDraftRevision: draft.record.draftRevision,
      shareWithPartner: true,
      sharingConsent: await records.publications.available(goalId),
    );
  }

  Future<void> interrupt() => db.customStatement(
    "UPDATE sharing_publications SET status='uncertain', attempts=1, error_code='interrupted'",
  );

  setUpAll(tzdata.initializeTimeZones);
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('publication-');
    db = AppDatabase(NativeDatabase(File('${directory.path}/data.sqlite')));
    clock = TestClock()..setDay(2026, 10, 21);
    enabledAt = clock.instant.toIso8601String();
    await bind();
    goalId = await goals.create(
      const GoalDraft(title: 'SYNTHETIC personal', kind: GoalKind.habit),
    );
    globalId = (await db.select(db.goals).get()).single.globalId;
    await pairing.acceptState(
      PairingState.fromJson({
        'protocol': companionProtocol,
        'member_id': id(1),
        'invitation': null,
        'group': {'id': id(3), 'partner_id': id(2), 'paired_at': enabledAt},
      }),
      expectedRevision: 0,
    );
    sharing = await LocalSharingStore.open(pairing);
    await seed();
    clock.instant = clock.instant.add(const Duration(minutes: 1));
  });
  tearDown(() async {
    await db.close();
    await directory.delete(recursive: true);
  });

  test(
    'completion is durably queued once without private record details',
    () async {
      var draft = await records.beginDraft(goalId, clock.day);
      draft = await records.writeDraft(
        draft.record.id,
        content: 'SYNTHETIC secret',
        expectedDraftRevision: draft.record.draftRevision,
      );
      await save(draft);
      for (var i = 0; i < 5; i++) {
        await goals.setCompleted(goalId, true, expectedDay: clock.day);
      }
      final before = await queue();
      expect(before, hasLength(1));
      expect(before.single['content'], '');
      expect(before.single['share_details'], 0);
      expect(jsonEncode(before), isNot(contains('SYNTHETIC secret')));
      await db.close();
      db = AppDatabase(NativeDatabase(File('${directory.path}/data.sqlite')));
      await bind();
      expect(await queue(), before);
      expect(
        (await records.at(goalId, clock.day))!.record.content,
        'SYNTHETIC secret',
      );
    },
  );

  test('a bare saved boolean is not a scoped sharing consent', () async {
    final draft = await records.beginDraft(goalId, clock.day);
    await expectLater(
      records.writeDraft(
        draft.record.id,
        content: 'SYNTHETIC secret',
        shareWithPartner: true,
        expectedDraftRevision: draft.record.draftRevision,
      ),
      throwsA(isA<RecordRuleException>()),
    );
    expect(
      (await records.at(goalId, clock.day))!.record.draftShareWithPartner,
      false,
    );
  });

  test('private goal and no pairing never enqueue personal content', () async {
    await seed(active: false);
    await goals.setCompleted(goalId, true, expectedDay: clock.day);
    final draft = await records.beginDraft(goalId, clock.day);
    await save(
      await records.writeDraft(
        draft.record.id,
        content: 'SYNTHETIC secret',
        expectedDraftRevision: draft.record.draftRevision,
      ),
    );
    expect(await queue(), isEmpty);
    await pairing.forgetRemote();
    await goals.setCompleted(goalId, false, expectedDay: clock.day);
    await goals.setCompleted(goalId, true, expectedDay: clock.day);
    expect(await queue(), isEmpty);
  });

  test(
    'draft consent persists and save is idempotent in the same transaction',
    () async {
      final draft = await draftWithConsent();
      final operation = const Uuid().v4();
      await db.close();
      db = AppDatabase(NativeDatabase(File('${directory.path}/data.sqlite')));
      await bind();
      for (var i = 0; i < 5; i++) {
        await records.save(
          draft.record.id,
          operationId: operation,
          expectedRevision: draft.record.revision,
          expectedDraftRevision: draft.record.draftRevision,
        );
      }
      final rows = await queue();
      expect(rows, hasLength(1));
      expect(rows.single['content'], 'SYNTHETIC shared');
      expect(rows.single['share_details'], 1);
      expect(rows.single['completed_at'], isNull);
      expect(
        (await records.at(goalId, clock.day))!.record.syncState,
        'pending',
      );
    },
  );

  test(
    'unchanged grant refresh preserves draft consent and queued snapshots',
    () async {
      var draft = await draftWithConsent();
      await seed();
      await save(draft);
      final before = await queue();
      await seed();
      expect(await queue(), before);
      draft = await records.beginDraft(goalId, clock.day);
      expect(draft.record.draftShareWithPartner, true);
      expect(
        await records.publications.recordConsent(draft.record, 'draft'),
        isNotNull,
      );
    },
  );

  test(
    'goal sharing never backfills old completion or pre-grant drafts',
    () async {
      await seed(active: false);
      final old = await records.beginDraft(goalId, clock.day);
      await goals.setCompleted(goalId, true, expectedDay: clock.day);
      clock.instant = clock.instant.add(const Duration(minutes: 1));
      enabledAt = clock.instant.toIso8601String();
      await seed(grant: 5);
      expect(await queue(), isEmpty);
      await expectLater(
        records.writeDraft(
          old.record.id,
          content: 'SYNTHETIC old',
          expectedDraftRevision: old.record.draftRevision,
          shareWithPartner: true,
          sharingConsent: await records.publications.available(goalId),
        ),
        throwsA(isA<RecordRuleException>()),
      );
      await save(
        await records.writeDraft(
          old.record.id,
          content: 'SYNTHETIC private edit',
          expectedDraftRevision: old.record.draftRevision,
        ),
      );
      expect(await queue(), isEmpty);
    },
  );

  for (final savedFirst in [false, true]) {
    test(
      'revoking and renewing grant does not reuse ${savedFirst ? 'saved' : 'draft'} consent',
      () async {
        var draft = await draftWithConsent();
        if (savedFirst) {
          await save(draft);
          draft = await records.beginDraft(goalId, clock.day);
        }
        final oldConsent = await records.publications.available(goalId);
        await seed(active: false);
        await seed(grant: 5);
        expect(await queue(), isEmpty);
        await expectLater(
          records.writeDraft(
            draft.record.id,
            content: 'SYNTHETIC stale',
            expectedDraftRevision: draft.record.draftRevision,
            shareWithPartner: true,
            sharingConsent: oldConsent,
          ),
          throwsA(isA<RecordRuleException>()),
        );
        final local = await save(draft);
        expect(local.record.content, 'SYNTHETIC shared');
        expect(local.record.shareWithPartner, false);
        expect(await queue(), isEmpty);
      },
    );
  }

  test('credential rotation clears queued content without changing personal content', () async {
    final saved = await save(await draftWithConsent());
    final before = saved.record.content;
    await LocalPairingStore.open(goals, credentialScope: 'b' * 64);
    expect(await queue(), isEmpty);
    expect(await db.select(db.recordSharingConsents).get(), isEmpty);
    expect(await db.select(db.sharingPublicationSources).get(), isEmpty);
    expect((await records.at(goalId, clock.day))!.record.content, before);
    final reopened = await records.beginDraft(goalId, clock.day);
    expect(reopened.record.draftShareWithPartner, false);
  });

  test('unfinished stop and leave suppress new publications', () async {
    await sharing.enqueue(
      SharingCommand.fromJson(SharingCommandKind.stop, {
        'protocol': companionProtocol,
        'group_id': id(3),
        'operation_id': const Uuid().v4(),
        'grant_id': id(4),
      }),
    );
    await goals.setCompleted(goalId, true, expectedDay: clock.day);
    expect(await queue(), isEmpty);
    await db.customStatement('DELETE FROM sharing_commands');
    await pairing.start(
      PairingCommand.fromJson(PairingCommandKind.leave, {
        'protocol': companionProtocol,
        'operation_id': const Uuid().v4(),
        'group_id': id(3),
      }),
    );
    await goals.setCompleted(goalId, false, expectedDay: clock.day);
    await goals.setCompleted(goalId, true, expectedDay: clock.day);
    expect(await queue(), isEmpty);
  });

  test(
    'unsent completion undo cancels publication but keeps private record',
    () async {
      var draft = await records.beginDraft(goalId, clock.day);
      draft = await records.writeDraft(
        draft.record.id,
        content: 'SYNTHETIC private',
        expectedDraftRevision: draft.record.draftRevision,
      );
      await save(draft);
      await goals.setCompleted(goalId, true, expectedDay: clock.day);
      await goals.setCompleted(goalId, false, expectedDay: clock.day);
      expect(await queue(), isEmpty);
      expect(
        (await records.at(goalId, clock.day))!.record.content,
        'SYNTHETIC private',
      );
    },
  );

  test(
    'completion undo keeps independently shared record and stable source',
    () async {
      await save(await draftWithConsent());
      final source = (await queue()).single['source_id'];
      await goals.setCompleted(goalId, true, expectedDay: clock.day);
      expect((await queue()).single['completed_at'], isNotNull);
      await goals.setCompleted(goalId, false, expectedDay: clock.day);
      final row = (await queue()).single;
      expect(row['source_id'], source);
      expect(row['content'], 'SYNTHETIC shared');
      expect(row['completed_at'], isNull);
      expect(row['kind'], 'publish');
    },
  );

  test(
    'withdrawing never-attempted details drops the private payload',
    () async {
      await save(await draftWithConsent());
      var draft = await records.beginDraft(goalId, clock.day);
      draft = await records.writeDraft(
        draft.record.id,
        content: 'SYNTHETIC now private',
        expectedDraftRevision: draft.record.draftRevision,
        shareWithPartner: false,
      );
      final local = await save(draft);
      expect(await queue(), isEmpty);
      expect(local.record.syncState, 'local');
      expect(local.record.content, 'SYNTHETIC now private');
    },
  );

  test('unknown attempt is immutable and withdrawal follows it', () async {
    final saved = await save(await draftWithConsent());
    await interrupt();
    final head = (await queue()).single;
    await records.delete(
      saved.record.id,
      operationId: const Uuid().v4(),
      expectedRevision: saved.record.revision,
    );
    final rows = await queue();
    expect(rows, hasLength(2));
    expect(rows.first, head);
    expect(rows.last['kind'], 'remove');
    expect(rows.last['content'], '');
    expect(rows.last['source_id'], head['source_id']);
  });

  test(
    'photo payload survives local delete while an upload is unresolved',
    () async {
      final files = RecordPhotoFiles(directory, goals.owner);
      final photo = await files.write(
        await sanitizeRecordPhoto(
          img.encodeJpg(img.Image(width: 3, height: 2)),
        ),
      );
      var draft = await draftWithConsent(text: '');
      draft = await records.addPhoto(
        draft.record.id,
        photo: photo,
        expectedDraftRevision: draft.record.draftRevision,
      );
      final saved = await save(draft);
      await interrupt();
      final pinned =
          (await db.select(db.sharingPublicationPhotos).get()).single;
      await records.delete(
        saved.record.id,
        operationId: const Uuid().v4(),
        expectedRevision: saved.record.revision,
      );
      await files.clean(records);
      expect(await records.unreferencedPhotos(), isEmpty);
      expect(await files.read(saved.savedPhotos.single), isNotEmpty);
      await db.close();
      db = AppDatabase(NativeDatabase(File('${directory.path}/data.sqlite')));
      await bind();
      expect(
        (await db.select(db.sharingPublicationPhotos).get()).single,
        pinned,
      );
      expect(await files.read(saved.savedPhotos.single), isNotEmpty);
      sharing = await LocalSharingStore.open(pairing);
      await seed(active: false);
      await files.clean(records);
      expect(await db.select(db.recordPhotos).get(), isEmpty);
      expect(
        await File('${files.directory.path}/${photo.filename}').exists(),
        false,
      );
    },
  );

  for (final mutation in ['complete', 'save']) {
    test('outbox failure rolls back the $mutation and keeps editable draft', () async {
      final draft = await draftWithConsent();
      final original = (await db.select(db.dayRecords).get()).single;
      await db.customStatement(
        "CREATE TRIGGER fail_publication BEFORE INSERT ON sharing_publications "
        "BEGIN SELECT RAISE(ABORT, 'SYNTHETIC storage failure'); END",
      );
      await expectLater(
        mutation == 'complete'
            ? goals.setCompleted(goalId, true, expectedDay: clock.day)
            : save(draft),
        throwsA(anything),
      );
      expect(await queue(), isEmpty);
      expect(await db.select(db.sharingPublicationSources).get(), isEmpty);
      expect(await db.select(db.checkIns).get(), isEmpty);
      expect((await db.select(db.dayRecords).get()).single, original);
    });
  }

  test('identity changes reject old record and outbox writes', () async {
    final draft = await draftWithConsent();
    final identities = IdentityStore(db);
    await identities.finish(
      await identities.begin(SyncIdentity.account(id(88))),
    );
    await expectLater(save(draft), throwsA(isA<StaleIdentity>()));
    await expectLater(
      goals.setCompleted(goalId, true, expectedDay: clock.day),
      throwsA(isA<StaleIdentity>()),
    );
    expect(await queue(), isEmpty);
  });

  test(
    'midnight and time-zone changes keep each source on its recorded day',
    () async {
      final draft = await draftWithConsent();
      final originalDay = clock.day;
      clock.location = tz.getLocation('America/Los_Angeles');
      clock.setDay(2026, 10, 22);
      await save(draft);
      await goals.setCompleted(goalId, true, expectedDay: clock.day);
      final rows = await db.select(db.sharingPublicationSources).get();
      expect(rows.map((r) => r.day).toSet(), {originalDay.key, clock.day.key});
      expect(rows.map((r) => r.id).toSet(), hasLength(2));
    },
  );

  test(
    'withdrawn grant clears obsolete consent indicators and pending state',
    () async {
      final saved = await save(await draftWithConsent());
      await records.beginDraft(goalId, clock.day);
      await seed(active: false);
      final row = (await records.at(goalId, clock.day))!.record;
      expect(row.shareWithPartner, false);
      expect(row.draftShareWithPartner, false);
      expect(row.syncState, 'local');
      expect(row.content, saved.record.content);
      expect(row.draftText, saved.record.content);
    },
  );

  test('draft edits never leak into the captured saved details', () async {
    final saved = await save(await draftWithConsent());
    final draft = await records.beginDraft(goalId, clock.day);
    await records.writeDraft(
      draft.record.id,
      content: 'SYNTHETIC unsaved secret',
      expectedDraftRevision: draft.record.draftRevision,
      shareWithPartner: false,
    );
    await goals.setCompleted(goalId, true, expectedDay: clock.day);
    expect((await queue()).single['content'], saved.record.content);
    expect(
      jsonEncode(await queue()),
      isNot(contains('SYNTHETIC unsaved secret')),
    );
  });

  test(
    'a fast device clock cannot turn a pre-grant draft into shareable content',
    () async {
      await seed(active: false);
      final old = await records.beginDraft(goalId, clock.day);
      // Server authorization happened later in reality but its clock is behind.
      await seed(grant: 5);
      await expectLater(
        records.writeDraft(
          old.record.id,
          content: 'SYNTHETIC history',
          expectedDraftRevision: old.record.draftRevision,
          shareWithPartner: true,
          sharingConsent: await records.publications.available(goalId),
        ),
        throwsA(isA<RecordRuleException>()),
      );
    },
  );

  test(
    'a fast device clock cannot backfill a pre-grant completion on record save',
    () async {
      await seed(active: false);
      await goals.setCompleted(goalId, true, expectedDay: clock.day);
      await seed(grant: 5);
      final draft = await records.beginDraft(goalId, clock.day);
      await save(
        await records.writeDraft(
          draft.record.id,
          content: 'SYNTHETIC private',
          expectedDraftRevision: draft.record.draftRevision,
        ),
      );
      expect(await queue(), isEmpty);
    },
  );
}
