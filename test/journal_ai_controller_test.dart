import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/sync/identity_store.dart';
import 'package:habit_checkin/data/sync/sync_identity.dart';
import 'package:habit_checkin/features/assistant/data/assistant_service.dart';
import 'package:habit_checkin/features/assistant/data/local_memory_store.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:habit_checkin/features/journal/ai/journal_ai_context.dart';
import 'package:habit_checkin/features/journal/ai/journal_ai_controller.dart';
import 'package:habit_checkin/features/journal/data/local_journal_store.dart';
import 'package:habit_checkin/features/journal/domain/journal_entry.dart';
import 'package:habit_checkin/features/journal/presentation/journal_editor_controller.dart';
import 'package:habit_checkin/features/records/data/local_day_record_store.dart';
import 'package:habit_checkin/features/records/data/record_photo_picker.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:uuid/uuid.dart';

import 'support/journal_fixtures.dart';
import 'support/test_clock.dart';
import 'support/journal_ai_service.dart';
import 'support/journal_request_size.dart';

class GatedJournalContext extends JournalAiContext {
  GatedJournalContext(super.goals, {required super.credentialRevision});
  final reached = Completer<void>();
  final release = Completer<void>();
  int checks = 0;

  @override
  Future<AssistantAccess> authorize() async {
    final access = await super.authorize();
    return AssistantAccess(
      consentVersion: access.consentVersion,
      isCurrent: () async {
        if (++checks == 2) {
          reached.complete();
          await release.future;
        }
        return access.isCurrent();
      },
    );
  }
}

