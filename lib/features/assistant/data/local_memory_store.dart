import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

import '../../../data/local/app_database.dart';
import '../../../data/local/local_goal_repository.dart';
import '../../goals/domain/goal.dart';
import 'assistant_service.dart';

class MemoryDraft {
  const MemoryDraft({
    required this.category,
    required this.text,
    this.expiresOn,
    this.pinned = false,
  });
  final String category;
  final String text;
  final CalendarDate? expiresOn;
  final bool pinned;
}

class LocalMemoryStore {
  LocalMemoryStore(this.goals);
  final LocalGoalRepository goals;
  AppDatabase get db => goals.db;
  String get owner => goals.owner;
  int get _now => goals.clock.read().instant.microsecondsSinceEpoch;

  Future<StoredAssistantSettings> settings() => db.transaction(() async {
    await goals.requireActiveIdentity();
    return await (db.select(
          db.assistantSettings,
        )..where((row) => row.owner.equals(owner))).getSingleOrNull() ??
        StoredAssistantSettings(
          owner: owner,
          consentVersion: 0,
          sendMemories: true,
          sendSchedule: true,
          sendStats: true,
          autoMemory: true,
          agentEnabled: true,
        );
  });

  Future<void> consent() => db.transaction(() async {
    await goals.requireActiveIdentity();
    final current = await settings();
    await db
        .into(db.assistantSettings)
        .insertOnConflictUpdate(
          current.copyWith(
            consentVersion: assistantConsentVersion,
            consentedAt: Value(_now),
          ),
        );
  });

  Future<void> updateSettings({
    bool? sendMemories,
    bool? sendSchedule,
    bool? sendStats,
    bool? autoMemory,
    bool? agentEnabled,
  }) => db.transaction(() async {
    await goals.requireActiveIdentity();
    final current = await settings();
    await db
        .into(db.assistantSettings)
        .insertOnConflictUpdate(
          current.copyWith(
            sendMemories: sendMemories,
            sendSchedule: sendSchedule,
            sendStats: sendStats,
            autoMemory: autoMemory,
            agentEnabled: agentEnabled,
          ),
        );
  });

  Future<void> revokeConsent() => db.transaction(() async {
    await goals.requireActiveIdentity();
    await (db.update(
      db.assistantSettings,
    )..where((row) => row.owner.equals(owner))).write(
      const AssistantSettingsCompanion(
        consentVersion: Value(0),
        consentedAt: Value(null),
      ),
    );
  });

  Future<List<StoredAssistantMemory>> list() => db.transaction(() async {
    await goals.requireActiveIdentity();
    return (db.select(db.assistantMemories)
          ..where((row) => row.owner.equals(owner))
          ..orderBy([
            (row) => OrderingTerm.desc(row.pinned),
            (row) => OrderingTerm.desc(row.updatedAt),
            (row) => OrderingTerm.asc(row.id),
          ]))
        .get();
  });

  Future<List<AssistantMemory>?> forRequest() => db.transaction(() async {
    await goals.requireActiveIdentity();
    if (!(await settings()).sendMemories) return null;
    final today = goals.clock.read().day.key;
    return [
      for (final row in await list())
        if (row.expiresOn == null || row.expiresOn!.compareTo(today) >= 0)
          _wire(row),
    ];
  });

  AssistantMemory _wire(StoredAssistantMemory row) => AssistantMemory.fromJson({
    'id': row.id,
    'category': row.category,
    'text': row.content,
    'expires_on': row.expiresOn,
  });

  MemoryOperation _validate(MemoryDraft draft) => MemoryOperation.fromJson({
    'op': 'add',
    'id': null,
    'category': draft.category,
    'text': draft.text,
    'expires_on': draft.expiresOn?.key,
  }, {});

  Future<StoredAssistantMemory?> _find(String id) =>
      (db.select(db.assistantMemories)
            ..where((row) => row.id.equals(id) & row.owner.equals(owner)))
          .getSingleOrNull();

  Future<String> add(MemoryDraft draft) => db.transaction(() async {
    await goals.requireActiveIdentity();
    final valid = _validate(draft);
    if ((await list()).length >= 200) {
      throw const GoalRuleException('记忆已达 200 条，请先清理后再新增。');
    }
    final id = const Uuid().v4();
    await db
        .into(db.assistantMemories)
        .insert(
          AssistantMemoriesCompanion.insert(
            id: id,
            owner: owner,
            category: valid.category!,
            content: valid.text!,
            expiresOn: Value(valid.expiresOn?.key),
            pinned: Value(draft.pinned),
            createdAt: _now,
            updatedAt: _now,
          ),
        );
    return id;
  });

  Future<void> edit(String id, MemoryDraft draft) => db.transaction(() async {
    await goals.requireActiveIdentity();
    final valid = _validate(draft);
    final current = await _find(id);
    if (current == null) throw const GoalRuleException('找不到当前身份的记忆。');
    await (db.update(
      db.assistantMemories,
    )..where((row) => row.id.equals(id) & row.owner.equals(owner))).write(
      AssistantMemoriesCompanion(
        category: Value(valid.category!),
        content: Value(valid.text!),
        expiresOn: Value(valid.expiresOn?.key),
        pinned: Value(draft.pinned),
        updatedAt: Value(_now),
      ),
    );
  });

  Future<void> remove(String id) => db.transaction(() async {
    await goals.requireActiveIdentity();
    await (db.delete(
      db.assistantMemories,
    )..where((row) => row.id.equals(id) & row.owner.equals(owner))).go();
  });

  Future<void> clear() => db.transaction(() async {
    await goals.requireActiveIdentity();
    await (db.delete(
      db.assistantMemories,
    )..where((row) => row.owner.equals(owner))).go();
  });

