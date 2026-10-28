import 'dart:convert';

import 'package:characters/characters.dart';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

import '../../../data/local/app_database.dart';
import '../../../data/local/local_goal_repository.dart';
import '../../../data/sync/identity_store.dart';
import '../../../data/sync/sync_identity.dart';
import '../../goals/domain/goal.dart';
import '../domain/plan_preview.dart';
import '../domain/agent_run_metadata.dart';
import 'assistant_service.dart';
import 'local_memory_store.dart';
import 'local_proposal_store.dart';

class PendingAssistantTurn {
  PendingAssistantTurn._({
    required this.identity,
    required this.settings,
    required this.sessionId,
    required this.messageId,
    required this.requestId,
  });

  final IdentityLease identity;
  final StoredAssistantSettings settings;
  final String sessionId;
  final String messageId;
  final String requestId;
  final cancellation = AssistantCancellation();
}

class ConversationInput {
  ConversationInput._(
    this.summary,
    this.summaryThrough,
    this.recent,
    this.older,
  );

  final String? summary;
  final String? summaryThrough;
  final List<StoredAssistantMessage> recent;
  final List<StoredAssistantMessage> older;
  bool get needsSummary => older.isNotEmpty;
  List<Map<String, String>> get messages => recent.map(_wireMessage).toList();
}

class PendingAssistantSummary {
  PendingAssistantSummary._(this.turn, this.request, this.before, this.through);

  final PendingAssistantTurn turn;
  final SummaryRequest request;
  final String? before;
  final String through;
}

class CommittedAssistantTurn {
  const CommittedAssistantTurn(this.message, this.events, this.proposalId);

  final StoredAssistantMessage message;
  final List<StoredMemoryEvent> events;
  final String? proposalId;
}

Map<String, String> _wireMessage(StoredAssistantMessage row) => {
  'role': row.role,
  'text': row.content,
};

class LocalConversationStore {
  LocalConversationStore(this.goals)
    : memories = LocalMemoryStore(goals),
      proposals = LocalProposalStore(goals);

  final LocalGoalRepository goals;
  final LocalMemoryStore memories;
  final LocalProposalStore proposals;
  AppDatabase get db => goals.db;
  String get owner => goals.owner;
  int get _now => goals.clock.read().instant.microsecondsSinceEpoch;

  Future<IdentityLease> _active() async {
    await goals.requireActiveIdentity();
    final lease = await IdentityStore(db).active();
    if (lease.identity.owner != owner) throw const StaleIdentity();
    return lease;
  }

  Future<StoredAssistantSession> _session(String id) async {
    final row =
        await (db.select(db.assistantSessions)
              ..where((row) => row.owner.equals(owner) & row.id.equals(id)))
            .getSingleOrNull();
    if (row == null) throw const GoalRuleException('找不到当前身份的会话。');
    return row;
  }

  Future<StoredAssistantSession> session(String id) => db.transaction(() async {
    await _active();
    return _session(id);
  });

  Future<List<StoredAssistantSession>> sessions() => db.transaction(() async {
    await _active();
    return (db.select(db.assistantSessions)
          ..where((row) => row.owner.equals(owner))
          ..orderBy([
            (row) => OrderingTerm.desc(row.updatedAt),
            (row) => OrderingTerm.asc(row.id),
          ]))
        .get();
  });

  Future<String> createSession() => db.transaction(() async {
    await _active();
    final id = const Uuid().v4();
    await db
        .into(db.assistantSessions)
        .insert(
          AssistantSessionsCompanion.insert(
            id: id,
            owner: owner,
            title: '新会话',
            createdAt: _now,
            updatedAt: _now,
          ),
        );
    return id;
  });

  Future<void> renameSession(String id, String title) =>
      db.transaction(() async {
        await _active();
        await _session(id);
        final value = title.trim();
        if (value.isEmpty || value.characters.length > 60) {
          throw const GoalRuleException('会话名称需要 1 至 60 字。');
        }
        await (db.update(db.assistantSessions)
              ..where((row) => row.owner.equals(owner) & row.id.equals(id)))
            .write(AssistantSessionsCompanion(title: Value(value)));
      });

