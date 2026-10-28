import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/sync/identity_store.dart';
import 'package:habit_checkin/features/assistant/data/assistant_request_builder.dart';
import 'package:habit_checkin/features/assistant/data/local_conversation_store.dart';
import 'package:habit_checkin/features/journal/data/chat_diary_store.dart';
import 'package:habit_checkin/features/journal/data/local_journal_store.dart';
import 'package:habit_checkin/features/records/data/local_day_record_store.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:uuid/uuid.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

import 'support/test_clock.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);
  test(
    'chat intent commits a pending diary proposal, never a saved diary',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final clock = TestClock()..setDay(2026, 10, 25);
      final lease = await IdentityStore(db).active();
      final goals = LocalGoalRepository(
        db,
        clock,
        owner: lease.identity.owner,
        identityLease: lease,
      );
      final store = LocalConversationStore(goals);
      await store.memories.consent();
      final session = await store.createSession();
      final turn = await store.begin(session, '合成素材：今天读了十页书。把上面这段放入今天日记');
      final payload = TurnRequest.fromJson({
        ...(await AssistantRequestBuilder(store).build(turn)).toJson(),
        'diary_proposals': true,
      });
      await store.recordRequest(turn, payload);
      await store.commitResponse(
        turn,
        TurnResponse.fromJson({
          'protocol': assistantProtocol,
          'request_id': turn.requestId,
          'reply': '日记建议待确认。',
          'plan': null,
          'memory_ops': <Object?>[],
          'diary': {'date': '2026-10-25', 'content': '今天读了十页书。'},
        }, request: payload),
      );
      final proposals = await db
          .customSelect('SELECT * FROM assistant_diary_proposals')
          .get();
      expect(proposals, hasLength(1));
      expect(proposals.single.data['status'], 'pending');
      expect(await db.select(db.diaryEntries).get(), isEmpty);
      final diaries = LocalDiaryStore(goals);
      var existing = await diaries.beginDraft(clock.day);
      existing = await diaries.writeDraft(
        existing.entry.id,
        content: 'PRIVATE_DIARY_ONLY',
        expectedDraftRevision: existing.entry.draftRevision,
      );
      final photo = const Uuid().v4();
      existing = await diaries.addPhoto(
        existing.entry.id,
        expectedDraftRevision: existing.entry.draftRevision,
        photo: RecordPhotoInput(
          id: photo,
          width: 10,
          height: 10,
          byteCount: 100,
          sha256: 'a' * 64,
        ),
      );
      await diaries.save(
        existing.entry.id,
        operationId: const Uuid().v4(),
        expectedRevision: existing.entry.revision,
        expectedDraftRevision: existing.entry.draftRevision,
      );
      final diaryStore = ChatDiaryStore(goals);
      await diaryStore.apply(
        await diaryStore.preview(
          proposals.single.data['id'] as String,
          clock.day,
        ),
        ChatDiaryMode.append,
      );
      final other = await store.createSession();
      await db
          .into(db.assistantMessages)
          .insert(
            AssistantMessagesCompanion.insert(
              id: const Uuid().v4(),
              sessionId: other,
              owner: goals.owner,
              role: 'user',
              content: 'PRIVATE_OTHER_CONVERSATION',
              status: 'sent',
              createdAt: 1,
            ),
          );
      final next = await store.begin(session, '合成继续聊');
      final sent = jsonEncode(
        (await AssistantRequestBuilder(store).build(next)).toJson(),
      );
      expect(sent, isNot(contains('PRIVATE_DIARY_ONLY')));
      expect(sent, isNot(contains('PRIVATE_OTHER_CONVERSATION')));
      expect(sent, isNot(contains(photo)));
      expect(sent, isNot(contains('before_json')));
    },
  );
}