  Future<List<StoredMemoryEvent>> events(String messageId) =>
      db.transaction(() async {
        await goals.requireActiveIdentity();
        return (db.select(db.memoryEvents)..where(
              (row) =>
                  row.owner.equals(owner) & row.messageId.equals(messageId),
            ))
            .get();
      });

  /// Call inside the transaction that persists the response and its proposal.
  /// An add with both snapshots null records a capacity skip, not a saved memory.
  Future<List<StoredMemoryEvent>> applyResponse({
    required String messageId,
    required TurnRequest request,
    required TurnResponse response,
  }) => db.transaction(() async {
    await goals.requireActiveIdentity();
    final currentSettings = await settings();
    if (currentSettings.consentVersion != assistantConsentVersion ||
        currentSettings.consentedAt == null) {
      throw const AssistantFailure(AssistantFailureKind.consent);
    }
    final message =
        await (db.select(db.assistantMessages)..where(
              (row) =>
                  row.id.equals(messageId) &
                  row.owner.equals(owner) &
                  row.role.equals('assistant') &
                  row.status.equals('sent') &
                  row.requestId.equals(request.requestId),
            ))
            .getSingleOrNull();
    if (message == null) throw const GoalRuleException('找不到本轮回复，未保存记忆。');
    // Re-check current opt-out in case it changed while the model was running.
    final effectiveRequest = !currentSettings.autoMemory && request.autoMemory
        ? TurnRequest.fromJson({
            ...request.toJson(),
            'settings': {'auto_memory': false},
          })
        : request;
    final validated = TurnResponse.fromJson(
      response.toJson(),
      request: effectiveRequest,
    );
    final ops = validated.memoryOps;
    final eventIds = [
      for (var i = 0; i < ops.length; i++)
        const Uuid().v5(
          Namespace.url.value,
          jsonEncode([owner, messageId, request.requestId, i, ops[i].toJson()]),
        ),
    ];
    final existing = await events(messageId);
    if (existing.isNotEmpty) {
      if (existing.length != eventIds.length ||
          existing.any((row) => !eventIds.contains(row.id))) {
        throw const GoalRuleException('这轮回复已处理，不能用不同记忆操作重放。');
      }
      return [
        for (final id in eventIds) existing.singleWhere((row) => row.id == id),
      ];
    }
    final result = <StoredMemoryEvent>[];
    for (var i = 0; i < ops.length; i++) {
      final op = ops[i];
      final before = op.id == null ? null : await _find(op.id!);
      if (op.op != 'add') {
        final sent = request.memories
            ?.where((row) => row.id == op.id)
            .firstOrNull;
        if (before == null ||
            sent == null ||
            jsonEncode(_wire(before).toJson()) != jsonEncode(sent.toJson())) {
          throw const GoalRuleException('记忆已发生变化，请重新发送后再修改，未覆盖本机内容。');
        }
      }
      final memoryId = before?.id ?? const Uuid().v4();
      StoredAssistantMemory? after;
      if (op.op == 'delete') {
        await remove(memoryId);
      } else if (op.op == 'update' || (await list()).length < 200) {
        after = StoredAssistantMemory(
          id: memoryId,
          owner: owner,
          category: op.category!,
          content: op.text!,
          sourceSessionId: message.sessionId,
          sourceMessageId: messageId,
          expiresOn: op.expiresOn?.key,
          pinned: before?.pinned ?? false,
          createdAt: before?.createdAt ?? _now,
          updatedAt: _now,
        );
        await db
            .into(db.assistantMemories)
            .insertOnConflictUpdate(after.toCompanion(false));
      }
      final event = StoredMemoryEvent(
        id: eventIds[i],
        owner: owner,
        messageId: messageId,
        op: op.op,
        memoryId: memoryId,
        beforeJson: before == null ? null : jsonEncode(before.toJson()),
        afterJson: after == null ? null : jsonEncode(after.toJson()),
        reverted: false,
      );
      await db.into(db.memoryEvents).insert(event);
      result.add(event);
    }
    await goals.requireActiveIdentity();
    return result;
  });

  Future<void> undo(String eventId) => db.transaction(() async {
    await goals.requireActiveIdentity();
    final event =
        await (db.select(
              db.memoryEvents,
            )..where((row) => row.id.equals(eventId) & row.owner.equals(owner)))
            .getSingleOrNull();
    if (event == null) throw const GoalRuleException('找不到当前身份的记忆操作。');
    if (event.reverted) return;
    final before = _decode(event.beforeJson);
    final after = _decode(event.afterJson);
    if ((before != null &&
            (before.owner != owner || before.id != event.memoryId)) ||
        (after != null &&
            (after.owner != owner || after.id != event.memoryId))) {
      throw const FormatException('记忆操作记录无效');
    }
    final current = await _find(event.memoryId);
    if (current != after) {
      throw const GoalRuleException('记忆已被再次修改，不能覆盖后续更改。');
    }
    if (before != null) {
      if (current == null && (await list()).length >= 200) {
        throw const GoalRuleException('记忆已达 200 条，请先清理再恢复。');
      }
      // Null provenance/expiry are values to restore, not absent columns.
      await db
          .into(db.assistantMemories)
          .insertOnConflictUpdate(before.toCompanion(false));
    } else if (after != null) {
      await remove(event.memoryId);
    }
    await (db.update(db.memoryEvents)
          ..where((row) => row.id.equals(eventId) & row.owner.equals(owner)))
        .write(const MemoryEventsCompanion(reverted: Value(true)));
  });

  StoredAssistantMemory? _decode(String? value) {
    if (value == null) return null;
    try {
      return StoredAssistantMemory.fromJson(
        jsonDecode(value) as Map<String, dynamic>,
      );
    } catch (_) {
      throw const FormatException('无法读取记忆操作记录');
    }
  }
}
