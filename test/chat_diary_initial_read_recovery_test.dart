import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/app/app.dart';
import 'package:habit_checkin/app/providers.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/sync/identity_store.dart';
import 'package:habit_checkin/features/assistant/assistant_providers.dart';
import 'package:habit_checkin/features/assistant/data/local_conversation_store.dart';
import 'package:habit_checkin/features/companion/companion_providers.dart';
import 'package:habit_checkin/features/journal/data/chat_diary_store.dart';
import 'package:habit_checkin/features/journal/data/local_journal_store.dart';
import 'package:habit_checkin/features/journal/domain/journal_entry.dart';
import 'package:habit_checkin/features/journal/journal_providers.dart';
import 'package:habit_checkin/features/journal/presentation/chat_diary_page.dart';
import 'package:habit_checkin/features/records/data/local_day_record_store.dart';
import 'package:habit_checkin/shared/presentation.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'assistant_conversation_ui_test.dart' show openPlanning;
import 'assistant_diary_entry_layout_test.dart' show viewport;
import 'assistant_diary_ui_test.dart' show tapDiaryControl;
import 'journal_diary_capture_test.dart'
    show capture, captureDirectory, captureFont, loadDiaryCaptureFont;
import 'support/assistant_fixtures.dart';
import 'support/chat_photo_files.dart';
import 'support/journal_fixtures.dart';
import 'support/test_assistant_service.dart';
import 'support/test_clock.dart';
import 'support/test_reminder_notifications.dart';
import 'support/ui_harness.dart';

const proposalId = 'r7-proposal';
const proposalText = '合成建议：今天读完一章，仍有一处没弄懂。';
const readError = '操作未完成，请重试。原有日记和建议已保留。';

// Only the first exact proposal SELECT fails, after the identity lease is live.
class OneShotProposalRead extends QueryInterceptor {
  bool armed = false;
  int failures = 0;
  int proposalReads = 0;
  String? failedStatement;

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    if (statement.contains('assistant_diary_proposals') &&
        args.contains(proposalId)) {
      proposalReads++;
      if (armed) {
        armed = false;
        failures++;
        failedStatement = statement;
        throw StateError('R7 synthetic one-shot proposal read failure');
      }
    }
    return executor.runSelect(statement, args);
  }
}

Future<Map<String, Object>> readState(AppDatabase db) async => {
  for (final table in [
    'diary_entries',
    'diary_photos',
    'quick_notes',
    'quick_note_photos',
    'assistant_diary_proposals',
    'assistant_messages',
    'assistant_sessions',
    'identity_states',
  ])
    table:
        (await db
                .customSelect(
                  'SELECT * FROM $table ORDER BY ${table == 'identity_states' ? 'singleton' : 'id'}',
                )
                .get())
            .map((row) => row.data)
            .toList(),
};

