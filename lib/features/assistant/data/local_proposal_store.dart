import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

import '../../../data/local/app_database.dart';
import '../../../data/local/local_goal_repository.dart';
import '../../../shared/local_date.dart';
import '../../goals/domain/goal.dart';
import '../../reminders/reminder_payload.dart';
import '../domain/plan_preview.dart';
import '../domain/agent_run_metadata.dart';
import '../domain/agent_planning.dart';
import 'local_agent_source.dart';
import 'local_memory_store.dart';
import 'assistant_service.dart';

enum UndoDisposition {
  deleted,
  keptHistory,
  keptRecord,
  archivedSynced,
  alreadyMissing,
}

class ProposalUndoItem {
  const ProposalUndoItem(this.goalId, this.title, this.disposition);
  final int goalId;
  final String title;
  final UndoDisposition disposition;

  Map<String, Object?> toJson() => {
    'goal_id': goalId,
    'title': title,
    'disposition': disposition.name,
  };
}

class ProposalUndoResult {
  ProposalUndoResult(Iterable<ProposalUndoItem> items)
    : items = List.unmodifiable(items);
  final List<ProposalUndoItem> items;

  String encode() => jsonEncode(items.map((item) => item.toJson()).toList());
  factory ProposalUndoResult.decode(String value) {
    try {
      return ProposalUndoResult(
        (jsonDecode(value) as List).map(
          (row) => ProposalUndoItem(
            row['goal_id'] as int,
            row['title'] as String,
            UndoDisposition.values.byName(row['disposition'] as String),
          ),
        ),
      );
    } catch (_) {
      throw const FormatException('无法读取撤销回执');
    }
  }
}

class AgentConfirmationCheck {
  const AgentConfirmationCheck(this.validation, this.token);
  final AgentPlanValidation validation;
  final String token;
}

class AgentPlanChanged extends GoalRuleException {
  const AgentPlanChanged() : super('安排有变化，未创建任何内容。');
}

class LocalProposalStore {
  LocalProposalStore(this.goals);
  final LocalGoalRepository goals;
  AppDatabase get db => goals.db;

  Future<StoredPlanProposal> _find(String id) async {
    final row =
        await (db.select(db.planProposals)..where(
              (row) => row.id.equals(id) & row.owner.equals(goals.owner),
            ))
            .getSingleOrNull();
    if (row == null) throw const GoalRuleException('找不到当前身份的计划。');
    return row;
  }

  Future<StoredPlanProposal> read(String id) => db.transaction(() async {
    await goals.requireActiveIdentity();
    return _find(id);
  });

  Future<String> saveDraft({
    required String sessionId,
    required String messageId,
    required PlanPreview preview,
    CalendarDate? requestDate,
    AgentRunMetadata? agentMetadata,
  }) => db.transaction(() async {
    await goals.requireActiveIdentity();
    final message =
        await (db.select(db.assistantMessages)..where(
              (row) =>
                  row.id.equals(messageId) &
                  row.sessionId.equals(sessionId) &
                  row.owner.equals(goals.owner) &
                  row.role.equals('assistant') &
                  row.status.equals('sent'),
            ))
            .getSingleOrNull();
    if (message == null) throw const GoalRuleException('找不到计划来源回复。');
    final date = requestDate ?? CalendarDate.parse(goals.clock.read().day.key);
    if (agentMetadata != null) {
      preview.validateAgentForConfirmation(date);
    } else {
      preview.validateForConfirmation(date);
    }
    final id = const Uuid().v4();
    await db
        .into(db.planProposals)
        .insert(
          PlanProposalsCompanion.insert(
            id: id,
            owner: goals.owner,
            sessionId: Value(sessionId),
            messageId: Value(messageId),
            itemsJson: preview.encode(),
            agentMetadata: Value(agentMetadata?.encode()),
          ),
        );
    return id;
  });

