import 'dart:async';

import 'package:habit_checkin/features/assistant/data/assistant_service.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

class SyntheticJournalAi implements JournalAiService {
  @override
  bool configured = true;
  final calls = <Map<String, Object?>>[];
  Completer<void>? gate;
  bool fail = false;
  AssistantFailureKind failureKind = AssistantFailureKind.network;
  String rewrite = '我读完一章。';
  String diary = '我今天读完一章。';

  @override
  Future<PolishNoteResponse> polishNote(
    PolishNoteRequest request, {
    required AssistantAccess access,
    AssistantCancellation? cancellation,
  }) async {
    calls.add(request.toJson());
    await gate?.future;
    if (fail) throw AssistantFailure(failureKind);
    return PolishNoteResponse.fromJson({
      'protocol': assistantProtocol,
      'request_id': request.requestId,
      'rewrite': rewrite,
      'tips': ['保留了原意。'],
    }, request: request);
  }

  @override
  Future<GenerateDiaryResponse> generateDiary(
    GenerateDiaryRequest request, {
    required AssistantAccess access,
    AssistantCancellation? cancellation,
  }) async {
    calls.add(request.toJson());
    await gate?.future;
    if (fail) throw AssistantFailure(failureKind);
    return request.hasMaterial
        ? GenerateDiaryResponse.fromJson({
            'protocol': assistantProtocol,
            'request_id': request.requestId,
            'status': 'draft',
            'draft': diary,
          }, request: request)
        : GenerateDiaryResponse.insufficient(request);
  }
}
