import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:xingyuan_core/xingyuan_core.dart';

import '../../../shared/service_endpoint.dart';

const assistantConsentVersion = 2;
// The deployed proxy's 64KB request limit is decimal, unlike the protocol limit.
const diaryRequestBodyLimit = 64000;

enum AssistantFailureKind {
  consent,
  unconfigured,
  credential,
  request,
  tooLarge,
  budget,
  invalidResponse,
  busy,
  unavailable,
  timeout,
  network,
  cancelled,
  discarded,
  summary,
}

class AssistantFailure implements Exception {
  const AssistantFailure(this.kind);
  final AssistantFailureKind kind;

  String get message => switch (kind) {
    AssistantFailureKind.consent => '请先确认发送范围，尚未发送任何内容。',
    AssistantFailureKind.unconfigured => 'AI 服务未连接，未创建任何内容。',
    AssistantFailureKind.credential => '请在设置中检查访问凭证，未创建任何内容。',
    AssistantFailureKind.request => '请求格式不正确，请更新 App。未创建任何内容。',
    AssistantFailureKind.tooLarge => '内容过大，请新开会话或关闭部分发送内容。未创建任何内容。',
    AssistantFailureKind.budget => '本次规划已达到调用或用量上限，请新开会话或缩短条件。未创建任何内容。',
    AssistantFailureKind.invalidResponse => 'AI 未给出有效结果，未创建任何内容，可重试。',
    AssistantFailureKind.busy => '服务繁忙，请稍后再试。未创建任何内容。',
    AssistantFailureKind.unavailable => 'AI 服务暂时不可用，未创建任何内容，可重试。',
    AssistantFailureKind.timeout => '等待超时，未创建任何内容。重试可能再次调用模型。',
    AssistantFailureKind.network => '网络连接失败，未创建任何内容。重试可能再次调用模型。',
    AssistantFailureKind.cancelled => '已取消等待，未创建任何内容；模型调用可能已经发生。',
    AssistantFailureKind.discarded => '身份或授权已变化，回复已丢弃，未创建任何内容。',
    AssistantFailureKind.summary => '无法生成会话摘要，请新开会话。原聊天仍保留，未创建任何内容。',
  };

  @override
  String toString() => message;
}

/// The caller checks an identity generation, not only the current owner name.
/// It must repeat this check inside the transaction that stores any reply.
class AssistantAccess {
  const AssistantAccess({
    required this.consentVersion,
    required this.isCurrent,
  });
  final int consentVersion;
  final Future<bool> Function() isCurrent;
}

class AssistantCancellation {
  final _cancelled = Completer<void>();
  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;
  void cancel() {
    if (!isCancelled) _cancelled.complete();
  }
}

abstract interface class AssistantService {
  bool get configured;
  Future<TurnResponse> turn(
    TurnRequest request, {
    required AssistantAccess access,
    AssistantCancellation? cancellation,
  });
  Future<SummaryResponse> summarize(
    SummaryRequest request, {
    required AssistantAccess access,
    AssistantCancellation? cancellation,
  });
  Future<void> health({required AssistantAccess access});
}

abstract interface class DayAnalysisService {
  bool get configured;
  Future<DayAnalysisResponse> analyzeDay(
    DayAnalysisRequest request, {
    required AssistantAccess access,
    AssistantCancellation? cancellation,
  });
}

abstract interface class AgentService {
  Future<AgentTurnResponse> agentTurn(
    AgentRequest request, {
    required AssistantAccess access,
    required AssistantCancellation cancellation,
  });
}

class AgentServiceStopped implements Exception {
  const AgentServiceStopped(this.code);
  final String code;
  @override
  String toString() => 'AgentServiceStopped($code)';
}

abstract interface class JournalAiService {
  bool get configured;
  Future<PolishNoteResponse> polishNote(
    PolishNoteRequest request, {
    required AssistantAccess access,
    AssistantCancellation? cancellation,
  });
  Future<GenerateDiaryResponse> generateDiary(
    GenerateDiaryRequest request, {
    required AssistantAccess access,
    AssistantCancellation? cancellation,
  });
}

