import 'dart:convert';
import 'dart:io';

import 'package:habit_checkin/features/planning/domain/daily_plan.dart';

import 'planning_service.dart';

typedef GeneratePlan = Future<List<PlanTask>> Function(PlanningRequest request);

class PlanningDevGateway {
  PlanningDevGateway({
    required this.token,
    required this.generate,
    required this.maxCalls,
  }) {
    if (token.length < 32 || maxCalls < 0 || maxCalls > 3) {
      throw ArgumentError('Invalid development gateway configuration');
    }
  }
  final String token;
  final GeneratePlan generate;
  final int maxCalls;
  int calls = 0;
  bool _busy = false;

  Future<void> handle(HttpRequest request) async {
    final response = request.response;
    response.headers.contentType = ContentType.json;
    response.headers.set('Cache-Control', 'no-store');
    var reserved = false;
    try {
      if (request.headers.value('Origin') != null ||
          request.headers.value(HttpHeaders.authorizationHeader) !=
              'Bearer $token') {
        response.statusCode = 401;
      } else if (request.method != 'POST' ||
          request.uri.path != '/plan' ||
          request.uri.query.isNotEmpty) {
        response.statusCode = 404;
      } else if (request.headers.contentType?.mimeType != 'application/json') {
        response.statusCode = 415;
      } else if (_busy || calls >= maxCalls) {
        response.statusCode = 429;
      } else {
        _busy = true;
        reserved = true;
        final body = await readPlanningBody(
          request,
          limit: 16384,
        ).timeout(const Duration(seconds: 10));
        final input = PlanningRequest.fromJson(jsonDecode(body));
        calls++;
        final tasks = validatePlanTasks(
          await generate(input),
          input.availableMinutes,
        );
        response.write(encodePlanTasks(tasks));
      }
    } on PlanningException {
      response.statusCode = 422;
    } on FormatException {
      response.statusCode = 400;
    } catch (_) {
      response.statusCode = 502;
    } finally {
      if (reserved) _busy = false;
      await response.close();
    }
  }
}