  Future<List<StoredAssistantMessage>> _messages(String sessionId) =>
      (db.select(db.assistantMessages)
            ..where(
              (row) =>
                  row.owner.equals(owner) & row.sessionId.equals(sessionId),
            )
            ..orderBy([
              (row) => OrderingTerm.asc(row.createdAt),
              (row) => OrderingTerm.asc(row.id),
            ]))
          .get();

  Future<List<StoredAssistantMessage>> messages(String sessionId) =>
      db.transaction(() async {
        await _active();
        await _session(sessionId);
        return _messages(sessionId);
      });

  Future<List<StoredPlanProposal>> sessionProposals(String sessionId) =>
      db.transaction(() async {
        await _active();
        await _session(sessionId);
        return (db.select(db.planProposals)..where(
              (row) =>
                  row.owner.equals(owner) & row.sessionId.equals(sessionId),
            ))
            .get();
      });

  Future<void> deleteSession(String sessionId) => db.transaction(() async {
    await _active();
    await _session(sessionId);
    await (db.delete(db.planProposals)..where(
          (row) =>
              row.owner.equals(owner) &
              row.sessionId.equals(sessionId) &
              row.status.equals('draft'),
        ))
        .go();
    await (db.update(db.planProposals)..where(
          (row) => row.owner.equals(owner) & row.sessionId.equals(sessionId),
        ))
        .write(
          const PlanProposalsCompanion(
            sessionId: Value(null),
            messageId: Value(null),
          ),
        );
    await (db.delete(
      db.assistantSessions,
    )..where((row) => row.owner.equals(owner) & row.id.equals(sessionId))).go();
  });

  Future<PendingAssistantTurn> begin(
    String sessionId,
    String text, {
    String? retryMessageId,
  }) => db.transaction(() async {
    final identity = await _active();
    final settings = await memories.settings();
    if (settings.consentVersion != assistantConsentVersion ||
        settings.consentedAt == null) {
      throw const AssistantFailure(AssistantFailureKind.consent);
    }
    final session = await _session(sessionId);
    final history = await _messages(sessionId);
    if (history.any((row) => row.status == 'pending')) {
      throw const GoalRuleException('请等待本轮回复，或先取消等待。');
    }
    final value = text.trim();
    if (value.isEmpty || value.characters.length > 2000) {
      throw const GoalRuleException('消息需要 1 至 2,000 字。');
    }
    if (retryMessageId != null) {
      final original = history
          .where((row) => row.id == retryMessageId)
          .firstOrNull;
      if (original == null ||
          original.role != 'user' ||
          !{'failed', 'discarded'}.contains(original.status) ||
          original.content != value) {
        throw const GoalRuleException('这条消息不能重试。');
      }
    }
    final ticket = PendingAssistantTurn._(
      identity: identity,
      settings: settings,
      sessionId: sessionId,
      messageId: const Uuid().v4(),
      requestId: const Uuid().v4(),
    );
    final timestamp = _nextTimestamp(history);
    await db
        .into(db.assistantMessages)
        .insert(
          AssistantMessagesCompanion.insert(
            id: ticket.messageId,
            sessionId: sessionId,
            owner: owner,
            role: 'user',
            content: value,
            status: 'pending',
            requestId: Value(ticket.requestId),
            createdAt: timestamp,
          ),
        );
    await (db.update(db.assistantSessions)
          ..where((row) => row.owner.equals(owner) & row.id.equals(sessionId)))
        .write(
          AssistantSessionsCompanion(
            title: history.isEmpty && session.title == '新会话'
                ? Value(value.characters.take(30).toString())
                : const Value.absent(),
            updatedAt: Value(timestamp),
          ),
        );
    return ticket;
  });

  int _nextTimestamp(List<StoredAssistantMessage> history) {
    final now = _now;
    return history.isEmpty || history.last.createdAt < now
        ? now
        : history.last.createdAt + 1;
  }

  Future<void> _requireIdentity(PendingAssistantTurn turn) async {
    await _active();
    if (turn.identity.identity.owner != owner) throw const StaleIdentity();
    await IdentityStore(db).require(turn.identity);
  }