  Future<List<int>> apply(
    String id,
    PlanPreview preview, {
    bool partialAcknowledged = false,
    String? expectedAgentValidation,
  }) => db.transaction(() async {
    await goals.requireActiveIdentity();
    final row = await _find(id);
    final encoded = preview.encode();
    if (row.status == 'undone') {
      throw const GoalRuleException('这份计划已撤销，不能再次创建。');
    }
    if (row.status == 'applied') {
      if (row.appliedItemsJson != encoded) {
        throw const GoalRuleException('这份计划已创建，不能用不同内容重复确认。');
      }
      return List<int>.unmodifiable(_ids(row));
    }
    if (row.agentMetadata != null && row.itemsJson != encoded) {
      throw const AgentPlanChanged();
    }
    final original = PlanPreview.decode(row.itemsJson);
    for (final item in preview.items) {
      if (!original.items.any(
        (old) => old.id == item.id && old.task.isHabit == item.task.isHabit,
      )) {
        throw const GoalRuleException('计划条目不属于原提议。');
      }
    }
    if (row.agentMetadata != null) {
      final check = await inspectAgent(id, preview);
      if (check == null ||
          check.validation.hasErrors ||
          expectedAgentValidation != check.token) {
        throw const AgentPlanChanged();
      }
      if (check.validation.partialIndexes.isNotEmpty && !partialAcknowledged) {
        throw const GoalRuleException('请先确认已了解无法判断的项。未创建任何内容。');
      }
    } else {
      preview.validateForConfirmation(
        CalendarDate.parse(goals.clock.read().day.key),
      );
    }
    final ids = <int>[];
    for (final item in preview.items) {
      final task = item.task;
      ids.add(
        await goals.create(
          GoalDraft(
            title: task.title,
            kind: task.isHabit ? GoalKind.habit : GoalKind.single,
            weekdays:
                task.weekdays?.fold<int>(
                  0,
                  (mask, day) => mask | (1 << (day - 1)),
                ) ??
                0,
            plannedDay: task.isHabit ? null : LocalDate.parse(task.date.key),
            startMinute: item.timing.startMinute,
            durationMinutes: item.timing.durationMinutes,
            reminderEnabled: item.reminder,
            reminderMinute: item.timing.startMinute ?? 1200,
          ),
        ),
      );
    }
    await goals.requireActiveIdentity();
    if (row.agentMetadata != null) {
      final dates = validateAgentPlan(
        items: preview.agentItems,
        schedule: const [],
        today: CalendarDate.parse(goals.clock.read().day.key),
      );
      if (dates.hasErrors) throw const AgentPlanChanged();
      await _requireAgentConsent();
    } else {
      preview.validateForConfirmation(
        CalendarDate.parse(goals.clock.read().day.key),
      );
    }
    await (db.update(db.planProposals)..where(
          (entry) => entry.id.equals(id) & entry.owner.equals(goals.owner),
        ))
        .write(
          PlanProposalsCompanion(
            status: const Value('applied'),
            appliedItemsJson: Value(encoded),
            appliedGoalIdsJson: Value(jsonEncode(ids)),
            appliedAt: Value(goals.clock.read().instant.microsecondsSinceEpoch),
          ),
        );
    return List<int>.unmodifiable(ids);
  });

  Future<void> _requireAgentConsent() async {
    final settings = await LocalMemoryStore(goals).settings();
    if (settings.consentVersion != assistantConsentVersion ||
        settings.consentedAt == null ||
        !settings.sendSchedule) {
      throw const GoalRuleException('授权已变化，未创建任何内容。请检查 AI 设置。');
    }
  }

