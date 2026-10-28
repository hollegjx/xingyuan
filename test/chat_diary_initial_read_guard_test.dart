import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

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
import 'package:habit_checkin/data/sync/sync_identity.dart';
import 'package:habit_checkin/features/assistant/assistant_providers.dart';
import 'package:habit_checkin/features/assistant/data/local_conversation_store.dart';
import 'package:habit_checkin/features/companion/companion_providers.dart';
import 'package:habit_checkin/features/journal/domain/journal_entry.dart';
import 'package:habit_checkin/features/journal/journal_providers.dart';
import 'package:habit_checkin/features/journal/presentation/chat_diary_page.dart';
import 'package:habit_checkin/features/journal/presentation/diary_preview_body.dart';
import 'package:habit_checkin/shared/presentation.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'assistant_conversation_ui_test.dart' show openPlanning;
import 'assistant_diary_entry_layout_test.dart' show viewport;
import 'assistant_diary_ui_test.dart' show tapDiaryControl;
import 'chat_diary_initial_read_recovery_test.dart'
    show
        OneShotProposalRead,
        proposalId,
        proposalText,
        readError,
        readState,
        seed;
import 'journal_diary_capture_test.dart'
    show capture, captureFont, loadDiaryCaptureFont;
import 'support/chat_photo_files.dart';
import 'support/journal_fixtures.dart';
import 'support/sync_fixtures.dart';
import 'support/test_assistant_service.dart';
import 'support/test_clock.dart';
import 'support/test_reminder_notifications.dart';
import 'support/ui_harness.dart';

Finder get retry => find.widgetWithText(OutlinedButton, '重试');
Finder control(String name) => find.byKey(ValueKey('chat-diary-$name'));

class DeferredProposalRead extends OneShotProposalRead {
  Completer<void>? completion;
  bool _proposalSelected = false;
  bool committed = false;

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    final rows = await super.runSelect(executor, statement, args);
    if (statement.contains('assistant_diary_proposals') &&
        args.contains(proposalId)) {
      _proposalSelected = true;
    }
    return rows;
  }

  @override
  Future<void> commitTransaction(TransactionExecutor inner) async {
    final gate = _proposalSelected ? completion : null;
    _proposalSelected = false;
    if (gate != null) completion = null;
    await inner.send();
    // Delay delivery after the read releases SQLite, so a real identity change
    // can finish while the page is still waiting for the original read.
    if (gate != null) {
      committed = true;
      await gate.future;
    }
  }

  Completer<void> delayNextRead() {
    committed = false;
    final gate = completion = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    return gate;
  }
}

class ReadFixture {
  ReadFixture({DeferredProposalRead? fault})
    : fault = fault ?? DeferredProposalRead();
  final DeferredProposalRead fault;
  late final db = AppDatabase(NativeDatabase.memory().interceptWith(fault));
  final clock = TestClock();
  final service = ConversationTestService();
  final boundary = GlobalKey();
  final unavailableStore = Completer<LocalConversationStore>();
  late ProviderContainer container;
  late LocalConversationStore conversation;
  late Map<String, Object> before;
  late int healthCalls;

