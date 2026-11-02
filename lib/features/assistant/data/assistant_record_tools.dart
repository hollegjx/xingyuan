import 'dart:convert';

import 'package:characters/characters.dart';
import 'package:drift/drift.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

import '../../../shared/local_date.dart';
import '../../goals/domain/goal.dart';
import 'agent_tool_executor.dart';
import 'assistant_service.dart';
import 'local_conversation_store.dart';

/// An explicit entry can supply this scope; it is never inferred from keywords.
class AssistantRecordScope {
  AssistantRecordScope(this.day, Set<String> kinds)
    : kinds = Set.unmodifiable(kinds);
  final CalendarDate day;
  final Set<String> kinds;
}

typedef ConfirmAssistantRead = Future<bool> Function(
  CalendarDate day,
  Set<String> kinds,
);

/// One instance per pending turn. It cannot be reused by another run/identity.
class AssistantRecordTools {
  AssistantRecordTools(
    this.store,
    this.turn,
    this.today, {
    this.confirm,
    this.scope,
  });
  final LocalConversationStore store;
  final PendingAssistantTurn turn;
  final CalendarDate today;
  final ConfirmAssistantRead? confirm;
  final AssistantRecordScope? scope;
  CalendarDate? _requestedDay;
  String? _denialReason;
  final Map<String, bool> _decisions = {};
  final Map<String, Map<String, dynamic>> _cache = {};
  final Map<String, int> _counts = {};
  final List<Map<String, dynamic>> receipts = [];
  Map<String, dynamic>? diaryDraft;

  Future<void> check() async {
    if (turn.cancellation.isCancelled ||
        !await store.isCurrent(turn) ||
        CalendarDate.parse(store.goals.clock.read().day.key) != today) {
      throw const AgentToolStop('authorization_changed');
    }
  }

  Future<bool> _authorize(AgentToolCall call) async {
    await check();
    final day = assistantRecordDay(call.arguments['day'], today);
    if (store.isContinuous(turn.sessionId)) {
      if (day.isBefore(today.addDays(-6))) {
        _denialReason = 'scope';
        return false;
      }
      if (call.name == 'create_diary_draft') return true;
      if (!turn.settings.readJournalOnRequest) {
        _denialReason = 'disabled';
        return false;
      }
      return true;
    }
    // C77: automatic authorization covers one whole day; entry scope stays fixed.
    if (scope != null && day != scope!.day) {
      _denialReason = 'scope';
      return false;
    }
    if (call.name == 'create_diary_draft') {
      if (_requestedDay != null && day != _requestedDay) {
        _denialReason = 'scope';
        return false;
      }
      _requestedDay ??= day;
      return true;
    }
    final kinds = call.name == 'get_day_summary'
        ? <String>{'summary'}
        : (call.arguments['kinds'] as List).cast<String>().toSet();
    if (scope != null && !scope!.kinds.containsAll(kinds)) {
      _denialReason = 'scope';
      return false;
    }
    final expanding =
        scope == null && _requestedDay != null && day != _requestedDay;
    if (!turn.settings.readJournalOnRequest) {
      _denialReason = 'disabled';
      return false;
    }
    if (call.name == 'get_day_summary' &&
        (!turn.settings.sendSchedule || !turn.settings.sendStats)) {
      _denialReason = 'context_disabled';
      return false;
    }
    final key = day.key;
    // Returning to an earlier accepted day is still a date change. A denial
    // stays denied for the run, so later tools cannot nag for the same date.
    if (expanding && _decisions[key] == true) _decisions.remove(key);
    if (!_decisions.containsKey(key)) {
      _decisions[key] =
          scope != null ||
          (!expanding && day == today) ||
          (await confirm?.call(day, {'summary', 'quickNote', 'diary'}) ??
              false);
    }
    await check();
    if (!_decisions[key]!) {
      _denialReason = confirm == null ? 'scope' : 'denied';
      return false;
    }
    _requestedDay = day;
    return true;
  }

  Future<Map<String, dynamic>> execute(AgentToolCall incoming) async {
    final call = AssistantAgentCall.parse(incoming.toJson(), today);
    _denialReason = null;
    final allowed = await _authorize(call);
    final count = _counts.update(
      call.signature,
      (n) => n + 1,
      ifAbsent: () => 1,
    );
    if (count > 2) throw const AgentToolStop('repeated_tool_call');
    Map<String, dynamic> result;
    if (!allowed) {
      result = {'status': 'not_authorized', 'data': null};
    } else if (count == 2) {
      result =
          _cache[call.signature] ??
          (throw const AgentToolStop('missing_tool_result'));
    } else {
      try {
        result = await _perform(call);
      } on AssistantFailure {
        rethrow;
      } on AgentToolStop {
        rethrow;
      } catch (_) {
        result = {'status': 'failed', 'data': null};
      }
    }
    await check();
    validateAssistantAgentResult(
      result,
      call.name,
      today,
      allowDuplicate: false,
    );
    if (count == 1) _cache[call.signature] = result;
    final data = result['data'] as Map?;
    if (call.name != 'create_diary_draft') {
      receipts.add({
        'day': call.arguments['day'],
        'kinds': call.name == 'get_day_summary'
            ? ['summary']
            : call.arguments['kinds'],
        'count': (data?['items'] as List?)?.length ?? 0,
        'status': result['status'],
        'cached': count == 2,
        'reason': _denialReason,
        'counts': {
          for (final kind
              in call.name == 'get_day_summary'
                  ? ['summary']
                  : call.arguments['kinds'] as List)
            kind as String: kind == 'summary'
                ? (data?['items'] as List?)?.length ?? 0
                : ((data?['items'] as List?) ?? [])
                      .where((row) => row['kind'] == kind)
                      .length,
        },
      });
    }
    return count == 1
        ? result
        : {
            'status': 'duplicate',
            'original_status': result['status'],
            'result': result,
          };
  }