  Future<StoredAssistantMessage> _pending(PendingAssistantTurn turn) async {
    try {
      await _requireIdentity(turn);
    } on StaleIdentity {
      throw const AssistantFailure(AssistantFailureKind.discarded);
    }
    if (turn.cancellation.isCancelled) {
      throw const AssistantFailure(AssistantFailureKind.cancelled);
    }
    if (await memories.settings() != turn.settings) {
      throw const AssistantFailure(AssistantFailureKind.discarded);
    }
    final message =
        await (db.select(db.assistantMessages)..where(
              (row) =>
                  row.owner.equals(owner) &
                  row.sessionId.equals(turn.sessionId) &
                  row.id.equals(turn.messageId) &
                  row.requestId.equals(turn.requestId) &
                  row.role.equals('user') &
                  row.status.equals('pending'),
            ))
            .getSingleOrNull();
    if (message == null) {
      throw const AssistantFailure(AssistantFailureKind.discarded);
    }
    return message;
  }

  Future<bool> isCurrent(PendingAssistantTurn turn) => db.transaction(() async {
    try {
      await _pending(turn);
      return true;
    } on AssistantFailure {
      return false;
    }
  });

  AssistantAccess access(PendingAssistantTurn turn) => AssistantAccess(
    consentVersion: turn.settings.consentVersion,
    isCurrent: () => isCurrent(turn),
  );

  Future<ConversationInput> input(PendingAssistantTurn turn) =>
      db.transaction(() async {
        await _pending(turn);
        final session = await _session(turn.sessionId);
        final history = (await _messages(turn.sessionId))
            .where((row) => row.status == 'sent' || row.id == turn.messageId)
            .toList();
        final through = session.summaryThrough == null
            ? -1
            : history.indexWhere((row) => row.id == session.summaryThrough);
        if ((session.summary == null) != (session.summaryThrough == null) ||
            (session.summaryThrough != null && through < 0)) {
          throw const GoalRuleException('会话摘要记录不完整，请新开会话；原聊天仍保留。');
        }
        final remaining = history.skip(through + 1).toList();
        var characters = 0;
        var count = 0;
        for (final row in remaining.reversed) {
          final length = row.content.characters.length;
          if (count == 20 || characters + length > 12000) break;
          characters += length;
          count++;
        }
        final split = remaining.length - count;
        return ConversationInput._(
          session.summary,
          session.summaryThrough,
          List.unmodifiable(remaining.skip(split)),
          List.unmodifiable(remaining.take(split)),
        );
      });

  Future<PendingAssistantSummary?> nextSummary(PendingAssistantTurn turn) =>
      db.transaction(() async {
        final context = await input(turn);
        if (!context.needsSummary) return null;
        final requestId = const Uuid().v4();
        final messages = <Map<String, String>>[];
        SummaryRequest? request;
        String? through;
        for (final row in context.older) {
          // The full reply stays in SQLite; only summary transport is chunked.
          final chunks = row.content.characters;
          final added = <Map<String, String>>[
            for (var start = 0; start < chunks.length; start += 12000)
              {
                'role': row.role,
                'text': chunks.skip(start).take(12000).toString(),
              },
          ];
          try {
            final candidate = SummaryRequest.fromJson({
              'protocol': assistantProtocol,
              'request_id': requestId,
              'summary': context.summary,
              'messages': [...messages, ...added],
            });
            request = candidate;
            through = row.id;
            messages.addAll(added);
          } on FormatException {
            break;
          }
        }
        if (request == null || through == null) {
          throw const GoalRuleException('历史内容过大，无法生成摘要，请新开会话；原聊天仍保留。');
        }
        return PendingAssistantSummary._(
          turn,
          request,
          context.summaryThrough,
          through,
        );
      });

  Future<void> saveSummary(
    PendingAssistantSummary work,
    SummaryResponse response,
  ) => db.transaction(() async {
    await _pending(work.turn);
    final session = await _session(work.turn.sessionId);
    if (session.summaryThrough != work.before ||
        session.summary != work.request.summary) {
      throw const AssistantFailure(AssistantFailureKind.discarded);
    }
    final valid = SummaryResponse.fromJson(
      response.toJson(),
      requestId: work.request.requestId,
    );
    await (db.update(db.assistantSessions)..where(
          (row) => row.owner.equals(owner) & row.id.equals(work.turn.sessionId),
        ))
        .write(
          AssistantSessionsCompanion(
            summary: Value(valid.summary),
            summaryThrough: Value(work.through),
          ),
        );
    await _pending(work.turn);
  });

