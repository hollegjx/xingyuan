import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/assistant/data/local_conversation_store.dart';
import 'package:habit_checkin/features/journal/domain/journal_entry.dart';
import 'package:habit_checkin/features/journal/journal_providers.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'assistant_diary_ui_test.dart' show openDiarySuggestion, tapDiaryControl;
import 'support/journal_ai_service.dart';
import 'support/journal_fixtures.dart';
import 'support/test_assistant_service.dart';
import 'support/ui_harness.dart';

Finder key(String value) => find.byKey(ValueKey(value));

Future<(UiHarness, SyntheticJournalAi)> openEditorPreview(
  WidgetTester tester, {
  String original = '',
  String? suggestion,
  Widget Function(Widget child)? wrapApp,
}) async {
  final app = UiHarness();
  await LocalConversationStore(app.repository).memories.consent();
  final service = SyntheticJournalAi();
  if (suggestion != null) service.diary = suggestion;
  await app.mount(
    tester,
    journalAiService: service,
    wrapApp: wrapApp,
    assistantCredentials: ConversationTestCredentials(),
    journalPhotoFiles: {
      for (final kind in JournalKind.values)
        kind: MemoryJournalPhotoFiles(kind),
    },
  );
  final notes = await app.container.read(quickNoteStoreProvider.future);
  await saveJournalNotes(notes, ['今天读完了一章，有一段还想再读一遍。']);
  await tapVisible(tester, key('entry-diary'));
  if (original.isNotEmpty) {
    await tester.enterText(key('journal-text'), original);
    await tester.pumpAndSettle();
  }
  await tapVisible(tester, key('journal-ai-request'));
  return (app, service);
}

void main() {
  setUpAll(tzdata.initializeTimeZones);

  testUiWidgets(
    'empty diary preview leads with the draft, not empty original',
    (tester) async {
      final (app, service) = await openEditorPreview(tester);
      expect(key('journal-ai-original'), findsNothing);
      expect(find.text('空白草稿'), findsNothing);
      expect(key('journal-ai-suggestion'), findsOneWidget);
      expect(find.text('放入草稿'), findsOneWidget);
      await tapVisible(tester, key('journal-ai-use'));
      expect(
        tester.widget<TextField>(key('journal-text')).controller!.text,
        service.diary,
      );
      final diaries = await app.container.read(diaryStoreProvider.future);
      expect(await diaries.savedOn(app.clock.day), isEmpty);
      await tapVisible(tester, key('journal-ai-undo'));
      expect(
        tester.widget<TextField>(key('journal-text')).controller!.text,
        '',
      );
      expect(service.calls, hasLength(1));
    },
  );

  for (final append in [true, false]) {
    testUiWidgets(
      'diary chooses ${append ? 'append' : 'replace'} in the preview',
      (tester) async {
        final (app, service) = await openEditorPreview(
          tester,
          original: '自己的开头',
        );
        expect(key('journal-ai-original'), findsNothing);
        expect(
          tester.widget<FilledButton>(key('journal-ai-use')).onPressed,
          isNull,
        );
        await tapVisible(tester, key('journal-ai-original-toggle'));
        expect(find.text('自己的开头'), findsWidgets);
        await tapVisible(tester, key('journal-ai-original-toggle'));
        await tapVisible(tester, find.text(append ? '追加' : '替换'));
        expect(find.byType(AlertDialog), findsNothing);
        expect(
          tester.widget<Text>(key('journal-ai-suggestion')).data,
          append ? '自己的开头\n\n${service.diary}' : service.diary,
        );
        await tapVisible(tester, key('journal-ai-use'));
        expect(
          tester.widget<TextField>(key('journal-text')).controller!.text,
          append ? '自己的开头\n\n${service.diary}' : service.diary,
        );
        final diaries = await app.container.read(diaryStoreProvider.future);
        expect(await diaries.savedOn(app.clock.day), isEmpty);
        await tapVisible(tester, key('journal-ai-undo'));
        expect(
          tester.widget<TextField>(key('journal-text')).controller!.text,
          '自己的开头',
        );
        expect(service.calls, hasLength(1));
      },
    );
  }

  testUiWidgets('switching diary modes then cancelling keeps the draft', (
    tester,
  ) async {
    final (app, service) = await openEditorPreview(tester, original: '自己的开头');
    await tapVisible(tester, find.text('追加'));
    await tapVisible(tester, find.text('替换'));
    await tapVisible(tester, key('journal-ai-keep'));
    expect(
      tester.widget<TextField>(key('journal-text')).controller!.text,
      '自己的开头',
    );
    final diaries = await app.container.read(diaryStoreProvider.future);
    expect(await diaries.savedOn(app.clock.day), isEmpty);
    expect(service.calls, hasLength(1));
    expect(key('journal-ai-undo'), findsNothing);
  });

  testUiWidgets('switching chat modes then cancelling keeps the saved diary', (
    tester,
  ) async {
    final (app, service) = await openDiarySuggestion(tester, original: '合成原文');
    final before =
        (await app.database
                .customSelect('SELECT * FROM diary_entries')
                .getSingle())
            .data;
    await tapDiaryControl(tester, key('chat-diary-suggested-date'));
    await tapDiaryControl(tester, find.text('追加'));
    await tapDiaryControl(tester, find.text('替换'));
    await tapDiaryControl(tester, key('chat-diary-cancel'));
    expect(
      (await app.database
              .customSelect('SELECT * FROM diary_entries')
              .getSingle())
          .data,
      before,
    );
    expect(service.requests, hasLength(1));
    expect(key('chat-diary-receipt'), findsNothing);
    expect(find.text('建议已取消，未写入日记'), findsOneWidget);
  });

  testUiWidgets('chat has one reading surface before and after merge choice', (
    tester,
  ) async {
    final (app, service) = await openDiarySuggestion(tester, original: '合成原文');
    await tapDiaryControl(tester, key('chat-diary-suggested-date'));
    expect(find.text('合成原文'), findsNothing);
    expect(find.text('合成新正文'), findsOneWidget);
    await tapDiaryControl(tester, find.text('追加'));
    expect(find.text('合成新正文'), findsNothing);
    expect(find.text('合成原文\n\n合成新正文'), findsOneWidget);
    await tapDiaryControl(tester, key('chat-diary-save'));
    expect(
      (await app.database.select(app.database.diaryEntries).getSingle())
          .content,
      '合成原文',
    );
    await tapVisible(tester, key('chat-diary-abort-save'));
    expect(service.requests, hasLength(1));
    await tapDiaryControl(tester, key('chat-diary-save'));
    await tapVisible(tester, key('chat-diary-confirm-save'));
    expect(
      (await app.database.select(app.database.diaryEntries).getSingle())
          .content,
      '合成原文\n\n合成新正文',
    );
    expect(key('chat-diary-receipt'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testUiWidgets('chat diary preview retains selectable body and original', (
    tester,
  ) async {
    await openDiarySuggestion(tester, original: '合成原文');
    await tapDiaryControl(tester, key('chat-diary-suggested-date'));
    await tapDiaryControl(tester, key('chat-diary-original-toggle'));
    for (final text in ['chat-diary-suggestion', 'chat-diary-original']) {
      expect(
        find.ancestor(of: key(text), matching: find.byType(SelectableRegion)),
        findsOneWidget,
      );
    }
  });
}
