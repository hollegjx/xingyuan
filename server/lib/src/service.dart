import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:xingyuan_core/xingyuan_core.dart';

import 'agent_protocol.dart';
import 'agent_runner.dart';
import 'device_registry.dart';
import 'journal_rate_limit.dart';
import 'model_client.dart';

class AssistantService {
  AssistantService({
    required this.devices,
    required this.turn,
    required this.summarize,
    this.analyzeDay,
    this.polishNote,
    this.generateDiary,
    this.agent,
    JournalRateLimit? journalRateLimit,
    required this.log,
    this.readTimeout = const Duration(seconds: 10),
  }) : journalRateLimit = journalRateLimit ?? JournalRateLimit();
  final DeviceRegistry devices;
  final Future<ModelResult<TurnResponse>> Function(TurnRequest) turn;
  final Future<ModelResult<SummaryResponse>> Function(SummaryRequest) summarize;
  final Future<ModelResult<DayAnalysisResponse>> Function(DayAnalysisRequest)?
  analyzeDay;
  final Future<ModelResult<PolishNoteResponse>> Function(PolishNoteRequest)?
  polishNote;
  final Future<ModelResult<GenerateDiaryResponse>> Function(
    GenerateDiaryRequest,
  )?
  generateDiary;
  final JournalRateLimit journalRateLimit;
  final AgentRunner? agent;
  final void Function(Map<String, Object?>) log;
  final Duration readTimeout;
  final Map<String, int> _active = {};

