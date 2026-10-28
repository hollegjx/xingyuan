import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/sync/identity_store.dart';
import 'package:habit_checkin/features/assistant/assistant_providers.dart';
import 'package:habit_checkin/features/assistant/data/assistant_service.dart';
import 'package:habit_checkin/features/assistant/data/local_memory_store.dart';
import 'package:habit_checkin/features/assistant/presentation/assistant_conversation_details_page.dart';
import 'package:habit_checkin/features/assistant/presentation/assistant_proposal_page.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'support/test_assistant_service.dart';
import 'support/sync_fixtures.dart';
import 'support/ui_harness.dart';

Future<void> openPlanning(WidgetTester tester, {bool consent = true}) async {
  await tapVisible(tester, find.byTooltip('规划'));
  if (consent &&
      find
          .byKey(const ValueKey('assistant-consent-confirm'))
          .evaluate()
          .isNotEmpty) {
    await tapVisible(
      tester,
      find.byKey(const ValueKey('assistant-consent-confirm')),
    );
  }
}

Future<void> sendText(
  WidgetTester tester,
  String text, {
  bool waiting = false,
}) async {
  await tester.ensureVisible(find.byKey(const ValueKey('assistant-input')));
  await tester.enterText(find.byKey(const ValueKey('assistant-input')), text);
  await tester.pump();
  expect(
    tester
        .widget<IconButton>(find.byKey(const ValueKey('assistant-send')))
        .onPressed,
    isNotNull,
  );
  await tapVisible(
    tester,
    find.byKey(const ValueKey('assistant-send')),
    settle: !waiting,
  );
}

