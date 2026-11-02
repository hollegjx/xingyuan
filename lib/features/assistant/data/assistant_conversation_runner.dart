import '../../../data/sync/identity_store.dart';
import 'assistant_request_builder.dart';
import 'assistant_service.dart';
import 'local_conversation_store.dart';
import '../domain/agent_run_metadata.dart';
import 'agent_conversation_runner.dart';
import 'assistant_record_tools.dart';

import 'package:xingyuan_core/xingyuan_core.dart';

enum AssistantRunStage {
  summarizing,
  sending,
  saving,
  querying,
  finding,
  preferences,
  validating,
  adjusting,
  confirming,
}

class AssistantConversationRunner {
  AssistantConversationRunner({required this.store, required this.service});
  final LocalConversationStore store;
  final AssistantService service;

  Future<CommittedAssistantTurn> run(
    PendingAssistantTurn turn, {
    void Function(AssistantRunStage stage)? onStage,
    ConfirmAssistantRead? confirmRead,
    AssistantRecordScope? recordScope,
    void Function(AgentRunMetadata metadata)? onProgress,
    void Function(AgentToolCall, Map<String, dynamic>)? onToolResult,
    void Function(String)? onStop,
    void Function(int, String)? onRequestRejected,
  }) async {
    Future<void> recordFailure({bool discarded = false}) async {
      turn.cancellation.cancel();
      try {
        await store
            .fail(turn, discarded: discarded)
            .timeout(const Duration(seconds: 5));
      } catch (_) {
        // A locked/unavailable store must not hide the original failure.
        // Pending rows remain recoverable; late writes are request-ID scoped.
      }
    }

    try {
      if (!service.configured) {
        throw const AssistantFailure(AssistantFailureKind.unconfigured);
      }
      final agent = service;
      if (turn.settings.agentEnabled && agent is AgentService) {
        return await AgentConversationRunner(
          store: store,
          service: agent as AgentService,
        ).run(
          turn,
          onStage: onStage,
          confirmRead: confirmRead,
          recordScope: recordScope,
          onProgress: onProgress,
          onToolResult: onToolResult,
          onStop: onStop,
          onRequestRejected: onRequestRejected,
        );
      }
      while (true) {
        final work = await store.nextSummary(turn);
        if (work == null) break;
        onStage?.call(AssistantRunStage.summarizing);
        try {
          final summary = await service.summarize(
            work.request,
            access: store.access(turn),
            cancellation: turn.cancellation,
          );
          await store.saveSummary(work, summary);
        } on AssistantFailure catch (error) {
          if ({
            AssistantFailureKind.cancelled,
            AssistantFailureKind.discarded,
            AssistantFailureKind.credential,
            AssistantFailureKind.consent,
            AssistantFailureKind.unconfigured,
          }.contains(error.kind)) {
            rethrow;
          }
          throw const AssistantFailure(AssistantFailureKind.summary);
        } on FormatException {
          throw const AssistantFailure(AssistantFailureKind.summary);
        }
      }
      final request = await AssistantRequestBuilder(store).build(turn);
      await store.recordRequest(turn, request);
      onStage?.call(AssistantRunStage.sending);
      final response = await service.turn(
        request,
        access: store.access(turn),
        cancellation: turn.cancellation,
      );
      onStage?.call(AssistantRunStage.saving);
      return await store.commitResponse(turn, response);
    } on AssistantFailure catch (error) {
      await recordFailure(
        discarded: {
          AssistantFailureKind.cancelled,
          AssistantFailureKind.discarded,
        }.contains(error.kind),
      );
      rethrow;
    } on StaleIdentity {
      throw const AssistantFailure(AssistantFailureKind.discarded);
    } on FormatException {
      await recordFailure();
      throw const AssistantFailure(AssistantFailureKind.invalidResponse);
    } catch (_) {
      await recordFailure();
      rethrow;
    }
  }
}