  Future<void> handle(HttpRequest incoming) async {
    final watch = Stopwatch()..start();
    String? requestId;
    String? device;
    var status = 500;
    var reserved = false;
    var journalReserved = false;
    var inputBytes = 0;
    var attempts = 0;
    StreamSubscription<List<int>>? bodySubscription;
    Map<String, int> usage = {};
    Map<String, Object?> agentMetadata = {};
    final route =
        [
          '/v1/turn',
          '/v1/summarize',
          '/v1/analyze-day',
          '/v1/polish-note',
          '/v1/generate-diary',
          '/v1/agent/turn',
          '/v1/health',
        ].contains(incoming.uri.path)
        ? incoming.uri.path
        : 'unknown';
    final agentRoute = route == '/v1/agent/turn';
    final bodyLimit = agentRoute ? agentBodyLimit - 1 : assistantBodyLimit;
    Future<void> respond(int code, Map<String, Object?> body) async {
      status = code;
      try {
        incoming.response.statusCode = code;
        incoming.response.headers.contentType = ContentType.json;
        incoming.response.headers.set(
          HttpHeaders.cacheControlHeader,
          'no-store',
        );
        if (code != 200) incoming.response.persistentConnection = false;
        incoming.response.write(jsonEncode(body));
        await incoming.response.close();
      } on HttpException {
        // The client or reverse proxy may have already closed the connection.
      } on SocketException {
        // Keep the outcome, without logging the transport error or request data.
      }
    }

    try {
      if (incoming.headers['origin'] != null) {
        await respond(403, {'error': 'browser_origin_rejected'});
        return;
      }
      if (route == '/v1/health' && incoming.method == 'GET') {
        await respond(200, {'protocol': assistantProtocol, 'status': 'ok'});
        return;
      }
      if (![
            '/v1/turn',
            '/v1/summarize',
            '/v1/analyze-day',
            '/v1/polish-note',
            '/v1/generate-diary',
            '/v1/agent/turn',
          ].contains(route) ||
          incoming.method != 'POST') {
        await respond(404, {'error': 'not_found'});
        return;
      }
      device = await devices.authenticate(
        incoming.headers[HttpHeaders.authorizationHeader]?.singleOrNull,
      );
      if (device == null) {
        await respond(401, {'error': 'unauthorized'});
        return;
      }
      if ((_active[device] ?? 0) >= 2) {
        await respond(429, {'error': 'device_busy'});
        return;
      }
      if (incoming.contentLength > bodyLimit) {
        // Without a listener, dart:io drains the entire declared body before
        // sending headers. Reject now even if a limiting proxy stops uploading.
        bodySubscription = incoming.listen((_) {}, onError: (Object _) {});
        await respond(413, {'error': 'request_too_large'});
        return;
      }
      if (incoming.headers.contentType?.mimeType != 'application/json') {
        await respond(400, {'error': 'invalid_content_type'});
        return;
      }
      if (route == '/v1/polish-note' || route == '/v1/generate-diary') {
        if (!journalRateLimit.reserve(device, route)) {
          await respond(429, {'error': 'journal_rate_limited'});
          return;
        }
        journalReserved = true;
      }
      _active.update(device, (count) => count + 1, ifAbsent: () => 1);
      reserved = true;
      final bytes = <int>[];
      final bodyRead = Completer<void>();
      bodySubscription = incoming.listen(
        (chunk) {
          if (bodyRead.isCompleted) return;
          if (bytes.length + chunk.length > bodyLimit) {
            bodyRead.completeError(const _Oversized());
          } else {
            bytes.addAll(chunk);
          }
        },
        onError: (Object error, StackTrace stack) {
          if (bodyRead.isCompleted) return;
          bodyRead.completeError(
            error is HttpException || error is SocketException
                ? const _Interrupted()
                : error,
            stack,
          );
        },
        onDone: () {
          if (!bodyRead.isCompleted) bodyRead.complete();
        },
      );
      await bodyRead.future.timeout(readTimeout);
      inputBytes = bytes.length;
      final payload = decodeAssistantJson(utf8.decode(bytes));
      Map<String, Object?> result;
      if (agentRoute) {
        final runner = agent;
        if (runner == null) {
          await respond(503, {'error': 'agent_unavailable'});
          return;
        }
        final request = AgentRequest.fromJson(payload);
        final generated = await runner.turn(device, request);
        attempts = 1;
        usage = generated.usage;
        result = generated.body;
        agentMetadata = {
          'kind': generated.settlement.outcome.kind,
          'tool': generated.settlement.outcome.call?.name,
          'stop_code': generated.settlement.outcome.code,
          'round': generated.settlement.calls,
          'charged_tokens': generated.settlement.tokens,
          'budget_violation': generated.settlement.violation,
        };
      } else if (route == '/v1/turn') {
        final request = TurnRequest.fromJson(payload);
        requestId = request.requestId;
        final generated = await turn(request);
        attempts = generated.attempts;
        usage = generated.usage;
        result = TurnResponse.fromJson(
          generated.value.toJson(),
          request: request,
        ).toJson();
      } else if (route == '/v1/summarize') {
        final request = SummaryRequest.fromJson(payload);
        requestId = request.requestId;
        final generated = await summarize(request);
        attempts = generated.attempts;
        usage = generated.usage;
        result = SummaryResponse.fromJson(
          generated.value.toJson(),
          requestId: request.requestId,
        ).toJson();
      } else if (route == '/v1/analyze-day') {
        final request = DayAnalysisRequest.fromJson(payload);
        requestId = request.requestId;
        final analyze = analyzeDay;
        if (analyze == null) {
          await respond(503, {'error': 'analysis_unavailable'});
          return;
        }
        final generated = await analyze(request);
        attempts = generated.attempts;
        usage = generated.usage;
        result = DayAnalysisResponse.fromJson(
          generated.value.toJson(),
          request: request,
        ).toJson();
      } else if (route == '/v1/polish-note') {
        final request = PolishNoteRequest.fromJson(payload);
        requestId = request.requestId;
        final polish = polishNote;
        if (polish == null) {
          await respond(503, {'error': 'journal_unavailable'});
          return;
        }
        final generated = await polish(request);
        attempts = generated.attempts;
        usage = generated.usage;
        result = PolishNoteResponse.fromJson(
          generated.value.toJson(),
          request: request,
        ).toJson();
      } else {
        final request = GenerateDiaryRequest.fromJson(payload);
        requestId = request.requestId;
        final generate = generateDiary;
        if (generate == null) {
          await respond(503, {'error': 'journal_unavailable'});
          return;
        }
        final generated = request.hasMaterial
            ? await generate(request)
            : ModelResult(GenerateDiaryResponse.insufficient(request), 0, {});
        attempts = generated.attempts;
        usage = generated.usage;
        result = GenerateDiaryResponse.fromJson(
          generated.value.toJson(),
          request: request,
        ).toJson();
      }
      if (utf8.encode(jsonEncode(result)).length > bodyLimit) {
        throw const FormatException();
      }
      await respond(200, result);
    } on AgentFailure catch (error) {
      agentMetadata = {'kind': 'stopped', 'stop_code': error.code};
      await respond(error.status, {
        'protocol': agentProtocol,
        'kind': 'stopped',
        'code': error.code,
      });
    } on _Oversized {
      await respond(413, {'error': 'request_too_large'});
    } on TimeoutException {
      await respond(400, {'error': 'request_read_timeout'});
    } on _Interrupted {
      await respond(400, {'error': 'request_interrupted'});
    } on ModelFailure catch (error) {
      attempts = error.attempts;
      await respond(error.status, {'error': error.code});
    } on FormatException {
      await respond(400, {'error': 'invalid_request'});
    } catch (_) {
      try {
        await respond(500, {'error': 'service_error'});
      } catch (_) {}
    } finally {
      // Cancel after responding: canceling an unfinished HttpRequest first can
      // close the socket before the client receives the timeout/size response.
      await bodySubscription?.cancel();
      if (journalReserved) journalRateLimit.release(device!, route);
      if (reserved) {
        final left = (_active[device] ?? 1) - 1;
        if (left == 0) {
          _active.remove(device);
        } else {
          _active[device!] = left;
        }
      }
      log({
        'time': DateTime.now().toUtc().toIso8601String(),
        if (!agentRoute &&
            route != '/v1/polish-note' &&
            route != '/v1/generate-diary') ...{
          'request_id': requestId,
          'device': device,
        },
        'route': route,
        'status': status,
        'elapsed_ms': watch.elapsedMilliseconds,
        if (agentRoute ||
            route == '/v1/polish-note' ||
            route == '/v1/generate-diary')
          'input_bytes': inputBytes,
        ...agentMetadata,
        'usage': usage,
        'retried': attempts > 1,
      });
    }
  }
}

class _Oversized implements Exception {
  const _Oversized();
}

class _Interrupted implements Exception {
  const _Interrupted();
}
