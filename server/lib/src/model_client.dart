import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:xingyuan_core/xingyuan_core.dart';

import 'agent_protocol.dart';
import 'prompts.dart';
import 'tool_schema.dart';

class ModelFailure implements Exception {
  const ModelFailure(this.status, this.code, this.attempts);
  final int status;
  final String code;
  final int attempts;
  @override
  String toString() => 'ModelFailure($status, $code, attempts=$attempts)';
}

class ModelResult<T> {
  ModelResult(this.value, this.attempts, this.usage);
  final T value;
  final int attempts;
  final Map<String, int> usage;
}

class AssistantModelClient {
  AssistantModelClient({
    required this.endpoint,
    required this.apiKey,
    this.reasoning = 'none',
    this.maxCompletionTokens = 4000,
    this.timeout = const Duration(seconds: 75),
    this.onCall,
  }) {
    if (!['none', 'low'].contains(reasoning) ||
        maxCompletionTokens < 1 ||
        timeout <= Duration.zero) {
      throw const FormatException('Invalid model options');
    }
  }
  final Uri endpoint;
  final String apiKey;
  final String reasoning;
  final int maxCompletionTokens;
  final Duration timeout;
  final void Function()? onCall;

  Future<AgentModelReply> agentTurn(
    String body,
    AgentRequest request,
    Duration remaining,
  ) async {
    final limit = remaining < timeout ? remaining : timeout;
    final client = HttpClient()..connectionTimeout = limit;
    AgentModelReply stop(String code, {String? detail}) => AgentModelReply(
      AgentOutcome.stop(code),
      AgentUsage.parse(null),
      rejectionDetail: detail,
    );
    try {
      if (limit <= Duration.zero ||
          utf8.encode(body).length >= agentBodyLimit) {
        return stop('model_request_limit');
      }
      return await (() async {
        final outgoing = await client.postUrl(endpoint);
        outgoing.followRedirects = false;
        outgoing.headers.contentType = ContentType.json;
        outgoing.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
        outgoing.add(utf8.encode(body));
        onCall?.call();
        final response = await outgoing.close();
        if (response.statusCode != 200) return stop('upstream_http');
        final String content;
        try {
          content = await readBoundedBody(response, limit: agentBodyLimit - 1);
        } on FormatException catch (error) {
          return stop(
            'invalid_model_output',
            detail: error.message == 'Body too large'
                ? 'response_body_limit'
                : 'response_encoding',
          );
        }
        try {
          final raw = decodeAssistantJson(content);
          return AgentModelReply.parse(raw, request.now.date);
        } on FormatException {
          return stop('invalid_model_output', detail: 'response_json');
        }
      })().timeout(limit);
    } on TimeoutException {
      return stop('model_timeout');
    } catch (_) {
      return stop('model_connection');
    } finally {
      client.close(force: true);
    }
  }

  Future<ModelResult<TurnResponse>> turn(TurnRequest request) => _generate(
    payload: request.toJson(),
    toolName: 'assistant_turn',
    schema: assistantTurnSchemaFor(diaryProposals: request.diaryProposals),
    system:
        '$assistantSystemPrompt${request.diaryProposals ? '\n$chatDiarySystemPrompt' : ''}\n可信日历计算（不是任务提议）：${jsonEncode({'remaining_week_dates': request.now.date.remainingWeek.map((day) => day.key).toList(), 'next_week_dates': request.now.date.nextWeek.map((day) => day.key).toList(), 'minutes_until_midnight': 1440 - parseMinute(request.now.time), 'sunday_this_week_requires_question': request.now.date.weekday == 7})}',
    validate: (value) => TurnResponse.fromJson({
      ..._modelObject(value, {
        'reply',
        'plan',
        'memory_ops',
        if (request.diaryProposals) 'diary',
      }),
      'protocol': assistantProtocol,
      'request_id': request.requestId,
    }, request: request),
  );

  Future<ModelResult<SummaryResponse>> summarize(SummaryRequest request) =>
      _generate(
        payload: request.toJson(),
        toolName: 'assistant_summary',
        schema: assistantSummarySchema,
        system: summarySystemPrompt,
        validate: (value) => SummaryResponse.fromJson({
          ..._modelObject(value, {'summary'}),
          'protocol': assistantProtocol,
          'request_id': request.requestId,
        }, requestId: request.requestId),
      );

  Future<ModelResult<DayAnalysisResponse>> analyzeDay(
    DayAnalysisRequest request,
  ) => _generate(
    payload: request.toJson(),
    toolName: 'analyze_day',
    schema: dayAnalysisSchema(withNotes: request.hasNotes),
    system: dayAnalysisSystemPrompt,
    validate: (value) => DayAnalysisResponse.fromJson({
      ..._modelObject(value, {'summary', 'suggestions'}),
      'protocol': assistantProtocol,
      'request_id': request.requestId,
    }, request: request),
  );

  Future<ModelResult<PolishNoteResponse>> polishNote(
    PolishNoteRequest request,
  ) => _generate(
    payload: request.toJson(),
    toolName: 'polish_note',
    schema: polishNoteSchema,
    system: polishNoteSystemPrompt,
    validate: (value) => PolishNoteResponse.fromJson({
      ..._modelObject(value, {'rewrite', 'tips'}),
      'protocol': assistantProtocol,
      'request_id': request.requestId,
    }, request: request),
  );