  Future<AgentConfirmationCheck?> inspectAgent(
    String id,
    PlanPreview preview,
  ) => db.transaction(() async {
    await goals.requireActiveIdentity();
    final row = await _find(id);
    if (row.agentMetadata == null) return null;
    await _requireAgentConsent();
    final metadata = AgentRunMetadata.decode(row.agentMetadata!);
    final today = CalendarDate.parse(goals.clock.read().day.key);
    final dates = preview.items.map((item) => item.task.date.key).toList()
      ..sort();
    if (dates.isEmpty) throw const FormatException('Empty plan');
    final first = CalendarDate.parse(dates.first);
    final last = CalendarDate.parse(dates.last);
    final from = first.isBefore(today) ? today : first;
    final end = today.addDays(14);
    final to = last.isAfter(end) ? end : last;
    final schedule = from.isAfter(to)
        ? <AgentScheduleItem>[]
        : await loadAgentSchedule(goals, from, to);
    await _requireAgentConsent();
    final validation = validateAgentPlan(
      items: preview.agentItems,
      schedule: schedule,
      today: today,
      dailyCaps: metadata.dailyCaps,
    );
    // Bind acknowledgement to the actual unknown records, not only the
    // affected item indexes. This digest stays local and is never logged.
    final token = sha256
        .convert(
          utf8.encode(
            agentCanonical({
              'preview': preview.encode(),
              'validation': validation.toJson(),
              'unknown_schedule': [
                for (final row in schedule)
                  if (row.incomplete && dates.contains(row.date.key))
                    row.toJson(),
              ],
            }),
          ),
        )
        .toString();
    return AgentConfirmationCheck(validation, token);
  });

  Future<void> editDraft(String id, PlanPreview preview) => db.transaction(
    () async {
      await goals.requireActiveIdentity();
      final row = await _find(id);
      if (row.status != 'draft') throw const GoalRuleException('已处理的计划不能再编辑。');
      final original = PlanPreview.decode(row.itemsJson);
      for (final item in preview.items) {
        if (!original.items.any(
          (old) => old.id == item.id && old.task.isHabit == item.task.isHabit,
        )) {
          throw const GoalRuleException('计划条目不属于原提议。');
        }
      }
      await (db.update(db.planProposals)
            ..where((row) => row.id.equals(id) & row.owner.equals(goals.owner)))
          .write(PlanProposalsCompanion(itemsJson: Value(preview.encode())));
      await goals.requireActiveIdentity();
    },
  );

  Future<ProposalUndoResult> previewUndo(String id) => db.transaction(() async {
    await goals.requireActiveIdentity();
    final row = await _find(id);
    return row.status == 'undone'
        ? ProposalUndoResult.decode(row.undoResultJson!)
        : _undoPlan(row);
  });

  Future<ProposalUndoResult> undo(String id) => db.transaction(() async {
    await goals.requireActiveIdentity();
    final row = await _find(id);
    if (row.status == 'undone') {
      return ProposalUndoResult.decode(row.undoResultJson!);
    }
    final result = await _undoPlan(row);
    for (final item in result.items) {
      if (item.disposition == UndoDisposition.deleted) {
        await _deleteUnrecorded(item.goalId);
      } else if (item.disposition == UndoDisposition.archivedSynced) {
        await goals.archive(item.goalId);
      }
    }
    await goals.requireActiveIdentity();
    await (db.update(db.planProposals)..where(
          (entry) => entry.id.equals(id) & entry.owner.equals(goals.owner),
        ))
        .write(
          PlanProposalsCompanion(
            status: const Value('undone'),
            undoResultJson: Value(result.encode()),
            undoneAt: Value(goals.clock.read().instant.microsecondsSinceEpoch),
          ),
        );
    return result;
  });

  List<int> _ids(StoredPlanProposal row) {
    if (row.status == 'draft') throw const GoalRuleException('这份计划尚未创建。');
    final ids = List<int>.from(jsonDecode(row.appliedGoalIdsJson!) as List);
    if (ids.toSet().length != ids.length || ids.any((id) => id < 1)) {
      throw const FormatException('计划回执无效');
    }
    return ids;
  }

