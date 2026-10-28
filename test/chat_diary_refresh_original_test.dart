import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/features/journal/data/local_journal_store.dart';
import 'package:habit_checkin/features/journal/presentation/chat_diary_page.dart';
import 'package:habit_checkin/features/journal/presentation/journal_editor_page.dart';
import 'package:habit_checkin/shared/local_date.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:uuid/uuid.dart';

import 'assistant_diary_entry_layout_test.dart' show viewport;
import 'assistant_diary_ui_test.dart' show tapDiaryControl;
import 'chat_diary_initial_read_guard_test.dart'
    show ReadFixture, DeferredProposalRead;
import 'chat_diary_initial_read_recovery_test.dart'
    show readState, proposalText;
import 'chat_diary_recovery_journey_test.dart'
    show control, correction, expectCorrection, confirmSave, frame;
import 'journal_diary_capture_test.dart' show captureFont, loadDiaryCaptureFont;
import 'support/ui_harness.dart';

const newerOriginal = '另处已保存的新原文：读完一章，仍有疑问。';
const refreshProposalId = '00000000-0000-4000-8000-000000000901';
const refreshWarning = '原文已有更新，请先刷新原文。当前修改已保留。';
Finder get refresh => control('chat-diary-refresh-original');

class RefreshRead extends DeferredProposalRead {
  bool selected = false;
  int? failAtRead;

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    if (statement.contains('assistant_diary_proposals') &&
        args.contains(refreshProposalId)) {
      proposalReads++;
      if (armed || proposalReads == failAtRead) {
        armed = false;
        failures++;
        throw StateError('R9 synthetic one-shot proposal read failure');
      }
      selected = true;
    }
    return executor.runSelect(statement, args);
  }

  @override
  Future<void> commitTransaction(TransactionExecutor inner) async {
    final gate = selected ? this.completion : null;
    selected = false;
    if (gate != null) this.completion = null;
    await inner.send();
    if (gate != null) {
      committed = true;
      await gate.future;
    }
  }
}

class RefreshFixture extends ReadFixture {
  RefreshFixture() : super(fault: RefreshRead());
  LocalDiaryStore get diaries => LocalDiaryStore(conversation.goals);

  Future<void> saveText(String text, {LocalDate? day}) async {
    var row = await diaries.beginDraft(day ?? clock.day);
    row = await diaries.writeDraft(
      row.entry.id,
      content: text,
      expectedDraftRevision: row.entry.draftRevision,
    );
    await diaries.save(
      row.entry.id,
      operationId: const Uuid().v4(),
      expectedRevision: row.entry.revision,
      expectedDraftRevision: row.entry.draftRevision,
    );
  }