class HttpAssistantService
    implements
        AssistantService,
        DayAnalysisService,
        JournalAiService,
        AgentService {
  HttpAssistantService({
    required Uri? endpoint,
    required this.readCredential,
    bool allowInsecureLoopback = false,
    this.timeout = const Duration(seconds: 90),
  }) : endpoint = _validateEndpoint(endpoint, allowInsecureLoopback);

  final Uri? endpoint;
  final Future<String?> Function() readCredential;
  final Duration timeout;
  @override
  bool get configured => endpoint != null;

  @override
  Future<AgentTurnResponse> agentTurn(
    AgentRequest request, {
    required AssistantAccess access,
    required AssistantCancellation cancellation,
  }) async {
    if (utf8.encode(jsonEncode(request.toJson())).length >= agentBodyLimit) {
      throw const AssistantFailure(AssistantFailureKind.tooLarge);
    }
    final value = await _send(
      '/v1/agent/turn',
      request.toJson(),
      access,
      cancellation,
      requestBodyLimit: agentBodyLimit - 1,
      responseBodyLimit: agentBodyLimit - 1,
    );
    try {
      return AgentTurnResponse.fromJson(value, request: request);
    } on FormatException {
      throw const AssistantFailure(AssistantFailureKind.invalidResponse);
    }
  }

  @override
  Future<PolishNoteResponse> polishNote(
    PolishNoteRequest request, {
    required AssistantAccess access,
    AssistantCancellation? cancellation,
  }) async {
    final value = await _send(
      '/v1/polish-note',
      request.toJson(),
      access,
      cancellation,
    );
    try {
      return PolishNoteResponse.fromJson(value, request: request);
    } on FormatException {
      throw const AssistantFailure(AssistantFailureKind.invalidResponse);
    }
  }

  @override
  Future<GenerateDiaryResponse> generateDiary(
    GenerateDiaryRequest request, {
    required AssistantAccess access,
    AssistantCancellation? cancellation,
  }) async {
    final value = await _send(
      '/v1/generate-diary',
      request.toJson(),
      access,
      cancellation,
      requestBodyLimit: diaryRequestBodyLimit,
    );
    try {
      return GenerateDiaryResponse.fromJson(value, request: request);
    } on FormatException {
      throw const AssistantFailure(AssistantFailureKind.invalidResponse);
    }
  }

  @override
  Future<DayAnalysisResponse> analyzeDay(
    DayAnalysisRequest request, {
    required AssistantAccess access,
    AssistantCancellation? cancellation,
  }) async {
    final value = await _send(
      '/v1/analyze-day',
      request.toJson(),
      access,
      cancellation,
    );
    try {
      return DayAnalysisResponse.fromJson(value, request: request);
    } on FormatException {
      throw const AssistantFailure(AssistantFailureKind.invalidResponse);
    }
  }

  @override
  Future<TurnResponse> turn(
    TurnRequest request, {
    required AssistantAccess access,
    AssistantCancellation? cancellation,
  }) async {
    final value = await _send(
      '/v1/turn',
      request.toJson(),
      access,
      cancellation,
    );
    try {
      return TurnResponse.fromJson(value, request: request);
    } on FormatException {
      throw const AssistantFailure(AssistantFailureKind.invalidResponse);
    }
  }

  @override
  Future<SummaryResponse> summarize(
    SummaryRequest request, {
    required AssistantAccess access,
    AssistantCancellation? cancellation,
  }) async {
    final value = await _send(
      '/v1/summarize',
      request.toJson(),
      access,
      cancellation,
    );
    try {
      return SummaryResponse.fromJson(value, requestId: request.requestId);
    } on FormatException {
      throw const AssistantFailure(AssistantFailureKind.invalidResponse);
    }
  }

  @override
  Future<void> health({required AssistantAccess access}) async {
    final value = await _send('/v1/health', null, access, null);
    if (value is! Map<String, dynamic> ||
        value.length != 2 ||
        value['protocol'] != assistantProtocol ||
        value['status'] != 'ok') {
      throw const AssistantFailure(AssistantFailureKind.invalidResponse);
    }
  }

  Future<Object?> _send(
    String route,
    Map<String, Object?>? payload,
    AssistantAccess access,
    AssistantCancellation? cancellation, {
    int requestBodyLimit = assistantBodyLimit,
    int responseBodyLimit = assistantBodyLimit,
  }) async {
    HttpClient? client;
    var ended = false;
    Future<void> requireAccess() async {
      if (ended) {
        throw const AssistantFailure(AssistantFailureKind.discarded);
      }
      if (cancellation?.isCancelled ?? false) {
        throw const AssistantFailure(AssistantFailureKind.cancelled);
      }
      if (access.consentVersion != assistantConsentVersion) {
        throw const AssistantFailure(AssistantFailureKind.consent);
      }
      if (!await access.isCurrent()) {
        throw const AssistantFailure(AssistantFailureKind.discarded);
      }
      if (ended) {
        throw const AssistantFailure(AssistantFailureKind.discarded);
      }
      if (cancellation?.isCancelled ?? false) {
        throw const AssistantFailure(AssistantFailureKind.cancelled);
      }
    }

    Future<Object?> perform() async {
      await requireAccess();
      final base = endpoint;
      if (base == null) {
        throw const AssistantFailure(AssistantFailureKind.unconfigured);
      }
      final String? credential;
      if (payload == null) {
        credential = null;
      } else {
        try {
          credential = await readCredential();
        } catch (_) {
          throw const AssistantFailure(AssistantFailureKind.credential);
        }
        if (credential == null ||
            !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(credential)) {
          throw const AssistantFailure(AssistantFailureKind.credential);
        }
      }
      final bytes = payload == null ? null : utf8.encode(jsonEncode(payload));
      if (bytes != null && bytes.length > requestBodyLimit) {
        throw const AssistantFailure(AssistantFailureKind.tooLarge);
      }
      await requireAccess();
      final transport = HttpClient()..connectionTimeout = timeout;
      client = transport;
      final outgoing = await transport.openUrl(
        payload == null ? 'GET' : 'POST',
        base.replace(path: route),
      );
      await requireAccess();
      outgoing.followRedirects = false;
      outgoing.headers.contentType = ContentType.json;
      if (credential != null) {
        outgoing.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer $credential',
        );
      }
      if (bytes != null) {
        outgoing.contentLength = bytes.length;
        outgoing.add(bytes);
      }
      final response = await outgoing.close();
      if (response.statusCode != 200 && route == '/v1/agent/turn') {
        final received = <int>[];
        await for (final chunk in response) {
          if (received.length + chunk.length > responseBodyLimit) {
            throw const AssistantFailure(AssistantFailureKind.invalidResponse);
          }
          received.addAll(chunk);
        }
        await requireAccess();
        try {
          final value = agentObject(
            decodeAssistantJson(utf8.decode(received)),
            {'protocol', 'kind', 'code'},
          );
          if (value['protocol'] == agentProtocol &&
              value['kind'] == 'stopped' &&
              value['code'] is String &&
              RegExp(r'^[a-z_]{1,64}$').hasMatch(value['code'] as String)) {
            throw AgentServiceStopped(value['code'] as String);
          }
        } on FormatException {
          // Legacy gateway errors retain their typed HTTP failure below.
        }
      }
      if (response.statusCode != 200) {
        throw AssistantFailure(switch (response.statusCode) {
          400 => AssistantFailureKind.request,
          401 || 403 => AssistantFailureKind.credential,
          413 => AssistantFailureKind.tooLarge,
          422 => AssistantFailureKind.invalidResponse,
          429 => AssistantFailureKind.busy,
          504 => AssistantFailureKind.timeout,
          _ => AssistantFailureKind.unavailable,
        });
      }
      final received = <int>[];
      await for (final chunk in response) {
        if (received.length + chunk.length > responseBodyLimit) {
          throw const AssistantFailure(AssistantFailureKind.invalidResponse);
        }
        received.addAll(chunk);
      }
      await requireAccess();
      return decodeAssistantJson(utf8.decode(received));
    }

    try {
      return await Future.any([
        perform(),
        if (cancellation != null)
          cancellation._cancelled.future.then<Object?>((_) {
            throw const AssistantFailure(AssistantFailureKind.cancelled);
          }),
      ]).timeout(timeout);
    } on AssistantFailure {
      rethrow;
    } on AgentServiceStopped {
      rethrow;
    } on TimeoutException {
      throw const AssistantFailure(AssistantFailureKind.timeout);
    } on FormatException {
      throw const AssistantFailure(AssistantFailureKind.invalidResponse);
    } catch (_) {
      throw const AssistantFailure(AssistantFailureKind.network);
    } finally {
      ended = true;
      client?.close(force: true);
    }
  }

  static Uri? _validateEndpoint(Uri? endpoint, bool allowInsecureLoopback) {
    try {
      return validateServiceEndpoint(
        endpoint,
        allowInsecureLoopback: allowInsecureLoopback,
      );
    } on FormatException {
      throw const AssistantFailure(AssistantFailureKind.unconfigured);
    }
  }
}