  Future<ProposalUndoResult> _undoPlan(StoredPlanProposal row) async {
    final ids = _ids(row);
    final created = PlanPreview.decode(row.appliedItemsJson!).items;
    if (created.length != ids.length) throw const FormatException('计划回执无效');
    final current = {for (final goal in await goals.loadGoals()) goal.id: goal};
    final result = <ProposalUndoItem>[];
    for (var i = 0; i < ids.length; i++) {
      final id = ids[i];
      final goal = current[id];
      if (goal == null) {
        // A foreign goal is never treated as a missing owned one.
        if (await (db.select(
              db.goals,
            )..where((row) => row.id.equals(id))).getSingleOrNull() !=
            null) {
          throw const GoalRuleException('计划回执中的目标不属于当前身份。');
        }
        result.add(
          ProposalUndoItem(
            id,
            created[i].task.title,
            UndoDisposition.alreadyMissing,
          ),
        );
        continue;
      }
      final history =
          await (db.select(db.checkIns)
                ..where((row) => row.goalId.equals(id))
                ..limit(1))
              .get();
      if (history.isNotEmpty) {
        result.add(
          ProposalUndoItem(
            id,
            goal.titleOn(goals.clock.read().day),
            UndoDisposition.keptHistory,
          ),
        );
        continue;
      }
      final records =
          await (db.select(db.dayRecords)
                ..where(
                  (row) =>
                      row.goalId.equals(id) & row.owner.equals(goals.owner),
                )
                ..limit(1))
              .get();
      if (records.isNotEmpty) {
        result.add(
          ProposalUndoItem(
            id,
            goal.titleOn(goals.clock.read().day),
            UndoDisposition.keptRecord,
          ),
        );
        continue;
      }
      final state = await (db.select(
        db.syncStates,
      )..where((row) => row.goalId.equals(id))).getSingleOrNull();
      final operations = await (db.select(
        db.syncOutbox,
      )..where((row) => row.goalId.equals(id))).get();
      final conflicts =
          await (db.select(db.syncConflicts)
                ..where((row) => row.goalId.equals(id))
                ..limit(1))
              .get();
      final possiblyUploaded =
          (state != null &&
              (state.serverRevision > 0 ||
                  state.confirmedJson != null ||
                  state.lastSyncedAt != null)) ||
          operations.any(
            (row) =>
                row.attempts > 0 ||
                row.baseRevision != null ||
                row.state != 'pending',
          ) ||
          conflicts.isNotEmpty;
      result.add(
        ProposalUndoItem(
          id,
          goal.titleOn(goals.clock.read().day),
          possiblyUploaded
              ? UndoDisposition.archivedSynced
              : UndoDisposition.deleted,
        ),
      );
    }
    return ProposalUndoResult(result);
  }

  Future<void> _deleteUnrecorded(int id) async {
    final reminders =
        await (db.select(db.reminderOccurrences)..where(
              (row) => row.goalId.equals(id) & row.owner.equals(goals.owner),
            ))
            .get();
    for (final row in reminders) {
      await db
          .into(db.reminderCancellations)
          .insert(
            ReminderCancellationsCompanion.insert(
              notificationId: Value(row.id),
              owner: goals.owner,
              payload: reminderPayload(row),
            ),
          );
    }
    await (db.delete(db.syncConflicts)..where(
          (row) => row.goalId.equals(id) & row.owner.equals(goals.owner),
        ))
        .go();
    await (db.delete(db.syncOutbox)..where(
          (row) => row.goalId.equals(id) & row.owner.equals(goals.owner),
        ))
        .go();
    await (db.delete(
      db.syncStates,
    )..where((row) => row.goalId.equals(id))).go();
    await (db.delete(
      db.reminderOccurrences,
    )..where((row) => row.goalId.equals(id))).go();
    await (db.delete(
      db.goalReminders,
    )..where((row) => row.goalId.equals(id))).go();
    await (db.delete(
      db.goalSchedules,
    )..where((row) => row.goalId.equals(id))).go();
    await (db.delete(
      db.goalTitles,
    )..where((row) => row.goalId.equals(id))).go();
    await (db.delete(
      db.goals,
    )..where((row) => row.id.equals(id) & row.owner.equals(goals.owner))).go();
  }
}
