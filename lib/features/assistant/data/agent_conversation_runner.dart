import 'dart:async';
import 'dart:convert';

import 'package:xingyuan_core/xingyuan_core.dart';

import '../domain/agent_run_metadata.dart';
import '../domain/plan_preview.dart';
import 'agent_tool_executor.dart';
import 'assistant_conversation_runner.dart';
import 'assistant_service.dart';
import 'local_agent_source.dart';
import 'local_conversation_store.dart';

String agentStopMessage(String? code) => switch (code) {
  'repeated_tool_call' => '重复查询已停止，请补充条件后重新规划。未创建任何内容。',
  'invalid_plan' => '没能排出不冲突的方案，请调整条件后重新规划。未创建任何内容。',
  'run_deadline' || 'model_timeout' => '本次规划已超时，请重新开始。未创建任何内容。',
  'not_authorized' => '未授权读取已有安排，无法检查草稿。未创建任何内容。',
  'token_budget' ||
  'run_calls' ||
  'daily_quota' ||
  'run_call_limit' ||
  'run_token_limit' ||
  'daily_run_limit' ||
  'daily_token_limit' => '本次规划已达到调用或用量上限，请稍后重新开始。未创建任何内容。',
  'usage_violation' ||
  'invalid_usage' ||
  'usage_exceeds_reservation' => '用量校验未通过，本次规划已停止。请重新开始，未创建任何内容。',
  'run_expired' ||
  'unknown_run' ||
  'run_restart_required' ||
  'run_stopped' ||
  'start_replayed' ||
  'turn_replayed' ||
  'history_mismatch' => '本次规划已失效，请重新开始。未创建任何内容。',
  'model_request_too_large' => '内容过大，请新开会话或缩短条件。未创建任何内容。',
  _ => '本次规划未能完成，请重新开始。未创建任何内容。',
};

String _invalidPlanMessage(Map<String, dynamic> result) => [
  agentStopMessage('invalid_plan'),
  for (final issue in (result['data'] as Map)['issues'] as List)
    '第 ${(issue['index'] as int) + 1} 项：${switch (issue['code']) {
      'date_range' => '日期超出规划范围',
      'conflict' => '与已有安排或计划内其他项冲突',
      'duplicate' => '同一天有重复安排',
      'daily_cap' => '超过每日时长上限',
      'unknown_schedule' => '已有安排不完整，无法判断冲突',
      _ => '日期、开始时间或时长无效',
    }}',
].join('\n');

class AgentConversationRunner {
  AgentConversationRunner({
    required this.store,
    required this.service,
    this.limit = const Duration(seconds: 60),
  });
  final LocalConversationStore store;
  final AgentService service;
  final Duration limit;

