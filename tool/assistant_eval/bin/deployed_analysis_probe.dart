import 'dart:convert';
import 'dart:io';

import 'package:xingyuan_assistant_eval/analysis_cases.dart';
import 'package:xingyuan_core/xingyuan_core.dart';
import 'package:xingyuan_server/src/model_client.dart';

// Explicit live probe using only committed synthetic cases and a private token.
Future<void> main(List<String> args) async {
  if (args.length < 3 ||
      args[0] != '--live' ||
      args[1] != '--token-file' ||
      args.length > 4 ||
      (args.length == 4 && args[3] != '--revoked')) {
    stderr.writeln('Usage: --live --token-file /private/qa-token [--revoked]');
    exitCode = 64;
    return;
  }
  final tokenFile = File(args[2]);
  if ((await tokenFile.stat()).mode & 0x3f != 0) {
    throw const FormatException('Private token file required');
  }
  final token = (await tokenFile.readAsString()).trim();
  final revoked = args.contains('--revoked');
  final run = DateTime.now().toUtc().microsecondsSinceEpoch.toString();
  final report = File('../../build/analysis-eval/deployed-$run.json');
  await report.parent.create(recursive: true);
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  final results = <Map<String, Object?>>[];
  var calls = 0;

  Future<(int, Object?)> send(
    Object payload, {
    String? credential,
    bool authorized = true,
    String? origin,
  }) async {
    final outgoing = await client.postUrl(
      Uri.https('assistant.example.invalid', '/v1/analyze-day'),
    );
    outgoing.followRedirects = false;
    outgoing.headers.contentType = ContentType.json;
    if (authorized) {
      outgoing.headers.set('authorization', 'Bearer ${credential ?? token}');
    }
    if (origin != null) outgoing.headers.set('origin', origin);
    outgoing.add(utf8.encode(jsonEncode(payload)));
    final response = await outgoing.close().timeout(
      const Duration(seconds: 90),
    );
    final body = await readBoundedBody(response)
        .timeout(const Duration(seconds: 10));
    return (
      response.statusCode,
      response.statusCode == 200 ? decodeAssistantJson(body) : null,
    );
  }

  void record(String check, bool passed, Object status, {Object? output}) {
    final row = <String, Object?>{
      'check': check,
      'passed': passed,
      'status': status,
      'synthetic_output': ?output,
    };
    results.add(row);
    report.writeAsStringSync(
      jsonEncode({
        'run': run,
        'model_requests': calls,
        'results': results,
        'all_passed': results.every((row) => row['passed'] == true),
      }),
    );
    stdout.writeln(
      jsonEncode({'check': check, 'passed': passed, 'status': status}),
    );
    if (!passed) exitCode = 1;
  }

  try {
    final sample = analysisCases().first;
    final payload = sample.request.toJson();
    if (revoked) {
      final response = await send(payload);
      record('revoked', response.$1 == 401, response.$1);
      return;
    }
    final missing = await send(payload, authorized: false);
    record('missing-token', missing.$1 == 401, missing.$1);
    final wrong = await send(payload, credential: 'synthetic-invalid');
    record('wrong-token', wrong.$1 == 401, wrong.$1);
    final origin = await send(payload, origin: 'https://browser.invalid');
    record('browser-origin', origin.$1 == 403, origin.$1);
    final photos = await send({
      ...payload,
      'photos': ['synthetic-not-a-photo'],
    });
    record('photos-rejected', photos.$1 == 400, photos.$1);
    final large = await send({'text': 'x' * assistantBodyLimit});
    record('size-limit', large.$1 == 413, large.$1);
    for (final sample in [analysisCases().first, analysisCases()[2]]) {
      final request = DayAnalysisRequest.fromJson({
        ...sample.request.toJson(),
        'request_id': 'analysis-deploy-$run-${sample.id}',
      });
      calls++;
      final response = await send(request.toJson());
      final result = response.$1 == 200
          ? DayAnalysisResponse.fromJson(response.$2, request: request)
          : null;
      record(
        sample.id,
        result != null && checkAnalysis(sample, result).isEmpty,
        response.$1,
        output: result?.toJson(),
      );
    }
  } catch (_) {
    record('probe-error', false, 'transport-or-validation');
  } finally {
    client.close(force: true);
    stdout.writeln('Report: ${report.absolute.path}');
  }
}
