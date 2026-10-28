import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/sync/identity_store.dart';
import 'package:habit_checkin/data/sync/sync_identity.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:habit_checkin/features/records/data/local_day_record_store.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:uuid/uuid.dart';

import 'support/test_clock.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);
  late AppDatabase db;
  late TestClock clock;
  late LocalGoalRepository goals;
  late LocalDayRecordStore store;
  late int goal;

  Future<void> bind() async {
    final lease = await IdentityStore(db).active();
    goals = LocalGoalRepository(
      db,
      clock,
      owner: lease.identity.owner,
      identityLease: lease,
    );
    store = LocalDayRecordStore(goals);
  }

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    clock = TestClock()..setDay(2026, 10, 21);
    await bind();
    goal = await goals.create(
      const GoalDraft(
        title: 'TEST record',
        kind: GoalKind.habit,
        weekdays: 127,
      ),
    );
  });
  tearDown(() => db.close());

  Future<DayRecordSnapshot> draft(String text) async {
    final current = await store.beginDraft(goal, clock.day);
    return store.writeDraft(
      current.record.id,
      content: text,
      expectedDraftRevision: current.record.draftRevision,
    );
  }

  Future<DayRecordSnapshot> save(
    DayRecordSnapshot value, {
    String? operationId,
  }) => store.save(
    value.record.id,
    operationId: operationId ?? const Uuid().v4(),
    expectedRevision: value.record.revision,
    expectedDraftRevision: value.record.draftRevision,
  );

  test(
    'record, completion, undo and record deletion remain independent',
    () async {
      final value = await save(await draft('TEST a different plan today'));
      expect(value.record.shareWithPartner, isFalse);
      expect(value.record.syncState, 'local');
      expect(await db.select(db.checkIns).get(), isEmpty);
      await goals.setCompleted(goal, true, expectedDay: clock.day);
      await goals.setCompleted(goal, false, expectedDay: clock.day);
      expect(
        (await store.savedOn(clock.day)).single.record.content,
        'TEST a different plan today',
      );
      await goals.setCompleted(goal, true, expectedDay: clock.day);
      await store.delete(
        value.record.id,
        operationId: const Uuid().v4(),
        expectedRevision: value.record.revision,
      );
      expect(await store.savedOn(clock.day), isEmpty);
      expect((await db.select(db.checkIns).get()).single.completed, isTrue);
      expect((await db.select(db.dayRecords).get()).single.content, isEmpty);
    },
  );

  test('draft edits never replace saved text before explicit save', () async {
    await save(await draft('TEST saved'));
    final editing = await draft('TEST not saved');
    expect(editing.record.draftText, 'TEST not saved');
    expect(
      (await store.savedOn(clock.day)).single.record.content,
      'TEST saved',
    );
    final reopened = await store.beginDraft(goal, clock.day);
    expect(reopened.record.draftText, 'TEST not saved');
    expect(reopened.record.shareWithPartner, isFalse);
  });

  test('five repeated saves apply once and late retries cannot overwrite newer edits', () async {
    final value = await draft('TEST first');
    final operation = const Uuid().v4();
    final results = await Future.wait(
      List.generate(5, (_) => save(value, operationId: operation)),
    );
    expect(results.map((item) => item.record.revision).toSet(), {1});
    final next = await draft('TEST second draft');
    await save(value, operationId: operation);
    expect(
      (await store.beginDraft(goal, clock.day)).record.draftText,
      'TEST second draft',
    );
    final saved = await save(next);
    await expectLater(
      save(value, operationId: operation),
      throwsA(isA<RecordConflict>()),
    );
    expect(saved.record.revision, 2);
  });

  test('stale draft writer is rejected without erasing a later edit', () async {
    final first = await draft('TEST first');
    final second = await store.writeDraft(
      first.record.id,
      content: 'TEST later',
      expectedDraftRevision: first.record.draftRevision,
    );
    await expectLater(
      store.writeDraft(
        first.record.id,
        content: 'TEST stale',
        expectedDraftRevision: first.record.draftRevision,
      ),
      throwsA(isA<RecordConflict>()),
    );
    await expectLater(save(first), throwsA(isA<RecordConflict>()));
    expect(
      (await store.beginDraft(goal, clock.day)).record.draftText,
      second.record.draftText,
    );
  });

  test(
    'grapheme limits preserve Unicode, line breaks and invalid drafts',
    () async {
      final text = '${'👨‍👩‍👧‍👦' * 498}\ne\u0301';
      expect((await save(await draft(text))).record.content, text);
      final tooLong = await draft('$text!');
      await expectLater(save(tooLong), throwsA(isA<RecordRuleException>()));
      expect(
        (await store.beginDraft(goal, clock.day)).record.draftText,
        '$text!',
      );
      await expectLater(
        save(await draft(' \n ')),
        throwsA(isA<RecordRuleException>()),
      );
    },
  );

  test(
    'photo draft limit, removal, save and deletion retain cleanup metadata',
    () async {
      var value = await draft('');
      for (var slot = 0; slot < 3; slot++) {
        value = await store.addPhoto(
          value.record.id,
          photo: RecordPhotoInput(
            id: const Uuid().v4(),
            width: 1600,
            height: 900,
            byteCount: 1024,
            sha256: 'a' * 64,
          ),
          expectedDraftRevision: value.record.draftRevision,
        );
      }
      await expectLater(
        store.addPhoto(
          value.record.id,
          photo: RecordPhotoInput(
            id: const Uuid().v4(),
            width: 10,
            height: 10,
            byteCount: 100,
            sha256: 'b' * 64,
          ),
          expectedDraftRevision: value.record.draftRevision,
        ),
        throwsA(isA<RecordRuleException>()),
      );
      final removed = value.draftPhotos[1].id;
      value = await store.removePhoto(
        value.record.id,
        removed,
        expectedDraftRevision: value.record.draftRevision,
      );
      expect(value.draftPhotos.map((photo) => photo.draftPosition), [0, 1]);
      value = await save(value);
      expect(value.savedPhotos, hasLength(2));
      expect((await store.unreferencedPhotos()).single.id, removed);
      await store.delete(
        value.record.id,
        operationId: const Uuid().v4(),
        expectedRevision: value.record.revision,
      );
      expect(await store.unreferencedPhotos(), hasLength(3));
    },
  );

  test(
    'identity transition invalidates both reads and pending writes',
    () async {
      final value = await draft('TEST private');
      final identities = IdentityStore(db);
      final intent = await identities.begin(
        SyncIdentity.account('55555555-5555-4555-8555-555555555555'),
      );
      await expectLater(
        store.savedOn(clock.day),
        throwsA(isA<StaleIdentity>()),
      );
      await expectLater(save(value), throwsA(isA<StaleIdentity>()));
      await identities.finish(intent);
      final oldStore = store;
      await bind();
      expect(await store.savedOn(clock.day), isEmpty);
      await expectLater(
        store.beginDraft(goal, clock.day),
        throwsA(isA<RecordRuleException>()),
      );
      await identities.finish(await identities.begin(SyncIdentity.guest));
      await expectLater(
        oldStore.savedOn(clock.day),
        throwsA(isA<StaleIdentity>()),
      );
    },
  );

  test(
    'draft survives process reopen and stays on its original local date',
    () async {
      await db.close();
      final directory = await Directory.systemTemp.createTemp('record-draft-');
      final file = File('${directory.path}/records.sqlite');
      addTearDown(() => directory.delete(recursive: true));
      db = AppDatabase(NativeDatabase(file));
      clock.location = tz.getLocation('America/Los_Angeles');
      clock.setDay(2026, 10, 20, hour: 23, minute: 59);
      await bind();
      goal = await goals.create(
        const GoalDraft(
          title: 'TEST midnight',
          kind: GoalKind.habit,
          weekdays: 127,
        ),
      );
      final originalDay = clock.day;
      final value = await draft('TEST retained across restart');
      await db.close();
      db = AppDatabase(NativeDatabase(file));
      clock.location = tz.getLocation('Asia/Shanghai');
      await bind();
      final reopened = await store.beginDraft(goal, originalDay);
      expect(reopened.record.draftText, value.record.draftText);
      await save(reopened);
      expect(
        (await store.savedOn(originalDay)).single.record.zone,
        'America/Los_Angeles',
      );
      expect(await store.savedOn(clock.day), isEmpty);
    },
  );
}
