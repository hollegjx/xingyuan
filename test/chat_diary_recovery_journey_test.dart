import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/assistant/data/local_conversation_store.dart';
import 'package:habit_checkin/features/journal/data/chat_diary_store.dart';
import 'package:habit_checkin/features/journal/domain/journal_entry.dart';
import 'package:habit_checkin/features/journal/journal_providers.dart';
import 'package:habit_checkin/features/journal/presentation/chat_diary_page.dart';
import 'package:habit_checkin/features/journal/presentation/diary_preview_body.dart';
import 'package:habit_checkin/features/journal/presentation/journal_editor_page.dart';
import 'package:habit_checkin/features/records/data/local_day_record_store.dart';
import 'package:habit_checkin/shared/local_date.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:uuid/uuid.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

import 'assistant_conversation_ui_test.dart' show openPlanning, sendText;
import 'assistant_diary_entry_layout_test.dart' show viewport;
import 'assistant_diary_ui_test.dart' show tapDiaryControl;
import 'assistant_identity_ui_test.dart' show switchAway, switchBack;
import 'journal_diary_capture_test.dart'
    show capture, captureFont, loadDiaryCaptureFont;
import 'support/journal_fixtures.dart';
import 'support/test_assistant_service.dart';
import 'support/ui_harness.dart';

const savedText = '合成已保存日记：读完一章，暂时没想好是否散步。';
const draftText = '合成未保存草稿：这一段还没有整理完。';
const modelText = '合成模型原建议：今天读了一章。';
const correction = TextEditingValue(
  text: '我今天仍有点累。\n这是本地修正，不加乐观结尾。',
  selection: TextSelection(baseOffset: 2, extentOffset: 6),
);
const draftWarning = '这一天有未保存的草稿，请先在日记中处理；原内容未改动。';
const conflictWarning = '内容已有新的修改，请重新打开后再保存';

Finder control(String key) => find.byKey(ValueKey(key));

// Same fixture helper as AI1's independent regression suite; no QA backlog.
Future<void> saveDiary(UiHarness app, LocalDate day, String text) async {
  final store = await app.container.read(diaryStoreProvider.future);
  var row = await store.beginDraft(day);
  row = await store.writeDraft(
    row.entry.id,
    content: text,
    expectedDraftRevision: row.entry.draftRevision,
  );
  await store.save(
    row.entry.id,
    operationId: const Uuid().v4(),
    expectedRevision: row.entry.revision,
    expectedDraftRevision: row.entry.draftRevision,
  );
}

Future<Map<String, Object>> protectedState(UiHarness app) async => {
  for (final table in [
    'diary_entries',
    'diary_photos',
    'assistant_diary_proposals',
    'assistant_messages',
    'assistant_sessions',
  ])
    table:
        (await app.database
                .customSelect('SELECT * FROM $table ORDER BY id')
                .get())
            .map((row) => row.data)
            .toList(),
};

Future<void> addPhotoMetadata(UiHarness app, {LocalDate? day}) async {
  final store = await app.container.read(diaryStoreProvider.future);
  final row = await store.beginDraft(day ?? app.clock.day);
  await store.addPhoto(
    row.entry.id,
    expectedDraftRevision: row.entry.draftRevision,
    photo: RecordPhotoInput(
      id: const Uuid().v4(),
      width: 10,
      height: 10,
      byteCount: 100,
      sha256: 'a' * 64,
    ),
  );
}

Future<void> pendingDraft(UiHarness app, {LocalDate? day}) async {
  final store = await app.container.read(diaryStoreProvider.future);
  final row = await store.beginDraft(day ?? app.clock.day);
  await store.writeDraft(
    row.entry.id,
    content: draftText,
    expectedDraftRevision: row.entry.draftRevision,
  );
  await addPhotoMetadata(app, day: day);
}

