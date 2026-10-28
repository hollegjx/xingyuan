import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/assistant/assistant_providers.dart';
import 'package:habit_checkin/features/assistant/data/local_conversation_store.dart';
import 'package:habit_checkin/features/journal/domain/journal_entry.dart';
import 'package:habit_checkin/features/journal/journal_providers.dart';
import 'package:habit_checkin/features/journal/presentation/journal_editor_page.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:xingyuan_core/xingyuan_core.dart';

import 'assistant_conversation_ui_test.dart' show openPlanning, sendText;
import 'assistant_diary_ui_test.dart' show tapDiaryControl;
import 'support/journal_fixtures.dart';
import 'support/test_assistant_service.dart';
import 'support/ui_harness.dart';

Finder control(String value) => find.byKey(ValueKey(value));

void main() {
  setUpAll(tzdata.initializeTimeZones);

  Future<(UiHarness, ConversationTestService)> openProposal(
    WidgetTester tester,
  ) async {
    final app = UiHarness()..clock.setDay(2026, 10, 25);
    await LocalConversationStore(app.repository).memories.consent();
    final service = ConversationTestService()
      ..onTurn = (request) async => TurnResponse.fromJson({
        'protocol': assistantProtocol,
        'request_id': request.requestId,
        'reply': 'SYNTHETIC proposal awaiting local confirmation',
        'plan': null,
        'memory_ops': <Object?>[],
        'diary': {
          'date': request.now.date.key,
          'content': 'SYNTHETIC diary from chat',
        },
      }, request: request);
    await app.mount(
      tester,
      assistantService: service,
      assistantCredentials: ConversationTestCredentials(),
      journalPhotoFiles: {
        JournalKind.diary: MemoryJournalPhotoFiles(JournalKind.diary),
      },
    );
    await openPlanning(tester);
    await sendText(
      tester,
      'SYNTHETIC write this conversation into today diary',
    );
    final proposal = await app.database
        .select(app.database.assistantDiaryProposals)
        .getSingle();
    await tapDiaryControl(
      tester,
      control('open-diary-proposal-${proposal.id}'),
    );
    return (app, service);
  }

  Future<void> saveProposal(WidgetTester tester) async {
    await tapDiaryControl(tester, control('chat-diary-suggested-date'));
    await tapDiaryControl(tester, control('chat-diary-save'));
    await tapDiaryControl(tester, control('chat-diary-confirm-save'));
    expect(control('chat-diary-receipt'), findsOneWidget);
  }

  testUiWidgets('chat save and undo update an already subscribed diary view', (
    tester,
  ) async {
    final (app, service) = await openProposal(tester);
    final provider = diaryOnProvider(app.clock.day);
    final subscription = app.container.listen(provider, (_, _) {});
    addTearDown(subscription.close);
    await tester.pumpAndSettle();
    expect(app.container.read(provider).requireValue, isNull);

    await saveProposal(tester);
    expect(
      app.container.read(provider).requireValue!.entry.content,
      'SYNTHETIC diary from chat',
    );
    expect(app.container.read(provider).requireValue!.entry.isSaved, isTrue);
    await tapDiaryControl(tester, control('chat-diary-undo'));
    await tapDiaryControl(tester, control('chat-diary-confirm-undo'));
    expect(app.container.read(provider).requireValue, isNull);
    expect(service.requests, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testUiWidgets('viewing the saved diary without editing still permits undo', (
    tester,
  ) async {
    final (app, service) = await openProposal(tester);
    await saveProposal(tester);
    await tapDiaryControl(tester, control('chat-diary-view'));
    expect(find.byType(JournalEditorPage), findsOneWidget);
    expect(
      tester.widget<TextField>(control('journal-text')).controller!.text,
      'SYNTHETIC diary from chat',
    );
    await goBack(tester);
    await tapDiaryControl(tester, control('chat-diary-undo'));
    await tapDiaryControl(tester, control('chat-diary-confirm-undo'));
    final diary = await app.container.read(diaryStoreProvider.future);
    expect(await diary.savedOn(app.clock.day), isEmpty);
    expect(find.text('本次写入已撤销'), findsOneWidget);
    expect(service.requests, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testUiWidgets('receipt opens the diary editor and later edits survive undo', (
    tester,
  ) async {
    final (app, service) = await openProposal(tester);
    await saveProposal(tester);
    await tapDiaryControl(tester, control('chat-diary-view'));
    expect(find.byType(JournalEditorPage), findsOneWidget);
    expect(
      tester.widget<TextField>(control('journal-text')).controller!.text,
      'SYNTHETIC diary from chat',
    );
    await tester.enterText(control('journal-text'), 'SYNTHETIC later edit');
    await tester.pumpAndSettle();
    await tapDiaryControl(tester, control('save-journal'));
    expect(find.byType(JournalEditorPage), findsNothing);
    final before =
        (await app.database
                .customSelect('SELECT * FROM diary_entries ORDER BY id')
                .get())
            .map((row) => row.data)
            .toList();

    await tapDiaryControl(tester, control('chat-diary-undo'));
    await tapDiaryControl(tester, control('chat-diary-confirm-undo'));
    expect(control('chat-diary-receipt'), findsOneWidget);
    expect(
      (await app.database.select(app.database.diaryEntries).getSingle())
          .content,
      'SYNTHETIC later edit',
    );
    expect(
      (await app.database
              .customSelect('SELECT * FROM diary_entries ORDER BY id')
              .get())
          .map((row) => row.data)
          .toList(),
      before,
    );
    expect(
      (await app.database
              .select(app.database.assistantDiaryProposals)
              .getSingle())
          .status,
      'applied',
    );
    expect(service.requests, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testUiWidgets(
    'deleting the chat removes its receipt but preserves the diary',
    (tester) async {
      final (app, service) = await openProposal(tester);
      await saveProposal(tester);
      final before =
          (await app.database
                  .customSelect('SELECT * FROM diary_entries ORDER BY id')
                  .get())
              .map((row) => row.data)
              .toList();
      final proposal = await app.database
          .select(app.database.assistantDiaryProposals)
          .getSingle();
      await goBack(tester);
      final controller = await app.container.read(
        assistantConversationProvider.future,
      );
      await controller.delete(proposal.sessionId);
      await tester.pumpAndSettle();

      expect(
        await app.database.select(app.database.assistantSessions).get(),
        isEmpty,
      );
      expect(
        await app.database.select(app.database.assistantMessages).get(),
        isEmpty,
      );
      expect(
        await app.database.select(app.database.assistantDiaryProposals).get(),
        isEmpty,
      );
      expect(
        (await app.database
                .customSelect('SELECT * FROM diary_entries ORDER BY id')
                .get())
            .map((row) => row.data)
            .toList(),
        before,
      );
      final diary = await app.container.read(diaryStoreProvider.future);
      expect(
        (await diary.savedOn(app.clock.day)).single.entry.content,
        'SYNTHETIC diary from chat',
      );
      expect(service.requests, hasLength(1));
      expect(controller.error, isNull);
      expect(tester.takeException(), isNull);
    },
  );
}
