import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/sync/identity_store.dart';
import 'package:habit_checkin/features/analysis/data/local_day_analysis_store.dart';
import 'package:habit_checkin/features/assistant/data/assistant_service.dart';
import 'package:habit_checkin/features/assistant/data/local_memory_store.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:habit_checkin/features/records/data/local_day_record_store.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:uuid/uuid.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

import 'support/sync_fixtures.dart';
import 'support/test_clock.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);
  late AppDatabase db;
  late TestClock clock;
  late LocalGoalRepository goals;
  late LocalDayAnalysisStore store;
  late LocalDayRecordStore records;
  Future<void> bind() async {
    final lease = await IdentityStore(db).active();
    goals = LocalGoalRepository(
      db,
      clock,
      owner: lease.identity.owner,
      identityLease: lease,
    );
    store = LocalDayAnalysisStore(goals);
    records = LocalDayRecordStore(goals);
  }

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    clock = TestClock()..setDay(2026, 10, 21);
    await bind();
  });
  tearDown(() => db.close());
  Future<int> goal(String title) => goals.create(
    GoalDraft(
      title: title,
      kind: GoalKind.habit,
      startMinute: 1200,
      durationMinutes: 20,
    ),
  );
  DayAnalysisResponse response(DayAnalysisAttempt attempt) =>
      DayAnalysisResponse.fromJson({
        'protocol': assistantProtocol,
        'request_id': attempt.request.requestId,
        'summary': 'TEST synthetic analysis',
        'suggestions': ['TEST optional suggestion'],
      }, request: attempt.request);

  test(
    'separate consent, default enabled and disable/re-enable need consent',
    () async {
      final settings = await store.settings();
      expect(settings.enabled, true);
      expect(settings.consentVersion, 0);
      await LocalMemoryStore(goals).consent();
      await expectLater(store.begin(), throwsA(isA<AssistantFailure>()));
      await store.consent();
      final attempt = await store.begin();
      expect(await store.authorized(attempt.consentedAt), true);
      await store.setEnabled(false);
      expect(await store.authorized(attempt.consentedAt), false);
      expect((await store.list()).single.status, 'cancelled');
      await store.setEnabled(true);
      expect((await store.settings()).consentVersion, 0);
      await expectLater(store.begin(), throwsA(isA<AssistantFailure>()));
      await store.consent();
      expect(await store.finish(attempt, response(attempt)), false);
    },
  );

  test('snapshot contains only own-day saved text, not photos/drafts/history/memory', () async {
    clock.setDay(2026, 10, 20);
    final id = await goal('TEST own goal');
    var past = await records.beginDraft(id, clock.day);
    past = await records.writeDraft(
      past.record.id,
      content: 'SECRET past text',
      expectedDraftRevision: past.record.draftRevision,
    );
    await records.save(
      past.record.id,
      operationId: const Uuid().v4(),
      expectedRevision: past.record.revision,
      expectedDraftRevision: past.record.draftRevision,
    );
    clock.setDay(2026, 10, 21);
    var draft = await records.beginDraft(id, clock.day);
    draft = await records.writeDraft(
      draft.record.id,
      content: 'TEST saved\n📚',
      expectedDraftRevision: draft.record.draftRevision,
    );
    draft = await records.addPhoto(
      draft.record.id,
      photo: RecordPhotoInput(
        id: const Uuid().v4(),
        width: 20,
        height: 20,
        byteCount: 400,
        sha256: 'a' * 64,
      ),
      expectedDraftRevision: draft.record.draftRevision,
    );
    await records.save(
      draft.record.id,
      operationId: const Uuid().v4(),
      expectedRevision: draft.record.revision,
      expectedDraftRevision: draft.record.draftRevision,
    );
    draft = await records.beginDraft(id, clock.day);
    await records.writeDraft(
      draft.record.id,
      content: 'SECRET unsaved',
      expectedDraftRevision: draft.record.draftRevision,
    );
    await goals.setCompleted(id, true, expectedDay: clock.day);
    await LocalMemoryStore(goals)
        .add(const MemoryDraft(category: '其他', text: 'OMITTED memory'));
    final other = LocalGoalRepository(db, clock, owner: accountA.owner);
    await other.create(
      const GoalDraft(title: 'SECRET other owner', kind: GoalKind.habit),
    );
    await goals.create(
      GoalDraft(
        title: 'SECRET tomorrow',
        kind: GoalKind.single,
        plannedDay: clock.day.addDays(1),
      ),
    );
    final before = await store.preview();
    expect(before.entries, hasLength(1));
    final row = before.entries.single;
    expect(row.title, 'TEST own goal');
    expect(row.text, 'TEST saved\n📚');
    expect(row.plannedMinutes, 20);
    expect(row.plannedTime, '20:00');
    expect(row.completed, true);
    expect(row.completedAt, clock.instant.toIso8601String());
    final body = jsonEncode(before.toJson());
    for (final secret in [
      'SECRET',
      'OMITTED',
      'sha256',
      'photos',
      'draft',
      'owner',
      '.jpg',
    ]) {
      expect(body, isNot(contains(secret)));
    }
    expect((await store.settings()).consentVersion, 0);
    expect(await store.list(), isEmpty);
  });

  test('one pending attempt, frozen retry, duplicate finish and independent delete', () async {
    final id = await goal('TEST before request');
    await store.consent();
    final attempt = await store.begin();
    await expectLater(store.begin(), throwsA(isA<AssistantFailure>()));
    await store.fail(attempt.row.id, 'network');
    await goals.edit(
      id,
      const GoalDraft(title: 'TEST after request', kind: GoalKind.habit),
    );
    final retry = await store.begin(retryOf: attempt.row.id);
    expect(retry.request.entries.single.title, 'TEST before request');
    expect(retry.request.requestId, isNot(attempt.request.requestId));
    expect(await store.finish(retry, response(retry)), true);
    expect(await store.finish(retry, response(retry)), false);
    await store.remove(retry.row.id);
    expect((await store.list()).single.id, attempt.row.id);
    expect(
      (await goals.loadGoals()).single.titleOn(clock.day),
      'TEST after request',
    );
  });

  test(
    'pending file recovery never automatically resends; LA date is retained',
    () async {
      await db.close();
      final directory = await Directory.systemTemp.createTemp(
        'analysis-store-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/test.sqlite');
      db = AppDatabase(NativeDatabase(file));
      clock.location = tz.getLocation('America/Los_Angeles');
      clock.setDay(2026, 10, 21, hour: 23, minute: 59);
      await bind();
      await goal('TEST LA goal');
      await store.consent();
      final original = await store.begin();
      await db.close();
      db = AppDatabase(NativeDatabase(file));
      clock.location = tz.getLocation('Asia/Shanghai');
      await bind();
      await store.recoverInterrupted();
      final row = (await store.list()).single;
      expect(row.day, '2026-10-21');
      expect(row.zone, 'America/Los_Angeles');
      expect(row.status, 'cancelled');
      expect(row.failureCode, 'interrupted');
      expect(row.requestJson, original.row.requestJson);
      await expectLater(
        store.begin(retryOf: row.id),
        throwsA(isA<GoalRuleException>()),
      );
    },
  );

  test(
    'stale identity cannot read, finish or delete another identity result',
    () async {
      await goal('TEST guest');
      await store.consent();
      final attempt = await store.begin();
      final identities = IdentityStore(db);
      await identities.finish(await identities.begin(accountA));
      await expectLater(store.list(), throwsA(isA<StaleIdentity>()));
      expect(await store.authorized(attempt.consentedAt), false);
      await expectLater(
        store.finish(attempt, response(attempt)),
        throwsA(isA<StaleIdentity>()),
      );
      await bind();
      expect(await store.list(), isEmpty);
      expect((await store.settings()).consentVersion, 0);
      await store.remove(attempt.row.id);
      expect(await db.select(db.dayAnalyses).get(), hasLength(1));
    },
  );
}
