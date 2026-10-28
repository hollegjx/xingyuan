import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/sync/identity_store.dart';
import 'package:habit_checkin/data/sync/sync_identity.dart';
import 'package:habit_checkin/features/assistant/data/assistant_service.dart';
import 'package:habit_checkin/features/assistant/data/local_conversation_store.dart';
import 'package:habit_checkin/features/assistant/presentation/assistant_conversation_controller.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'support/sync_fixtures.dart';
import 'support/test_assistant_service.dart';
import 'support/test_clock.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);
  late AppDatabase db;
  late LocalConversationStore store;
  late AssistantConversationController controller;
  late ConversationTestService service;
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    final clock = TestClock()..setDay(2026, 10, 20);
    store = LocalConversationStore(LocalGoalRepository(db, clock));
    await store.memories.consent();
    service = ConversationTestService();
    controller = AssistantConversationController(
      store: store,
      service: service,
    );
    await controller.initialize();
  });
  tearDown(() async {
    controller.dispose();
    await db.close();
  });

  test(
    'startup recovery runs once; refresh does not fail a pending request',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      service.onTurn = (request) async {
        entered.complete();
        await release.future;
        return syntheticReply(request);
      };
      final sending = controller.send('TEST 你好');
      await entered.future;
      await controller.refresh();
      expect(controller.messages.single.status, 'pending');
      expect(controller.busy, isTrue);
      await controller.send('TEST double tap');
      expect(service.requests, hasLength(1));
      release.complete();
      await sending;
      expect(controller.messages.map((row) => row.status), ['sent', 'sent']);
      expect(controller.busy, isFalse);
    },
  );

  test(
    'cancel releases the composer and late reply cannot overwrite a retry',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      service.onTurn = (request) async {
        if (service.requests.length == 1) {
          entered.complete();
          await release.future;
        }
        return syntheticReply(request, plan: true, memory: true);
      };
      final first = controller.send('TEST 规划');
      await entered.future;
      final original = controller.messages.single;
      await controller.cancel();
      expect(controller.busy, isFalse);
      expect(controller.messages.single.status, 'discarded');
      await controller.send(original.content, retryMessageId: original.id);
      expect(
        service.requests[0].requestId,
        isNot(service.requests[1].requestId),
      );
      release.complete();
      await first;
      expect(controller.messages, hasLength(3));
      expect(controller.proposals, hasLength(1));
      expect(await store.memories.list(), hasLength(1));
      expect(await store.goals.loadGoals(), isEmpty);
      expect(controller.error, isNull);
    },
  );

  test('identity generation changes hide all conversation data and reject late writes', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    service.onTurn = (request) async {
      entered.complete();
      await release.future;
      return syntheticReply(request, plan: true, memory: true);
    };
    final sending = controller.send('TEST 私密');
    await entered.future;
    final identities = IdentityStore(db);
    await identities.finish(await identities.begin(accountA));
    await identities.finish(await identities.begin(SyncIdentity.guest));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    release.complete();
    await sending;
    expect(controller.identityChanged, isTrue);
    expect(controller.messages, isEmpty);
    expect(controller.sessions, isEmpty);
    expect(await db.select(db.planProposals).get(), isEmpty);
    expect(await db.select(db.assistantMemories).get(), isEmpty);
    expect(
      (await db.select(db.assistantMessages).get()).single.status,
      'pending',
    );
  });

  test('changing sending categories cancels an in-flight turn', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    service.onTurn = (request) async {
      entered.complete();
      await release.future;
      return syntheticReply(request, memory: true);
    };
    final sending = controller.send('TEST 记住偏好');
    await entered.future;
    await store.memories.updateSettings(sendMemories: false);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    release.complete();
    await sending;
    expect(controller.messages.single.status, 'discarded');
    expect(controller.error, contains('授权已变化'));
    expect(await store.memories.list(), isEmpty);
  });

  test('switching sessions cancels, rename/delete are scoped, memories survive deletion', () async {
    service.onTurn = (request) async => syntheticReply(request, memory: true);
    await controller.send('TEST 第一个');
    final first = controller.session!.id;
    await controller.rename(first, 'TEST 命名');
    expect(controller.session!.title, 'TEST 命名');
    await controller.create();
    final second = controller.session!.id;
    expect(second, isNot(first));
    final entered = Completer<void>();
    final release = Completer<void>();
    service.onTurn = (request) async {
      entered.complete();
      await release.future;
      return syntheticReply(request);
    };
    final sending = controller.send('TEST 等待');
    await entered.future;
    await controller.select(first);
    release.complete();
    await sending;
    expect(controller.session!.id, first);
    expect((await store.messages(second)).single.status, 'discarded');
    await controller.delete(first);
    expect(controller.session!.id, second);
    expect(await store.memories.list(), hasLength(1));
  });

  test(
    'manual retry of a failed turn does not repeat the failed context',
    () async {
      service.onTurn = (_) async =>
          throw const AssistantFailure(AssistantFailureKind.network);
      await controller.send('TEST 未发送');
      final failed = controller.messages.single;
      expect(failed.status, 'failed');
      expect(controller.failures[failed.id], contains('网络连接失败'));
      service.onTurn = (request) async => syntheticReply(request);
      await controller.send(failed.content, retryMessageId: failed.id);
      expect(service.requests.last.messages, hasLength(1));
      expect(controller.messages, hasLength(3));
      expect(controller.busy, isFalse);
    },
  );

  test(
    'summary and memory operation state remain available after refresh',
    () async {
      for (var i = 0; i < 11; i++) {
        await controller.send('TEST $i');
      }
      expect(controller.session!.summary, 'TEST 历史约束摘要');
      expect(service.summaries, hasLength(1));
      service.onTurn = (request) async => syntheticReply(request, memory: true);
      await controller.send('TEST 偏好');
      final event = controller.events.values.expand((rows) => rows).single;
      await controller.undoMemory(event.id);
      expect(
        controller.events.values.expand((rows) => rows).single.reverted,
        isTrue,
      );
      expect(await store.memories.list(), isEmpty);
    },
  );
}
