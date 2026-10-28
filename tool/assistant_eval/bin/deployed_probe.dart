import 'dart:convert';
import 'dart:io';

import 'package:xingyuan_assistant_eval/cases.dart';
import 'package:xingyuan_core/xingyuan_core.dart';
import 'package:xingyuan_server/src/model_client.dart';

Future<void> main(List<String> args) async {
  final home = Platform.environment['HOME'];
  var tokenPath = '$home/.config/xingyuan/p1-device-token';
  var truncated = false;
  var revoked = false;
  var readingPlan = false;
  var legacyMemory = false;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--token-file':
        if (++i == args.length || args[i].startsWith('--')) {
          throw const FormatException('Missing private token file');
        }
        tokenPath = args[i];
      case '--schedule-truncated':
        truncated = true;
      case '--revoked':
        revoked = true;
      case '--reading-plan':
        readingPlan = true;
      case '--legacy-memory':
        legacyMemory = true;
      default:
        throw const FormatException('Unknown probe argument');
    }
  }
  final tokenFile = File(tokenPath);
  if ((await tokenFile.stat()).mode & 0x3f != 0) {
    throw const FormatException('Private token file required');
  }
  final token = (await tokenFile.readAsString()).trim();
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  final run = DateTime.now().toUtc().millisecondsSinceEpoch.toString();
  final results = <Map<String, Object?>>[];
  final report = File('../../build/assistant-eval/deployed-$run.json');
  final request = TurnRequest.fromJson({
    'protocol': assistantProtocol,
    'request_id': 'deploy-$run',
    'now': {
      'date': '2026-10-20',
      'time': '21:00',
      'weekday': 2,
      'time_zone': 'Asia/Shanghai',
    },
    'summary': null,
    'messages': [
      {'role': 'user', 'text': '你好，今天只聊聊，不需要规划。'},
    ],
    'settings': {'auto_memory': true},
    if (truncated) 'schedule': [],
    if (truncated) 'schedule_truncated': true,
    if (legacyMemory)
      'memories': [
        for (final (index, text) in ['A${' ' * 199}', ' ' * 200, 'B'].indexed)
          {
            'id': 'legacy-$index',
            'category': '偏好',
            'text': text,
            'expires_on': null,
          },
      ],
  });
  Future<(int, Object?)> send(
    String path, {
    String? credential,
    bool authorized = true,
    String? origin,
    Object? body,
    String? raw,
    bool get = false,
  }) async {
    final outgoing = await client.openUrl(
      get ? 'GET' : 'POST',
      Uri.https('assistant.example.invalid', path),
    );
    outgoing.followRedirects = false;
    outgoing.headers.contentType = ContentType.json;
    if (authorized) {
      outgoing.headers.set('authorization', 'Bearer ${credential ?? token}');
    }
    if (origin != null) outgoing.headers.set('origin', origin);
    if (!get) {
      outgoing.add(utf8.encode(raw ?? jsonEncode(body ?? request.toJson())));
    }
    final response = await outgoing.close().timeout(
      const Duration(seconds: 90),
    );
    final text = await readBoundedBody(response)
        .timeout(const Duration(seconds: 10));
    return (
      response.statusCode,
      response.statusCode == 200 ? decodeAssistantJson(text) : null,
    );
  }

  void record(String name, bool pass, Object status) {
    final row = <String, Object?>{
      'check': name,
      'pass': pass,
      'status': status,
    };
    results.add(row);
    report.writeAsStringSync(
      jsonEncode({
        'time': DateTime.now().toUtc().toIso8601String(),
        'request_prefix': 'deploy-$run',
        'legacy_memory': legacyMemory,
        'results': results,
      }),
    );
    stdout.writeln(jsonEncode(row));
    if (!pass) exitCode = 1;
  }

  try {
    if (revoked) {
      final result = await send('/v1/turn');
      record('revoked', result.$1 == 401, result.$1);
      return;
    }
    final health = await send('/v1/health', get: true, authorized: false);
    record(
      'health',
      health.$1 == 200 && (health.$2 as Map)['protocol'] == assistantProtocol,
      health.$1,
    );
    final missing = await send('/v1/turn', authorized: false);
    record('missing-token', missing.$1 == 401, missing.$1);
    final wrong = await send('/v1/turn', credential: 'synthetic-invalid');
    record('wrong-token', wrong.$1 == 401, wrong.$1);
    final origin = await send('/v1/turn', origin: 'https://browser.invalid');
    record('origin', origin.$1 == 403, origin.$1);
    final large = await send('/v1/turn', raw: 'x' * (assistantBodyLimit + 1));
    record('body-limit', large.$1 == 413, large.$1);
    final normal = await send('/v1/turn');
    final reply = normal.$1 == 200
        ? TurnResponse.fromJson(normal.$2, request: request)
        : null;
    record(
      truncated ? 'real-turn-truncated-schedule' : 'real-turn',
      normal.$1 == 200 && reply?.plan == null,
      normal.$1,
    );
    if (legacyMemory) {
      record('legacy-memory-whitespace', reply != null, normal.$1);
    }
    if (readingPlan) {
      final sample = evaluationCases().singleWhere((row) => row.id == 'C07-03');
      final readingRequest = TurnRequest.fromJson({
        ...sample.request.toJson(),
        'request_id': 'deploy-$run-reading',
      });
      final reading = await send('/v1/turn', body: readingRequest.toJson());
      final plan = reading.$1 == 200
          ? TurnResponse.fromJson(reading.$2, request: readingRequest)
          : null;
      record(
        'original-reading-plan',
        plan != null && checkResult(sample, plan, soft: false).isEmpty,
        reading.$1,
      );
    }
    final summaryId = 'deploy-$run-summary';
    final summary = await send(
      '/v1/summarize',
      body: {
        'protocol': assistantProtocol,
        'request_id': summaryId,
        'summary': null,
        'messages': [
          {'role': 'user', 'text': '合成场景：周三加班，周四晚上想读书。'},
        ],
      },
    );
    final summarized = summary.$1 == 200
        ? SummaryResponse.fromJson(summary.$2, requestId: summaryId)
        : null;
    record('real-summary', summarized != null, summary.$1);
    final concurrent = [
      for (var i = 0; i < 3; i++)
        send(
          '/v1/turn',
          body: {
            ...request.toJson(),
            'request_id': 'deploy-$run-concurrent-$i',
          },
        ),
    ];
    final statuses = <int>[];
    for (final future in concurrent) {
      statuses.add((await future).$1);
    }
    statuses.sort();
    record('concurrency-two', statuses.join(',') == '200,200,429', statuses);
  } catch (_) {
    record('probe-error', false, 'transport-or-validation');
  } finally {
    client.close(force: true);
    stdout.writeln('Report: ${report.absolute.path}');
  }
}
