import 'package:xingyuan_core/xingyuan_core.dart';

import 'assistant_v4_scoring.dart';

/// C80 keeps the existing read order and tightens empty-material behavior:
/// a successful read leads to a draft without any pre-draft question.
/// This is synthetic trajectory evidence, not factuality/prose validation.
Map<String, Object?> scoreContinuousDiaryTrajectory({
  required CalendarDate day,
  required List<AgentRequest> requests,
  required List<AgentTurnResponse> responses,
}) {
  final base = scoreAssistantDiaryTrajectory(
    day: day,
    requests: requests,
    responses: responses,
  );
  final enabled =
      requests.isNotEmpty && requests.every(assistantContextEnabled);
  return {
    ...base,
    'passed':
        base['passed'] == true &&
        enabled &&
        base['questions_before_draft'] == 0 &&
        (base['material_state'] == 'blocked' || base['draft_proposed'] == true),
    'empty_material_exception': false,
    'contextual': enabled,
  };
}