  Future<void> mount(
    WidgetTester tester, {
    bool providerFailure = false,
  }) async {
    addTearDown(db.close);
    final lease = await IdentityStore(db).active();
    await seed(
      LocalGoalRepository(
        db,
        clock,
        owner: lease.identity.owner,
        identityLease: lease,
      ),
    );
    final files = MemoryChatPhotoFiles(db);
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
          if (providerFailure)
            assistantStoreProvider.overrideWith(
              (ref) => unavailableStore.future,
            ),
        ],
        child: RepaintBoundary(key: boundary, child: const HabitCheckinApp()),
      ),
    );
    await tester.pumpAndSettle();
    container = ProviderScope.containerOf(
      tester.element(find.byType(HabitCheckinApp)),
    );
    if (!providerFailure) {
      conversation = await container.read(assistantStoreProvider.future);
      await conversation.goals.requireActiveIdentity();
      await openPlanning(tester);
    }
    before = await readState(db);
    healthCalls = service.healthCalls;
  }

  Future<void> openFailed(WidgetTester tester) async {
    fault.armed = true;
    await tapDiaryControl(tester, find.text('预览日记建议'));
    expect(fault.failures, 1);
    expect(find.text(readError), findsOneWidget);
    expect(find.byType(NoticeBanner), findsNothing);
    expect(retry, findsOneWidget);
    await expectUnchanged();
  }

  Future<void> expectUnchanged({Map<String, Object>? expected}) async {
    expect(await readState(db), expected ?? before);
    expect(service.requests, isEmpty);
    expect(service.summaries, isEmpty);
    expect(service.healthCalls, healthCalls);
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
      final label = '${large ? '320-4x' : '390-1x'}-${theme.name}';
      testUiWidgets('R7 retry label, repeated failure and busy guard $label', (
        tester,
      ) async {
        viewport(tester, size, large ? 4 : 1, theme);
        final app = ReadFixture();
        await app.mount(tester);
        await app.openFailed(tester);
        final route = tester.state(find.byType(ChatDiaryPage));
        await tester.ensureVisible(retry);
        await tester.pumpAndSettle();
        expect(retry.hitTestable(), findsOneWidget);
        final rect = tester.getRect(retry);
        expect(rect.width, greaterThanOrEqualTo(44));
        expect(rect.height, greaterThanOrEqualTo(44));
        final semantics = tester.ensureSemantics();
        try {
          await tester.pump();
          final node = tester.getSemantics(retry).getSemanticsData();
          expect(node.label, '重试');
          expect(node.flagsCollection.isButton, isTrue);
          expect(node.hasAction(ui.SemanticsAction.tap), isTrue);
        } finally {
          semantics.dispose();
        }
        await capture(
          tester,
          app.boundary,
          'r7-guard-$label-retry-label',
          size,
          text: find.text('重试'),
          expectedText: '重试',
        );
        app.fault.armed = true;
        await tapVisible(tester, retry);
        expect(app.fault.failures, 2);
        expect(find.text(readError), findsOneWidget);
        expect(retry, findsOneWidget);
        await app.expectUnchanged();

        final callback = tester.widget<OutlinedButton>(retry).onPressed!;
        final reads = app.fault.proposalReads;
        final gate = app.fault.delayNextRead();
        await tapVisible(tester, retry, settle: false);
        callback();
        callback();
        await pumpWaiting(tester);
        expect(app.fault.committed, isTrue);
        expect(app.fault.proposalReads, reads + 1);
        final panel = tester.widget<StatusPanel>(find.byType(StatusPanel));
        expect(panel.loading, isTrue);
        expect(panel.retry, isNull);
        expect(find.text(readError), findsNothing);
        expect(retry, findsNothing);
        expect(find.byType(BackButton).hitTestable(), findsOneWidget);
        await tester.ensureVisible(find.text('正在读取日记建议'));
        await tester.pump();
        await capture(
          tester,
          app.boundary,
          'r7-guard-$label-busy',
          size,
          text: find.text('正在读取日记建议'),
          expectedText: '正在读取日记建议',
          firstLineOnly: large,
        );
        gate.complete();
        await tester.pumpAndSettle();
        expect(tester.state(find.byType(ChatDiaryPage)), same(route));
        expect(tester.widget<Text>(control('suggestion')).data, proposalText);
        expect(find.byType(StatusPanel), findsNothing);

        await tapDiaryControl(tester, control('edit'));
        await tester.enterText(control('edited-text'), '本地修改保留，不重新初始化。');
        final corrected = tester
            .widget<DiaryPreviewBody>(find.byType(DiaryPreviewBody))
            .editedText!
            .value;
        callback();
        await tester.pumpAndSettle();
        expect(app.fault.proposalReads, reads + 1);
        expect(
          tester
              .widget<DiaryPreviewBody>(find.byType(DiaryPreviewBody))
              .editedText!
              .value,
          corrected,
        );
        await app.expectUnchanged();
        expect(tester.takeException(), isNull);
      }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
    }
  }

  for (final initial in [true, false]) {
    testUiWidgets(
      'R7 leaves while ${initial ? 'initial' : 'retry'} read waits',
      (tester) async {
        final app = ReadFixture();
        await app.mount(tester);
        if (!initial) await app.openFailed(tester);
        final gate = app.fault.delayNextRead();
        if (initial) {
          await tapVisible(tester, find.text('预览日记建议'), settle: false);
        } else {
          await tapVisible(tester, retry, settle: false);
        }
        expect(app.fault.committed, isTrue);
        expect(
          tester.widget<StatusPanel>(find.byType(StatusPanel)).loading,
          isTrue,
        );
        await tapVisible(tester, find.byType(BackButton));
        expect(find.byType(ChatDiaryPage), findsNothing);
        gate.complete();
        await tester.pumpAndSettle();
        expect(find.byType(ChatDiaryPage), findsNothing);
        await app.expectUnchanged();
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final state in [
    'pending',
    'cancelled',
    'applied',
    'undone',
    'missing',
  ]) {
    testUiWidgets('R7 retry reads authoritative $state without writing', (
      tester,
    ) async {
      final app = ReadFixture();
      await app.mount(tester);
      await app.openFailed(tester);
      if (state == 'missing') {
        await (app.db.delete(
          app.db.assistantDiaryProposals,
        )..where((p) => p.id.equals(proposalId))).go();
      } else {
        final diary = await app.db.select(app.db.diaryEntries).getSingle();
        final receipt = state == 'applied' || state == 'undone';
        await (app.db.update(
          app.db.assistantDiaryProposals,
        )..where((p) => p.id.equals(proposalId))).write(
          AssistantDiaryProposalsCompanion(
            status: Value(state),
            content: const Value('权威行中的新建议，不能恢复旧建议。'),
            targetDay: Value(receipt ? app.clock.day.key : null),
            entryId: Value(receipt ? diary.id : null),
            appliedRevision: Value(receipt ? diary.revision : null),
            appliedDraftRevision: Value(receipt ? diary.draftRevision : null),
            appliedAt: Value(
              receipt ? app.clock.read().instant.microsecondsSinceEpoch : null,
            ),
          ),
        );
      }
      final expected = await readState(app.db);
      await tapVisible(tester, retry);
      switch (state) {
        case 'pending':
          expect(
            tester.widget<Text>(control('suggestion')).data,
            '权威行中的新建议，不能恢复旧建议。',
          );
        case 'cancelled':
          expect(find.text('建议已取消，未写入日记'), findsOneWidget);
        case 'applied':
          expect(control('receipt'), findsOneWidget);
        case 'undone':
          expect(find.text('本次写入已撤销'), findsOneWidget);
        case 'missing':
          expect(find.text('找不到这条日记建议'), findsOneWidget);
          expect(retry, findsOneWidget);
      }
      if (state != 'pending') {
        expect(control('save'), findsNothing);
        expect(control('suggestion'), findsNothing);
      }
      await app.expectUnchanged(expected: expected);
      expect(tester.takeException(), isNull);
    });
  }

  for (final pending in [false, true]) {
    testUiWidgets(
      'R7 original lease stays invalid after switch back $pending',
      (tester) async {
        final app = ReadFixture();
        await app.mount(tester);
        await app.openFailed(tester);
        final callback = tester.widget<OutlinedButton>(retry).onPressed!;
        Completer<void>? gate;
        if (pending) {
          gate = app.fault.delayNextRead();
          await tapVisible(tester, retry, settle: false);
          expect(app.fault.committed, isTrue);
        }
        final identity = IdentityStore(app.db);
        await identity.finish(await identity.begin(accountA));
        await pumpWaiting(tester);
        expect(find.text('身份已变化或不可用。'), findsOneWidget);
        expect(control('suggestion'), findsNothing);
        gate?.complete();
        await tester.pumpAndSettle();
        await identity.finish(await identity.begin(SyncIdentity.guest));
        await tester.pumpAndSettle();
        final expected = await readState(app.db);
        callback();
        await tester.pumpAndSettle();
        expect(find.text('身份已变化或不可用。'), findsOneWidget);
        expect(control('suggestion'), findsNothing);
        expect(retry, findsNothing);
        expect(
          await app.container.read(assistantStoreProvider.future),
          same(app.conversation),
        );
        await app.expectUnchanged(expected: expected);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
