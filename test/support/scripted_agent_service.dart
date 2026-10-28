import 'package:habit_checkin/features/assistant/data/assistant_service.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

import 'test_assistant_service.dart';

Map<String, dynamic> agentResponse(
  AgentRequest request, {
  String? tool,
  Map<String, dynamic> arguments = const {},
  String? stop,
  String text = 'TEST answer',
  bool question = false,
  int? tokens,
}) => {
  'protocol': agentProtocol,
  'request_id': request.requestId,
  'run_id': request.runId ?? 'test_run',
  'turn': request.turn,
  'kind': tool != null
      ? 'tool_call'
      : stop != null
      ? 'stopped'
      : question
      ? 'question'
      : 'text',
  if (tool != null)
    'tool_call': {
      'id': agentCallId(request.runId ?? 'test_run', request.turn),
      'type': 'function',
      'function': {'name': tool, 'arguments': agentCanonical(arguments)},
    }
  else if (stop != null)
    'code': stop
  else
    'text': text,
  'budget': {
    'calls': request.turn,
    'charged_tokens': tokens ?? request.turn * 100,
    'remaining_ms': 60000 - request.turn,
    'violation': false,
  },
};

class ScriptedAgentService extends ConversationTestService
    implements AgentService {
  final agentRequests = <AgentRequest>[];
  final script = <Future<Map<String, dynamic>> Function(AgentRequest)>[];
  @override
  Future<AgentTurnResponse> agentTurn(
    AgentRequest request, {
    required AssistantAccess access,
    required AssistantCancellation cancellation,
  }) async {
    if (!await access.isCurrent() || cancellation.isCancelled) {
      throw const AssistantFailure(AssistantFailureKind.discarded);
    }
    agentRequests.add(AgentRequest.fromJson(request.toJson()));
    if (script.isEmpty) throw StateError('Unexpected fake model call');
    return AgentTurnResponse.fromJson(
      await script.removeAt(0)(request),
      request: request,
    );
  }
}