Future<(UiHarness, ConversationTestService)> openRecoveryFixture(
  WidgetTester tester,
  GlobalKey boundary, {
  required bool draftBeforePreview,
}) async {
  final app = UiHarness();
  await LocalConversationStore(app.repository).memories.consent();
  final service = ConversationTestService()
    ..onTurn = (request) async => TurnResponse.fromJson({
      'protocol': assistantProtocol,
      'request_id': request.requestId,
      'reply': '请预览合成日记建议。',
      'plan': null,
      'memory_ops': <Object?>[],
      'diary': {'date': request.now.date.key, 'content': modelText},
    }, request: request);
  await app.mount(
    tester,
    assistantService: service,
    assistantCredentials: ConversationTestCredentials(),
    journalPhotoFiles: {
      JournalKind.diary: MemoryJournalPhotoFiles(JournalKind.diary),
    },
    wrapApp: (child) => RepaintBoundary(key: boundary, child: child),
  );
  await openPlanning(tester);
  await saveDiary(app, app.clock.day.addDays(-1), '合成昨日原文，不参与本次操作。');
  await addPhotoMetadata(app);
  await saveDiary(app, app.clock.day, savedText);
  if (draftBeforePreview) await pendingDraft(app);
  await sendText(tester, '今天读了一章，请整理成今天的日记建议。');
  await tapDiaryControl(tester, find.text('预览日记建议'));
  await tapDiaryControl(tester, control('chat-diary-suggested-date'));
  await tapDiaryControl(tester, control('chat-diary-edit'));
  await tester.showKeyboard(control('chat-diary-edited-text'));
  tester.testTextInput.updateEditingValue(correction);
  await tester.pumpAndSettle();
  await tapDiaryControl(tester, control('chat-diary-edit'));
  expectCorrection(tester);
  await tapDiaryControl(tester, find.text('追加'));
  expect(service.requests, hasLength(1));
  expect(service.summaries, isEmpty);
  return (app, service);
}

void expectCorrection(WidgetTester tester) {
  expect(
    tester
        .widget<DiaryPreviewBody>(find.byType(DiaryPreviewBody))
        .editedText!
        .value,
    correction,
  );
}

Future<void> confirmSave(WidgetTester tester) async {
  await tapDiaryControl(tester, control('chat-diary-save'));
  await tapDiaryControl(tester, control('chat-diary-confirm-save'));
}

Future<void> reselectDay(WidgetTester tester) async {
  await tapDiaryControl(tester, control('chat-diary-date'));
  await tapVisible(tester, find.text('确定'));
  expectCorrection(tester);
  expect(
    tester.widget<FilledButton>(control('chat-diary-save')).onPressed,
    isNull,
    reason: 'A refreshed nonempty original requires a fresh merge choice.',
  );
}

Future<void> frame(
  WidgetTester tester,
  GlobalKey boundary,
  String name,
  Size size,
  String text, {
  bool firstLineOnly = false,
  Finder? reveal,
}) async {
  final target = find.text(text);
  await Scrollable.ensureVisible(
    tester.element(reveal ?? target),
    alignment: 0,
  );
  await tester.pumpAndSettle();
  await capture(
    tester,
    boundary,
    name,
    size,
    text: target,
    expectedText: text,
    firstLineOnly: firstLineOnly,
  );
}