  Future<void> openEdited(WidgetTester tester) async {
    await mount(tester);
    // R7's read-only fixture ID is too short for journal operation receipts.
    await db
        .update(db.assistantDiaryProposals)
        .write(
          const AssistantDiaryProposalsCompanion(id: Value(refreshProposalId)),
        );
    await saveText('合成最初原文，之后在另一处更新。');
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.text('预览日记建议'))).push<void>(
      MaterialPageRoute(
        builder: (_) => const ChatDiaryPage(proposalId: refreshProposalId),
      ),
    );
    await tester.pumpAndSettle();
    await tapDiaryControl(tester, control('chat-diary-suggested-date'));
    await tapDiaryControl(tester, control('chat-diary-edit'));
    await tester.showKeyboard(control('chat-diary-edited-text'));
    tester.testTextInput.updateEditingValue(correction);
    await tester.pumpAndSettle();
    await tapDiaryControl(tester, control('chat-diary-edit'));
    await tapDiaryControl(tester, find.text('追加'));
    expectCorrection(tester);
    expect(refresh, findsNothing);
  }

  Future<void> stale(WidgetTester tester) async {
    await saveText(newerOriginal);
    before = await readState(db);
    await confirmSave(tester);
    await expectUnchanged();
    expectCorrection(tester);
  }
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

  for (final large in [false, true]) {
    for (final theme in Brightness.values) {
      final size = large ? const Size(320, 568) : const Size(390, 844);
      final name = '${large ? '320-4x' : '390-1x'}-${theme.name}';
      testUiWidgets('R9 direct refresh keeps correction and date $name', (
        tester,
      ) async {
        viewport(tester, size, large ? 4 : 1, theme);
        final app = RefreshFixture();
        await app.openEdited(tester);
        final route = tester.state(find.byType(ChatDiaryPage));
        await app.stale(tester);
        if (refresh.evaluate().isEmpty) {
          await frame(
            tester,
            app.boundary,
            'r9-$name-before',
            size,
            '内容已有新的修改，请重新打开后再保存',
            firstLineOnly: true,
          );
        }
        expect(
          refresh,
          findsOneWidget,
          reason: 'A saved-version conflict needs direct same-day recovery.',
        );
        expect(find.text(refreshWarning), findsOneWidget);
        expect(
          tester.widget<FilledButton>(control('chat-diary-save')).onPressed,
          isNull,
          reason: 'Known stale state must not offer another confirmation.',
        );
        await frame(
          tester,
          app.boundary,
          'r9-$name-refresh',
          size,
          '刷新原文',
          reveal: refresh,
        );
        expect(tester.getSize(refresh).height, greaterThanOrEqualTo(44));
        final label = tester.renderObject<RenderParagraph>(
          find.descendant(
            of: find.text('刷新原文'),
            matching: find.byType(RichText),
          ),
        );
        expect(
          label
              .getBoxesForSelection(
                const TextSelection(baseOffset: 0, extentOffset: 4),
              )
              .map((b) => b.top)
              .toSet(),
          hasLength(1),
        );
        final action = tester.widget<TextButton>(refresh).onPressed!;
        action();
        action();
        await tester.pumpAndSettle();
        expect(tester.state(find.byType(ChatDiaryPage)), same(route));
        expect(find.byType(JournalEditorPage), findsNothing);
        expect(find.byType(DatePickerDialog), findsNothing);
        expect(refresh, findsNothing);
        expectCorrection(tester);
        expect(
          tester.widget<FilledButton>(control('chat-diary-save')).onPressed,
          isNull,
          reason: 'The changed original requires a new explicit choice.',
        );
        await tapDiaryControl(tester, control('chat-diary-original-toggle'));
        await frame(
          tester,
          app.boundary,
          'r9-$name-original',
          size,
          newerOriginal,
          firstLineOnly: true,
        );
        await app.expectUnchanged();
        await tapDiaryControl(tester, find.text('追加'));
        expect(
          tester.widget<Text>(control('chat-diary-suggestion')).data,
          '$newerOriginal\n\n${correction.text}',
        );
        await frame(
          tester,
          app.boundary,
          'r9-$name-combined',
          size,
          '$newerOriginal\n\n${correction.text}',
          firstLineOnly: true,
        );
        await tapDiaryControl(tester, control('chat-diary-save'));
        await tapDiaryControl(tester, control('chat-diary-abort-save'));
        await app.expectUnchanged();
        expectCorrection(tester);
        await confirmSave(tester);
        expect(
          control('chat-diary-receipt'),
          findsOneWidget,
          reason: tester
              .widgetList<Text>(find.byType(Text))
              .map((text) => text.data)
              .join(' | '),
        );
        expect(
          (await app.diaries.atDay(app.clock.day))!.entry.content,
          '$newerOriginal\n\n${correction.text}',
        );
        final applied = await readState(app.db);
        for (final table in [
          'diary_photos',
          'quick_notes',
          'quick_note_photos',
          'assistant_messages',
          'assistant_sessions',
          'identity_states',
        ]) {
          expect(applied[table], app.before[table]);
        }
        final proposal = await app.db
            .select(app.db.assistantDiaryProposals)
            .getSingle();
        expect(proposal.content, proposalText);
        expect(proposal.id, refreshProposalId);
        expect(proposal.targetDay, app.clock.day.key);
        action();
        await tester.pumpAndSettle();
        await app.expectUnchanged(expected: applied);
        await tapDiaryControl(tester, control('chat-diary-undo'));
        await tapDiaryControl(tester, control('chat-diary-confirm-undo'));
        expect(
          (await app.diaries.atDay(app.clock.day))!.entry.content,
          newerOriginal,
        );
        expect(tester.takeException(), isNull);
      }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
    }
  }
}
