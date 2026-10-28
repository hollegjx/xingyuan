import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/sync/identity_store.dart';
import 'package:habit_checkin/features/assistant/data/assistant_request_builder.dart';
import 'package:habit_checkin/features/assistant/data/local_conversation_store.dart';
import 'package:habit_checkin/features/assistant/data/local_memory_store.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:habit_checkin/features/journal/ai/journal_ai_context.dart';
import 'package:habit_checkin/features/journal/data/local_journal_store.dart';
import 'package:habit_checkin/features/records/data/local_day_record_store.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:uuid/uuid.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

// Share pure synthetic inputs without adding the eval package to App dependencies.
// ignore: avoid_relative_lib_imports
import '../tool/assistant_eval/lib/journal_r3_cases.dart';
import 'support/journal_fixtures.dart';
import 'support/test_clock.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);
  late AppDatabase db;
  late TestClock clock;
  late LocalGoalRepository goals;
  late LocalQuickNoteStore notes;
  late LocalConversationStore conversations;
  final cases = journalR3Cases();
  const photoId = '44444444-4444-4444-8444-444444444444';

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    clock = TestClock()..setDay(2026, 10, 26, hour: 21);
    final lease = await IdentityStore(db).active();
    goals = LocalGoalRepository(
      db,
      clock,
      owner: lease.identity.owner,
      identityLease: lease,
    );
    notes = LocalQuickNoteStore(goals);
    conversations = LocalConversationStore(goals);
    await conversations.memories.consent();
    // Chat may send these by explicit settings. This privacy scenario opts out.
    await conversations.memories.updateSettings(
      sendMemories: false,
      sendSchedule: false,
      sendStats: false,
      autoMemory: false,
    );
  });
  tearDown(() => db.close());

  Future<void> seedPrivateMaterial({bool unrelatedTodayNote = false}) async {
    final today = clock.instant;
    clock.instant = today.subtract(const Duration(days: 1));
    await saveJournalNotes(notes, ['PRIVATE_HISTORY_NOTE']);
    final diaries = LocalDiaryStore(goals);
    var diary = await diaries.beginDraft(clock.day);
    diary = await diaries.writeDraft(
      diary.entry.id,
      content: 'PRIVATE_HISTORY_DIARY',
      expectedDraftRevision: diary.entry.draftRevision,
    );
    await diaries.save(
      diary.entry.id,
      operationId: const Uuid().v4(),
      expectedRevision: diary.entry.revision,
      expectedDraftRevision: diary.entry.draftRevision,
    );
    clock.instant = today;
    if (unrelatedTodayNote) {
      await saveJournalNotes(notes, ['PRIVATE_SAVED_TODAY_NOTE']);
    }
    diary = await diaries.beginDraft(clock.day);
    diary = await diaries.writeDraft(
      diary.entry.id,
      content: 'PRIVATE_TODAY_DIARY',
      expectedDraftRevision: diary.entry.draftRevision,
    );
    await diaries.save(
      diary.entry.id,
      operationId: const Uuid().v4(),
      expectedRevision: diary.entry.revision,
      expectedDraftRevision: diary.entry.draftRevision,
    );
    var draft = await notes.beginDraft();
    draft = await notes.writeDraft(
      draft.entry.id,
      content: 'PRIVATE_UNSAVED_NOTE',
      expectedDraftRevision: draft.entry.draftRevision,
    );
    await notes.addPhoto(
      draft.entry.id,
      expectedDraftRevision: draft.entry.draftRevision,
      photo: RecordPhotoInput(
        id: photoId,
        width: 10,
        height: 10,
        byteCount: 100,
        sha256: 'a' * 64,
      ),
    );
    await conversations.memories.add(
      const MemoryDraft(category: '其他', text: 'PRIVATE_MEMORY'),
    );
    await goals.create(
      GoalDraft(
        title: 'PRIVATE_FUTURE_SCHEDULE',
        kind: GoalKind.single,
        plannedDay: clock.day.addDays(1),
      ),
    );
    final other = LocalGoalRepository(
      db,
      clock,
      owner: 'account:55555555-5555-4555-8555-555555555555',
    );
    await other.create(
      const GoalDraft(title: 'PRIVATE_OTHER_OWNER_GOAL', kind: GoalKind.habit),
    );
    // Seed an inactive owner's retained row without acquiring that identity.
    final now = clock.instant.microsecondsSinceEpoch;
    await db
        .into(db.quickNotes)
        .insert(
          QuickNotesCompanion.insert(
            id: const Uuid().v4(),
            owner: other.owner,
            day: clock.day.key,
            zone: clock.read().zone,
            content: const Value('PRIVATE_OTHER_OWNER_NOTE'),
            revision: const Value(1),
            savedAt: Value(now),
            createdAt: now,
            updatedAt: now,
          ),
        );
    final otherSession = await conversations.createSession();
    final otherTurn = await conversations.begin(
      otherSession,
      'PRIVATE_OTHER_CONVERSATION',
    );
    final request = await AssistantRequestBuilder(conversations)
        .build(otherTurn);
    await conversations.recordRequest(otherTurn, request);
    clock.instant = clock.instant.add(const Duration(seconds: 1));
    await conversations.commitResponse(
      otherTurn,
      TurnResponse.fromJson({
        'protocol': assistantProtocol,
        'request_id': request.requestId,
        'reply': 'PRIVATE_OTHER_REPLY',
        'plan': null,
        'memory_ops': [],
        'diary': null,
      }, request: request),
    );
  }

  void expectPrivateMaterialAbsent(Map<String, Object?> payload) {
    final body = jsonEncode(payload);
    for (final forbidden in [
      'PRIVATE_',
      photoId,
      'sha256',
      'photos',
      'before_json',
      'owner',
    ]) {
      expect(body, isNot(contains(forbidden)), reason: forbidden);
    }
  }

  test('R3-MULTI retains all independent saved notes in time order and factual statuses', () async {
    await seedPrivateMaterial();
    final expected = cases.first.request as GenerateDiaryRequest;
    final read = await goals.create(
      const GoalDraft(title: '阅读', kind: GoalKind.habit),
    );
    await goals.create(const GoalDraft(title: '跑步', kind: GoalKind.habit));
    final records = LocalDayRecordStore(goals);
    var record = await records.beginDraft(read, clock.day);
    record = await records.writeDraft(
      record.record.id,
      content: '读完一章。',
      expectedDraftRevision: record.record.draftRevision,
    );
    record = await records.addPhoto(
      record.record.id,
      expectedDraftRevision: record.record.draftRevision,
      photo: RecordPhotoInput(
        id: '66666666-6666-4666-8666-666666666666',
        width: 10,
        height: 10,
        byteCount: 100,
        sha256: 'b' * 64,
      ),
    );
    await records.save(
      record.record.id,
      operationId: const Uuid().v4(),
      expectedRevision: record.record.revision,
      expectedDraftRevision: record.record.draftRevision,
    );
    await goals.setCompleted(read, true, expectedDay: clock.day);
    for (final text in expected.notes) {
      clock.instant = clock.instant.add(const Duration(minutes: 1));
      await saveJournalNotes(notes, [text]);
    }
    final saved = (await db.select(db.quickNotes).get()).singleWhere(
      (row) => row.content == expected.notes.first,
    );
    var edit = await notes.beginDraft(id: saved.id);
    edit = await notes.writeDraft(
      edit.entry.id,
      content: 'PRIVATE_UNSAVED_EDIT',
      expectedDraftRevision: edit.entry.draftRevision,
    );
    final context = JournalAiContext(goals, credentialRevision: () => 0);
    expect(await (await context.authorize()).isCurrent(), true);
    final request = await context.diary(clock.day);
    expect(request.day, expected.day);
    expect(request.notes, expected.notes);
    expect(
      request.entries.map((e) => e.toJson()),
      unorderedEquals(expected.entries.map((e) => e.toJson())),
    );
    expectPrivateMaterialAbsent(request.toJson());
    expect(
      jsonEncode(request.toJson()),
      isNot(contains('66666666-6666-4666-8666-666666666666')),
    );
    final unchanged = await notes.at(saved.id);
    expect(unchanged!.entry.content, expected.notes.first);
    expect(unchanged.entry.draftText, 'PRIVATE_UNSAVED_EDIT');
  });

  for (final sample in cases.where((item) => item.request is TurnRequest)) {
    test(
      '${sample.id} preserves ordered current turns without private context',
      () async {
        await seedPrivateMaterial(unrelatedTodayNote: true);
        final expected = sample.request as TurnRequest;
        final messages = (expected.toJson()['messages'] as List)
            .cast<Map<String, Object?>>();
        final session = await conversations.createSession();
        final builder = AssistantRequestBuilder(conversations);
        for (var index = 0; index < messages.length; index += 2) {
          clock.instant = clock.instant.add(const Duration(seconds: 1));
          expect(messages[index]['role'], 'user');
          final turn = await conversations.begin(
            session,
            messages[index]['text']! as String,
          );
          final request = await builder.build(turn);
          expect(
            request.toJson()['messages'],
            messages.take(index + 1).toList(),
          );
          expect(request.toJson()['summary'], isNull);
          expect(request.diaryProposals, true);
          for (final setting in ['memories', 'schedule', 'stats']) {
            expect(request.toJson(), isNot(contains(setting)));
          }
          expect(request.toJson()['settings'], {'auto_memory': false});
          expectPrivateMaterialAbsent(request.toJson());
          if (index + 1 == messages.length) break;
          await conversations.recordRequest(turn, request);
          clock.instant = clock.instant.add(const Duration(seconds: 1));
          expect(messages[index + 1]['role'], 'assistant');
          await conversations.commitResponse(
            turn,
            TurnResponse.fromJson({
              'protocol': assistantProtocol,
              'request_id': request.requestId,
              'reply': messages[index + 1]['text'],
              'plan': null,
              'memory_ops': [],
              'diary': null,
            }, request: request),
          );
        }
        expect(await db.select(db.assistantDiaryProposals).get(), isEmpty);
      },
    );
  }
}