  Future<CommittedAssistantTurn> run(
    PendingAssistantTurn turn, {
    void Function(AssistantRunStage)? onStage,
    void Function(AgentRunMetadata)? onProgress,
    void Function(AgentToolCall, Map<String, dynamic>)? onToolResult,
    void Function(String)? onStop,
    void Function(int, String)? onRequestRejected,
  }) async {
    String stop(String code) {
      onStop?.call(code);
      return agentStopMessage(code);
    }

    final timer = Stopwatch()..start();
    final deadline = limit.inMilliseconds.clamp(1, 60000);
    final now = store.goals.clock.read();
    final date = CalendarDate.parse(now.day.key);
    final executor = AgentToolExecutor(
      source: LocalAgentSource(store, turn),
      today: date,
    );
    final trace = <AgentTraceEntry>[];
    final statuses = <String>{};
    Set<int> partial = {};
    var ended = false;
    var discarded = false;
    var tokens = 0;
    var remainingMs = 60000;
    var watching = true;
    var repairing = false;
    String? runId;
    final messages = <Map<String, dynamic>>[];
    final subscriptions = <StreamSubscription<Object?>>[];
    AgentRunMetadata metadata() => AgentRunMetadata(
      date: date,
      statuses: statuses,
      trace: trace,
      partial: partial,
      dailyCaps: executor.dailyCaps,
    );
    Future<void> check() async {
      if (ended || discarded) {
        throw const AssistantFailure(AssistantFailureKind.discarded);
      }
      if (turn.cancellation.isCancelled) {
        throw const AssistantFailure(AssistantFailureKind.cancelled);
      }
      if (!await store.isCurrent(turn)) {
        throw const AssistantFailure(AssistantFailureKind.discarded);
      }
    }

    void invalidate(Object? _) {
      if (ended || !watching) return;
      store
          .isCurrent(turn)
          .then(
            (current) {
              if (!ended && watching && !current) {
                discarded = true;
                turn.cancellation.cancel();
              }
            },
            onError: (Object _) {
              if (!ended && watching) {
                discarded = true;
                turn.cancellation.cancel();
              }
            },
          );
    }

    Future<T> bounded<T>(
      Future<T> Function() action, {
      bool commitsTurn = false,
    }) async {
      final remaining = (deadline - timer.elapsedMilliseconds).clamp(
        0,
        remainingMs,
      );
      if (remaining <= 0) {
        throw const AssistantFailure(AssistantFailureKind.timeout);
      }
      try {
        final result = await Future.any<T>([
          action(),
          turn.cancellation.whenCancelled.then<T>((_) {
            throw AssistantFailure(
              discarded
                  ? AssistantFailureKind.discarded
                  : AssistantFailureKind.cancelled,
            );
          }),
        ]).timeout(Duration(milliseconds: remaining));
        // A successful commit consumes the pending turn. Its transaction
        // performs the final identity/cancellation checks before committing.
        if (!commitsTurn) await check();
        return result;
      } on TimeoutException {
        turn.cancellation.cancel();
        throw const AssistantFailure(AssistantFailureKind.timeout);
      }
    }

    void stopWatching() {
      watching = false;
      // Detach immediately. Shared Drift query cleanup can wait for other
      // listeners; it must not delay committing a draft or cancelling a run.
      for (final sub in subscriptions) {
        sub.cancel().ignore();
      }
      subscriptions.clear();
    }

    Future<CommittedAssistantTurn> finish(
      String text, {
      PlanPreview? preview,
    }) => bounded(() async {
      await check();
      onStage?.call(
        preview == null
            ? AssistantRunStage.saving
            : AssistantRunStage.confirming,
      );
      stopWatching();
      return store.commitAgentResponse(
        turn,
        text: text,
        metadata: metadata(),
        preview: preview,
      );
    }, commitsTurn: true);

    try {
      subscriptions.add(
        store.db
            .select(store.db.identityStates)
            .watch()
            .listen(invalidate, onError: invalidate),
      );
      subscriptions.add(
        (store.db.select(store.db.assistantSettings)
              ..where((row) => row.owner.equals(store.owner)))
            .watch()
            .listen(invalidate, onError: invalidate),
      );
      await check();
      messages.add({'role': 'user', 'content': await store.agentInput(turn)});
      for (var round = 1; round <= agentCallLimit; round++) {
        await check();
        if (timer.elapsedMilliseconds >= deadline) {
          if (runId == null) {
            throw const AssistantFailure(AssistantFailureKind.timeout);
          }
          return await finish(stop('run_deadline'));
        }
        final envelope = <String, dynamic>{
          'protocol': agentProtocol,
          'request_id': turn.requestId,
          'run_id': runId,
          'turn': round,
          'now': {
            'date': date.key,
            'time': formatMinute(
              now.localTime.hour * 60 + now.localTime.minute,
            ),
            'weekday': date.weekday,
            'time_zone': now.zone,
          },
          'messages': messages,
        };
        // Embedded tool JSON has a parser size limit too. Preserve the real
        // cause by checking the whole envelope before parsing that content.
        final envelopeBytes = utf8.encode(jsonEncode(envelope)).length;
        if (envelopeBytes >= agentBodyLimit) {
          onRequestRejected?.call(envelopeBytes, 'model_request_too_large');
          throw const AssistantFailure(AssistantFailureKind.tooLarge);
        }
        final request = AgentRequest.fromJson(envelope);
        final bytes = utf8.encode(jsonEncode(request.toJson())).length;
        if (bytes >= agentBodyLimit) {
          onRequestRejected?.call(bytes, 'model_request_too_large');
          throw const AssistantFailure(AssistantFailureKind.tooLarge);
        }
        // The server additionally reserves its exact body including system/tools.
        if (tokens + (bytes + 1) ~/ 2 + agentOutputLimit > agentTokenLimit) {
          onRequestRejected?.call(bytes, 'token_budget');
          if (runId == null) {
            throw const AssistantFailure(AssistantFailureKind.budget);
          }
          return await finish(stop('token_budget'));
        }
        await store.recordAgentRequest(turn, request);
        onStage?.call(
          repairing ? AssistantRunStage.adjusting : AssistantRunStage.sending,
        );
        final response = AgentTurnResponse.fromJson(
          (await bounded(
            () => service.agentTurn(
              request,
              access: store.access(turn),
              cancellation: turn.cancellation,
            ),
          )).toJson(),
          request: request,
        );
        if (response.tokens < tokens ||
            (response.kind != 'stopped' && response.tokens == tokens) ||
            response.remainingMs > remainingMs) {
          throw const FormatException('Invalid budget progression');
        }
        tokens = response.tokens;
        remainingMs = response.remainingMs;
        runId = response.runId;
        if (response.kind == 'stopped') {
          return await finish(stop(response.code!));
        }
        if (response.kind == 'text' || response.kind == 'question') {
          return await finish(response.text!);
        }
        final call = response.call!;
        onStage?.call(switch (call.name) {
          'query_schedule' => AssistantRunStage.querying,
          'find_free_slots' => AssistantRunStage.finding,
          'get_planning_preferences' => AssistantRunStage.preferences,
          _ => AssistantRunStage.validating,
        });
        final started = timer.elapsedMilliseconds;
        final result = await bounded(() => executor.execute(call));
        // Optional in-process observation; never persisted or logged by the app.
        if (onToolResult != null) {
          onToolResult(
            AgentToolCall.parse(call.toJson(), date),
            jsonDecode(jsonEncode(result)) as Map<String, dynamic>,
          );
        }
        final original = result['status'] == 'duplicate'
            ? result['result'] as Map<String, dynamic>
            : result;
        final status = original['status'] as String;
        statuses.add(status);
        trace.add(
          AgentTraceEntry(
            call.name,
            result['status'] as String,
            (timer.elapsedMilliseconds - started).clamp(0, 60000),
          ),
        );
        onProgress?.call(metadata());
        if (call.name == 'submit_plan_draft') {
          if (status == 'ok' || status == 'partial') {
            // execute(submit) validates this exact draft against fresh, full data.
            partial = {
              for (final issue in ((original['data'] as Map)['issues'] as List))
                if (issue['code'] == 'unknown_schedule') issue['index'] as int,
            };
            return await finish(
              (call.arguments['note'] as String).trim().isEmpty
                  ? '计划草稿已检查，等你确认。'
                  : call.arguments['note'] as String,
              preview: PlanPreview.fromAgentItems(
                (call.arguments['items'] as List).cast<Map<String, dynamic>>(),
              ),
            );
          }
          if (status != 'invalid') {
            return await finish(stop(status));
          }
        }
        repairing = status == 'invalid';
        if (repairing) onStage?.call(AssistantRunStage.adjusting);
        if (round == agentCallLimit) {
          onStop?.call('run_calls');
          return await finish(
            status == 'invalid'
                ? _invalidPlanMessage(original)
                : agentStopMessage('run_calls'),
          );
        }
        messages.add(call.message);
        messages.add({
          'role': 'tool',
          'tool_call_id': call.id,
          'content': agentCanonical(result),
        });
      }
      return await finish(stop('run_calls'));
    } on AgentToolStop catch (error) {
      return await finish(stop(error.code));
    } on AgentServiceStopped catch (error) {
      return await finish(stop(error.code));
    } finally {
      ended = true;
      timer.stop();
      stopWatching();
    }
  }
}