Future<void> seed(LocalGoalRepository goals) async {
  await LocalConversationStore(goals).memories.consent();
  await seedAssistantReply(goals.db, id: 'r7');
  await goals.db
      .into(goals.db.assistantDiaryProposals)
      .insert(
        AssistantDiaryProposalsCompanion.insert(
          id: proposalId,
          owner: goals.owner,
          sessionId: 'r7-session',
          messageId: 'r7-message',
          content: proposalText,
          suggestedDay: Value(goals.clock.read().day.key),
        ),
      );
  final diaries = LocalDiaryStore(goals);
  var row = await diaries.beginDraft(goals.clock.read().day);
  row = await diaries.writeDraft(
    row.entry.id,
    content: '合成已保存正文，不能被读取重试改动。',
    expectedDraftRevision: row.entry.draftRevision,
  );
  row = await diaries.addPhoto(
    row.entry.id,
    expectedDraftRevision: row.entry.draftRevision,
    photo: RecordPhotoInput(
      id: '00000000-0000-4000-8000-000000000701',
      width: 10,
      height: 10,
      byteCount: 100,
      sha256: 'a' * 64,
    ),
  );
  row = await diaries.save(
    row.entry.id,
    operationId: '00000000-0000-4000-8000-000000000702',
    expectedRevision: row.entry.revision,
    expectedDraftRevision: row.entry.draftRevision,
  );
  row = await diaries.beginDraft(goals.clock.read().day);
  row = await diaries.writeDraft(
    row.entry.id,
    content: '合成尚未保存的草稿，读取前后保持原样。',
    expectedDraftRevision: row.entry.draftRevision,
  );
  await diaries.addPhoto(
    row.entry.id,
    expectedDraftRevision: row.entry.draftRevision,
    photo: RecordPhotoInput(
      id: '00000000-0000-4000-8000-000000000703',
      width: 10,
      height: 10,
      byteCount: 100,
      sha256: 'b' * 64,
    ),
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
      final label = '${large ? '320-4x' : '390-1x'}-${theme.name}';
      testUiWidgets('R7 initial read can retry on the same route $label', (
        tester,
      ) async {
        viewport(tester, size, large ? 4 : 1, theme);
        final fault = OneShotProposalRead();
        final db = AppDatabase(NativeDatabase.memory().interceptWith(fault));
        addTearDown(db.close);
        final clock = TestClock();
        final lease = await IdentityStore(db).active();
        final goals = LocalGoalRepository(
          db,
          clock,
          owner: lease.identity.owner,
          identityLease: lease,
        );
        await seed(goals);
        final service = ConversationTestService();
        final files = MemoryChatPhotoFiles(db);
        final boundary = GlobalKey();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              databaseProvider.overrideWith((ref) => db),
              clockProvider.overrideWithValue(clock),
              refreshClockProvider.overrideWithValue(() async {}),
              notificationPermissionsProvider.overrideWithValue(
                TestNotificationPermissions(),
              ),
              reminderNotificationsProvider.overrideWithValue(
                TestReminderNotifications(),
              ),
              companionForegroundProvider.overrideWithValue(null),
              chatPhotoFilesProvider.overrideWith((ref) {
                ref.onDispose(() => files.dispose().ignore());
                return files;
              }),
              for (final kind in JournalKind.values)
                journalPhotoFilesProvider(kind)
                    .overrideWith((ref) => MemoryJournalPhotoFiles(kind)),
              assistantServiceProvider.overrideWithValue(service),
              assistantCredentialProvider.overrideWithValue(
                ConversationTestCredentials(),
              ),
            ],
            child: RepaintBoundary(
              key: boundary,
              child: const HabitCheckinApp(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final container = ProviderScope.containerOf(
          tester.element(find.byType(HabitCheckinApp)),
        );
        final conversation = await container.read(
          assistantStoreProvider.future,
        );
        await conversation.goals.requireActiveIdentity();
        expect(conversation.goals.identityLease!.generation, lease.generation);
        final store = ChatDiaryStore(conversation.goals);
        expect((await store.proposal(proposalId)).status, 'pending');
        await openPlanning(tester);
        expect(find.text('预览日记建议'), findsOneWidget);
        final before = await readState(db);
        final healthCalls = service.healthCalls;
        final readsBefore = fault.proposalReads;
        fault.armed = true;
        await tapDiaryControl(tester, find.text('预览日记建议'));
        expect(fault.failures, 1);
        expect(fault.armed, isFalse);
        expect(fault.proposalReads, readsBefore + 1);
        expect(find.byType(ChatDiaryPage), findsOneWidget);
        expect(find.text('身份已变化或不可用。'), findsNothing);
        expect(find.text(readError), findsWidgets);
        expect(
          tester.widget<StatusPanel>(find.byType(StatusPanel)).loading,
          false,
        );
        expect(await readState(db), before);
        final routeState = tester.state(find.byType(ChatDiaryPage));
        final messages = find.text(readError).evaluate().length;
        final bannerText = find.descendant(
          of: find.byType(NoticeBanner),
          matching: find.text(readError),
        );
        final statusText = find.descendant(
          of: find.byType(StatusPanel),
          matching: find.text(readError),
        );
        await capture(
          tester,
          boundary,
          'r7-$label-failed-initial',
          size,
          text: bannerText.evaluate().isNotEmpty ? bannerText : statusText,
          expectedText: readError,
          firstLineOnly: true,
        );

        // A successful independent read proves the fault has cleared; it does
        // not stand in for a UI retry or rebind the page's original lease.
        expect((await store.proposal(proposalId)).content, proposalText);
        await conversation.goals.requireActiveIdentity();
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpAndSettle();
        expect(tester.state(find.byType(ChatDiaryPage)), same(routeState));
        expect(
          find.byKey(const ValueKey('chat-diary-suggestion')),
          findsNothing,
        );
        await Scrollable.ensureVisible(
          tester.element(statusText),
          alignment: 0,
        );
        await tester.pumpAndSettle();
        await capture(
          tester,
          boundary,
          'r7-$label-failed-status',
          size,
          text: statusText,
          expectedText: readError,
          firstLineOnly: true,
        );
        final scroll = Scrollable.of(tester.element(statusText)).position;
        final maxScroll = scroll.maxScrollExtent;
        await tester.drag(
          find.byType(SingleChildScrollView).last,
          const Offset(0, -1600),
        );
        await tester.pumpAndSettle();
        final retry = find.widgetWithText(OutlinedButton, '重试');
        final hasRetry = retry.evaluate().isNotEmpty;
        final back = find.byType(BackButton);
        expect(back.hitTestable(), findsOneWidget);
        final backRect = tester.getRect(back);
        expect(backRect.width, greaterThanOrEqualTo(44));
        expect(backRect.height, greaterThanOrEqualTo(44));
        final enabledButtons = find
            .byWidgetPredicate(
              (w) => w is ButtonStyleButton && w.onPressed != null,
            )
            .evaluate()
            .map((e) => e.widget.runtimeType.toString())
            .toList();

        if (hasRetry) {
          await tapVisible(tester, retry);
          expect(tester.state(find.byType(ChatDiaryPage)), same(routeState));
        } else {
          await tapVisible(tester, back);
          expect(find.byType(ChatDiaryPage), findsNothing);
          expect(await readState(db), before);
          await tapDiaryControl(tester, find.text('预览日记建议'));
          expect(
            tester.state(find.byType(ChatDiaryPage)),
            isNot(same(routeState)),
          );
        }
        final suggestion = find.byKey(const ValueKey('chat-diary-suggestion'));
        expect(tester.widget<Text>(suggestion).data, proposalText);
        await Scrollable.ensureVisible(
          tester.element(suggestion),
          alignment: 0,
        );
        await tester.pumpAndSettle();
        await capture(
          tester,
          boundary,
          'r7-$label-${hasRetry ? 'retried' : 'reopened'}-proposal',
          size,
          text: suggestion,
          expectedText: proposalText,
          firstLineOnly: true,
        );
        expect(await readState(db), before);
        expect((await store.proposal(proposalId)).status, 'pending');
        expect(service.requests, isEmpty);
        expect(service.summaries, isEmpty);
        expect(service.healthCalls, healthCalls);
        expect(fault.failures, 1);
        expect(tester.takeException(), isNull);
        final observation = {
          'case': label,
          'faultCount': fault.failures,
          'failedStatement': fault.failedStatement,
          'originalIdentityHealthy': true,
          'independentReadAfterFaultSucceeded': true,
          'errorTextCount': messages,
          'sameRouteRetryAvailable': hasRetry,
          'enabledBodyButtons': enabledButtons,
          'errorMaxScrollExtent': maxScroll,
          'safeBackHitTarget': [backRect.width, backRect.height],
          'sameProposalReadableAfter': hasRetry ? 'retry' : 'leave-and-reopen',
          'allEightTablesUnchanged': true,
          'turnRequests': service.requests.length,
          'summaryRequests': service.summaries.length,
          'syntheticPhotosOnly': true,
        };
        if (captureDirectory.isNotEmpty) {
          await tester.runAsync(
            () => File('$captureDirectory/r7-$label.json').writeAsString(
              '${const JsonEncoder.withIndent('  ').convert(observation)}\n',
            ),
          );
        }
        expect(
          hasRetry,
          isTrue,
          reason:
              'The healthy original identity can read the same pending '
              'proposal after a one-shot failure, but this route offers no '
              'retry. Back/reopen works without writes; it is not same-route recovery.',
        );
      }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
    }
  }
}