  Future<Map<String, dynamic>> _perform(AgentToolCall call) async {
    if (call.name == 'create_diary_draft') {
      diaryDraft = Map.unmodifiable(call.arguments);
      return {
        'status': 'ok',
        'data': {'day': call.arguments['day'], 'pending_confirmation': true},
      };
    }
    return store.db.transaction(() async {
      await check();
      final day = call.arguments['day'] as String;
      final journal = call.name == 'get_journal_text';
      final kinds = journal
          ? (call.arguments['kinds'] as List).cast<String>()
          : const <String>[];
      final rows = <Map<String, dynamic>>[];
      if (journal) {
        // Select only saved text. Drafts/photos/locations never enter this query.
        for (final kind in kinds) {
          final table = kind == 'quickNote' ? 'quick_notes' : 'diary_entries';
          final records = await store.db
              .customSelect(
                'SELECT content FROM $table WHERE owner = ? AND day = ? AND saved_at IS NOT NULL AND deleted_at IS NULL ORDER BY created_at, id LIMIT 21',
                variables: [
                  Variable.withString(store.owner),
                  Variable.withString(day),
                ],
              )
              .get();
          rows.addAll(
            records.map(
              (r) => {'kind': kind, 'text': r.read<String>('content')},
            ),
          );
        }
      } else {
        final localDay = LocalDate.parse(day);
        final goals = await store.goals.loadGoals();
        final records = await store.db
            .customSelect(
              'SELECT goal_id, content FROM day_records WHERE owner = ? AND day = ? AND saved_at IS NOT NULL AND deleted_at IS NULL',
              variables: [
                Variable.withString(store.owner),
                Variable.withString(day),
              ],
            )
            .get();
        final texts = {
          for (final r in records)
            r.read<int>('goal_id'): r.read<String>('content'),
        };
        final overview = TodayOverview(goals, localDay);
        final currentDay = store.goals.clock.read().day;
        final ids = {
          // Today hides archived and subsequently completed single tasks. A
          // historical day must retain arrangements that still existed then.
          if (localDay.isBefore(currentDay))
            ...goals
                .where(
                  (goal) =>
                      goal.dayView(localDay, today: currentDay).status ==
                      GoalDayStatus.notRecorded,
                )
                .map((goal) => goal.id)
          else
            ...overview.pending.map((v) => v.goal.id),
          ...overview.completed.map((v) => v.goal.id),
          ...texts.keys,
        };
        final included = goals.where((g) => ids.contains(g.id)).toList()
          ..sort((a, b) => a.id.compareTo(b.id));
        for (final goal in included) {
          final view = goal.dayView(
            localDay,
            today: store.goals.clock.read().day,
          );
          rows.add({
            'title': view.title,
            'planned_time': view.schedule.startMinute == null
                ? null
                : formatMinute(view.schedule.startMinute!),
            'planned_minutes': view.schedule.durationMinutes,
            'completed': view.status == GoalDayStatus.completed,
            'completed_at': view.completion?.instant.toUtc().toIso8601String(),
            'text': texts[goal.id] ?? '',
          });
        }
      }
      await check();
      return boundedAssistantRecords(
        day: day,
        kinds: journal ? kinds : null,
        rows: rows,
      );
    });
  }
}

/// Reserve room for a possible duplicate wrapper within the same 12000 byte cap.
Map<String, dynamic> boundedAssistantRecords({
  required String day,
  List<String>? kinds,
  required List<Map<String, dynamic>> rows,
}) {
  final limit = kinds == null ? 60 : 20;
  final charactersLimit = kinds == null ? 1000 : 2000;
  var truncated = rows.length > limit;
  final items = <Map<String, dynamic>>[];
  final result = <String, dynamic>{
    'status': 'ok',
    'data': {'day': day, 'kinds': ?kinds, 'items': items},
  };
  for (final row in rows.take(limit)) {
    final text = row['text'] as String;
    final clipped = text.characters.take(charactersLimit).toString();
    if (clipped != text) truncated = true;
    items.add({...row, 'text': clipped});
    result['status'] = 'truncated';
    if (utf8.encode(jsonEncode(result)).length > assistantToolByteLimit - 100) {
      items.removeLast();
      truncated = true;
      break;
    }
  }
  result['status'] = truncated ? 'truncated' : 'ok';
  return result;
}
