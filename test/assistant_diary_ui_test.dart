import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/sync/identity_store.dart';
import 'package:habit_checkin/features/assistant/assistant_providers.dart';
import 'package:habit_checkin/features/assistant/data/local_conversation_store.dart';
import 'package:habit_checkin/features/journal/data/local_journal_store.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:uuid/uuid.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

import 'assistant_conversation_ui_test.dart' show openPlanning, sendText;
import 'support/test_assistant_service.dart';
import 'support/ui_harness.dart';
import 'support/sync_fixtures.dart';

Finder key(String value) => find.byKey(ValueKey(value));

Future<void> tapDiaryControl(WidgetTester tester, Finder finder) async {
  await Scrollable.ensureVisible(tester.element(finder), alignment: 0.5);
  await tester.pumpAndSettle();
  expect(finder.hitTestable(), findsOneWidget);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<(UiHarness, ConversationTestService)> openDiarySuggestion(
  WidgetTester tester, {
  bool dated = true,
  String? original,
  bool preconsented = false,
  String content = '合成新正文',
  Widget Function(Widget child)? wrapApp,
}) async {
  final app = UiHarness();
  if (preconsented) {
    await LocalConversationStore(app.repository).memories.consent();
  }
  final service = ConversationTestService()
    ..onTurn = (request) async => TurnResponse.fromJson({
      'protocol': assistantProtocol,
      'request_id': request.requestId,
      'reply': '请确认日记建议。',
      'plan': null,
      'memory_ops': <Object?>[],
      'diary': {
        'date': dated ? request.now.date.key : null,
        'content': content,
      },
    }, request: request);
  await app.mount(
    tester,
    assistantService: service,
    wrapApp: wrapApp,
    assistantCredentials: ConversationTestCredentials(),
  );
  if (original != null) {
    final store = await app.container.read(assistantStoreProvider.future);
    final diaries = LocalDiaryStore(store.goals);
    var draft = await diaries.beginDraft(app.clock.day);
    draft = await diaries.writeDraft(
      draft.entry.id,
      content: original,
      expectedDraftRevision: draft.entry.draftRevision,
    );
    await diaries.save(
      draft.entry.id,
      operationId: const Uuid().v4(),
      expectedRevision: draft.entry.revision,
      expectedDraftRevision: draft.entry.draftRevision,
    );
  }
  await openPlanning(tester);
  await sendText(tester, '合成新正文，放入${dated ? '今天' : ''}日记');
  await tapDiaryControl(tester, find.text('预览日记建议'));
  return (app, service);
}

void main() {
  setUpAll(tzdata.initializeTimeZones);
  testUiWidgets('model text alone cannot create a diary receipt', (
    tester,
  ) async {
    final app = UiHarness();
    final service = ConversationTestService()
      ..onTurn = (request) async => TurnResponse.fromJson({
        'protocol': assistantProtocol,
        'request_id': request.requestId,
        'reply': '合成模型误称：已保存到日记',
        'plan': null,
        'memory_ops': <Object?>[],
      }, request: request);
    await app.mount(
      tester,
      assistantService: service,
      assistantCredentials: ConversationTestCredentials(),
    );
    await openPlanning(tester);
    await sendText(tester, '把合成文字放入今天日记');
    expect(await app.database.select(app.database.diaryEntries).get(), isEmpty);
    expect(
      await app.database.select(app.database.assistantDiaryProposals).get(),
      isEmpty,
    );
    expect(key('chat-diary-receipt'), findsNothing);
    expect(find.text('预览日记建议'), findsNothing);
  });
  testUiWidgets('cancelled confirmation and cancelled proposal do not save', (
    tester,
  ) async {
    final (app, service) = await openDiarySuggestion(tester);
    await tapVisible(tester, key('chat-diary-suggested-date'));
    await tapVisible(tester, key('chat-diary-save'));
    await tapVisible(tester, key('chat-diary-abort-save'));
    expect(await app.database.select(app.database.diaryEntries).get(), isEmpty);
    await tapVisible(tester, key('chat-diary-cancel'));
    expect(find.text('建议已取消，未写入日记'), findsOneWidget);
    expect(await app.database.select(app.database.diaryEntries).get(), isEmpty);
    expect(service.requests, hasLength(1));
  });

  testUiWidgets('ambiguous date requires explicit picker confirmation', (
    tester,
  ) async {
    final (app, _) = await openDiarySuggestion(tester, dated: false);
    expect(key('chat-diary-suggested-date'), findsNothing);
    expect(
      tester.widget<FilledButton>(key('chat-diary-save')).onPressed,
      isNull,
    );
    await tapVisible(tester, key('chat-diary-date'));
    await tapVisible(tester, find.text('确定'));
    expect(find.text(app.clock.day.key), findsWidgets);
    expect(
      tester.widget<FilledButton>(key('chat-diary-save')).onPressed,
      isNotNull,
    );
    expect(await app.database.select(app.database.diaryEntries).get(), isEmpty);
  });

  for (final append in [true, false]) {
    testUiWidgets(
      'existing diary requires explicit ${append ? 'append' : 'replace'} choice',
      (tester) async {
        final (app, _) = await openDiarySuggestion(tester, original: '合成原文');
        await tapVisible(tester, key('chat-diary-suggested-date'));
        expect(find.text('合成原文'), findsNothing);
        await tapVisible(tester, key('chat-diary-original-toggle'));
        expect(find.text('合成原文'), findsOneWidget);
        await tapVisible(tester, key('chat-diary-original-toggle'));
        expect(
          tester.widget<FilledButton>(key('chat-diary-save')).onPressed,
          isNull,
        );
        await tapVisible(tester, find.text(append ? '追加' : '替换'));
        await tapVisible(tester, key('chat-diary-save'));
        expect(
          (await app.database.select(app.database.diaryEntries).getSingle())
              .content,
          '合成原文',
        );
        await tapVisible(tester, key('chat-diary-confirm-save'));
        expect(
          (await app.database.select(app.database.diaryEntries).getSingle())
              .content,
          append ? '合成原文\n\n合成新正文' : '合成新正文',
        );
      },
    );
  }

  testUiWidgets(
    'receipt write failure gives no success; explicit retry saves once',
    (tester) async {
      final (app, service) = await openDiarySuggestion(tester);
      await app.database.customStatement(
        "CREATE TRIGGER fail_diary_receipt BEFORE UPDATE ON assistant_diary_proposals BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END",
      );
      await tapVisible(tester, key('chat-diary-suggested-date'));
      await tapVisible(tester, key('chat-diary-save'));
      await tapVisible(tester, key('chat-diary-confirm-save'));
      expect(key('chat-diary-receipt'), findsNothing);
      expect(find.text('操作未完成，请重试。原有日记和建议已保留。'), findsOneWidget);
      expect(
        await app.database.select(app.database.diaryEntries).get(),
        isEmpty,
      );
      await app.database.customStatement('DROP TRIGGER fail_diary_receipt');
      await tapVisible(tester, key('chat-diary-save'));
      await tapVisible(tester, key('chat-diary-confirm-save'));
      expect(key('chat-diary-receipt'), findsOneWidget);
      expect(
        (await app.database.select(app.database.diaryEntries).getSingle())
            .revision,
        1,
      );
      expect(service.requests, hasLength(1));
    },
  );

  testUiWidgets(
    'double save taps show one confirmation and one durable receipt',
    (tester) async {
      final (app, _) = await openDiarySuggestion(tester);
      await tapVisible(tester, key('chat-diary-suggested-date'));
      await tester.ensureVisible(key('chat-diary-save'));
      await tester.pumpAndSettle();
      expect(key('chat-diary-save').hitTestable(), findsOneWidget);
      final point = tester.getCenter(key('chat-diary-save'));
      await tester.tapAt(point);
      await tester.tapAt(point);
      await tester.pumpAndSettle();
      expect(key('chat-diary-confirm-save'), findsOneWidget);
      await tapVisible(tester, key('chat-diary-confirm-save'));
      expect(
        (await app.database.select(app.database.diaryEntries).getSingle())
            .revision,
        1,
      );
      expect(key('chat-diary-receipt'), findsOneWidget);
    },
  );

  testUiWidgets(
    'identity change closes confirmation and hides original content',
    (tester) async {
      final (app, _) = await openDiarySuggestion(tester);
      await tapVisible(tester, key('chat-diary-suggested-date'));
      await tapVisible(tester, key('chat-diary-save'));
      final identities = IdentityStore(app.database);
      await identities.finish(await identities.begin(accountA));
      await tester.pumpAndSettle();
      expect(key('chat-diary-confirm-save'), findsNothing);
      expect(find.text('合成新正文'), findsNothing);
      expect(
        await app.database.select(app.database.diaryEntries).get(),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final brightness in Brightness.values) {
    testUiWidgets(
      '320px 3.5x ${brightness.name} preview can append and save without overflow',
      (tester) async {
        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1;
        tester.view.padding = const FakeViewPadding(top: 20);
        tester.view.viewPadding = const FakeViewPadding(top: 20);
        tester.view.viewInsets = const FakeViewPadding();
        tester.platformDispatcher.textScaleFactorTestValue = 3.5;
        tester.platformDispatcher.platformBrightnessTestValue = brightness;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          tester.view.resetPadding();
          tester.view.resetViewPadding();
          tester.view.resetViewInsets();
          tester.platformDispatcher.clearTextScaleFactorTestValue();
          tester.platformDispatcher.clearPlatformBrightnessTestValue();
        });
        final (app, _) = await openDiarySuggestion(
          tester,
          original: '合成原文' * 40,
          preconsented: true,
        );
        await tapDiaryControl(tester, key('chat-diary-suggested-date'));
        await tapDiaryControl(tester, find.text('追加'));
        await tapDiaryControl(tester, key('chat-diary-save'));
        await tapDiaryControl(tester, key('chat-diary-confirm-save'));
        expect(key('chat-diary-receipt'), findsOneWidget);
        expect(
          (await app.database.select(app.database.diaryEntries).getSingle())
              .content,
          '${'合成原文' * 40}\n\n合成新正文',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
  testUiWidgets(
    'chat diary opens preview, explicit date and save receipt, then undo',
    (tester) async {
      final app = UiHarness();
      final service = ConversationTestService()
        ..onTurn = (request) async => TurnResponse.fromJson({
          'protocol': assistantProtocol,
          'request_id': request.requestId,
          'reply': '请确认日记建议。',
          'plan': null,
          'memory_ops': <Object?>[],
          'diary': {'date': request.now.date.key, 'content': '合成素材：读了十页书。'},
        }, request: request);
      await app.mount(
        tester,
        assistantService: service,
        assistantCredentials: ConversationTestCredentials(),
      );
      await openPlanning(tester);
      await sendText(tester, '合成素材：读了十页书。把上面这段放入今天日记');
      expect(
        await app.database.select(app.database.diaryEntries).get(),
        isEmpty,
      );
      await tapVisible(tester, find.text('预览日记建议'));
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('chat-diary-save')))
            .onPressed,
        isNull,
      );
      await tapVisible(
        tester,
        find.byKey(const ValueKey('chat-diary-suggested-date')),
      );
      expect(find.text(app.clock.day.key), findsWidgets);
      await tapVisible(tester, find.byKey(const ValueKey('chat-diary-save')));
      expect(
        await app.database.select(app.database.diaryEntries).get(),
        isEmpty,
      );
      await tapVisible(
        tester,
        find.byKey(const ValueKey('chat-diary-confirm-save')),
      );
      expect(find.byKey(const ValueKey('chat-diary-receipt')), findsOneWidget);
      final diary = await app.database
          .select(app.database.diaryEntries)
          .getSingle();
      expect(diary.content, '合成素材：读了十页书。');
      expect(diary.isSaved, isTrue);
      await tapVisible(tester, find.byKey(const ValueKey('chat-diary-undo')));
      await tapVisible(
        tester,
        find.byKey(const ValueKey('chat-diary-confirm-undo')),
      );
      expect(
        (await app.database.select(app.database.diaryEntries).getSingle())
            .isSaved,
        isFalse,
      );
      expect(service.requests, hasLength(1));
      final controller = await app.container.read(
        assistantConversationProvider.future,
      );
      expect(controller.error, isNull);
      expect(tester.takeException(), isNull);
    },
  );
}