void main() {
  setUpAll(() async {
    tzdata.initializeTimeZones();
    await loadDiaryCaptureFont();
    if (captureFont.isNotEmpty) {
      final bytes = ByteData.sublistView(await File(captureFont).readAsBytes());
      for (final family in ['CupertinoSystemText', 'CupertinoSystemDisplay']) {
        await (FontLoader(family)..addFont(Future.value(bytes))).load();
      }
    }
  });

  for (final before in [true, false]) {
    for (final large in [false, true]) {
      final theme = before == large ? Brightness.dark : Brightness.light;
      final size = large ? const Size(320, 568) : const Size(390, 844);
      final name =
          '${before ? 'existing-draft' : 'concurrent-draft'}-'
          '${large ? '320-4x' : '390-1x'}-${theme.name}';
      testUiWidgets('R5 recovery entry $name', (tester) async {
        viewport(tester, size, large ? 4 : 1, theme);
        final boundary = GlobalKey();
        final (app, service) = await openRecoveryFixture(
          tester,
          boundary,
          draftBeforePreview: before,
        );
        if (!before) {
          await saveDiary(app, app.clock.day, '合成并发保存的新版本。');
          await pendingDraft(app);
        }
        final state = await protectedState(app);
        final store = await app.container.read(diaryStoreProvider.future);
        final original = (await store.atDay(app.clock.day))!;
        expect(original.entry.isSaved, isTrue);
        expect(original.entry.draftText, draftText);
        expect(original.savedPhotos, hasLength(1));
        expect(original.draftPhotos, hasLength(2));
        for (var attempt = 0; attempt < 2; attempt++) {
          await confirmSave(tester);
          expect(
            find.text(before ? draftWarning : conflictWarning),
            findsOneWidget,
          );
          expect(await protectedState(app), state);
          expectCorrection(tester);
          expect(control('chat-diary-receipt'), findsNothing);
          expect(service.requests, hasLength(1));
          expect(service.summaries, isEmpty);
        }
        await frame(
          tester,
          boundary,
          'r5-$name-blocked',
          size,
          before ? draftWarning : conflictWarning,
          firstLineOnly: true,
        );
        await frame(tester, boundary, 'r5-$name-actions', size, '保存日记');

        // Same-day refresh can fix a stale snapshot, not an unresolved draft.
        await reselectDay(tester);
        await tapDiaryControl(tester, find.text('追加'));
        await confirmSave(tester);
        expect(find.text(draftWarning), findsOneWidget);
        expect(await protectedState(app), state);
        expectCorrection(tester);
        expect(control('journal-text'), findsNothing);
        await tapDiaryControl(tester, control('chat-diary-original-toggle'));
        expect(find.text(original.entry.content), findsOneWidget);
        expect(await protectedState(app), state);

        await tapVisible(tester, find.byType(BackButton));
        expect(control('chat-diary-discard-cancel'), findsOneWidget);
        await frame(tester, boundary, 'r5-$name-leave', size, '继续修改');
        await tapDiaryControl(tester, control('chat-diary-discard-cancel'));
        expect(find.byType(ChatDiaryPage), findsOneWidget);
        expectCorrection(tester);
        await tapDiaryControl(tester, control('chat-diary-cancel'));
        await tapDiaryControl(tester, control('chat-diary-discard-cancel'));
        expectCorrection(tester);
        expect(await protectedState(app), state);
        expect(service.requests, hasLength(1));
        expect(tester.takeException(), isNull);
        debugPrint(
          'R5 protected $name: five tables unchanged; saved photo1, '
          'draft photos2; exact edit/selection; requests1; no receipt.',
        );

        // AI1's failing-first acceptance remains, followed by the round trip.
        expect(
          control('chat-diary-view'),
          findsOneWidget,
          reason:
              'R5: open the selected diary without discarding the correction. '
              'Repeat save, same-day refresh, original disclosure and declining '
              'leave/cancel do not resolve this unsaved draft.',
        );
        await frame(
          tester,
          boundary,
          'r5-$name-recovery',
          size,
          '处理草稿',
          reveal: control('chat-diary-view'),
        );
        final label = tester.renderObject<RenderParagraph>(
          find.descendant(
            of: find.text('处理草稿'),
            matching: find.byType(RichText),
          ),
        );
        expect(
          label
              .getBoxesForSelection(
                const TextSelection(baseOffset: 0, extentOffset: 4),
              )
              .map((box) => box.top)
              .toSet(),
          hasLength(1),
          reason: 'The four-character recovery action must not wrap a lone character.',
        );
        final recover = tester
            .widget<TextButton>(control('chat-diary-view'))
            .onPressed!;
        recover();
        recover();
        await tester.pumpAndSettle();
        expect(find.byType(JournalEditorPage), findsOneWidget);
        expect(
          tester.widget<TextField>(control('journal-text')).controller!.text,
          draftText,
        );
        expect(await protectedState(app), state);
        await Scrollable.ensureVisible(
          tester.element(control('journal-text')),
          alignment: 0,
        );
        await tester.pumpAndSettle();
        await capture(
          tester,
          boundary,
          'r5-$name-editor',
          size,
          text: control('journal-text'),
          expectedText: draftText,
          firstLineOnly: true,
          editable: true,
        );
        await tapVisible(tester, find.byType(BackButton));
        expectCorrection(tester);
        expect(await protectedState(app), state);
        expect(find.text(draftWarning), findsOneWidget);
        await confirmSave(tester);
        expect(find.text(draftWarning), findsOneWidget);
        expect(await protectedState(app), state);

        await tapDiaryControl(tester, control('chat-diary-view'));
        await tapVisible(tester, control('save-journal'));
        expect(find.byType(JournalEditorPage), findsNothing);
        expectCorrection(tester);
        expect(find.text(draftText), findsOneWidget);
        expect(
          tester.widget<FilledButton>(control('chat-diary-save')).onPressed,
          isNull,
        );
        expect(control('chat-diary-view'), findsNothing);
        await frame(
          tester,
          boundary,
          'r5-$name-current-original',
          size,
          draftText,
          firstLineOnly: true,
        );
        final handled = await protectedState(app);
        final handledDiary = (await store.atDay(app.clock.day))!;
        expect(handledDiary.entry.content, draftText);
        expect(handledDiary.savedPhotos, hasLength(2));
        expect(handledDiary.entry.revision, original.entry.revision + 1);
        for (final table in [
          'assistant_diary_proposals',
          'assistant_messages',
          'assistant_sessions',
        ]) {
          expect(handled[table], state[table]);
        }
        await tapDiaryControl(tester, find.text('追加'));
        expect(
          tester.widget<Text>(control('chat-diary-suggestion')).data,
          '$draftText\n\n${correction.text}',
        );
        await frame(tester, boundary, 'r5-$name-refreshed', size, '保存日记');
        await tapDiaryControl(tester, control('chat-diary-save'));
        await tapDiaryControl(tester, control('chat-diary-abort-save'));
        expect(await protectedState(app), handled);
        expectCorrection(tester);
        final save = tester
            .widget<FilledButton>(control('chat-diary-save'))
            .onPressed!;
        save();
        save();
        await tester.pumpAndSettle();
        await tapDiaryControl(tester, control('chat-diary-confirm-save'));
        expect(control('chat-diary-receipt'), findsOneWidget);
        final saved = (await store.atDay(app.clock.day))!;
        expect(saved.entry.content, '$draftText\n\n${correction.text}');
        expect(saved.entry.revision, handledDiary.entry.revision + 1);
        final applied = await protectedState(app);
        save();
        recover();
        await tester.pumpAndSettle();
        expect(control('chat-diary-confirm-save'), findsNothing);
        expect(find.byType(JournalEditorPage), findsNothing);
        expect(await protectedState(app), applied);
        for (final table in [
          'diary_photos',
          'assistant_messages',
          'assistant_sessions',
        ]) {
          expect(applied[table], handled[table]);
        }
        final proposal = await app.database
            .select(app.database.assistantDiaryProposals)
            .getSingle();
        expect(proposal.content, modelText);
        expect(proposal.status, 'applied');
        expect(
          (await store.atDay(app.clock.day.addDays(-1)))!.entry.content,
          '合成昨日原文，不参与本次操作。',
        );
        if (!before) {
          await saveDiary(app, app.clock.day, '合成后续修改，撤销不得覆盖。');
        }
        final beforeUndo = await protectedState(app);
        await tapDiaryControl(tester, control('chat-diary-undo'));
        await tapDiaryControl(tester, control('chat-diary-confirm-undo'));
        if (before) {
          expect((await store.atDay(app.clock.day))!.entry.content, draftText);
          expect(
            (await protectedState(app))['diary_photos'],
            handled['diary_photos'],
          );
        } else {
          expect(await protectedState(app), beforeUndo);
          expect(find.textContaining('不能自动撤销'), findsOneWidget);
        }
        expect(service.requests, hasLength(1));
        expect(service.summaries, isEmpty);
        expect(tester.takeException(), isNull);
      }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
    }
  }

  for (final handled in ['cancelled', 'applied']) {
    for (final inEditor in [false, true]) {
      testUiWidgets(
        'R5 $handled ${inEditor ? 'during' : 'before'} recovery is not revived',
        (tester) async {
          final (app, service) = await openRecoveryFixture(
            tester,
            GlobalKey(),
            draftBeforePreview: true,
          );
          await confirmSave(tester);
          final recover = tester
              .widget<TextButton>(control('chat-diary-view'))
              .onPressed!;
          if (inEditor) {
            await tapDiaryControl(tester, control('chat-diary-view'));
          }
          final diaries = await app.container.read(diaryStoreProvider.future);
          final proposals = ChatDiaryStore(diaries.goals);
          final row = await app.database
              .select(app.database.assistantDiaryProposals)
              .getSingle();
          if (handled == 'cancelled') {
            await proposals.cancel(row.id);
          } else {
            await saveDiary(app, app.clock.day, draftText);
            await proposals.apply(
              await proposals.preview(row.id, app.clock.day),
              ChatDiaryMode.append,
            );
          }
          final before = await protectedState(app);
          if (inEditor) {
            await tapVisible(tester, find.byType(BackButton));
          } else {
            recover();
            await tester.pumpAndSettle();
          }
          expect(find.byType(JournalEditorPage), findsNothing);
          expect(control('chat-diary-save'), findsNothing);
          expect(control('chat-diary-edit'), findsNothing);
          expect(
            control('chat-diary-receipt'),
            handled == 'applied' ? findsOneWidget : findsNothing,
          );
          recover();
          await tester.pumpAndSettle();
          expect(find.byType(JournalEditorPage), findsNothing);
          expect(await protectedState(app), before);
          expect(service.requests, hasLength(1));
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testUiWidgets(
    'R5 resolved draft refreshes without opening a clean editor or writing',
    (tester) async {
      final (app, service) = await openRecoveryFixture(
        tester,
        GlobalKey(),
        draftBeforePreview: true,
      );
      await confirmSave(tester);
      await saveDiary(app, app.clock.day, '合成另一窗口已处理的草稿。');
      final before = await protectedState(app);
      await tapDiaryControl(tester, control('chat-diary-view'));
      expect(find.byType(JournalEditorPage), findsNothing);
      expectCorrection(tester);
      expect(control('chat-diary-view'), findsNothing);
      expect(
        tester.widget<FilledButton>(control('chat-diary-save')).onPressed,
        isNull,
      );
      await tapDiaryControl(tester, control('chat-diary-original-toggle'));
      expect(find.text('合成另一窗口已处理的草稿。'), findsOneWidget);
      expect(await protectedState(app), before);
      expect(service.requests, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testUiWidgets('R5 recovery opens the explicitly selected historical diary', (
    tester,
  ) async {
    final (app, service) = await openRecoveryFixture(
      tester,
      GlobalKey(),
      draftBeforePreview: false,
    );
    final previous = app.clock.day.addDays(-1);
    await pendingDraft(app, day: previous);
    await tapDiaryControl(tester, control('chat-diary-date'));
    await tapVisible(tester, find.text('${previous.day}'));
    await tapVisible(tester, find.text('确定'));
    await tapDiaryControl(tester, find.text('追加'));
    await confirmSave(tester);
    final before = await protectedState(app);
    await tapDiaryControl(tester, control('chat-diary-view'));
    expect(
      tester.widget<JournalEditorPage>(find.byType(JournalEditorPage)).day,
      previous,
    );
    expect(
      tester.widget<TextField>(control('journal-text')).controller!.text,
      draftText,
    );
    expect(await protectedState(app), before);
    await tapVisible(tester, find.byType(BackButton));
    expectCorrection(tester);
    expect(await protectedState(app), before);
    expect(service.requests, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testUiWidgets(
    'R5 identity change during recovery hides both routes and late actions',
    (tester) async {
      final (app, service) = await openRecoveryFixture(
        tester,
        GlobalKey(),
        draftBeforePreview: true,
      );
      await confirmSave(tester);
      final recover = tester
          .widget<TextButton>(control('chat-diary-view'))
          .onPressed!;
      await tapDiaryControl(tester, control('chat-diary-view'));
      final save = tester
          .widget<TextButton>(control('save-journal'))
          .onPressed!;
      final before = await protectedState(app);
      await switchAway(tester, app);
      save();
      recover();
      await tester.pumpAndSettle();
      expect(control('journal-text'), findsNothing);
      expect(control('chat-diary-save'), findsNothing);
      expect(find.text(correction.text), findsNothing);
      await switchBack(tester, app);
      recover();
      await tester.pumpAndSettle();
      expect(control('chat-diary-view'), findsNothing);
      expect(control('journal-text'), findsNothing);
      expect(await protectedState(app), before);
      expect(service.requests, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testUiWidgets(
    'R5 new draft during final confirmation still blocks after recovery',
    (tester) async {
      final (app, service) = await openRecoveryFixture(
        tester,
        GlobalKey(),
        draftBeforePreview: true,
      );
      await confirmSave(tester);
      await tapDiaryControl(tester, control('chat-diary-view'));
      await tapVisible(tester, control('save-journal'));
      expectCorrection(tester);
      await tapDiaryControl(tester, find.text('追加'));
      await tapDiaryControl(tester, control('chat-diary-save'));
      final store = await app.container.read(diaryStoreProvider.future);
      final draft = await store.beginDraft(app.clock.day);
      await store.writeDraft(
        draft.entry.id,
        content: '合成再次并发草稿。',
        expectedDraftRevision: draft.entry.draftRevision,
      );
      final before = await protectedState(app);
      await tapDiaryControl(tester, control('chat-diary-confirm-save'));
      expect(find.text(conflictWarning), findsOneWidget);
      expectCorrection(tester);
      expect(await protectedState(app), before);
      expect(control('chat-diary-receipt'), findsNothing);
      expect(control('chat-diary-view'), findsOneWidget);
      expect(service.requests, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testUiWidgets('R5 saved revision has an existing same-day recovery path', (
    tester,
  ) async {
    const size = Size(390, 844);
    viewport(tester, size, 1, Brightness.light);
    final boundary = GlobalKey();
    final (app, service) = await openRecoveryFixture(
      tester,
      boundary,
      draftBeforePreview: false,
    );
    const newer = '合成并发保存的原文，没有未保存草稿。';
    const savedRevisionWarning = '原文已有更新，请先刷新原文。当前修改已保留。';
    await saveDiary(app, app.clock.day, newer);
    final before = await protectedState(app);
    await confirmSave(tester);
    expect(find.text(savedRevisionWarning), findsOneWidget);
    expect(control('chat-diary-view'), findsNothing);
    expect(await protectedState(app), before);
    expectCorrection(tester);
    await frame(
      tester,
      boundary,
      'r5-saved-revision-blocked-390-1x-light',
      size,
      savedRevisionWarning,
    );
    await reselectDay(tester);
    await tapDiaryControl(tester, control('chat-diary-original-toggle'));
    expect(find.text(newer), findsOneWidget);
    await tapDiaryControl(tester, find.text('追加'));
    expect(
      tester.widget<Text>(control('chat-diary-suggestion')).data,
      '$newer\n\n${correction.text}',
    );
    await tapDiaryControl(tester, control('chat-diary-save'));
    await tapDiaryControl(tester, control('chat-diary-abort-save'));
    expect(await protectedState(app), before);
    expectCorrection(tester);
    await confirmSave(tester);
    expect(control('chat-diary-receipt'), findsOneWidget);
    final store = await app.container.read(diaryStoreProvider.future);
    final saved = (await store.atDay(app.clock.day))!;
    expect(saved.entry.content, '$newer\n\n${correction.text}');
    expect(
      (await store.atDay(app.clock.day.addDays(-1)))!.entry.content,
      '合成昨日原文，不参与本次操作。',
    );
    final after = await protectedState(app);
    for (final table in [
      'diary_photos',
      'assistant_messages',
      'assistant_sessions',
    ]) {
      expect(after[table], before[table]);
    }
    final proposal = await app.database
        .select(app.database.assistantDiaryProposals)
        .getSingle();
    expect(proposal.content, modelText);
    expect(proposal.status, 'applied');
    expect(proposal.entryId, saved.entry.id);
    expect(service.requests, hasLength(1));
    expect(service.summaries, isEmpty);
    expect(tester.takeException(), isNull);
    await frame(
      tester,
      boundary,
      'r5-saved-revision-recovered-390-1x-light',
      size,
      '已保存',
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
}
