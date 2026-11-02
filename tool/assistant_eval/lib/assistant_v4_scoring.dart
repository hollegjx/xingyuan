import 'package:xingyuan_core/xingyuan_core.dart';

/// Offline v2 diary trajectory gate. This measures typed protocol actions, not
/// semantic quality or a live model's intent classification. No text is emitted.
Map<String, Object?> scoreAssistantDiaryTrajectory({
  required CalendarDate day,
  required List<AgentRequest> requests,
  required List<AgentTurnResponse> responses,
}) {
  final aligned = requests.length == responses.length && responses.isNotEmpty;
  final tools = responses
      .where((r) => r.call != null)
      .map((r) => r.call!)
      .toList();
  final firstTwo =
      tools.length >= 2 &&
      tools[0].name == 'get_day_summary' &&
      tools[1].name == 'get_journal_text' &&
      tools.take(2).every((t) => t.arguments['day'] == day.key) &&
      agentCanonical(tools[1].arguments['kinds']) ==
          agentCanonical(['quickNote', 'diary']);
  final startsWithReads =
      responses.length >= 2 &&
      responses[0].call?.name == 'get_day_summary' &&
      responses[1].call?.name == 'get_journal_text';
  String material(AgentRequest request) {
    final results = <String, Map<String, dynamic>>{};
    for (var i = 0; i < request.calls.length; i++) {
      final call = request.calls[i];
      if (!['get_day_summary', 'get_journal_text'].contains(call.name) ||
          call.arguments['day'] != day.key) {
        continue;
      }
      final result = request.results[i];
      results[call.name] = result['status'] == 'duplicate'
          ? result['result'] as Map<String, dynamic>
          : result;
    }
    if (results.length != 2) return 'unknown';
    if (results.values.any(
      (r) =>
          r['data'] is Map &&
          (((r['data'] as Map)['items']) as List).isNotEmpty,
    )) {
      return 'present';
    }
    if (results.values.any(
      (r) => ['not_authorized', 'failed'].contains(r['status']),
    )) {
      return 'blocked';
    }
    return results.values.every((r) => r['status'] == 'ok')
        ? 'empty'
        : 'unknown';
  }

  var questions = 0;
  var validQuestions = true;
  var draft = false;
  if (aligned) {
    for (var i = 0; i < responses.length; i++) {
      if (responses[i].kind == 'question' && !draft) {
        questions++;
        if (material(requests[i]) != 'empty' || questions > 1) {
          validQuestions = false;
        }
      }
      if (responses[i].call?.name == 'create_diary_draft') {
        draft = responses[i].call!.arguments['day'] == day.key;
      }
    }
  }
  final state = aligned ? material(requests.last) : 'unknown';
  final outcome = switch (state) {
    'present' => draft && questions == 0,
    'empty' => draft || questions == 1,
    'blocked' => !draft && questions == 0,
    _ => false,
  };
  return {
    'passed':
        aligned && firstTwo && startsWithReads && validQuestions && outcome,
    'first_two_reads': firstTwo && startsWithReads,
    'questions_before_draft': questions,
    'empty_material_exception': state == 'empty',
    'material_state': state,
    'draft_proposed': draft,
    'evidence': 'synthetic_protocol_trajectory',
    'voice_and_factuality': 'not_assessed',
  };
}
