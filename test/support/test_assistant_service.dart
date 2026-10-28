import 'package:habit_checkin/features/assistant/data/assistant_service.dart';
import 'package:habit_checkin/features/assistant/data/device_credential_store.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

TurnResponse syntheticReply(
  TurnRequest request, {
  bool plan = false,
  bool memory = false,
}) => TurnResponse.fromJson({
  'protocol': assistantProtocol,
  'request_id': request.requestId,
  'reply': plan ? 'TEST 提议明晚阅读半小时，确认前不会创建。' : 'TEST 好的',
  'plan': plan
      ? {
          'tasks': [
            {
              'title': 'TEST 阅读',
              'date': request.now.date.addDays(1).key,
              'time': '20:00',
              'minutes': 30,
            },
          ],
          'habits': [],
        }
      : null,
  'memory_ops': memory
      ? [
          {
            'op': 'add',
            'id': null,
            'category': '偏好',
            'text': 'TEST 喜欢晚上阅读',
            'expires_on': null,
          },
        ]
      : [],
}, request: request);

class ConversationTestService implements AssistantService {
  @override
  bool configured = true;
  int healthCalls = 0;
  final requests = <TurnRequest>[];
  final summaries = <SummaryRequest>[];
  Future<TurnResponse> Function(TurnRequest)? onTurn;
  Future<SummaryResponse> Function(SummaryRequest)? onSummary;
  @override
  Future<TurnResponse> turn(
    TurnRequest request, {
    required AssistantAccess access,
    AssistantCancellation? cancellation,
  }) async {
    if (access.consentVersion != assistantConsentVersion ||
        !await access.isCurrent()) {
      throw const AssistantFailure(AssistantFailureKind.discarded);
    }
    requests.add(request);
    return onTurn == null ? syntheticReply(request) : onTurn!(request);
  }

  @override
  Future<SummaryResponse> summarize(
    SummaryRequest request, {
    required AssistantAccess access,
    AssistantCancellation? cancellation,
  }) async {
    summaries.add(request);
    return onSummary == null
        ? SummaryResponse.fromJson({
            'protocol': assistantProtocol,
            'request_id': request.requestId,
            'summary': 'TEST 历史约束摘要',
          }, requestId: request.requestId)
        : onSummary!(request);
  }

  @override
  Future<void> health({required AssistantAccess access}) async {
    healthCalls++;
  }
}

class ConversationTestCredentials extends DeviceCredentialStore {
  String? value = 'a' * 43;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> save(String input) async {
    if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(input.trim())) {
      throw const DeviceCredentialFailure('设备凭证格式不正确，原有凭证未更改。');
    }
    value = input.trim();
  }

  @override
  Future<void> clear() async {
    value = null;
  }
}