  /// Persist the exact credential-free body before handing it to the transport.
  Future<void> recordRequest(PendingAssistantTurn turn, TurnRequest request) =>
      db.transaction(() async {
        final pending = await _pending(turn);
        final context = await input(turn);
        final valid = TurnRequest.fromJson(request.toJson());
        if (context.needsSummary ||
            valid.requestId != turn.requestId ||
            valid.summary != context.summary ||
            jsonEncode(valid.messages.map((row) => row.toJson()).toList()) !=
                jsonEncode(context.messages) ||
            (!turn.settings.sendMemories && valid.memories != null) ||
            (!turn.settings.sendSchedule && valid.schedule != null) ||
            (!turn.settings.sendStats && valid.stats != null) ||
            valid.autoMemory != turn.settings.autoMemory ||
            pending.sentPayload != null) {
          throw const GoalRuleException('发送内容已变化或已发出，请重新发送。');
        }
        await (db.update(db.assistantMessages)..where(
              (row) => row.owner.equals(owner) & row.id.equals(turn.messageId),
            ))
            .write(
              AssistantMessagesCompanion(
                sentPayload: Value(jsonEncode(valid.toJson())),
              ),
            );
        await _pending(turn);
      });

  Future<String> agentInput(PendingAssistantTurn turn) => db.transaction(
    () async {
      final context = await input(turn);
      if (context.needsSummary) {
        // Agent summaries would be unmetered calls outside the six-call ledger.
        throw const AssistantFailure(AssistantFailureKind.summary);
      }
      return jsonEncode({
        'summary': context.summary,
        'messages': context.messages,
      });
    },
  );

  Future<void> recordAgentRequest(
    PendingAssistantTurn turn,
    AgentRequest request,
  ) => db.transaction(() async {
    final pending = await _pending(turn);
    final valid = AgentRequest.fromJson(request.toJson());
    if (valid.requestId != turn.requestId ||
        valid.messages.first['content'] != await agentInput(turn)) {
      throw const AssistantFailure(AssistantFailureKind.discarded);
    }
    if (pending.sentPayload != null) {
      final previous = AgentRequest.fromJson(
        decodeAssistantJson(pending.sentPayload!),
      );
      if (valid.turn != previous.turn + 1 ||
          agentCanonical(valid.now.toJson()) !=
              agentCanonical(previous.now.toJson()) ||
          (previous.runId != null && valid.runId != previous.runId) ||
          agentCanonical(
                valid.messages.take(previous.messages.length).toList(),
              ) !=
              agentCanonical(previous.messages)) {
        throw const FormatException('Invalid agent request history');
      }
    } else if (valid.turn != 1) {
      throw const FormatException('Missing initial request');
    }
    final encoded = jsonEncode(valid.toJson());
    if (utf8.encode(encoded).length >= agentBodyLimit) {
      throw const AssistantFailure(AssistantFailureKind.tooLarge);
    }
    await (db.update(db.assistantMessages)..where(
          (row) => row.owner.equals(owner) & row.id.equals(turn.messageId),
        ))
        .write(AssistantMessagesCompanion(sentPayload: Value(encoded)));
    await _pending(turn);
  });

  Future<CommittedAssistantTurn> commitAgentResponse(
    PendingAssistantTurn turn, {
    required String text,
    required AgentRunMetadata metadata,
    PlanPreview? preview,
  }) => db.transaction(() async {
    final pending = await _pending(turn);
    if (pending.sentPayload == null ||
        text.trim().isEmpty ||
        text.characters.length > 4000) {
      throw const FormatException('Invalid agent reply');
    }
    final request = AgentRequest.fromJson(
      decodeAssistantJson(pending.sentPayload!),
    );
    final validMetadata = AgentRunMetadata.decode(metadata.encode());
    if (request.now.date != metadata.date) {
      throw const FormatException('Invalid agent date');
    }
    final reply = StoredAssistantMessage(
      id: const Uuid().v4(),
      owner: owner,
      sessionId: turn.sessionId,
      role: 'assistant',
      content: text,
      status: 'sent',
      requestId: turn.requestId,
      agentMetadata: validMetadata.encode(),
      createdAt: _nextTimestamp(await _messages(turn.sessionId)),
    );
    await db.into(db.assistantMessages).insert(reply);
    final id = preview == null
        ? null
        : await proposals.saveDraft(
            sessionId: turn.sessionId,
            messageId: reply.id,
            preview: preview,
            requestDate: request.now.date,
            agentMetadata: validMetadata,
          );
    await _pending(turn);
    await (db.update(db.assistantMessages)..where(
          (row) => row.owner.equals(owner) & row.id.equals(turn.messageId),
        ))
        .write(const AssistantMessagesCompanion(status: Value('sent')));
    await (db.update(db.assistantSessions)..where(
          (row) => row.owner.equals(owner) & row.id.equals(turn.sessionId),
        ))
        .write(AssistantSessionsCompanion(updatedAt: Value(reply.createdAt)));
    await _requireIdentity(turn);
    if (turn.cancellation.isCancelled) {
      throw const AssistantFailure(AssistantFailureKind.cancelled);
    }
    return CommittedAssistantTurn(reply, const [], id);
  });

