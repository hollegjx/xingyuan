import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/sync/identity_store.dart';
import 'package:habit_checkin/features/assistant/data/assistant_service.dart';
import 'package:habit_checkin/features/assistant/data/local_memory_store.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:xingyuan_core/xingyuan_core.dart';

import 'support/assistant_fixtures.dart';
import 'support/sync_fixtures.dart';
import 'support/test_clock.dart';

Map<String, Object?> addOp([String text = 'TEST 晚上有空']) => {
  'op': 'add',
  'id': null,
  'category': '作息',
  'text': text,
  'expires_on': null,
};
Map<String, Object?> deleteOp(String id) => {
  'op': 'delete',
  'id': id,
  'category': null,
  'text': null,
  'expires_on': null,
};

void main() {
  setUpAll(tzdata.initializeTimeZones);
  late AppDatabase db;
  late TestClock clock;
  late LocalGoalRepository goals;
  late LocalMemoryStore store;
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    clock = TestClock();
    goals = LocalGoalRepository(db, clock);
    store = LocalMemoryStore(goals);
  });
  tearDown(() => db.close());

  Future<TurnRequest> request({
    String text = 'TEST 今天下班后有空',
    bool auto = true,
    String id = 'request-1',
  }) async => TurnRequest.fromJson({
    'protocol': assistantProtocol,
    'request_id': id,
    'now': {
      'date': clock.day.key,
      'time': '12:00',
      'weekday': clock.day.weekday,
      'time_zone': 'Asia/Shanghai',
    },
    'summary': null,
    'messages': [
      {'role': 'user', 'text': text},
    ],
    'memories': [
      for (final memory in await store.forRequest() ?? <AssistantMemory>[])
        memory.toJson(),
    ],
    'settings': {'auto_memory': auto},
  });
  TurnResponse response(TurnRequest request, List<Map<String, Object?>> ops) =>
      TurnResponse.fromJson({
        'protocol': assistantProtocol,
        'request_id': request.requestId,
        'reply': 'TEST 已处理记忆',
        'plan': null,
        'memory_ops': ops,
      }, request: request);
  Future<void> prepare(TurnRequest request, {String id = 'test'}) async {
    await store.consent();
    await seedAssistantReply(db, id: id);
    await (db.update(db.assistantMessages)
          ..where((row) => row.id.equals('$id-message')))
        .write(AssistantMessagesCompanion(requestId: Value(request.requestId)));
  }

  Future<void> fill() async {
    await db.transaction(() async {
      for (var i = 0; i < 200; i++) {
        await store.add(MemoryDraft(category: '偏好', text: 'TEST memory $i'));
      }
    });
  }

  test('settings defaults do not create consent; toggles and consent stay owner-scoped', () async {
    final defaults = await store.settings();
    expect(defaults.consentVersion, 0);
    expect(defaults.consentedAt, isNull);
    expect(
      defaults.autoMemory &&
          defaults.sendMemories &&
          defaults.sendSchedule &&
          defaults.sendStats,
      isTrue,
    );
    expect(await db.select(db.assistantSettings).get(), isEmpty);
    await store.updateSettings(sendSchedule: false, autoMemory: false);
    expect((await store.settings()).consentVersion, 0);
    await store.consent();
    final saved = await store.settings();
    expect(saved.consentVersion, assistantConsentVersion);
    expect(saved.consentedAt, isNotNull);
    expect(saved.autoMemory || saved.sendSchedule, isFalse);
    final other = LocalMemoryStore(
      LocalGoalRepository(db, clock, owner: accountA.owner),
    );
    expect((await other.settings()).consentVersion, 0);
    expect((await other.settings()).autoMemory, isTrue);
    expect(await db.select(db.syncOutbox).get(), isEmpty);
  });

  test(
    'manual memory validates categories, grapheme length and sensitive content',
    () async {
      for (final draft in [
        const MemoryDraft(category: '不支持', text: 'TEST'),
        const MemoryDraft(category: '偏好', text: '  '),
        MemoryDraft(category: '偏好', text: List.filled(201, '好').join()),
        const MemoryDraft(category: '其他', text: 'TEST 密码不要记录'),
      ]) {
        await expectLater(store.add(draft), throwsFormatException);
      }
      final text = List.filled(200, '👨‍👩‍👧‍👦').join();
      final id = await store.add(MemoryDraft(category: '偏好', text: text));
      expect((await store.list()).single.content, text);
      await store.edit(
        id,
        const MemoryDraft(category: '其他', text: 'TEST revised', pinned: true),
      );
      expect((await store.list()).single.pinned, isTrue);
      await store.remove(id);
      expect(await store.list(), isEmpty);
    },
  );

  test('pin order and expiry affect sending but opt-out never deletes local memory', () async {
    await store.add(
      MemoryDraft(
        category: '近期约束',
        text: 'TEST expired',
        expiresOn: CalendarDate.parse(clock.day.addDays(-1).key),
        pinned: true,
      ),
    );
    final today = await store.add(
      MemoryDraft(
        category: '近期约束',
        text: 'TEST today',
        expiresOn: CalendarDate.parse(clock.day.key),
      ),
    );
    final pinned = await store.add(
      const MemoryDraft(category: '偏好', text: 'TEST pinned', pinned: true),
    );
    final sent = await store.forRequest();
    expect(sent!.map((row) => row.id), [pinned, today]);
    expect(await store.list(), hasLength(3));
    await store.updateSettings(sendMemories: false);
    expect(await store.forRequest(), isNull);
    expect(await store.list(), hasLength(3));
    await store.updateSettings(sendMemories: true);
    clock.setDay(2026, 10, 10);
    expect((await store.forRequest())!.map((row) => row.id), [pinned]);
  });

  test('automatic add has provenance and an idempotent individually undoable event', () async {
    final sent = await request();
    await prepare(sent);
    final answer = response(sent, [addOp()]);
    final events = await store.applyResponse(
      messageId: 'test-message',
      request: sent,
      response: answer,
    );
    final memory = (await store.list()).single;
    expect(memory.sourceSessionId, 'test-session');
    expect(memory.sourceMessageId, 'test-message');
    expect(events.single.beforeJson, isNull);
    expect(events.single.afterJson, isNotNull);
    expect(
      (await store.applyResponse(
        messageId: 'test-message',
        request: sent,
        response: answer,
      )).single.id,
      events.single.id,
    );
    expect(await store.list(), hasLength(1));
    await store.undo(events.single.id);
    await store.undo(events.single.id);
    expect(await store.list(), isEmpty);
    expect((await store.events('test-message')).single.reverted, isTrue);
    await store.applyResponse(
      messageId: 'test-message',
      request: sent,
      response: answer,
    );
    expect(await store.list(), isEmpty);
    await expectLater(
      store.applyResponse(
        messageId: 'test-message',
        request: sent,
        response: response(sent, [addOp('TEST changed replay')]),
      ),
      throwsA(isA<GoalRuleException>()),
    );
    expect(await db.select(db.assistantMessages).get(), hasLength(1));
    expect(await db.select(db.goals).get(), isEmpty);
    expect(await db.select(db.syncOutbox).get(), isEmpty);
  });

  test('updates and deletes undo to the exact original row including pin and timestamps', () async {
    final id = await store.add(
      const MemoryDraft(category: '偏好', text: 'TEST original', pinned: true),
    );
    final before = (await store.list()).single;
    final sent = await request();
    await prepare(sent);
    final updated = await store.applyResponse(
      messageId: 'test-message',
      request: sent,
      response: response(sent, [
        {...addOp('TEST updated'), 'op': 'update', 'id': id},
      ]),
    );
    expect((await store.list()).single.content, 'TEST updated');
    expect((await store.list()).single.pinned, isTrue);
    await store.undo(updated.single.id);
    expect((await store.list()).single, before);
    final next = await request(id: 'request-2');
    await prepare(next, id: 'delete');
    final deleted = await store.applyResponse(
      messageId: 'delete-message',
      request: next,
      response: response(next, [deleteOp(id)]),
    );
    expect(await store.list(), isEmpty);
    await store.undo(deleted.single.id);
    expect((await store.list()).single, before);
  });

  test(
    'an AI update can explicitly clear expiry and undo restores it',
    () async {
      final day = CalendarDate.parse(clock.day.key);
      final id = await store.add(
        MemoryDraft(category: '近期约束', text: 'TEST temporary', expiresOn: day),
      );
      final before = (await store.list()).single;
      final sent = await request();
      await prepare(sent);
      final events = await store.applyResponse(
        messageId: 'test-message',
        request: sent,
        response: response(sent, [
          {...addOp('TEST permanent'), 'op': 'update', 'id': id},
        ]),
      );
      expect((await store.list()).single.expiresOn, isNull);
      await store.undo(events.single.id);
      expect((await store.list()).single, before);
    },
  );

  test('concurrent manual adds cannot exceed the per-owner capacity', () async {
    await fill();
    final first = (await store.list()).first;
    await store.remove(first.id);
    final results = await Future.wait([
      for (var i = 0; i < 3; i++)
        store
            .add(MemoryDraft(category: '偏好', text: 'TEST race $i'))
            .then<bool>((_) => true, onError: (Object _) => false),
    ]);
    expect(results.where((success) => success), hasLength(1));
    expect(await store.list(), hasLength(200));
    final other = LocalMemoryStore(
      LocalGoalRepository(db, clock, owner: accountA.owner),
    );
    await other.add(
      const MemoryDraft(category: '偏好', text: 'TEST other owner'),
    );
    expect(await other.list(), hasLength(1));
  });

  test('automatic opt-out during flight rejects extraction but explicit remember still works', () async {
    final sent = await request();
    await prepare(sent);
    await store.updateSettings(autoMemory: false);
    await expectLater(
      store.applyResponse(
        messageId: 'test-message',
        request: sent,
        response: response(sent, [addOp()]),
      ),
      throwsFormatException,
    );
    expect(await store.list(), isEmpty);
    expect(await store.events('test-message'), isEmpty);
    final explicit = await request(
      text: '记住我下班后有空',
      auto: false,
      id: 'explicit-request',
    );
    await prepare(explicit, id: 'explicit');
    await store.applyResponse(
      messageId: 'explicit-message',
      request: explicit,
      response: response(explicit, [addOp()]),
    );
    expect(await store.list(), hasLength(1));
  });

  test(
    'unconsented application and uncorrelated messages write no memory',
    () async {
      final sent = await request();
      final answer = response(sent, [addOp()]);
      await expectLater(
        store.applyResponse(
          messageId: 'test-message',
          request: sent,
          response: answer,
        ),
        throwsA(isA<AssistantFailure>()),
      );
      await prepare(sent);
      final different = await request(id: 'other-request');
      await expectLater(
        store.applyResponse(
          messageId: 'test-message',
          request: different,
          response: response(different, [addOp()]),
        ),
        throwsA(isA<GoalRuleException>()),
      );
      expect(await store.list(), isEmpty);
    },
  );

  test('changed local memory during flight rolls back every operation in the response', () async {
    final id = await store.add(
      const MemoryDraft(category: '偏好', text: 'TEST original'),
    );
    final sent = await request();
    await prepare(sent);
    await store.edit(
      id,
      const MemoryDraft(category: '偏好', text: 'TEST manual change'),
    );
    await expectLater(
      store.applyResponse(
        messageId: 'test-message',
        request: sent,
        response: response(sent, [addOp(), deleteOp(id)]),
      ),
      throwsA(isA<GoalRuleException>()),
    );
    expect((await store.list()).single.content, 'TEST manual change');
    expect(await store.events('test-message'), isEmpty);
  });

  test('undo cannot overwrite a later manual edit', () async {
    final sent = await request();
    await prepare(sent);
    final events = await store.applyResponse(
      messageId: 'test-message',
      request: sent,
      response: response(sent, [addOp()]),
    );
    final memory = (await store.list()).single;
    await store.edit(
      memory.id,
      const MemoryDraft(category: '作息', text: 'TEST later manual'),
    );
    await expectLater(
      store.undo(events.single.id),
      throwsA(isA<GoalRuleException>()),
    );
    expect((await store.list()).single.content, 'TEST later manual');
    expect((await store.events('test-message')).single.reverted, isFalse);
  });

  test('capacity skips automatic additions durably and never evicts another memory', () async {
    await fill();
    await expectLater(
      store.add(const MemoryDraft(category: '偏好', text: 'TEST over limit')),
      throwsA(isA<GoalRuleException>()),
    );
    final sent = await request();
    await prepare(sent);
    final answer = response(sent, [addOp()]);
    final events = await store.applyResponse(
      messageId: 'test-message',
      request: sent,
      response: answer,
    );
    expect(events.single.beforeJson, isNull);
    expect(events.single.afterJson, isNull);
    expect(await store.list(), hasLength(200));
    await store.remove((await store.list()).first.id);
    await store.applyResponse(
      messageId: 'test-message',
      request: sent,
      response: answer,
    );
    expect(await store.list(), hasLength(199));
    await store.undo(events.single.id);
    expect(await store.list(), hasLength(199));
  });

  test('delete undo at capacity requires clearing space, without losing its receipt', () async {
    await fill();
    final sent = await request(text: '忘掉第一条记忆');
    await prepare(sent);
    final id = sent.memories!.first.id;
    final events = await store.applyResponse(
      messageId: 'test-message',
      request: sent,
      response: response(sent, [deleteOp(id)]),
    );
    final replacement = await store.add(
      const MemoryDraft(category: '偏好', text: 'TEST replacement'),
    );
    await expectLater(
      store.undo(events.single.id),
      throwsA(isA<GoalRuleException>()),
    );
    expect((await store.events('test-message')).single.reverted, isFalse);
    await store.remove(replacement);
    await store.undo(events.single.id);
    expect((await store.list()).any((row) => row.id == id), isTrue);
    expect(await store.list(), hasLength(200));
  });

  test(
    'foreign owners cannot read, change or undo another identity memory',
    () async {
      final sent = await request();
      await prepare(sent);
      final events = await store.applyResponse(
        messageId: 'test-message',
        request: sent,
        response: response(sent, [addOp()]),
      );
      final memory = (await store.list()).single;
      final other = LocalMemoryStore(
        LocalGoalRepository(db, clock, owner: accountA.owner),
      );
      expect(await other.list(), isEmpty);
      expect(await other.events('test-message'), isEmpty);
      await expectLater(
        other.edit(
          memory.id,
          const MemoryDraft(category: '偏好', text: 'TEST bad'),
        ),
        throwsA(isA<GoalRuleException>()),
      );
      await expectLater(
        other.undo(events.single.id),
        throwsA(isA<GoalRuleException>()),
      );
      await other.remove(memory.id);
      expect(await store.list(), hasLength(1));
    },
  );

  test(
    'stale identity rejects reads, settings and memory writes before applying',
    () async {
      final lease = await IdentityStore(db).active();
      final stale = LocalMemoryStore(
        LocalGoalRepository(db, clock, identityLease: lease),
      );
      await IdentityStore(db).begin(accountA);
      await expectLater(stale.list(), throwsA(isA<StaleIdentity>()));
      await expectLater(stale.settings(), throwsA(isA<StaleIdentity>()));
      await expectLater(stale.consent(), throwsA(isA<StaleIdentity>()));
      await expectLater(
        stale.add(const MemoryDraft(category: '偏好', text: 'TEST')),
        throwsA(isA<StaleIdentity>()),
      );
      expect(await db.select(db.assistantMemories).get(), isEmpty);
    },
  );

  test('memory, settings and undo survive file reopening; source deletion retains memory', () async {
    await db.close();
    final directory = await Directory.systemTemp.createTemp('memory-reopen-');
    final file = File('${directory.path}/local.sqlite');
    var local = AppDatabase(NativeDatabase(file));
    try {
      store = LocalMemoryStore(LocalGoalRepository(local, clock));
      final sent = await request();
      await store.consent();
      await seedAssistantReply(local);
      await (local.update(local.assistantMessages)
            ..where((row) => row.id.equals('test-message')))
          .write(AssistantMessagesCompanion(requestId: Value(sent.requestId)));
      final events = await store.applyResponse(
        messageId: 'test-message',
        request: sent,
        response: response(sent, [addOp()]),
      );
      final memory = (await store.list()).single;
      await local.close();
      local = AppDatabase(NativeDatabase(file));
      store = LocalMemoryStore(LocalGoalRepository(local, clock));
      expect((await store.settings()).consentVersion, assistantConsentVersion);
      expect((await store.list()).single, memory);
      await store.undo(events.single.id);
      expect(await store.list(), isEmpty);
      final next = await request(id: 'request-2');
      await seedAssistantReply(local, id: 'retained');
      await (local.update(local.assistantMessages)
            ..where((row) => row.id.equals('retained-message')))
          .write(AssistantMessagesCompanion(requestId: Value(next.requestId)));
      await store.applyResponse(
        messageId: 'retained-message',
        request: next,
        response: response(next, [addOp('TEST retained')]),
      );
      await local.delete(local.assistantSessions).go();
      expect(await store.list(), hasLength(1));
      expect((await store.list()).single.sourceSessionId, 'retained-session');
      expect(await local.select(local.memoryEvents).get(), isEmpty);
      expect(await local.select(local.syncOutbox).get(), isEmpty);
    } finally {
      await local.close();
      await directory.delete(recursive: true);
    }
  });
}
