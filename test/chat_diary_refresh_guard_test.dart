import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/data/sync/identity_store.dart';
import 'package:habit_checkin/data/sync/sync_identity.dart';
import 'package:habit_checkin/features/journal/presentation/journal_editor_page.dart';
import 'package:habit_checkin/shared/presentation.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'assistant_diary_entry_layout_test.dart' show viewport;
import 'assistant_diary_ui_test.dart' show tapDiaryControl;
import 'chat_diary_initial_read_recovery_test.dart' show readState;
import 'chat_diary_recovery_journey_test.dart'
    show
        control,
        correction,
        expectCorrection,
        confirmSave,
        frame,
        draftWarning;
import 'chat_diary_refresh_original_test.dart'
    show RefreshFixture, RefreshRead, refresh, refreshWarning;
import 'journal_diary_capture_test.dart' show captureFont, loadDiaryCaptureFont;
import 'support/sync_fixtures.dart';
import 'support/ui_harness.dart';

const readError = '刷新未完成，请重试。当前修改已保留。';

Future<void> draft(RefreshFixture app) async {
  final row = await app.diaries.beginDraft(app.clock.day);
  await app.diaries.writeDraft(
    row.entry.id,
    content: '合成并发未保存草稿。',
    expectedDraftRevision: row.entry.draftRevision,
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

  for (final large in [false, true]) {
    for (final theme in Brightness.values) {
      final size = large ? const Size(320, 568) : const Size(390, 844);
      final name = '${large ? '320-4x' : '390-1x'}-${theme.name}';
      testUiWidgets('R9 refresh failure retry and busy exclusion $name', (
        tester,
      ) async {
        viewport(tester, size, large ? 4 : 1, theme);
        final app = RefreshFixture();
        await app.openEdited(tester);
        final staleSave = tester
            .widget<FilledButton>(control('chat-diary-save'))
            .onPressed!;
        await app.stale(tester);
        staleSave();
        await tester.pumpAndSettle();
        expect(control('chat-diary-confirm-save'), findsNothing);
        expect(find.text(refreshWarning), findsOneWidget);
        await tapDiaryControl(tester, control('chat-diary-cancel'));
        await tapDiaryControl(tester, control('chat-diary-discard-cancel'));
        await tapVisible(tester, find.byType(BackButton));
        await tapDiaryControl(tester, control('chat-diary-discard-cancel'));
        expectCorrection(tester);
        expect(refresh, findsOneWidget);
        expect(
          tester.widget<ListTile>(control('chat-diary-date')).onTap,
          isNotNull,
        );
        expect(
          tester.widget<IconButton>(control('chat-diary-edit')).onPressed,
          isNotNull,
        );
        for (var i = 0; i < 2; i++) {
          app.fault.armed = true;
          await tapDiaryControl(tester, refresh);
          expect(find.text(readError), findsOneWidget);
          expect(find.byType(NoticeBanner), findsOneWidget);
          expectCorrection(tester);
          expect(find.byType(DatePickerDialog), findsNothing);
          expect(
            tester.widget<FilledButton>(control('chat-diary-save')).onPressed,
            isNull,
          );
          expect(
            find.descendant(
              of: control('chat-diary-date'),
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is Text &&
                    widget.semanticsLabel == app.clock.day.key,
              ),
            ),
            findsOneWidget,
          );
          await app.expectUnchanged();
        }
        await frame(
          tester,
          app.boundary,
          'r9-$name-read-error',
          size,
          readError,
          firstLineOnly: true,
        );
        await frame(
          tester,
          app.boundary,
          'r9-$name-read-retry',
          size,
          '刷新原文',
          reveal: refresh,
        );
        final semantics = tester.ensureSemantics();
        try {
          await tester.pump();
          final node = tester.getSemantics(refresh).getSemanticsData();
          expect(node.label, '刷新原文');
          expect(node.flagsCollection.isButton, isTrue);
          expect(node.hasAction(ui.SemanticsAction.tap), isTrue);
        } finally {
          semantics.dispose();
        }
        final action = tester.widget<TextButton>(refresh).onPressed!;
        final reads = app.fault.proposalReads;
        final gate = app.fault.delayNextRead();
        await tapVisible(tester, refresh, settle: false);
        action();
        action();
        await pumpWaiting(tester);
        expect(app.fault.committed, isTrue);
        expect(app.fault.proposalReads, reads + 1);
        expect(tester.widget<TextButton>(refresh).onPressed, isNull);
        expectCorrection(tester);
        await frame(
          tester,
          app.boundary,
          'r9-$name-busy',
          size,
          '刷新中',
          reveal: refresh,
        );
        gate.complete();
        await tester.pumpAndSettle();
        expect(refresh, findsNothing);
        expectCorrection(tester);
        final afterReads = app.fault.proposalReads;
        action();
        await tester.pumpAndSettle();
        expect(app.fault.proposalReads, afterReads);
        await app.expectUnchanged();
        expect(tester.takeException(), isNull);
      }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
    }
  }

  testUiWidgets(
    'R9 new draft uses existing recovery without losing correction',
    (tester) async {
      final app = RefreshFixture();
      await app.openEdited(tester);
      await app.stale(tester);
      await draft(app);
      final before = await readState(app.db);
      await tapDiaryControl(tester, refresh);
      expect(refresh, findsNothing);
      expect(find.text(draftWarning), findsOneWidget);
      expect(control('chat-diary-view'), findsOneWidget);
      expectCorrection(tester);
      await app.expectUnchanged(expected: before);
      await tapDiaryControl(tester, control('chat-diary-view'));
      expect(find.byType(JournalEditorPage), findsOneWidget);
      expect(
        tester.widget<TextField>(control('journal-text')).controller!.text,
        '合成并发未保存草稿。',
      );
      await app.expectUnchanged(expected: before);
      await tapVisible(tester, control('save-journal'));
      expect(find.byType(JournalEditorPage), findsNothing);
      expectCorrection(tester);
      expect(
        tester.widget<FilledButton>(control('chat-diary-save')).onPressed,
        isNull,
      );
      await tapDiaryControl(tester, find.text('替换'));
      await confirmSave(tester);
      expect(
        (await app.diaries.atDay(app.clock.day))!.entry.content,
        correction.text,
      );
      await app.saveText('合成后续保存，不能被撤销覆盖。');
      final saved = await readState(app.db);
      await tapDiaryControl(tester, control('chat-diary-undo'));
      await tapDiaryControl(tester, control('chat-diary-confirm-undo'));
      expect(find.textContaining('不能自动撤销'), findsOneWidget);
      await app.expectUnchanged(expected: saved);
      expect(tester.takeException(), isNull);
    },
  );

  for (final newDraft in [false, true]) {
    testUiWidgets(
      'R9 concurrent ${newDraft ? 'draft' : 'save'} during confirmation stays protected',
      (tester) async {
        final app = RefreshFixture();
        await app.openEdited(tester);
        await app.stale(tester);
        await tapDiaryControl(tester, refresh);
        await tapDiaryControl(tester, find.text('追加'));
        await tapDiaryControl(tester, control('chat-diary-save'));
        if (newDraft) {
          await draft(app);
        } else {
          await app.saveText('合成再次改变的原文。');
        }
        final expected = await readState(app.db);
        await tapDiaryControl(tester, control('chat-diary-confirm-save'));
        expect(control('chat-diary-receipt'), findsNothing);
        expectCorrection(tester);
        await app.expectUnchanged(expected: expected);
        if (newDraft) {
          expect(control('chat-diary-view'), findsOneWidget);
          expect(refresh, findsNothing);
        } else {
          expect(refresh, findsOneWidget);
          expect(
            tester.widget<FilledButton>(control('chat-diary-save')).onPressed,
            isNull,
          );
          await tapDiaryControl(tester, refresh);
          expect(
            tester.widget<FilledButton>(control('chat-diary-save')).onPressed,
            isNull,
          );
          await tapDiaryControl(tester, find.text('追加'));
          expect(
            tester.widget<Text>(control('chat-diary-suggestion')).data,
            '合成再次改变的原文。\n\n${correction.text}',
          );
        }
        await app.expectUnchanged(expected: expected);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final pending in [false, true]) {
    for (final state in ['cancelled', 'applied', 'missing']) {
      testUiWidgets(
        'R9 $state ${pending ? 'during' : 'before'} refresh cannot revive saving',
        (tester) async {
          final app = RefreshFixture();
          await app.openEdited(tester);
          await app.stale(tester);
          final action = tester.widget<TextButton>(refresh).onPressed!;
          final gate = pending ? app.fault.delayNextRead() : null;
          if (gate != null) {
            await tapVisible(tester, refresh, settle: false);
            expect(app.fault.committed, isTrue);
          }
          if (state == 'missing') {
            await app.db.delete(app.db.assistantDiaryProposals).go();
          } else {
            final row = (await app.diaries.atDay(app.clock.day))!.entry;
            await app.db
                .update(app.db.assistantDiaryProposals)
                .write(
                  AssistantDiaryProposalsCompanion(
                    status: Value(state),
                    targetDay: Value(
                      state == 'applied' ? app.clock.day.key : null,
                    ),
                    entryId: Value(state == 'applied' ? row.id : null),
                    appliedRevision: Value(
                      state == 'applied' ? row.revision : null,
                    ),
                    appliedDraftRevision: Value(
                      state == 'applied' ? row.draftRevision : null,
                    ),
                    appliedAt: Value(
                      state == 'applied'
                          ? app.clock.read().instant.microsecondsSinceEpoch
                          : null,
                    ),
                  ),
                );
          }
          final expected = await readState(app.db);
          if (gate != null) {
            gate.complete();
          } else {
            action();
          }
          await tester.pumpAndSettle();
          if (state == 'missing') {
            expect(find.text('找不到这条日记建议'), findsOneWidget);
            expect(
              tester.widget<FilledButton>(control('chat-diary-save')).onPressed,
              isNull,
            );
            expectCorrection(tester);
          } else {
            expect(control('chat-diary-save'), findsNothing);
            expect(control('chat-diary-edit'), findsNothing);
            expect(
              control('chat-diary-receipt'),
              state == 'applied' ? findsOneWidget : findsNothing,
            );
          }
          action();
          await tester.pumpAndSettle();
          expect(control('chat-diary-confirm-save'), findsNothing);
          await app.expectUnchanged(expected: expected);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testUiWidgets('R9 second refresh read failure retains day and correction', (
    tester,
  ) async {
    final app = RefreshFixture();
    await app.openEdited(tester);
    await app.stale(tester);
    (app.fault as RefreshRead).failAtRead = app.fault.proposalReads + 2;
    await tapDiaryControl(tester, refresh);
    expect(find.text(readError), findsOneWidget);
    expect(refresh, findsOneWidget);
    expectCorrection(tester);
    expect(
      tester.widget<FilledButton>(control('chat-diary-save')).onPressed,
      isNull,
    );
    await app.expectUnchanged();
    await tapDiaryControl(tester, refresh);
    expect(refresh, findsNothing);
    expectCorrection(tester);
    expect(
      tester.widget<FilledButton>(control('chat-diary-save')).onPressed,
      isNull,
    );
    await app.expectUnchanged();
    expect(tester.takeException(), isNull);
  });

  testUiWidgets('R9 refresh retains explicitly selected historical date', (
    tester,
  ) async {
    final app = RefreshFixture();
    await app.openEdited(tester);
    final day = app.clock.day.addDays(-1);
    await app.saveText('合成历史日期旧正文。', day: day);
    await tapDiaryControl(tester, control('chat-diary-date'));
    await tapVisible(tester, find.text('${day.day}'));
    await tapVisible(tester, find.text('确定'));
    await tapDiaryControl(tester, find.text('追加'));
    await app.saveText('合成历史日期最新原文。', day: day);
    final before = await readState(app.db);
    await confirmSave(tester);
    expect(refresh, findsOneWidget);
    await tapDiaryControl(tester, refresh);
    expect(find.text(day.key), findsOneWidget);
    expectCorrection(tester);
    expect(
      tester.widget<FilledButton>(control('chat-diary-save')).onPressed,
      isNull,
    );
    await app.expectUnchanged(expected: before);
    await tapDiaryControl(tester, find.text('替换'));
    await confirmSave(tester);
    expect((await app.diaries.atDay(day))!.entry.content, correction.text);
    expect(
      (await app.diaries.atDay(app.clock.day))!.entry.content,
      '合成最初原文，之后在另一处更新。',
    );
    expect(
      (await app.db.select(app.db.assistantDiaryProposals).getSingle())
          .targetDay,
      day.key,
    );
    expect(tester.takeException(), isNull);
  });

  for (final identity in [false, true]) {
    testUiWidgets(
      'R9 late refresh after ${identity ? 'identity switch away and back' : 'disposal'} stays inert',
      (tester) async {
        final app = RefreshFixture();
        await app.openEdited(tester);
        await app.stale(tester);
        final action = tester.widget<TextButton>(refresh).onPressed!;
        final gate = app.fault.delayNextRead();
        await tapVisible(tester, refresh, settle: false);
        expect(app.fault.committed, isTrue);
        if (identity) {
          final identities = IdentityStore(app.db);
          await identities.finish(await identities.begin(accountA));
          await pumpWaiting(tester);
          expect(find.text('身份已变化或不可用。'), findsOneWidget);
          await identities.finish(await identities.begin(SyncIdentity.guest));
        } else {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(Duration.zero);
        }
        final expected = await readState(app.db);
        gate.complete();
        await tester.pumpAndSettle();
        action();
        await tester.pumpAndSettle();
        expect(control('chat-diary-save'), findsNothing);
        expect(refresh, findsNothing);
        expect(find.text(correction.text), findsNothing);
        await app.expectUnchanged(expected: expected);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
