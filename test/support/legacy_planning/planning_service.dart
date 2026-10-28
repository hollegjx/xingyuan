import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:habit_checkin/features/planning/domain/daily_plan.dart';

abstract interface class PlanningService {
  bool get available;
  String get destination;
  Future<List<PlanTask>> generate(PlanningRequest request);
}

class UnconfiguredPlanningService implements PlanningService {
  @override
  bool get available => false;
  @override
  String get destination => '';
  @override
  Future<List<PlanTask>> generate(PlanningRequest request) async =>
      throw const PlanningException('AI 服务尚未连接，未发送任何内容。');
}

class HttpPlanningService implements PlanningService {
  HttpPlanningService({
    required this.endpoint,
    required this.token,
    required this.destination,
    this.timeout = const Duration(seconds: 60),
  });

  final Uri endpoint;
  final String token;
  @override
  final String destination;
  final Duration timeout;
  @override
  bool get available => true;

  @override
  Future<List<PlanTask>> generate(PlanningRequest request) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      return await (() async {
        final outgoing = await client.postUrl(endpoint);
        outgoing.followRedirects = false;
        outgoing.headers.contentType = ContentType.json;
        outgoing.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        outgoing.write(jsonEncode(request.toJson()));
        final response = await outgoing.close();
        if (response.statusCode != 200) {
          throw PlanningException(switch (response.statusCode) {
            401 || 403 => 'AI 服务认证失败，未创建目标。',
            429 => 'AI 调用额度已用完或服务繁忙，请稍后再试。',
            400 || 422 => 'AI 未返回有效计划，请调整需求后重试。',
            _ => 'AI 服务暂时不可用，未创建目标。',
          });
        }
        return parsePlanTasks(
          jsonDecode(await readPlanningBody(response)),
          request.availableMinutes,
        );
      })().timeout(timeout);
    } on PlanningException {
      rethrow;
    } on TimeoutException {
      throw const PlanningException('生成超时，未创建目标。重试可能产生新的调用费用。');
    } catch (_) {
      throw const PlanningException('未能取得有效计划，请检查连接后重试。');
    } finally {
      client.close(force: true);
    }
  }
}

Future<String> readPlanningBody(
  Stream<List<int>> stream, {
  int limit = 32768,
}) async {
  final bytes = <int>[];
  await for (final chunk in stream) {
    if (bytes.length + chunk.length > limit) {
      throw const PlanningException('响应内容过长，未创建目标。');
    }
    bytes.addAll(chunk);
  }
  return utf8.decode(bytes);
}