  Future<CommittedAssistantTurn> commitResponse(
    PendingAssistantTurn turn,
    TurnResponse response,
  ) => db.transaction(() async {
    final pending = await _pending(turn);
    if (pending.sentPayload == null) {
      throw const GoalRuleException('本轮尚未发送，不能保存回复。');
    }
    final request = TurnRequest.fromJson(
      decodeAssistantJson(pending.sentPayload!),
    );
    final valid = TurnResponse.fromJson(response.toJson(), request: request);
    final reply = StoredAssistantMessage(
      id: const Uuid().v4(),
      owner: owner,
      sessionId: turn.sessionId,
      role: 'assistant',
      content: valid.reply,
      status: 'sent',
      requestId: turn.requestId,
      createdAt: _nextTimestamp(await _messages(turn.sessionId)),
    );
    await db.into(db.assistantMessages).insert(reply);
    if (valid.diary case final diary?) {
      await db
          .into(db.assistantDiaryProposals)
          .insert(
            AssistantDiaryProposalsCompanion.insert(
              id: const Uuid().v4(),
              owner: owner,
              sessionId: turn.sessionId,
              messageId: reply.id,
              suggestedDay: Value(diary.date?.key),
              content: diary.content,
            ),
          );
    }
    final events = await memories.applyResponse(
      messageId: reply.id,
      request: request,
      response: valid,
    );
    final plan = valid.plan;
    final proposalId = plan == null
        ? null
        : await proposals.saveDraft(
            sessionId: turn.sessionId,
            messageId: reply.id,
            preview: PlanPreview.fromProposal(plan),
            requestDate: request.now.date,
          );
    await _pending(turn);
    await (db.update(db.assistantMessages)..where(
          (row) => row.owner.equals(owner) & row.id.equals(turn.messageId),
        ))
        .write(const AssistantMessagesCompanion(status: Value('sent')));
    await (db.update(db.assistantSessions)..where(
          (row) => row.owner.equals(owner) & row.id.equals(turn.sessionId),
        ))
        .write(AssistantSessionsCompanion(updatedAt: Value(reply.createdAt)));
    // Cancellation can happen while an awaited write is in flight.
    if (turn.cancellation.isCancelled) {
      throw const AssistantFailure(AssistantFailureKind.cancelled);
    }
    await _requireIdentity(turn);
    return CommittedAssistantTurn(reply, List.unmodifiable(events), proposalId);
  });

  Future<void> fail(PendingAssistantTurn turn, {bool discarded = false}) =>
      db.transaction(() async {
        try {
          await _requireIdentity(turn);
        } on StaleIdentity {
          return;
        }
        await (db.update(db.assistantMessages)..where(
              (row) =>
                  row.owner.equals(owner) &
                  row.sessionId.equals(turn.sessionId) &
                  row.id.equals(turn.messageId) &
                  row.requestId.equals(turn.requestId) &
                  row.status.equals('pending'),
            ))
            .write(
              AssistantMessagesCompanion(
                status: Value(discarded ? 'discarded' : 'failed'),
              ),
            );
      });

  Future<void> cancel(PendingAssistantTurn turn) async {
    turn.cancellation.cancel();
    await fail(turn, discarded: true);
  }

  /// Run once when opening this owner's conversation controller, never per send.
  Future<void> recoverInterrupted() => db.transaction(() async {
    await _active();
    await (db.update(db.assistantMessages)..where(
          (row) => row.owner.equals(owner) & row.status.equals('pending'),
        ))
        .write(const AssistantMessagesCompanion(status: Value('failed')));
  });
}
