import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/sync/identity_store.dart';
import 'package:habit_checkin/data/sync/sync_identity.dart';
import 'package:habit_checkin/features/journal/data/local_journal_store.dart';
import 'package:habit_checkin/features/journal/domain/journal_entry.dart';
import 'package:habit_checkin/features/journal/presentation/journal_editor_controller.dart';
import 'package:habit_checkin/features/records/data/record_photo.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'support/journal_fixtures.dart';
import 'support/record_fixtures.dart';
import 'support/test_clock.dart';

const _saveError = '未能保存，请重试。原有内容未被清空。';

class _FaultStore extends LocalQuickNoteStore {
  _FaultStore(super.goals);
  Object? draftFailure;
  Object? saveFailure;
  Object? deleteFailure;
  int deletes = 0;

  @override
  Future<JournalSnapshot> writeDraft(
    String id, {
    required String content,
    required int expectedDraftRevision,
  }) {
    if (draftFailure case final error?) throw error;
    return super.writeDraft(
      id,
      content: content,
      expectedDraftRevision: expectedDraftRevision,
    );
  }

  @override
  Future<JournalSnapshot> save(
    String id, {
    required String operationId,
    required int expectedRevision,
    required int expectedDraftRevision,
  }) {
    if (saveFailure case final error?) throw error;
    return super.save(
      id,
      operationId: operationId,
      expectedRevision: expectedRevision,
      expectedDraftRevision: expectedDraftRevision,
    );
  }

  @override
  Future<void> delete(
    String id, {
    required String operationId,
    required int expectedRevision,
    required int expectedDraftRevision,
  }) {
    deletes++;
    if (deleteFailure case final error?) throw error;
    return super.delete(
      id,
      operationId: operationId,
      expectedRevision: expectedRevision,
      expectedDraftRevision: expectedDraftRevision,
    );
  }
}

void main() {
  setUpAll(tzdata.initializeTimeZones);
  late AppDatabase db;
  late _FaultStore store;
  late JournalEditorController editor;
  late StubRecordPhotoPicker picker;

  Future<List<Map<String, Object?>>> rows() async =>
      (await db.customSelect('SELECT * FROM quick_notes ORDER BY id').get())
          .map((row) => row.data)
          .toList();

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    final clock = TestClock()..setDay(2026, 10, 27);
    final lease = await IdentityStore(db).active();
    store = _FaultStore(
      LocalGoalRepository(
        db,
        clock,
        owner: lease.identity.owner,
        identityLease: lease,
      ),
    );
    picker = StubRecordPhotoPicker();
    editor = JournalEditorController(
      store: store,
      files: MemoryJournalPhotoFiles(JournalKind.quickNote),
      picker: picker,
    );
    await editor.initialize(day: clock.day);
    await editor.setText('合成：保留的草稿。');
  });
  tearDown(() async {
    expect(picker.calls, 0);
    editor.dispose();
    await db.close();
  });

  test(
    'R15 failed draft flush blocks delete and retains save wording',
    () async {
      final before = await rows();
      store.draftFailure = const FileSystemException('SYNTHETIC draft failure');
      await editor.setText('合成：尚未落盘的新修改。');
      expect(await editor.delete(), isFalse);
      expect(store.deletes, 0);
      expect(editor.error, _saveError);
      expect(editor.text, '合成：尚未落盘的新修改。');
      expect(editor.closed, isFalse);
      expect(editor.busy, isFalse);
      expect(editor.dirty, isTrue);
      expect(await rows(), before);
      expect(await editor.save(), isFalse);
      expect(editor.error, _saveError);
      expect(await rows(), before);
      store.draftFailure = null;
      await editor.setText(editor.text);
      await editor.flush();
      expect(editor.error, isNull);
      expect(store.deletes, 0);
    },
  );

  test('R15 ordinary save failure does not become a delete failure', () async {
    final before = await rows();
    store.saveFailure = StateError('SYNTHETIC save failure');
    expect(await editor.save(), isFalse);
    expect(editor.error, _saveError);
    expect(editor.closed, isFalse);
    expect(editor.busy, isFalse);
    expect(editor.text, '合成：保留的草稿。');
    expect(await rows(), before);
    expect(store.deletes, 0);
  });

  for (final failure in <(Object, String)>[
    (const JournalRuleException('合成：版本已变化'), '合成：版本已变化'),
    (const RecordPhotoException('合成：照片不可读取'), '合成：照片不可读取'),
    (const StaleIdentity(), '身份已变化，请返回后重新打开'),
  ]) {
    test(
      'R15 delete preserves specific ${failure.$1.runtimeType} message',
      () async {
        final before = await rows();
        store.deleteFailure = failure.$1;
        expect(await editor.delete(), isFalse);
        expect(editor.error, failure.$2);
        expect(store.deletes, 1);
        expect(editor.text, '合成：保留的草稿。');
        expect(editor.closed, isFalse);
        expect(editor.busy, isFalse);
        expect(await rows(), before);
      },
    );
  }

  test(
    'R15 changed identity blocks deletion before the operation starts',
    () async {
      final before = await rows();
      final identities = IdentityStore(db);
      await identities.finish(
        await identities.begin(
          SyncIdentity.account('55555555-5555-4555-8555-555555555555'),
        ),
      );
      expect(await editor.delete(), isFalse);
      expect(editor.error, '身份已变化，请返回后重新打开');
      expect(store.deletes, 0);
      expect(editor.closed, isFalse);
      expect(editor.text, '合成：保留的草稿。');
      expect(await rows(), before);
    },
  );
}
