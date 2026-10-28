import 'package:characters/characters.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

const agentRejectionDetails = {
  'unspecified',
  'response_body_limit',
  'response_encoding',
  'response_json',
  'envelope_shape',
  'choices_shape',
  'message_shape',
  'message_role',
  'finish_reason',
  'tool_calls_shape',
  'stop_tool_calls',
  'content_shape',
  'content_json',
  'text_fields',
  'text_kind',
  'text_value',
  'call_fields',
  'call_type',
  'call_id',
  'function_fields',
  'tool_name',
  'arguments_text',
  'arguments_json',
  'arguments_schema',
  'history_mismatch',
  'duplicate_result_mismatch',
  'unexpected_duplicate',
  'draft_validation_terminal',
  'run_stopped',
  'turn_replayed',
  'app_response_validation',
  'confirmation_plan_changed',
  'transport_exception',
};

String? agentRejectionDetailForCode(String? code) => switch (code) {
  'invalid_model_output' => 'unspecified',
  'history_mismatch' ||
  'duplicate_result_mismatch' ||
  'unexpected_duplicate' ||
  'draft_validation_terminal' ||
  'run_stopped' ||
  'turn_replayed' => code,
  _ => null,
};

// Called only after the existing shared parser has rejected the call. This
// classification cannot admit input, retain content, or change the wire code.
String agentRejectedToolDetail(Object? value) {
  bool fields(Object? value, Set<String> keys) =>
      value is Map<String, dynamic> &&
      value.length == keys.length &&
      keys.every(value.containsKey);
  bool text(Object? value, int limit) =>
      value is String &&
      value.trim().isNotEmpty &&
      value.characters.length <= limit;
  if (!fields(value, {'id', 'type', 'function'})) return 'call_fields';
  final call = value as Map;
  if (call['type'] != 'function') return 'call_type';
  if (!fields(call['function'], {'name', 'arguments'})) {
    return 'function_fields';
  }
  final function = call['function'] as Map;
  if (!agentTools.contains(function['name'])) return 'tool_name';
  if (!text(function['arguments'], agentBodyLimit)) return 'arguments_text';
  try {
    decodeAssistantJson(function['arguments'] as String);
  } on FormatException {
    return 'arguments_json';
  }
  if (!text(call['id'], 128) ||
      !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(call['id'] as String)) {
    return 'call_id';
  }
  return 'arguments_schema';
}
