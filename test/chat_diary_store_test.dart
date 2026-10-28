import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/sync/identity_store.dart';
import 'package:habit_checkin/features/journal/data/chat_diary_store.dart';
import 'package:habit_checkin/features/journal/data/local_journal_store.dart';
import 'package:habit_checkin/features/journal/domain/journal_entry.dart';
import 'package:habit_checkin/features/records/data/local_day_record_store.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:uuid/uuid.dart';

import 'support/assistant_fixtures.dart';
import 'support/test_clock.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);
  late AppDatabase db;
  late TestClock clock;
  late LocalGoalRepository goals;
  late ChatDiaryStore store;
  late LocalDiaryStore diaries;
  late String id;

  Future<void> bind() async {
    final lease = await IdentityStore(db).active();
    goals = LocalGoalRepository(
      db,
      clock,
      owner: lease.identity.owner,
      identityLease: lease,
    );
    store = ChatDiaryStore(goals);
    diaries = LocalDiaryStore(goals);
  }

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    clock = TestClock()..setDay(2026, 10, 25);
    await bind();
    await seedAssistantReply(db);
    id = const Uuid().v4();
    await db
        .into(db.assistantDiaryProposals)
        .insert(
          AssistantDiaryProposalsCompanion.insert(
            id: id,
            owner: 'guest',
            sessionId: 'test-session',
            messageId: 'test-message',
            content: '合成新文字',
          ),
        );
  });
  tearDown(() => db.close());

  Future<JournalSnapshot> saved(String text, {bool photo = false}) async {
    var value = await diaries.beginDraft(clock.day);
    value = await diaries.writeDraft(
      value.entry.id,
      content: text,
      expectedDraftRevision: value.entry.draftRevision,
    );
    if (photo) {
      value = await diaries.addPhoto(
        value.entry.id,
        expectedDraftRevision: value.entry.draftRevision,
        photo: RecordPhotoInput(
          id: const Uuid().v4(),
          width: 10,
          height: 10,
          byteCount: 100,
          sha256: 'a' * 64,
        ),
      );
    }
    return diaries.save(
      value.entry.id,
      operationId: const Uuid().v4(),
      expectedRevision: value.entry.revision,
      expectedDraftRevision: value.entry.draftRevision,
    );
  }

  Future<Map<String, Object>> persistedDiaryState() async => {
    for (final table in [
      'diary_entries',
      'diary_photos',
      'assistant_diary_proposals',
    ])
      table: (await db.customSelect('SELECT * FROM $table ORDER BY id').get())
          .map((row) => row.data)
          .toList(),
  };

  for (final mode in ChatDiaryMode.values) {
    test(
      'local edited ${mode.name} keeps model proposal photos and receipt protection',
      () async {
        await saved('合成原文', photo: true);
        final photos = (await persistedDiaryState())['diary_photos'];
        final preview = await store.preview(id, clock.day);
        const edited = '修正后的本地文字';
        final receipt = await store.apply(preview, mode, editedText: edited);
        expect(
          (await diaries.atDay(clock.day))!.entry.content,
          mode == ChatDiaryMode.append ? '合成原文\n\n$edited' : edited,
        );
        expect((await store.proposal(id)).content, '合成新文字');
        expect(
          await store.apply(preview, mode, editedText: '重试不得再次写入'),
          receipt,
        );
        expect((await persistedDiaryState())['diary_photos'], photos);
        await store.undo(id);
        expect((await diaries.atDay(clock.day))!.entry.content, '合成原文');
        expect((await persistedDiaryState())['diary_photos'], photos);
      },
    );
  }

  for (final invalid in ['', ' \n ', '字' * 5001]) {
    test(
      'edited proposal rejects empty or over-limit ${invalid.length} before append',
      () async {
        await saved('合成原文');
        final preview = await store.preview(id, clock.day);
        final before = await persistedDiaryState();
        await expectLater(
          store.apply(preview, ChatDiaryMode.append, editedText: invalid),
          throwsA(isA<JournalRuleException>()),
        );
        expect(await persistedDiaryState(), before);
      },
    );
  }

  test(
    'edited append limit counts separators and graphemes, not UTF16',
    () async {
      await saved('字' * 4998);
      final preview = await store.preview(id, clock.day);
      await expectLater(
        store.apply(preview, ChatDiaryMode.append, editedText: '好'),
        throwsA(isA<JournalRuleException>()),
      );
      final text = '👨‍👩‍👧‍👦' * 5000;
      await store.apply(preview, ChatDiaryMode.replace, editedText: text);
      expect((await diaries.atDay(clock.day))!.entry.content, text);
      expect((await store.proposal(id)).content, '合成新文字');
    },
  );

  for (final change in ['saved', 'draft', 'identity', 'cancel']) {
    test('edited proposal does not bypass $change protection', () async {
      await saved('原文');
      final preview = await store.preview(id, clock.day);
      if (change == 'saved') {
        await saved('新的已保存文字');
      } else if (change == 'draft') {
        final draft = await diaries.beginDraft(clock.day);
        await diaries.writeDraft(
          draft.entry.id,
          content: '新的草稿',
          expectedDraftRevision: draft.entry.draftRevision,
        );
      } else if (change == 'identity') {
        await db.customStatement(
          'UPDATE identity_states SET generation=generation+1',
        );
      } else {
        await store.cancel(id);
      }
      final before = await persistedDiaryState();
      await expectLater(
        store.apply(preview, ChatDiaryMode.replace, editedText: '本地修改'),
        throwsA(
          anyOf(
            isA<JournalRuleException>(),
            isA<JournalConflict>(),
            isA<StaleIdentity>(),
          ),
        ),
      );
      expect(await persistedDiaryState(), before);
    });
  }

  test(
    'edited receipt failure is atomic and retry retains local text',
    () async {
      await saved('原文', photo: true);
      final preview = await store.preview(id, clock.day);
      final before = await persistedDiaryState();
      await db.customStatement(
        "CREATE TRIGGER fail_edited_receipt BEFORE UPDATE ON assistant_diary_proposals BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END",
      );
      await expectLater(
        store.apply(preview, ChatDiaryMode.append, editedText: '本地修改'),
        throwsA(isA<Exception>()),
      );
      expect(await persistedDiaryState(), before);
      await db.customStatement('DROP TRIGGER fail_edited_receipt');
      await store.apply(preview, ChatDiaryMode.append, editedText: '本地修改');
      expect((await diaries.atDay(clock.day))!.entry.content, '原文\n\n本地修改');
      await saved('之后的编辑');
      await expectLater(store.undo(id), throwsA(isA<JournalRuleException>()));
      expect((await diaries.atDay(clock.day))!.entry.content, '之后的编辑');
    },
  );

  test('preview and cancel never create diary rows; cancelled proposals cannot apply', () async {
    final preview = await store.preview(id, clock.day.addDays(-1));
    expect(preview.proposal.suggestedDay, isNull);
    expect(await db.select(db.diaryEntries).get(), isEmpty);
    expect((await store.cancel(id)).status, 'cancelled');
    await expectLater(
      store.apply(preview, ChatDiaryMode.replace),
      throwsA(isA<JournalRuleException>()),
    );
    expect(await db.select(db.diaryEntries).get(), isEmpty);
  });

  for (final mode in ChatDiaryMode.values) {
    test(
      '${mode.name} protects photos and restores old saved content on undo',
      () async {
        await saved('合成原文', photo: true);
        final photos =
            (await db.customSelect('SELECT * FROM diary_photos').get())
                .map((r) => r.data)
                .toList();
        final preview = await store.preview(id, clock.day);
        final receipt = await store.apply(preview, mode);
        expect(receipt.status, 'applied');
        expect(receipt.targetDay, clock.day.key);
        expect(
          (await diaries.atDay(clock.day))!.entry.content,
          mode == ChatDiaryMode.append ? '合成原文\n\n合成新文字' : '合成新文字',
        );
        expect(await store.apply(preview, mode), receipt);
        expect((await store.undo(id)).status, 'undone');
        expect((await store.undo(id)).status, 'undone');
        expect((await diaries.atDay(clock.day))!.entry.content, '合成原文');
        expect(
          (await db.customSelect('SELECT * FROM diary_photos').get())
              .map((r) => r.data)
              .toList(),
          photos,
        );
      },
    );
  }

  test(
    'unsaved text and photo drafts block application without losing either',
    () async {
      await saved('合成原文', photo: true);
      var draft = await diaries.beginDraft(clock.day);
      draft = await diaries.writeDraft(
        draft.entry.id,
        content: '未保存的合成草稿',
        expectedDraftRevision: draft.entry.draftRevision,
      );
      final before =
          (await db.customSelect('SELECT * FROM diary_entries').getSingle())
              .data;
      final preview = await store.preview(id, clock.day);
      for (final mode in ChatDiaryMode.values) {
        await expectLater(
          store.apply(preview, mode),
          throwsA(isA<ChatDiaryDraftConflict>()),
        );
      }
      expect(
        (await db.customSelect('SELECT * FROM diary_entries').getSingle()).data,
        before,
      );
      expect((await store.proposal(id)).status, 'pending');
      draft = await diaries.writeDraft(
        draft.entry.id,
        content: '合成原文',
        expectedDraftRevision: draft.entry.draftRevision,
      );
      await diaries.removePhoto(
        draft.entry.id,
        draft.draftPhotos.single.id,
        expectedDraftRevision: draft.entry.draftRevision,
      );
      await expectLater(
        store.apply(await store.preview(id, clock.day), ChatDiaryMode.replace),
        throwsA(isA<ChatDiaryDraftConflict>()),
      );
      expect((await diaries.atDay(clock.day))!.savedPhotos, hasLength(1));
    },
  );

  test(
    'clean open draft is kept coherent and restored exactly on undo',
    () async {
      await saved('合成原文', photo: true);
      final draft = await diaries.beginDraft(clock.day);
      final photos = (await db.customSelect('SELECT * FROM diary_photos').get())
          .map((r) => r.data)
          .toList();
      await store.apply(
        await store.preview(id, clock.day),
        ChatDiaryMode.append,
      );
      expect(
        (await diaries.atDay(clock.day))!.entry.draftText,
        '合成原文\n\n合成新文字',
      );
      expect((await diaries.beginDraft(clock.day)).hasDraftChanges, isFalse);
      await store.undo(id);
      expect(
        (await diaries.atDay(clock.day))!.entry.draftText,
        draft.entry.draftText,
      );
      expect(
        (await db.customSelect('SELECT * FROM diary_photos').get())
            .map((r) => r.data)
            .toList(),
        photos,
      );
    },
  );

  test('changed target after preview and changed draft after save never get overwritten', () async {
    final preview = await store.preview(id, clock.day);
    await saved('别人刚保存的合成文字');
    await expectLater(
      store.apply(preview, ChatDiaryMode.replace),
      throwsA(isA<JournalConflict>()),
    );
    await store.apply(await store.preview(id, clock.day), ChatDiaryMode.append);
    final draft = await diaries.beginDraft(clock.day);
    await diaries.writeDraft(
      draft.entry.id,
      content: '后续合成草稿',
      expectedDraftRevision: draft.entry.draftRevision,
    );
    await expectLater(store.undo(id), throwsA(isA<JournalRuleException>()));
    expect((await diaries.atDay(clock.day))!.entry.draftText, '后续合成草稿');
    expect((await store.proposal(id)).status, 'applied');
  });

  for (final mode in ChatDiaryMode.values) {
    test(
      '${mode.name} can undo after read-only opens without changing photos',
      () async {
        final original = await saved('合成原文', photo: true);
        final originalPhotos = (await persistedDiaryState())['diary_photos'];
        final receipt = await store.apply(
          await store.preview(id, clock.day),
          mode,
        );
        final viewed = await diaries.beginDraft(clock.day);
        expect(viewed.entry.draftRevision, receipt.appliedDraftRevision! + 1);
        expect(viewed.hasDraftChanges, isFalse);
        await diaries.beginDraft(clock.day);
        await diaries.beginDraft(clock.day);

        final results = await Future.wait(
          List.generate(5, (_) => store.undo(id)),
        );
        expect(results.every((result) => result.status == 'undone'), isTrue);
        final restored = (await diaries.atDay(clock.day))!;
        expect(restored.entry.content, original.entry.content);
        expect(restored.entry.savedAt, original.entry.savedAt);
        expect(restored.entry.deletedAt, original.entry.deletedAt);
        expect(restored.entry.draftText, isNull);
        expect(restored.entry.revision, receipt.appliedRevision! + 1);
        expect(restored.entry.draftRevision, viewed.entry.draftRevision + 1);
        expect((await persistedDiaryState())['diary_photos'], originalPhotos);

        final afterUndo = await persistedDiaryState();
        await expectLater(
          diaries.writeDraft(
            viewed.entry.id,
            content: '过期编辑器的合成文字',
            expectedDraftRevision: viewed.entry.draftRevision,
          ),
          throwsA(isA<JournalConflict>()),
        );
        await expectLater(
          diaries.save(
            viewed.entry.id,
            operationId: const Uuid().v4(),
            expectedRevision: viewed.entry.revision,
            expectedDraftRevision: viewed.entry.draftRevision,
          ),
          throwsA(isA<JournalConflict>()),
        );
        expect(await persistedDiaryState(), afterUndo);
      },
    );
  }

  for (final alreadyOpen in [false, true]) {
    for (final mutation in [
      'text',
      'restored text',
      'same text write',
      'added photo',
      'removed photo',
      'added then removed photo',
      'saved',
      'deleted',
    ]) {
      test(
        'undo protects $mutation after view; pre-existing draft=$alreadyOpen',
        () async {
          await saved('合成原文', photo: true);
          if (alreadyOpen) await diaries.beginDraft(clock.day);
          await store.apply(
            await store.preview(id, clock.day),
            ChatDiaryMode.append,
          );
          var draft = await diaries.beginDraft(clock.day);
          if (mutation == 'text' || mutation == 'restored text') {
            draft = await diaries.writeDraft(
              draft.entry.id,
              content: '未保存的后续合成修改',
              expectedDraftRevision: draft.entry.draftRevision,
            );
          }
          if (mutation == 'restored text' || mutation == 'same text write') {
            draft = await diaries.writeDraft(
              draft.entry.id,
              content: draft.entry.content,
              expectedDraftRevision: draft.entry.draftRevision,
            );
            expect(draft.hasDraftChanges, isFalse);
          }
          if (mutation == 'added photo' ||
              mutation == 'added then removed photo') {
            final photoId = const Uuid().v4();
            draft = await diaries.addPhoto(
              draft.entry.id,
              expectedDraftRevision: draft.entry.draftRevision,
              photo: RecordPhotoInput(
                id: photoId,
                width: 10,
                height: 10,
                byteCount: 100,
                sha256: 'b' * 64,
              ),
            );
            if (mutation == 'added then removed photo') {
              draft = await diaries.removePhoto(
                draft.entry.id,
                photoId,
                expectedDraftRevision: draft.entry.draftRevision,
              );
              expect(draft.hasDraftChanges, isFalse);
            }
          }
          if (mutation == 'removed photo') {
            await diaries.removePhoto(
              draft.entry.id,
              draft.draftPhotos.first.id,
              expectedDraftRevision: draft.entry.draftRevision,
            );
          }
          if (mutation == 'saved') {
            await diaries.save(
              draft.entry.id,
              operationId: const Uuid().v4(),
              expectedRevision: draft.entry.revision,
              expectedDraftRevision: draft.entry.draftRevision,
            );
          }
          if (mutation == 'deleted') {
            await diaries.delete(
              draft.entry.id,
              operationId: const Uuid().v4(),
              expectedRevision: draft.entry.revision,
              expectedDraftRevision: draft.entry.draftRevision,
            );
          }
          final before = await persistedDiaryState();
          await expectLater(
            store.undo(id),
            throwsA(isA<JournalRuleException>()),
          );
          expect(await persistedDiaryState(), before);
          expect((await store.proposal(id)).status, 'applied');
        },
      );
    }
  }

  test(
    'read-only undo rolls back photo draft slots when the receipt fails',
    () async {
      await saved('合成原文', photo: true);
      final originalPhotos = (await persistedDiaryState())['diary_photos'];
      await store.apply(
        await store.preview(id, clock.day),
        ChatDiaryMode.append,
      );
      await diaries.beginDraft(clock.day);
      final before = await persistedDiaryState();
      await db.customStatement(
        "CREATE TRIGGER fail_viewed_undo BEFORE UPDATE ON assistant_diary_proposals BEGIN SELECT RAISE(ABORT, 'synthetic receipt failure'); END",
      );
      await expectLater(
        store.undo(id),
        throwsA(
          predicate<Object>(
            (error) => error.toString().contains('synthetic receipt failure'),
          ),
        ),
      );
      expect(await persistedDiaryState(), before);
      await db.customStatement('DROP TRIGGER fail_viewed_undo');
      expect((await store.undo(id)).status, 'undone');
      expect((await persistedDiaryState())['diary_photos'], originalPhotos);
    },
  );

  test('read-only undo rejects an old identity lease after returning to the same owner', () async {
    await store.apply(
      await store.preview(id, clock.day),
      ChatDiaryMode.replace,
    );
    await diaries.beginDraft(clock.day);
    final before = await persistedDiaryState();
    await db.customStatement(
      "UPDATE identity_states SET owner='account:other', generation=generation+1",
    );
    await expectLater(store.undo(id), throwsA(isA<StaleIdentity>()));
    await db.customStatement(
      "UPDATE identity_states SET owner='guest', generation=generation+1",
    );
    await expectLater(store.undo(id), throwsA(isA<StaleIdentity>()));
    expect(await persistedDiaryState(), before);
    await bind();
    expect((await store.undo(id)).status, 'undone');
  });

  for (final field in ['text', 'photos']) {
    test('read-only revision exception still verifies unchanged $field', () async {
      await saved('合成原文', photo: true);
      final receipt = await store.apply(
        await store.preview(id, clock.day),
        ChatDiaryMode.append,
      );
      final draft = await diaries.beginDraft(clock.day);
      expect(draft.entry.draftRevision, receipt.appliedDraftRevision! + 1);
      // A partial writer must not pass merely by matching the opening revision.
      await db.customStatement(
        field == 'text'
            ? "UPDATE diary_entries SET draft_text='synthetic changed draft'"
            : 'UPDATE diary_photos SET draft_position=NULL',
      );
      final before = await persistedDiaryState();
      await expectLater(store.undo(id), throwsA(isA<JournalRuleException>()));
      expect(await persistedDiaryState(), before);
    });
  }

  test(
    'identity change during viewed undo rolls back entries photos and receipt',
    () async {
      await saved('合成原文', photo: true);
      await store.apply(
        await store.preview(id, clock.day),
        ChatDiaryMode.append,
      );
      await diaries.beginDraft(clock.day);
      final before = await persistedDiaryState();
      final lease = await IdentityStore(db).active();
      await db.customStatement(
        'CREATE TRIGGER switch_during_undo AFTER UPDATE ON diary_entries BEGIN UPDATE identity_states SET generation=generation+1; END',
      );
      await expectLater(store.undo(id), throwsA(isA<StaleIdentity>()));
      expect(await persistedDiaryState(), before);
      expect((await IdentityStore(db).active()).generation, lease.generation);
    },
  );

  test('receipt failure rolls back diary save; retry and undo failure remain atomic', () async {
    await db.customStatement(
      "CREATE TRIGGER fail_diary_receipt BEFORE UPDATE ON assistant_diary_proposals BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END",
    );
    final preview = await store.preview(id, clock.day);
    await expectLater(
      store.apply(preview, ChatDiaryMode.replace),
      throwsException,
    );
    expect(await db.select(db.diaryEntries).get(), isEmpty);
    expect((await store.proposal(id)).status, 'pending');
    await db.customStatement('DROP TRIGGER fail_diary_receipt');
    await store.apply(preview, ChatDiaryMode.replace);
    await db.customStatement(
      "CREATE TRIGGER fail_diary_receipt BEFORE UPDATE ON assistant_diary_proposals BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END",
    );
    await expectLater(store.undo(id), throwsException);
    expect((await diaries.atDay(clock.day))!.entry.content, '合成新文字');
    expect((await store.proposal(id)).status, 'applied');
  });

  test('identity generation change rejects old preview, even after returning to same owner', () async {
    final preview = await store.preview(id, clock.day);
    await db.customStatement(
      "UPDATE identity_states SET owner='account:other', generation=generation+1",
    );
    await expectLater(
      store.apply(preview, ChatDiaryMode.replace),
      throwsA(isA<StaleIdentity>()),
    );
    await expectLater(store.proposal(id), throwsA(isA<StaleIdentity>()));
    await db.customStatement(
      "UPDATE identity_states SET owner='guest', generation=generation+1",
    );
    await expectLater(
      store.apply(preview, ChatDiaryMode.replace),
      throwsA(isA<StaleIdentity>()),
    );
    expect(await db.select(db.diaryEntries).get(), isEmpty);
  });

  test('rapid repeated confirmations create one revision and repeated undo is safe', () async {
    final preview = await store.preview(id, clock.day);
    final results = await Future.wait(
      List.generate(5, (_) => store.apply(preview, ChatDiaryMode.replace)),
    );
    expect(results.map((p) => p.entryId).toSet(), hasLength(1));
    final entry = await db.select(db.diaryEntries).getSingle();
    expect(entry.revision, 1);
    await Future.wait(List.generate(5, (_) => store.undo(id)));
    expect((await db.select(db.diaryEntries).getSingle()).revision, 2);
    expect(await diaries.savedOn(clock.day), isEmpty);
  });

  test(
    '5000 visible-character limit includes separator and existing text',
    () async {
      await saved('e\u0301' * 4998);
      final preview = await store.preview(id, clock.day);
      await expectLater(
        store.apply(preview, ChatDiaryMode.append),
        throwsA(isA<JournalRuleException>()),
      );
      expect((await diaries.atDay(clock.day))!.entry.content, 'e\u0301' * 4998);
      expect((await store.proposal(id)).status, 'pending');
    },
  );

  test('selected historical date stays explicit across midnight; future is rejected', () async {
    final day = clock.day;
    await expectLater(
      store.preview(id, day.addDays(1)),
      throwsA(isA<JournalRuleException>()),
    );
    final preview = await store.preview(id, day);
    clock.setDay(2026, 10, 26);
    await store.apply(preview, ChatDiaryMode.replace);
    expect((await store.proposal(id)).targetDay, day.key);
    expect(await diaries.atDay(clock.day), isNull);
    expect((await diaries.atDay(day))!.entry.isSaved, isTrue);
  });

  for (final edit in [null, '本地修改后保存']) {
    test(
      'file reopen preserves receipt and idempotence without model replay edited=${edit != null}',
      () async {
        final dir = await Directory.systemTemp.createTemp(
          'chat-diary-synthetic-',
        );
        addTearDown(() => dir.delete(recursive: true));
        final path = '${dir.path}/synthetic.sqlite';
        final preview = await store.preview(id, clock.day);
        final receipt = await store.apply(
          preview,
          ChatDiaryMode.replace,
          editedText: edit,
        );
        await diaries.beginDraft(clock.day);
        await db.customStatement('VACUUM INTO ?', [path]);
        await db.close();
        final reopened = AppDatabase(NativeDatabase(File(path)));
        addTearDown(reopened.close);
        final lease = await IdentityStore(reopened).active();
        final resumed = ChatDiaryStore(
          LocalGoalRepository(reopened, clock, identityLease: lease),
        );
        expect(await resumed.proposal(id), receipt);
        expect(
          await resumed.apply(
            preview,
            ChatDiaryMode.replace,
            editedText: '重开不得覆盖',
          ),
          receipt,
        );
        expect(
          await reopened.select(reopened.diaryEntries).get(),
          hasLength(1),
        );
        expect(
          (await reopened.select(reopened.diaryEntries).getSingle()).content,
          edit ?? '合成新文字',
        );
        expect((await resumed.proposal(id)).content, '合成新文字');
        await resumed.undo(id);
        expect(
          (await reopened.select(reopened.diaryEntries).getSingle()).isSaved,
          isFalse,
        );
      },
    );
  }
}
