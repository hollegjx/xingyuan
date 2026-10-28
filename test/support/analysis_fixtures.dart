import 'dart:async';

import 'package:habit_checkin/features/assistant/data/assistant_service.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

class TestDayAnalysisService implements DayAnalysisService {
  @override
  bool configured = true;
  final requests = <DayAnalysisRequest>[];
  Completer<void>? gate;
  AssistantFailure? failure;
  @override
  Future<DayAnalysisResponse> analyzeDay(
    DayAnalysisRequest request, {
    required AssistantAccess access,
    AssistantCancellation? cancellation,
  }) async {
    requests.add(request);
    if (gate != null) await gate!.future;
    if (failure case final error?) throw error;
    if (cancellation?.isCancelled ?? false) {
      throw const AssistantFailure(AssistantFailureKind.cancelled);
    }
    if (!await access.isCurrent()) {
      throw const AssistantFailure(AssistantFailureKind.discarded);
    }
    return DayAnalysisResponse.fromJson({
      'protocol': assistantProtocol,
      'request_id': request.requestId,
      'summary': 'TEST 合成分析结果',
      'suggestions': ['TEST 可以留出一段休息时间。'],
    }, request: request);
  }
}