void main() {
  setUpAll(tzdata.initializeTimeZones);
  testUiWidgets('unsent text survives session-list return and other tabs', (
    tester,
  ) async {
    final app = UiHarness();
    final service = ConversationTestService();
    await app.mount(
      tester,
      assistantService: service,
      assistantCredentials: ConversationTestCredentials(),
    );
    await openPlanning(tester);
    final input = find.byKey(const ValueKey('assistant-input'));
    await tester.enterText(input, 'TEST 写到一半还没有发送');
    await tapVisible(tester, find.byTooltip('会话列表'));
    await goBack(tester);
    expect(tester.widget<TextField>(input).controller!.text, 'TEST 写到一半还没有发送');
    await tapVisible(tester, find.byTooltip('今天'));
    await openPlanning(tester);
    await tapVisible(tester, find.byTooltip('AI 设置'));
    await goBack(tester);
    expect(tester.widget<TextField>(input).controller!.text, 'TEST 写到一半还没有发送');
    expect(service.requests, isEmpty);
  });

  testUiWidgets('unsent drafts stay with their own sessions', (tester) async {
    final app = UiHarness();
    await app.mount(
      tester,
      assistantService: ConversationTestService(),
      assistantCredentials: ConversationTestCredentials(),
    );
    await openPlanning(tester);
    await sendText(tester, 'TEST 会话一');
    final controller = await app.container.read(
      assistantConversationProvider.future,
    );
    final first = controller.session!.id;
    final input = find.byKey(const ValueKey('assistant-input'));
    await tester.enterText(input, 'TEST 第一份草稿');
    await tapVisible(tester, find.byTooltip('会话列表'));
    await tapVisible(
      tester,
      find.byKey(const ValueKey('assistant-new-session')),
    );
    final second = controller.session!.id;
    expect(second, isNot(first));
    expect(tester.widget<TextField>(input).controller!.text, isEmpty);
    await tester.enterText(input, 'TEST 第二份草稿');
    await tapVisible(tester, find.byTooltip('会话列表'));
    await tapVisible(tester, find.widgetWithText(ListTile, 'TEST 会话一'));
    expect(tester.widget<TextField>(input).controller!.text, 'TEST 第一份草稿');
    await tapVisible(tester, find.byTooltip('会话列表'));
    await tapVisible(tester, find.widgetWithText(ListTile, '新会话'));
    expect(controller.session!.id, second);
    expect(tester.widget<TextField>(input).controller!.text, 'TEST 第二份草稿');
  });

  testUiWidgets('rapid new-session taps create and navigate only once', (
    tester,
  ) async {
    final app = UiHarness();
    await app.mount(
      tester,
      assistantService: ConversationTestService(),
      assistantCredentials: ConversationTestCredentials(),
    );
    await openPlanning(tester);
    await tapVisible(tester, find.byTooltip('会话列表'));
    final button = find.byKey(const ValueKey('assistant-new-session'));
    await tester.tap(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    final controller = await app.container.read(
      assistantConversationProvider.future,
    );
    expect(controller.sessions, hasLength(1));
    expect(find.byKey(const ValueKey('assistant-input')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testUiWidgets(
    'typing the next draft immediately after send does not lose it',
    (tester) async {
      final app = UiHarness();
      final service = ConversationTestService();
      await app.mount(
        tester,
        assistantService: service,
        assistantCredentials: ConversationTestCredentials(),
      );
      await openPlanning(tester);
      final input = find.byKey(const ValueKey('assistant-input'));
      await tester.enterText(input, 'TEST 发出去的内容');
      await tester.pump();
      final entered = Completer<void>();
      final release = Completer<void>();
      final lock = app.database.transaction(() async {
        entered.complete();
        await release.future;
      });
      await entered.future;
      await tester.tap(find.byKey(const ValueKey('assistant-send')));
      await tester.enterText(input, 'TEST 紧接着写下一条');
      release.complete();
      await lock;
      await tester.pumpAndSettle();
      expect(service.requests, hasLength(1));
      expect(service.requests.single.messages.last.text, 'TEST 发出去的内容');
      expect(tester.widget<TextField>(input).controller!.text, 'TEST 紧接着写下一条');
    },
  );

  testUiWidgets('selecting the same failed session returns without a retry', (
    tester,
  ) async {
    final app = UiHarness();
    final service = ConversationTestService()
      ..onTurn = (_) async =>
          throw const AssistantFailure(AssistantFailureKind.network);
    await app.mount(
      tester,
      assistantService: service,
      assistantCredentials: ConversationTestCredentials(),
    );
    await openPlanning(tester);
    await sendText(tester, 'TEST 失败的会话');
    final input = find.byKey(const ValueKey('assistant-input'));
    await tester.enterText(input, 'TEST 继续编辑');
    await tapVisible(tester, find.byTooltip('会话列表'));
    await tapVisible(tester, find.widgetWithText(ListTile, 'TEST 失败的会话'));
    expect(input, findsOneWidget);
    expect(tester.widget<TextField>(input).controller!.text, 'TEST 继续编辑');
    expect(service.requests, hasLength(1));
  });

  testUiWidgets('failed turn can be followed by a new message and plan', (
    tester,
  ) async {
    final app = UiHarness();
    final service = ConversationTestService();
    service.onTurn = (request) async {
      if (service.requests.length == 1) {
        throw const AssistantFailure(AssistantFailureKind.network);
      }
      return syntheticReply(request, plan: true);
    };
    await app.mount(
      tester,
      assistantService: service,
      assistantCredentials: ConversationTestCredentials(),
    );
    await openPlanning(tester);
    await sendText(tester, 'TEST 断网时发送');
    await sendText(tester, 'TEST 恢复后重新安排');
    final controller = await app.container.read(
      assistantConversationProvider.future,
    );
    expect(controller.messages, hasLength(3));
    expect(controller.messages.first.status, 'failed');
    expect(controller.proposals, hasLength(1));
    expect(controller.error, isNull);
    expect(await app.repository.loadGoals(), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testUiWidgets(
    'waiting, same-session selection and retry preserve next draft',
    (tester) async {
      final app = UiHarness();
      final release = Completer<void>();
      final service = ConversationTestService();
      service.onTurn = (request) async {
        if (service.requests.length == 1) await release.future;
        return syntheticReply(request);
      };
      await app.mount(
        tester,
        assistantService: service,
        assistantCredentials: ConversationTestCredentials(),
      );
      await openPlanning(tester);
      await sendText(tester, 'TEST 等待中的消息', waiting: true);
      final controller = await app.container.read(
        assistantConversationProvider.future,
      );
      final message = controller.messages.single;
      final input = find.byKey(const ValueKey('assistant-input'));
      await tester.enterText(input, 'TEST 等待时写的下一条');
      await tapVisible(tester, find.byTooltip('会话列表'));
      await tapVisible(
        tester,
        find.widgetWithText(ListTile, 'TEST 等待中的消息'),
        settle: false,
      );
      expect(controller.busy, isTrue);
      expect(tester.widget<TextField>(input).controller!.text, 'TEST 等待时写的下一条');
      await tapVisible(tester, find.byKey(const ValueKey('assistant-cancel')));
      await tapVisible(tester, find.byKey(ValueKey('retry-${message.id}')));
      await tapVisible(
        tester,
        find.byKey(const ValueKey('assistant-confirm-retry')),
      );
      release.complete();
      await tester.pumpAndSettle();
      expect(controller.messages, hasLength(3));
      expect(tester.widget<TextField>(input).controller!.text, 'TEST 等待时写的下一条');
      expect(tester.takeException(), isNull);
    },
  );

  testUiWidgets(
    'identity changes clear both visible and cached session drafts',
    (tester) async {
      final app = UiHarness();
      await app.mount(
        tester,
        assistantService: ConversationTestService(),
        assistantCredentials: ConversationTestCredentials(),
      );
      await openPlanning(tester);
      await sendText(tester, 'TEST 第一会话');
      final input = find.byKey(const ValueKey('assistant-input'));
      await tester.enterText(input, 'TEST 不应跨身份的草稿');
      await tapVisible(tester, find.byTooltip('会话列表'));
      await tapVisible(
        tester,
        find.byKey(const ValueKey('assistant-new-session')),
      );
      await tester.enterText(input, 'TEST 第二份私有草稿');
      final identity = IdentityStore(app.database);
      final original = await identity.active();
      await identity.finish(await identity.begin(accountA));
      await tester.pumpAndSettle();
      expect(input, findsNothing);
      await identity.finish(await identity.begin(original.identity));
      app.container.invalidate(assistantStoreProvider);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(input).controller!.text, isEmpty);
      await tapVisible(tester, find.byTooltip('会话列表'));
      await tapVisible(tester, find.widgetWithText(ListTile, 'TEST 第一会话'));
      expect(tester.widget<TextField>(input).controller!.text, isEmpty);
    },
  );

  for (final scale in [1.0, 2.0, 3.0]) {
    testUiWidgets(
      'conversation consent, payload, preview, receipt and memory undo at 320px ${scale}x',
      (tester) async {
        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final app = UiHarness();
        final service = ConversationTestService()
          ..onTurn = (request) async =>
              syntheticReply(request, plan: true, memory: true);
        await app.mount(
          tester,
          assistantService: service,
          assistantCredentials: ConversationTestCredentials(),
        );
        expect(find.byKey(const ValueKey('plan-today')), findsNothing);
        await openPlanning(tester, consent: false);
        expect(service.requests, isEmpty);
        expect(service.healthCalls, 0);
        expect(find.text('AI 数据授权'), findsOneWidget);
        await tapVisible(
          tester,
          find.byKey(const ValueKey('assistant-consent-confirm')),
        );
        expect(service.requests, isEmpty);
        await sendText(tester, 'TEST 明晚读书');
        final controller = await app.container.read(
          assistantConversationProvider.future,
        );
        expect(controller.messages, hasLength(2));
        expect(controller.proposals, hasLength(1));
        expect(await app.repository.loadGoals(), isEmpty);
        final message = controller.messages.first;
        await tapVisible(tester, find.byKey(ValueKey('payload-${message.id}')));
        expect(find.byType(AssistantConversationDetailsPage), findsOneWidget);
        final payloadText = tester
            .widget<SelectableText>(
              find.byKey(const ValueKey('assistant-sent-payload')),
            )
            .data!;
        expect(jsonDecode(payloadText), service.requests.single.toJson());
        expect(jsonDecode(payloadText), jsonDecode(message.sentPayload!));
        await goBack(tester);
        final proposal = controller.proposals.single;
        await tapVisible(
          tester,
          find.byKey(ValueKey('open-proposal-${proposal.id}')),
        );
        expect(find.byType(AssistantProposalPage), findsOneWidget);
        await tapVisible(tester, find.byTooltip('编辑条目'));
        await tester.enterText(
          find.byKey(const ValueKey('assistant-plan-title')),
          'TEST 修改后阅读',
        );
        await tapVisible(
          tester,
          find.byKey(const ValueKey('assistant-save-plan-item')),
        );
        await tapVisible(
          tester,
          find.byKey(const ValueKey('assistant-apply-plan')),
        );
        expect(
          (await app.repository.loadGoals()).single.titleOn(app.clock.day),
          'TEST 修改后阅读',
        );
        await goBack(tester);
        expect(find.text('已创建 1 项 · 查看'), findsOneWidget);
        final event = controller.events.values.expand((rows) => rows).single;
        await tapVisible(
          tester,
          find.byKey(ValueKey('undo-memory-${event.id}')),
        );
        expect(await controller.store.memories.list(), isEmpty);
        expect(find.textContaining('已撤销记忆操作'), findsOneWidget);
        await tapVisible(
          tester,
          find.byKey(ValueKey('undo-proposal-${proposal.id}')),
        );
        expect(find.text('撤销本批计划？'), findsOneWidget);
        await tapVisible(
          tester,
          find.byKey(const ValueKey('assistant-undo-confirm')),
        );
        expect(await app.repository.loadGoals(), isEmpty);
        await goBack(tester);
        expect(find.text('已撤销 · 查看结果'), findsOneWidget);
        expect(service.requests, hasLength(1));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testUiWidgets(
    'unconfigured and missing credential states keep manual tracking available',
    (tester) async {
      final app = UiHarness();
      final service = ConversationTestService()..configured = false;
      final credentials = ConversationTestCredentials()..value = null;
      await app.mount(
        tester,
        assistantService: service,
        assistantCredentials: credentials,
      );
      await openPlanning(tester);
      await tester.enterText(
        find.byKey(const ValueKey('assistant-input')),
        'TEST 不会发送',
      );
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('assistant-send')))
            .onPressed,
        isNull,
      );
      expect(find.textContaining('AI 服务未连接'), findsOneWidget);
      service.configured = true;
      app.container.invalidate(assistantServiceProvider);
      app.container.invalidate(assistantCredentialReadyProvider);
      await tester.pumpAndSettle();
      expect(find.textContaining('尚未录入访问凭证'), findsOneWidget);
      expect(service.requests, isEmpty);
      await tapVisible(tester, find.byTooltip('今天'));
      expect(find.byKey(const ValueKey('entry-new-goal')), findsOneWidget);
    },
  );

  testUiWidgets(
    'cancel and retry use distinct IDs; a late cancelled reply has no card',
    (tester) async {
      final app = UiHarness();
      final release = Completer<void>();
      final service = ConversationTestService();
      service.onTurn = (request) async {
        if (service.requests.length == 1) await release.future;
        return syntheticReply(request, plan: true);
      };
      await app.mount(
        tester,
        assistantService: service,
        assistantCredentials: ConversationTestCredentials(),
      );
      await openPlanning(tester);
      await sendText(tester, 'TEST 规划', waiting: true);
      final controller = await app.container.read(
        assistantConversationProvider.future,
      );
      expect(controller.busy, isTrue);
      final first = controller.messages.single;
      await tapVisible(tester, find.byKey(const ValueKey('assistant-cancel')));
      expect(find.textContaining('模型调用可能已经发生'), findsWidgets);
      await tapVisible(tester, find.byKey(ValueKey('retry-${first.id}')));
      await tapVisible(
        tester,
        find.byKey(const ValueKey('assistant-confirm-retry')),
      );
      release.complete();
      await tester.pumpAndSettle();
      expect(controller.messages, hasLength(3));
      expect(controller.proposals, hasLength(1));
      expect(
        service.requests[0].requestId,
        isNot(service.requests[1].requestId),
      );
      expect(await app.repository.loadGoals(), isEmpty);
    },
  );

  testUiWidgets(
    'credential replacement cancels pending work and does not accept a late reply',
    (tester) async {
      final app = UiHarness();
      final release = Completer<void>();
      final service = ConversationTestService()
        ..onTurn = (request) async {
          await release.future;
          return syntheticReply(request, plan: true, memory: true);
        };
      final credentials = ConversationTestCredentials();
      await app.mount(
        tester,
        assistantService: service,
        assistantCredentials: credentials,
      );
      await openPlanning(tester);
      await sendText(tester, 'TEST 待回复', waiting: true);
      await tapVisible(tester, find.byTooltip('AI 设置'));
      await tapVisible(
        tester,
        find.byKey(const ValueKey('assistant-clear-credential')),
      );
      release.complete();
      await tester.pumpAndSettle();
      await goBack(tester);
      final controller = await app.container.read(
        assistantConversationProvider.future,
      );
      expect(controller.messages.single.status, 'discarded');
      expect(controller.proposals, isEmpty);
      expect(await controller.store.memories.list(), isEmpty);
      expect(credentials.value, isNull);
      expect(find.textContaining('尚未录入访问凭证'), findsOneWidget);
    },
  );

  testUiWidgets(
    'sessions support rename, new, reopen and confirmed deletion without losing memories',
    (tester) async {
      final app = UiHarness();
      final service = ConversationTestService()
        ..onTurn = (request) async => syntheticReply(request, memory: true);
      await app.mount(
        tester,
        assistantService: service,
        assistantCredentials: ConversationTestCredentials(),
      );
      await openPlanning(tester);
      await sendText(tester, 'TEST 原会话');
      final controller = await app.container.read(
        assistantConversationProvider.future,
      );
      final first = controller.session!.id;
      await tapVisible(tester, find.byTooltip('会话列表'));
      await tapVisible(tester, find.byKey(ValueKey('rename-session-$first')));
      await tester.enterText(
        find.byKey(const ValueKey('assistant-session-title')),
        'TEST 已命名',
      );
      await tapVisible(tester, find.widgetWithText(FilledButton, '保存'));
      expect(controller.session!.title, 'TEST 已命名');
      await tapVisible(
        tester,
        find.byKey(const ValueKey('assistant-new-session')),
      );
      expect(controller.messages, isEmpty);
      await tapVisible(tester, find.byTooltip('会话列表'));
      await tapVisible(tester, find.text('TEST 已命名'));
      expect(controller.messages, hasLength(2));
      await tapVisible(tester, find.byTooltip('会话列表'));
      await tapVisible(tester, find.byKey(ValueKey('delete-session-$first')));
      await tapVisible(
        tester,
        find.byKey(const ValueKey('assistant-delete-session-confirm')),
      );
      expect(controller.sessions, hasLength(1));
      expect(await controller.store.memories.list(), hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testUiWidgets('summary view and opt-out payload reflect persisted state', (
    tester,
  ) async {
    final app = UiHarness();
    final service = ConversationTestService();
    await LocalMemoryStore(app.repository).updateSettings(
      sendMemories: false,
      sendSchedule: false,
      sendStats: false,
    );
    await app.mount(
      tester,
      assistantService: service,
      assistantCredentials: ConversationTestCredentials(),
    );
    await openPlanning(tester);
    final controller = await app.container.read(
      assistantConversationProvider.future,
    );
    for (var i = 0; i < 11; i++) {
      await controller.send('TEST $i');
      await tester.pumpAndSettle();
    }
    expect(service.summaries, hasLength(1));
    expect(service.requests.last.toJson().keys, isNot(contains('memories')));
    expect(service.requests.last.toJson().keys, isNot(contains('schedule')));
    expect(service.requests.last.toJson().keys, isNot(contains('stats')));
    await tapVisible(tester, find.byTooltip('会话信息'));
    expect(find.text('TEST 历史约束摘要'), findsOneWidget);
    expect(controller.messages, hasLength(22));
  });

  for (final kind in [
    AssistantFailureKind.network,
    AssistantFailureKind.credential,
    AssistantFailureKind.busy,
    AssistantFailureKind.invalidResponse,
    AssistantFailureKind.timeout,
  ]) {
    testUiWidgets(
      'conversation displays $kind without invented replies or goals',
      (tester) async {
        final app = UiHarness();
        final service = ConversationTestService()
          ..onTurn = (_) async => throw AssistantFailure(kind);
        await app.mount(
          tester,
          assistantService: service,
          assistantCredentials: ConversationTestCredentials(),
        );
        await openPlanning(tester);
        await sendText(tester, 'TEST 故障');
        final controller = await app.container.read(
          assistantConversationProvider.future,
        );
        expect(controller.messages.single.status, 'failed');
        expect(find.text(AssistantFailure(kind).message), findsWidgets);
        expect(await app.repository.loadGoals(), isEmpty);
        expect(service.requests, hasLength(1));
        expect(tester.takeException(), isNull);
      },
    );
  }
}