void main() {
  setUpAll(tzdata.initializeTimeZones);
  late AppDatabase db;
  late TestClock clock;
  late LocalGoalRepository goals;
  late JournalAiContext context;
  late SyntheticJournalAi service;
  late int credentialRevision;
  final editors = <JournalEditorController>[];
  final controllers = <JournalAiController>[];

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    clock = TestClock()..setDay(2026, 10, 23);
    final lease = await IdentityStore(db).active();
    goals = LocalGoalRepository(
      db,
      clock,
      owner: lease.identity.owner,
      identityLease: lease,
    );
    credentialRevision = 0;
    context = JournalAiContext(
      goals,
      credentialRevision: () => credentialRevision,
    );
    service = SyntheticJournalAi();
  });
  tearDown(() async {
    for (final controller in controllers) {
      controller.dispose();
    }
    for (final editor in editors) {
      editor.dispose();
    }
    controllers.clear();
    editors.clear();
    await db.close();
  });

  Future<JournalAiController> open({
    JournalKind kind = JournalKind.quickNote,
    String text = '我读完了一章',
    String? id,
  }) async {
    final store = kind == JournalKind.quickNote
        ? LocalQuickNoteStore(goals)
        : LocalDiaryStore(goals);
    final editor = JournalEditorController(
      store: store,
      files: MemoryJournalPhotoFiles(kind),
      picker: RecordPhotoPicker(),
    );
    editors.add(editor);
    await editor.initialize(day: clock.day, id: id);
    await editor.setText(text);
    final controller = JournalAiController(
      editor: editor,
      context: context,
      service: service,
    );
    controllers.add(controller);
    return controller;
  }

  Future<void> waitCall() async {
    while (service.calls.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<JournalAiController> editableDiary({String original = '自己的开头'}) async {
    await LocalMemoryStore(goals).consent();
    await saveJournalNotes(LocalQuickNoteStore(goals), ['今天读了一章']);
    final c = await open(kind: JournalKind.diary, text: original);
    expect(await c.request(), true);
    return c;
  }

  for (final append in [false, true]) {
    test(
      'edited diary ${append ? 'append' : 'replace'} is local, single-use and undoable',
      () async {
        final c = await editableDiary();
        final preview = c.preview!;
        const edited = '只想保留这一句。';
        final results = await Future.wait([
          c.use(append: append, editedText: edited),
          c.use(append: append, editedText: '不得重复写入'),
        ]);
        expect(results, [true, false]);
        expect(preview.suggestion, service.diary);
        expect(c.editor.text, append ? '自己的开头\n\n$edited' : edited);
        expect(c.editor.snapshot!.entry.savedAt, isNull);
        expect(await c.use(editedText: edited), false);
        expect(await c.undo(), true);
        expect(c.editor.text, '自己的开头');
        expect(service.calls, hasLength(1));
      },
    );
  }

  for (final invalid in ['', ' \n ', '字' * 5001]) {
    test(
      'invalid edited diary length ${invalid.length} preserves preview and draft',
      () async {
        final c = await editableDiary();
        final preview = c.preview;
        final before =
            (await db.customSelect('SELECT * FROM diary_entries').getSingle())
                .data;
        expect(await c.use(append: true, editedText: invalid), false);
        expect(c.error, isNotNull);
        expect(c.preview, same(preview));
        expect(
          (await db.customSelect('SELECT * FROM diary_entries').getSingle())
              .data,
          before,
        );
        expect(c.editor.text, '自己的开头');
        expect(service.calls, hasLength(1));
      },
    );
  }

  test(
    'edited graphemes include append separator and accept exact replace limit',
    () async {
      final c = await editableDiary(original: '字' * 4998);
      expect(await c.use(append: true, editedText: '好'), false);
      expect(c.error, contains('追加后超过'));
      final edited = '👨‍👩‍👧‍👦' * 5000;
      expect(await c.use(editedText: edited), true);
      expect(c.editor.text, edited);
      expect(await c.undo(), true);
      expect(c.editor.text, '字' * 4998);
    },
  );

  for (final change in ['draft', 'identity', 'credentials']) {
    test('edited diary rejects stale $change', () async {
      final c = await editableDiary();
      if (change == 'draft') {
        await c.editor.setText('后来的草稿');
        await c.editor.flush();
      } else if (change == 'identity') {
        await db.customStatement(
          'UPDATE identity_states SET generation=generation+1',
        );
      } else {
        credentialRevision++;
      }
      final before =
          (await db.customSelect('SELECT * FROM diary_entries').getSingle())
              .data;
      expect(await c.use(editedText: '本地修改'), false);
      expect(
        (await db.customSelect('SELECT * FROM diary_entries').getSingle()).data,
        before,
      );
      expect(service.calls, hasLength(1));
    });
  }

  test('edited diary failed write retries without another request and later edits block undo', () async {
    final c = await editableDiary();
    await db.customStatement(
      "CREATE TRIGGER fail_local_edit BEFORE UPDATE ON diary_entries BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END",
    );
    expect(await c.use(editedText: '改好的新正文'), false);
    expect(c.editor.text, '自己的开头');
    expect(c.preview!.suggestion, service.diary);
    await db.customStatement('DROP TRIGGER fail_local_edit');
    expect(await c.use(editedText: '改好的新正文'), true);
    await c.editor.setText('使用后的新修改');
    await c.editor.flush();
    expect(await c.undo(), false);
    expect(c.editor.text, '使用后的新修改');
    expect(service.calls, hasLength(1));
  });

  test(
    'unconsented, v1 consent, disabled and changing credentials send nothing',
    () async {
      final c = await open();
      expect(await c.request(), false);
      await LocalMemoryStore(goals).consent();
      await db.customStatement(
        'UPDATE assistant_settings SET consent_version = 1',
      );
      expect(await c.request(), false);
      await LocalMemoryStore(goals).consent();
      credentialRevision = -1;
      expect(await c.request(), false);
      credentialRevision = 0;
      await LocalMemoryStore(goals).revokeConsent();
      expect(await c.request(), false);
      expect(service.calls, isEmpty);
      expect(c.editor.text, '我读完了一章');
    },
  );

  test(
    'polish sends only the current text and does not modify or save before use',
    () async {
      await LocalMemoryStore(goals).consent();
      await LocalMemoryStore(goals)
          .add(const MemoryDraft(category: '其他', text: 'OMITTED memory'));
      final c = await open();
      expect(await c.request(), true);
      expect(service.calls.single.keys.toSet(), {
        'protocol',
        'request_id',
        'text',
      });
      expect(service.calls.single['text'], c.editor.text);
      expect(c.editor.text, '我读完了一章');
      expect(c.editor.snapshot!.entry.savedAt, isNull);
      c.discardPreview();
      expect(c.preview, isNull);
      expect(c.editor.text, '我读完了一章');
    },
  );

  test('use and undo write only drafts, not saved text', () async {
    await LocalMemoryStore(goals).consent();
    final original = await open(text: '原有已保存文字');
    expect(await original.editor.save(), true);
    final c = await open(
      id: original.editor.snapshot!.entry.id,
      text: '我读完了一章',
    );
    expect(await c.request(), true);
    expect(await c.use(), true);
    expect(c.editor.text, '我读完一章。');
    expect(c.canUndo, true);
    expect(
      (await c.editor.store.at(c.editor.snapshot!.entry.id))!.entry.content,
      '原有已保存文字',
    );
    expect(await c.undo(), true);
    expect(c.editor.text, '我读完了一章');
    expect(c.applied, false);
    expect(
      (await c.editor.store.at(c.editor.snapshot!.entry.id))!.entry.draftText,
      '我读完了一章',
    );
  });

  test('edits after preview or apply are never silently overwritten', () async {
    await LocalMemoryStore(goals).consent();
    final c = await open();
    await c.request();
    await c.editor.setText('新的文字');
    expect(await c.use(), false);
    expect(c.editor.text, '新的文字');
    await c.request();
    await c.use();
    await c.editor.setText('使用后继续编辑');
    expect(c.canUndo, false);
    expect(await c.undo(), false);
    expect(c.editor.text, '使用后继续编辑');
  });

  for (final action in ['cancel', 'dispose']) {
    test('$action during final access check discards the preview', () async {
      await LocalMemoryStore(goals).consent();
      final gated = GatedJournalContext(
        goals,
        credentialRevision: () => credentialRevision,
      );
      context = gated;
      final c = await open();
      final pending = c.request();
      await gated.reached.future;
      if (action == 'cancel') {
        c.cancel();
      } else {
        c.dispose();
        controllers.remove(c);
      }
      gated.release.complete();
      expect(await pending, false);
      expect(c.preview, isNull);
      expect(c.editor.text, '我读完了一章');
    });
  }

  test('cancelled use cannot clear a newer request busy state', () async {
    await LocalMemoryStore(goals).consent();
    final c = await open();
    await c.request();
    final use = c.use();
    c.cancel();
    service.gate = Completer<void>();
    final retry = c.request();
    expect(await use, false);
    final stillBusy = c.busy;
    c.cancel();
    service.gate!.complete();
    await retry;
    expect(stillBusy, true);
    expect(c.editor.text, '我读完了一章');
  });

  test('cancelled undo does not overwrite the applied draft', () async {
    await LocalMemoryStore(goals).consent();
    final c = await open();
    await c.request();
    await c.use();
    final pending = c.undo();
    c.cancel();
    expect(await pending, false);
    expect(c.editor.text, '我读完一章。');
  });

  test(
    'failed AI draft write leaves the original text and undo state intact',
    () async {
      await LocalMemoryStore(goals).consent();
      final c = await open();
      await c.request();
      await db.customStatement(
        "CREATE TRIGGER reject_ai_draft BEFORE UPDATE ON quick_notes "
        "WHEN NEW.draft_text = '我读完一章。' BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END",
      );
      expect(await c.use(), false);
      expect(c.editor.text, '我读完了一章');
      expect(c.applied, false);
      expect(c.canUndo, false);
      expect(
        (await c.editor.store.at(c.editor.snapshot!.entry.id))!.entry.draftText,
        '我读完了一章',
      );
      await db.customStatement('DROP TRIGGER reject_ai_draft');
      expect(await c.use(), true);
    },
  );

  test('failed undo preserves the applied draft and can be retried', () async {
    await LocalMemoryStore(goals).consent();
    final c = await open();
    await c.request();
    await c.use();
    await db.customStatement(
      "CREATE TRIGGER reject_ai_undo BEFORE UPDATE ON quick_notes "
      "WHEN NEW.draft_text = '我读完了一章' BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END",
    );
    expect(await c.undo(), false);
    expect(c.editor.text, '我读完一章。');
    expect(c.canUndo, true);
    await db.customStatement('DROP TRIGGER reject_ai_undo');
    expect(await c.undo(), true);
    expect(c.editor.text, '我读完了一章');
  });

  for (final change in ['cancel', 'edit', 'revoke', 'credential', 'identity']) {
    test(
      'late result after $change cannot change the draft or leave a preview',
      () async {
        await LocalMemoryStore(goals).consent();
        final c = await open();
        service.gate = Completer<void>();
        final pending = c.request();
        await waitCall();
        expect(await c.request(), false);
        switch (change) {
          case 'cancel':
            c.cancel();
          case 'edit':
            await c.editor.setText('新输入');
          case 'revoke':
            await LocalMemoryStore(goals).revokeConsent();
          case 'credential':
            credentialRevision++;
          case 'identity':
            final identities = IdentityStore(db);
            await identities.finish(
              await identities.begin(
                SyncIdentity.account('55555555-5555-4555-8555-555555555555'),
              ),
            );
            await identities.finish(await identities.begin(SyncIdentity.guest));
        }
        service.gate!.complete();
        expect(await pending, false);
        expect(c.preview, isNull);
        expect(c.editor.text, change == 'edit' ? '新输入' : '我读完了一章');
        expect(service.calls, hasLength(1));
      },
    );
  }

  test(
    'failure can retry explicitly without automatic duplicate request',
    () async {
      await LocalMemoryStore(goals).consent();
      final c = await open();
      service.fail = true;
      expect(await c.request(), false);
      expect(c.error, isNotNull);
      service.fail = false;
      expect(await c.request(), true);
      expect(service.calls, hasLength(2));
      expect(
        service.calls.first['request_id'],
        isNot(service.calls.last['request_id']),
      );
    },
  );

  for (final byteCount in [63999, 64000, 64001, 65536, 65537, 100000]) {
    test('diary byte budget $byteCount preserves sources and draft', () async {
      await LocalMemoryStore(goals).consent();
      final notes =
          diaryPayloadOfSize(byteCount, unit: '中')['notes']! as List<String>;
      final store = LocalQuickNoteStore(goals);
      await saveJournalNotes(store, notes);
      final c = await open(kind: JournalKind.diary, text: '已保存的原日记');
      expect(await c.editor.save(), true);
      final editing = await open(kind: JournalKind.diary, text: '还未保存的日记草稿');
      expect(await editing.request(), byteCount <= 64000);
      if (byteCount <= 64000) {
        expect(service.calls, hasLength(1));
        expect(
          utf8.encode(jsonEncode(service.calls.single)),
          hasLength(byteCount),
        );
        expect(service.calls.single['notes'], unorderedEquals(notes));
      } else {
        expect(service.calls, isEmpty);
        expect(editing.error, contains('今天的素材太多'));
        expect(editing.preview, isNull);
      }
      expect(editing.editor.text, '还未保存的日记草稿');
      final saved = await editing.editor.store.at(
        editing.editor.snapshot!.entry.id,
      );
      expect(saved!.entry.content, '已保存的原日记');
      expect(saved.entry.draftText, '还未保存的日记草稿');
      expect(
        (await store.savedOn(clock.day)).map((row) => row.entry.content),
        unorderedEquals(notes),
      );
      expect(editing.busy, false);
      expect(editing.canUndo, false);
    });
  }

  test('diary budget includes goal titles and saved check-in text', () async {
    await LocalMemoryStore(goals).consent();
    final notes = diaryPayloadOfSize(63999)['notes']! as List<String>;
    await saveJournalNotes(LocalQuickNoteStore(goals), notes);
    final id = await goals.create(
      GoalDraft(title: 't' * 60, kind: GoalKind.habit),
    );
    final records = LocalDayRecordStore(goals);
    var record = await records.beginDraft(id, clock.day);
    record = await records.writeDraft(
      record.record.id,
      content: 'r' * 500,
      expectedDraftRevision: record.record.draftRevision,
    );
    await records.save(
      record.record.id,
      operationId: const Uuid().v4(),
      expectedRevision: record.record.revision,
      expectedDraftRevision: record.record.draftRevision,
    );
    final c = await open(kind: JournalKind.diary);
    expect(await c.request(), false);
    expect(service.calls, isEmpty);
    expect(c.error, contains('今天的素材太多'));
    expect(c.editor.text, '我读完了一章');
  });

  test('diary accepts exactly 1000 small notes without truncation', () async {
    await LocalMemoryStore(goals).consent();
    await saveJournalNotes(LocalQuickNoteStore(goals), List.filled(1000, '读书'));
    final c = await open(kind: JournalKind.diary);
    expect(await c.request(), true);
    expect(service.calls.single['notes'], List.filled(1000, '读书'));
  });

  test(
    'diary source count limit is clear and never silently truncates',
    () async {
      await LocalMemoryStore(goals).consent();
      final store = LocalQuickNoteStore(goals);
      await saveJournalNotes(store, List.filled(1001, '读书'));
      final c = await open(kind: JournalKind.diary);
      expect(await c.request(), false);
      expect(service.calls, isEmpty);
      expect(c.error, contains('今天的素材太多'));
      expect(await store.savedOn(clock.day), hasLength(1001));
    },
  );

  test(
    'diary remote size rejection is specific and retry stays explicit',
    () async {
      await LocalMemoryStore(goals).consent();
      await saveJournalNotes(LocalQuickNoteStore(goals), ['读完一章']);
      final c = await open(kind: JournalKind.diary);
      service.fail = true;
      service.failureKind = AssistantFailureKind.tooLarge;
      expect(await c.request(), false);
      expect(c.error, contains('今天的素材太多'));
      expect(c.editor.text, '我读完了一章');
      expect(c.preview, isNull);
      expect(service.calls, hasLength(1));
      service.fail = false;
      expect(await c.request(), true);
      expect(c.error, isNull);
      expect(service.calls, hasLength(2));
      expect(c.editor.text, '我读完了一章');
    },
  );

  test('diary append is explicit, bounded and reversible', () async {
    await LocalMemoryStore(goals).consent();
    final note = await open(text: '读完一章');
    await note.editor.save();
    final c = await open(kind: JournalKind.diary, text: '自己的开头');
    expect(await c.request(), true);
    expect(await c.use(append: true), true);
    expect(c.editor.text, '自己的开头\n\n我今天读完一章。');
    expect(await c.undo(), true);
    expect(c.editor.text, '自己的开头');
    await c.editor.setText('a' * 4999);
    await c.request();
    expect(await c.use(append: true), false);
    expect(c.editor.text, 'a' * 4999);
  });

  test(
    'historical diary cannot consume today and empty day offers no draft',
    () async {
      await LocalMemoryStore(goals).consent();
      final c = await open(kind: JournalKind.diary, text: 'existing');
      expect(await c.request(), false);
      expect(c.error, contains('素材不足'));
      expect(c.editor.text, 'existing');
      service.calls.clear();
      clock.setDay(2026, 10, 24);
      expect(await c.request(), false);
      expect(service.calls, isEmpty);
    },
  );

  test('day snapshot excludes other owners, history, drafts, diary and photo metadata', () async {
    clock.setDay(2026, 10, 22);
    final historical = await open(text: 'OMITTED yesterday');
    await historical.editor.save();
    final goalId = await goals.create(
      const GoalDraft(title: '阅读', kind: GoalKind.habit),
    );
    clock.setDay(2026, 10, 23);
    final note = await open(text: 'SENT note');
    await note.editor.save();
    await open(
      id: note.editor.snapshot!.entry.id,
      text: 'OMITTED unsaved change',
    );
    await open(text: 'OMITTED new draft');
    final diary = await open(kind: JournalKind.diary, text: 'OMITTED diary');
    await diary.editor.save();
    final records = LocalDayRecordStore(goals);
    var row = await records.beginDraft(goalId, clock.day);
    row = await records.writeDraft(
      row.record.id,
      content: 'SENT record',
      expectedDraftRevision: row.record.draftRevision,
    );
    row = await records.addPhoto(
      row.record.id,
      photo: RecordPhotoInput(
        id: const Uuid().v4(),
        width: 20,
        height: 20,
        byteCount: 400,
        sha256: 'a' * 64,
      ),
      expectedDraftRevision: row.record.draftRevision,
    );
    await records.save(
      row.record.id,
      operationId: const Uuid().v4(),
      expectedRevision: row.record.revision,
      expectedDraftRevision: row.record.draftRevision,
    );
    await goals.setCompleted(goalId, true, expectedDay: clock.day);
    await LocalMemoryStore(goals)
        .add(const MemoryDraft(category: '其他', text: 'OMITTED memory'));
    await goals.create(
      GoalDraft(
        title: 'OMITTED future',
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
      const GoalDraft(title: 'OMITTED other', kind: GoalKind.habit),
    );
    final request = await context.diary(clock.day);
    expect(request.notes, ['SENT note']);
    expect(request.entries.single.toJson(), {
      'title': '阅读',
      'completed': true,
      'text': 'SENT record',
    });
    final body = jsonEncode(request.toJson());
    for (final omitted in [
      'OMITTED',
      'photos',
      'sha256',
      'owner',
      'planned_time',
      'draft',
      'filename',
      '.jpg',
    ]) {
      expect(body, isNot(contains(omitted)));
    }
  });
}