  Future<ModelResult<GenerateDiaryResponse>> generateDiary(
    GenerateDiaryRequest request,
  ) async {
    if (!request.hasMaterial) {
      return ModelResult(GenerateDiaryResponse.insufficient(request), 0, {});
    }
    return _generate(
      payload: request.toJson(),
      toolName: 'generate_diary',
      schema: generateDiarySchema,
      system: generateDiarySystemPrompt,
      validate: (value) => GenerateDiaryResponse.fromJson({
        ..._modelObject(value, {'status', 'draft'}),
        'protocol': assistantProtocol,
        'request_id': request.requestId,
      }, request: request),
    );
  }

  Future<ModelResult<T>> _generate<T>({
    required Map<String, Object?> payload,
    required String toolName,
    required Map<String, Object?> schema,
    required String system,
    required T Function(Object?) validate,
  }) async {
    final client = HttpClient()..connectionTimeout = timeout;
    var attempts = 0;
    final usage = <String, int>{};
    try {
      return await (() async {
        for (var attempt = 0; attempt < 2; attempt++) {
          final outgoing = await client.postUrl(endpoint);
          outgoing.followRedirects = false;
          outgoing.headers.contentType = ContentType.json;
          outgoing.headers.set(
            HttpHeaders.authorizationHeader,
            'Bearer $apiKey',
          );
          outgoing.write(
            jsonEncode({
              'model': 'gpt-6-luna',
              'reasoning_effort': reasoning,
              'max_completion_tokens': maxCompletionTokens,
              'store': false,
              'parallel_tool_calls': false,
              'messages': [
                {'role': 'system', 'content': system},
                if (attempt > 0)
                  {
                    'role': 'system',
                    'content':
                        '上次输出未通过协议校验。重新生成唯一的完整工具参数，严格检查日期、数量、字段、记忆操作和能力边界。',
                  },
                {'role': 'user', 'content': jsonEncode(payload)},
              ],
              'tools': [
                {
                  'type': 'function',
                  'function': {
                    'name': toolName,
                    'description': 'Return validated data for local review.',
                    'strict': true,
                    'parameters': schema,
                  },
                },
              ],
              'tool_choice': {
                'type': 'function',
                'function': {'name': toolName},
              },
            }),
          );
          attempts++;
          onCall?.call();
          final response = await outgoing.close();
          if (response.statusCode != 200) {
            throw ModelFailure(502, 'upstream_http', attempts);
          }
          try {
            final raw = decodeAssistantJson(await readBoundedBody(response));
            if (raw is! Map<String, dynamic>) throw const FormatException();
            if (raw['usage'] case final Map rawUsage) {
              for (final key in [
                'prompt_tokens',
                'completion_tokens',
                'total_tokens',
              ]) {
                if (rawUsage[key] case final int count when count >= 0) {
                  usage.update(
                    key,
                    (previous) => previous + count,
                    ifAbsent: () => count,
                  );
                }
              }
            }
            final arguments = parseToolArguments(raw, toolName);
            final result = validate(arguments);
            return ModelResult(result, attempts, Map.unmodifiable(usage));
          } on FormatException {
            if (attempt == 1) {
              throw ModelFailure(422, 'invalid_model_output', attempts);
            }
          }
        }
        throw ModelFailure(422, 'invalid_model_output', attempts);
      })().timeout(timeout);
    } on ModelFailure {
      rethrow;
    } on TimeoutException {
      throw ModelFailure(504, 'model_timeout', attempts);
    } catch (_) {
      throw ModelFailure(502, 'model_connection', attempts);
    } finally {
      client.close(force: true);
    }
  }
}

Map<String, dynamic> _modelObject(Object? value, Set<String> keys) {
  if (value is! Map<String, dynamic> ||
      value.keys.length != keys.length ||
      !keys.every(value.containsKey)) {
    throw const FormatException('Invalid tool fields');
  }
  return value;
}

Object? parseToolArguments(Map<String, dynamic> raw, String toolName) {
  final choices = raw['choices'];
  if (choices is! List || choices.length != 1) {
    throw const FormatException('Invalid choices');
  }
  final choice = choices.single;
  if (choice is! Map || choice['finish_reason'] != 'tool_calls') {
    throw const FormatException('Incomplete tool call');
  }
  final message = choice['message'];
  if (message is! Map ||
      message['refusal'] != null ||
      message['tool_calls'] is! List ||
      (message['tool_calls'] as List).length != 1) {
    throw const FormatException('Invalid tool call');
  }
  final tool = message['tool_calls'][0];
  if (tool is! Map ||
      tool['type'] != 'function' ||
      tool['function'] is! Map ||
      tool['function']['name'] != toolName ||
      tool['function']['arguments'] is! String) {
    throw const FormatException('Unexpected tool');
  }
  return decodeAssistantJson(tool['function']['arguments'] as String);
}

Future<String> readBoundedBody(
  Stream<List<int>> stream, {
  int limit = assistantBodyLimit,
}) async {
  final bytes = <int>[];
  await for (final chunk in stream) {
    if (bytes.length + chunk.length > limit) {
      throw const FormatException('Body too large');
    }
    bytes.addAll(chunk);
  }
  return utf8.decode(bytes);
}
