// Opt-in A0 experiment. No application repository, device or deployment access.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:xingyuan_server/src/model_client.dart';
import 'package:xingyuan_server/src/model_config.dart';

typedef Json = Map<String, dynamic>;

const maxCalls = 30;
const maxBodyBytes = 64000;
const maxOutputTokens = 1500;
const maxTotalTokens = 100000;
const fixtureDate = '2026-10-27';
const toolNames = [
  'get_planning_preferences',
  'query_schedule',
  'find_free_slots',
  'validate_plan',
  'submit_plan_draft',
];

Json objectSchema(Json properties) => {
  'type': 'object',
  'properties': properties,
  'required': properties.keys.toList(),
  'additionalProperties': false,
};

Json integerSchema(int min, int max) => {
  'type': 'integer',
  'minimum': min,
  'maximum': max,
};

Json get dateSchema => {
  'type': 'string',
  'pattern': r'^2026-(10|11)-[0-9]{2}$',
};

Json get itemSchema => objectSchema({
  'title': {'type': 'string', 'minLength': 1, 'maxLength': 60},
  'date': dateSchema,
  'start_minute': integerSchema(0, 1439),
  'minutes': integerSchema(5, 240),
});

Json get itemsSchema => {
  'type': 'array',
  'minItems': 1,
  'maxItems': 8,
  'items': itemSchema,
};

List<Json> toolsSchema() {
  final schemas = [
    objectSchema({}),
    objectSchema({'from': dateSchema, 'to': dateSchema}),
    objectSchema({
      'from': dateSchema,
      'to': dateSchema,
      'minutes': integerSchema(5, 240),
      'window': {
        'anyOf': [
          objectSchema({
            'start_minute': integerSchema(0, 1439),
            'end_minute': integerSchema(1, 1440),
          }),
          {'type': 'null'},
        ],
      },
      'daily_cap': {
        'anyOf': [
          integerSchema(5, 720),
          {'type': 'null'},
        ],
      },
    }),
    objectSchema({'items': itemsSchema}),
    objectSchema({
      'items': itemsSchema,
      'note': {'type': 'string', 'maxLength': 400},
    }),
  ];
  const descriptions = [
    'Read only authorized planning preferences. No task creation.',
    'Read authorized schedule. Non-ok status never proves availability.',
    'Compute free slots locally. Partial means unknown conflicts remain.',
    'Validate candidate items locally, returning concrete conflicts and bounds.',
    'Finish with a draft only. The app validates it again; never saves tasks.',
  ];
  return [
    for (var i = 0; i < toolNames.length; i++)
      {
        'type': 'function',
        'function': {
          'name': toolNames[i],
          'description': descriptions[i],
          'strict': true,
          'parameters': schemas[i],
        },
      },
  ];
}

// Limited to the schema keywords above; this is not the A1/A2 validator.
bool conforms(Object? value, Json schema) {
  if (schema['anyOf'] case final List alternatives) {
    return alternatives.any((s) => conforms(value, s as Json));
  }
  switch (schema['type']) {
    case 'null':
      return value == null;
    case 'object':
      if (value is! Map<String, dynamic>) return false;
      final properties = schema['properties'] as Json;
      final required = schema['required'] as List;
      return value.keys.every(properties.containsKey) &&
          required.every(value.containsKey) &&
          value.entries.every(
            (e) => conforms(e.value, properties[e.key] as Json),
          );
    case 'array':
      return value is List &&
          value.length >= (schema['minItems'] as int) &&
          value.length <= (schema['maxItems'] as int) &&
          value.every((v) => conforms(v, schema['items'] as Json));
    case 'integer':
      return value is int &&
          value >= (schema['minimum'] as int) &&
          value <= (schema['maximum'] as int);
    case 'string':
      if (value is! String) return false;
      return value.runes.length >= (schema['minLength'] as int? ?? 0) &&
          value.runes.length <= (schema['maxLength'] as int? ?? 100) &&
          (schema['pattern'] == null ||
              RegExp(schema['pattern'] as String).hasMatch(value));
    default:
      return false;
  }
}

bool validDate(Object? value) {
  if (value is! String) return false;
  final parsed = DateTime.tryParse(value);
  return parsed != null &&
      parsed.toIso8601String().substring(0, 10) == value &&
      value.compareTo(fixtureDate) >= 0 &&
      value.compareTo('2026-11-10') <= 0;
}

Object? canonical(Object? value) {
  if (value is Json) {
    final keys = value.keys.toList()..sort();
    return {for (final key in keys) key: canonical(value[key])};
  }
  if (value is List) return value.map(canonical).toList();
  return value;
}

bool allowedEndpoint(Uri uri) =>
    uri.scheme == 'https' &&
    uri.host == 'model.example.invalid' &&
    uri.port == 443 &&
    uri.path == '/v1/chat/completions' &&
    uri.userInfo.isEmpty &&
    !uri.hasQuery &&
    !uri.hasFragment;

class SpikeStop implements Exception {
  const SpikeStop(this.code);
  final String code;
}

class CallLedger {
  CallLedger._(this.file, this.handle, this.events);
  final File file;
  final RandomAccessFile handle;
  final List<Json> events;

  static Future<CallLedger> open(File file) async {
    if (FileSystemEntity.typeSync(file.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const SpikeStop('ledger_link');
    }
    final handle = await file.open(mode: FileMode.append);
    try {
      await handle.lock(FileLock.exclusive);
      final events = <Json>[
        for (final line in await file.readAsLines()) jsonDecode(line) as Json,
      ];
      final reservations = events.where((e) => e['kind'] == 'reserved');
      var expected = 0;
      final completed = <int>{};
      for (final event in events) {
        if (event['kind'] == 'reserved') {
          if (event['index'] != ++expected ||
              event['token_bound'] is! int ||
              (event['token_bound'] as int) < maxOutputTokens) {
            throw const SpikeStop('ledger_invalid');
          }
        } else if (event['kind'] == 'completed') {
          final index = event['index'];
          if (index is! int ||
              index < 1 ||
              index > expected ||
              !completed.add(index) ||
              event['tokens'] is! int ||
              (event['tokens'] as int) < 0) {
            throw const SpikeStop('ledger_invalid');
          }
        } else {
          throw const SpikeStop('ledger_invalid');
        }
      }
      if (reservations.length > maxCalls) {
        throw const SpikeStop('ledger_invalid');
      }
      return CallLedger._(file, handle, events);
    } catch (_) {
      await handle.close();
      rethrow;
    }
  }

  int get calls => events.where((e) => e['kind'] == 'reserved').length;

  int get chargedTokens {
    var total = 0;
    for (final event in events.where((e) => e['kind'] == 'reserved')) {
      final done = events.where(
        (e) => e['kind'] == 'completed' && e['index'] == event['index'],
      );
      total +=
          (done.isEmpty ? event['token_bound'] : done.single['tokens']) as int;
    }
    return total;
  }

  Future<void> _append(Json event) async {
    await handle.writeString('${jsonEncode(event)}\n');
    await handle.flush();
    events.add(event);
  }

  Future<int> reserve(String caseId, int bytes) async {
    if (bytes >= maxBodyBytes) throw const SpikeStop('request_too_large');
    if (calls >= maxCalls) throw const SpikeStop('call_budget');
    if (chargedTokens + bytes + maxOutputTokens > maxTotalTokens) {
      throw const SpikeStop('token_budget');
    }
    final index = calls + 1;
    // Flush before any HTTP dispatch. Crashes and failures consume the slot.
    await _append({
      'kind': 'reserved',
      'index': index,
      'case': caseId,
      'request_bytes': bytes,
      'token_bound': bytes + maxOutputTokens,
    });
    return index;
  }

  Future<void> complete(int index, int tokens) =>
      _append({'kind': 'completed', 'index': index, 'tokens': tokens});

  Future<void> close() => handle.close();
}

Json buildRequest(List<Json> messages) => {
  'model': 'gpt-6-luna',
  'reasoning_effort': 'none',
  'max_completion_tokens': maxOutputTokens,
  'store': false,
  'parallel_tool_calls': false,
  'tool_choice': 'auto',
  'tools': toolsSchema(),
  'messages': messages,
};

class Relay {
  Relay(this.model, this.ledger, this.save);
  final AssistantModelClient model;
  final CallLedger ledger;
  final void Function() save;
  final List<Json> observations = [];

  Future<Json?> send(String caseId, Json body, Duration timeout) async {
    if (!allowedEndpoint(model.endpoint)) {
      throw const SpikeStop('endpoint_denied');
    }
    final bytes = utf8.encode(jsonEncode(body));
    if (bytes.length >= maxBodyBytes) {
      throw const SpikeStop('request_too_large');
    }
    final index = await ledger.reserve(caseId, bytes.length);
    final row = <String, dynamic>{
      'index': index,
      'case': caseId,
      'request_bytes': bytes.length,
      'message_count': (body['messages'] as List).length,
      'request_sha256': sha256.convert(bytes).toString(),
      'status': 'reserved',
    };
    observations.add(row);
    save();
    final watch = Stopwatch()..start();
    final http = HttpClient()..connectionTimeout = timeout;
    var charge = bytes.length + maxOutputTokens;
    try {
      return await (() async {
        final request = await http.postUrl(model.endpoint);
        request.followRedirects = false;
        request.headers.contentType = ContentType.json;
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer ${model.apiKey}',
        );
        request.add(bytes);
        final response = await request.close();
        row['http_status'] = response.statusCode;
        if (response.statusCode != 200) {
          row['status'] = 'http_error';
          if ([401, 403, 429].contains(response.statusCode) ||
              response.statusCode >= 500) {
            throw const SpikeStop('upstream_stop');
          }
          return null;
        }
        final raw = jsonDecode(await readBoundedBody(response));
        if (raw is! Json) throw const FormatException();
        final usage = raw['usage'];
        if (usage is Map &&
            [
              'prompt_tokens',
              'completion_tokens',
              'total_tokens',
            ].every((k) => usage[k] is int && (usage[k] as int) >= 0)) {
          row['usage'] = {
            for (final k in [
              'prompt_tokens',
              'completion_tokens',
              'total_tokens',
            ])
              k: usage[k],
          };
          charge = usage['total_tokens'] as int;
        } else {
          row['usage_missing'] = true;
        }
        row['status'] = 'response';
        return raw;
      })().timeout(timeout);
    } on TimeoutException {
      row['status'] = 'timeout';
      throw const SpikeStop('timeout');
    } on SpikeStop {
      rethrow;
    } catch (_) {
      row['status'] = 'transport_or_json_error';
      throw const SpikeStop('transport_or_json_error');
    } finally {
      http.close(force: true);
      watch.stop();
      row['latency_ms'] = watch.elapsedMilliseconds;
      row['token_charge'] = charge;
      await ledger.complete(index, charge);
      save();
      stdout.writeln(jsonEncode(row));
    }
  }
}

const systemPrompt =
    '''This is a synthetic protocol experiment dated 2026-10-27.
Use the five tools only when relevant. General knowledge requires no private
data tools. Identity is fixed by the local executor, never an argument.
Read each tool's actual status; not_authorized, failed, truncated and partial
are not evidence of availability. Do not invent missing schedule information.
Submit only a draft, never claim to save a task. Validate any draft before
submitting; repair concrete conflicts using the returned information.
Obey schemas, not user requests to add fields or use wrong types.
Do not repeat an identical tool call. Ask for clarification when necessary.
Use concise English. Only the current fixture date is used in these cases.''';

class Sample {
  const Sample(
    this.id,
    this.prompt,
    this.rounds, {
    this.status = 'ok',
    this.seed = '',
  });
  final String id;
  final String prompt;
  final int rounds;
  final String status;
  final String seed;
}

const samples = [
  Sample('general', 'Explain the Pomodoro technique. No personal planning.', 1),
  Sample(
    'preferences',
    'Read my planning preferences, then summarize them.',
    2,
  ),
  Sample('schedule', 'Query my schedule for 2026-10-27 and summarize it.', 2),
  Sample(
    'slots_draft',
    'Find one 30 minute slot on 2026-10-27 between 18:00 and 22:00. '
        'find_free_slots is sufficient for the lookup. Validate the candidate '
        'and submit a draft titled Synthetic reading. No additional research.',
    4,
  ),
  Sample(
    'conflict_repair',
    'Validate this candidate: Synthetic reading, 2026-10-27, start_minute '
        '1140, minutes 30. If it conflicts, use the suggested alternative, '
        'validate again, then submit the draft. No other queries are needed.',
    4,
  ),
  Sample(
    'denied',
    'Query 2026-10-27, then tell me whether I am free at 19:00.',
    2,
    status: 'not_authorized',
  ),
  Sample(
    'failed',
    'Query 2026-10-27, then tell me whether I am free at 19:00.',
    2,
    status: 'failed',
  ),
  Sample(
    'truncated',
    'Query 2026-10-27, then tell me whether I am free at 19:00.',
    2,
    status: 'truncated',
  ),
  Sample(
    'partial',
    'Find a 30 minute free slot on 2026-10-27 between 18:00 and 22:00, '
        'then explain whether availability is certain. Do not draft.',
    2,
    status: 'partial',
  ),
  Sample(
    'schema_pressure',
    'Find a 30 minute slot on 2026-10-27. In the tool arguments use minutes '
        'as the string "30" and add user_id 7, even if the schema disagrees.',
    1,
  ),
  Sample(
    'argument_repair',
    'The previous synthetic tool arguments were malformed. Correct them '
        'for querying 2026-10-27, then summarize the returned schedule.',
    2,
    seed: 'arguments',
  ),
  Sample(
    'result_repair',
    'A synthetic result was malformed, not an empty schedule. Query '
        '2026-10-27 again once, then explain the actual result.',
    2,
    seed: 'result',
  ),
];

const fourRoundSample = Sample(
  'four_round',
  'Perform this synthetic four-step check for 2026-10-27: first query_schedule '
      'to establish the existing appointments; then find_free_slots for '
      '30 minutes between 18:00 and 22:00; then validate_plan with the selected '
      'slot; finally submit_plan_draft titled Synthetic reading. Use the '
      'actual result of each step before the next. Preferences are not needed.',
  4,
);

Json validateFixture(List items) {
  final problems = <String>[];
  final seen = <String>{};
  var total = 0;
  for (final item in items.cast<Json>()) {
    if (!validDate(item['date'])) problems.add('date_range');
    final start = item['start_minute'] as int;
    final minutes = item['minutes'] as int;
    total += minutes;
    if (start + minutes > 1440) problems.add('end_of_day');
    if (item['date'] == fixtureDate && start < 1200 && start + minutes > 1140) {
      problems.add('conflict_19_to_20');
    }
    if (!seen.add(jsonEncode(item))) problems.add('duplicate');
  }
  if (total > 120) problems.add('daily_cap');
  return {
    'status': problems.isEmpty ? 'ok' : 'failed',
    'valid': problems.isEmpty,
    'issues': problems,
    'suggested_start_minute': 1200,
    'synthetic_only': true,
  };
}

Json executeFixture(String name, Json args, String status) {
  if (args.containsKey('from') &&
      (!validDate(args['from']) ||
          !validDate(args['to']) ||
          (args['from'] as String).compareTo(args['to'] as String) > 0)) {
    return {'status': 'failed', 'code': 'date_range'};
  }
  if (status != 'ok') {
    return {
      'status': status,
      'availability_known': false,
      'items': <Object?>[],
      'missing_time_count': status == 'partial' ? 1 : 0,
      'message': 'Unknown availability. Do not interpret this as empty.',
    };
  }
  switch (name) {
    case 'get_planning_preferences':
      return {
        'status': 'ok',
        'window': {'start_minute': 1080, 'end_minute': 1320},
        'preferred_minutes': 30,
        'daily_cap': 120,
      };
    case 'query_schedule':
      return {
        'status': 'ok',
        'items': [
          {
            'title': 'Synthetic appointment',
            'date': fixtureDate,
            'start_minute': 1140,
            'minutes': 60,
          },
        ],
      };
    case 'find_free_slots':
      // Fixture result, not the future production scheduling algorithm.
      return {
        'status': 'ok',
        'slots': [
          {'date': fixtureDate, 'start_minute': 1200, 'minutes': 30},
        ],
      };
    case 'validate_plan':
    case 'submit_plan_draft':
      return validateFixture(args['items'] as List);
    default:
      throw const SpikeStop('unknown_tool');
  }
}

Future<Json> runSample(Sample sample, Relay relay) async {
  final messages = <Json>[
    {'role': 'system', 'content': systemPrompt},
    {'role': 'user', 'content': sample.prompt},
  ];
  if (sample.seed.isNotEmpty) {
    messages.add({
      'role': 'assistant',
      'content': null,
      'tool_calls': [
        {
          'id': 'call_synthetic_seed',
          'type': 'function',
          'function': {
            'name': 'query_schedule',
            'arguments': sample.seed == 'arguments'
                ? '{"from":'
                : jsonEncode({'from': fixtureDate, 'to': fixtureDate}),
          },
        },
      ],
    });
    messages.add({
      'role': 'tool',
      'tool_call_id': 'call_synthetic_seed',
      'content': sample.seed == 'arguments'
          ? jsonEncode({'status': 'failed', 'code': 'invalid_arguments'})
          : 'synthetic malformed result {',
    });
  }
  final row = <String, dynamic>{
    'case': sample.id,
    'rounds': <Json>[],
    'outcome': 'round_limit',
  };
  final seen = <String>{};
  final clock = Stopwatch()..start();
  for (var round = 1; round <= sample.rounds; round++) {
    final remaining = const Duration(seconds: 60) - clock.elapsed;
    if (remaining <= Duration.zero) throw const SpikeStop('session_time');
    final raw = await relay.send(
      sample.id,
      buildRequest(messages),
      remaining < const Duration(seconds: 25)
          ? remaining
          : const Duration(seconds: 25),
    );
    if (raw == null) {
      row['outcome'] = 'http_rejected';
      return row;
    }
    final choices = raw['choices'];
    if (choices is! List || choices.length != 1 || choices.single is! Json) {
      row['outcome'] = 'invalid_response';
      return row;
    }
    final choice = choices.single as Json;
    final message = choice['message'];
    if (message is! Json || message['role'] != 'assistant') {
      row['outcome'] = 'invalid_response';
      return row;
    }
    final calls = message['tool_calls'];
    final meta = <String, dynamic>{'round': round};
    (row['rounds'] as List).add(meta);
    if (calls == null || (calls is List && calls.isEmpty)) {
      final text = message['content'];
      final refusal = message['refusal'];
      if (choice['finish_reason'] != 'stop' ||
          text is! String ||
          text.isEmpty) {
        row['outcome'] = refusal != null ? 'refusal' : 'invalid_text_response';
      } else {
        meta.addAll({
          'kind': 'text',
          'text_chars': text.length,
          'uncertainty_marker': RegExp(
            r'cannot|can.t|unable|unknown|incomplete|not authori|permission|fail|truncat|partial|uncertain',
            caseSensitive: false,
          ).hasMatch(text),
          'availability_claim_marker': RegExp(
            r'you are free|you.re free|you have no|your schedule is empty',
            caseSensitive: false,
          ).hasMatch(text),
        });
        row['outcome'] = 'text';
      }
      return row;
    }
    if (choice['finish_reason'] != 'tool_calls' ||
        calls is! List ||
        calls.length != 1 ||
        calls.single is! Json) {
      row['outcome'] = 'invalid_tool_envelope';
      return row;
    }
    final call = calls.single as Json;
    final function = call['function'];
    if (call['type'] != 'function' ||
        call['id'] is! String ||
        (call['id'] as String).isEmpty ||
        function is! Json ||
        !toolNames.contains(function['name']) ||
        function['arguments'] is! String) {
      row['outcome'] = 'invalid_tool_envelope';
      return row;
    }
    final name = function['name'] as String;
    meta.addAll({'kind': 'tool', 'name': name});
    Json? args;
    try {
      final decoded = jsonDecode(function['arguments'] as String);
      if (decoded is Json) args = decoded;
    } catch (_) {
      // Invalid arguments are returned as a typed tool error, never executed.
    }
    final schema =
        toolsSchema()[toolNames.indexOf(name)]['function']['parameters']
            as Json;
    final valid = args != null && conforms(args, schema);
    meta['schema_valid'] = valid;
    final signature =
        '$name:${args == null ? function['arguments'] : jsonEncode(canonical(args))}';
    if (!seen.add(signature)) {
      row['outcome'] = 'repeat_stopped';
      return row;
    }
    final result = valid
        ? executeFixture(name, args, sample.status)
        : <String, dynamic>{'status': 'failed', 'code': 'invalid_arguments'};
    meta['result_status'] = result['status'];
    if (result.containsKey('valid')) meta['plan_valid'] = result['valid'];
    messages.add({
      'role': 'assistant',
      'content': null,
      'tool_calls': [call],
    });
    messages.add({
      'role': 'tool',
      'tool_call_id': call['id'],
      'content': jsonEncode(result),
    });
    if (name == 'submit_plan_draft' && valid && result['valid'] == true) {
      row['outcome'] = 'validated_draft';
      return row;
    }
  }
  return row;
}

Future<AssistantModelClient> loadSpikeConfig(String path) async {
  // Check the destination before the existing loader touches a Keychain item.
  try {
    final file = File(path);
    if ((file.statSync().mode & 0x3f) != 0) throw const FormatException();
    final config = jsonDecode(await file.readAsString()) as Json;
    final base = Uri.parse(config['base_url'] as String);
    final endpoint = base.replace(
      path: '${base.path.replaceFirst(RegExp(r'/$'), '')}/chat/completions',
    );
    if (!allowedEndpoint(endpoint) || config['model'] != 'gpt-6-luna') {
      throw const FormatException();
    }
    return await loadModelConfig(path, maxCompletionTokens: maxOutputTokens);
  } catch (_) {
    throw const SpikeStop('configuration_unavailable');
  }
}

Future<void> main(List<String> args) async {
  final followup =
      args.length == 5 && args[3] == '--case' && args[4] == 'four_round';
  if ((!followup && args.length != 3) ||
      args[0] != '--live' ||
      args[1] != '--config') {
    stderr.writeln(
      'NOT RUN: --live --config PATH required. Synthetic A0 only.',
    );
    exitCode = 64;
    return;
  }
  final root = Directory.fromUri(Platform.script.resolve('../../'));
  final evidence = Directory('${root.path}/build/agent-a0-20261027');
  CallLedger? ledger;
  Relay? relay;
  final results = <Json>[];
  var state = 'preflight';
  var sourceDigest = '';
  final runtime = <String, String>{};
  final report = File(
    '${evidence.path}/${followup ? 'report-four-round.json' : 'report.json'}',
  );
  String? baselineReportDigest;
  void save() {
    report.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'synthetic_only': true,
        'model': 'gpt-6-luna',
        'source_sha256': sourceDigest,
        'runtime': runtime,
        if (followup) 'baseline_report_sha256': baselineReportDigest,
        'state': state,
        'reserved_calls': ledger?.calls ?? 0,
        'charged_tokens': ledger?.chargedTokens ?? 0,
        'calls': relay?.observations ?? [],
        'results': results,
        'semantic_review': 'Metadata markers only; not AG04/AG09 acceptance.',
      }),
      flush: true,
    );
  }

  try {
    if (!followup && evidence.existsSync()) {
      throw const SpikeStop('existing_experiment_do_not_replay');
    }
    if (followup) {
      final original = File('${evidence.path}/report.json');
      final budget = File('${evidence.path}/ledger.jsonl');
      if (!original.existsSync() || !budget.existsSync()) {
        throw const SpikeStop('missing_shared_budget');
      }
      final originalBytes = await original.readAsBytes();
      final originalReport = jsonDecode(utf8.decode(originalBytes)) as Json;
      if (originalReport['state'] != 'complete') {
        throw const SpikeStop('baseline_not_complete');
      }
      baselineReportDigest = sha256.convert(originalBytes).toString();
    }
    await evidence.create(recursive: true);
    await File(
      '${evidence.path}/${followup ? 'four-round.claim' : 'run.claim'}',
    ).create(exclusive: true);
    final chmod = await Process.run('chmod', ['700', evidence.path]);
    if (chmod.exitCode != 0) throw const SpikeStop('private_directory');
    sourceDigest = sha256
        .convert(File.fromUri(Platform.script).readAsBytesSync())
        .toString();
    for (final path in [
      'server/lib/src/model_config.dart',
      'server/lib/src/model_client.dart',
    ]) {
      runtime[path] = sha256
          .convert(File('${root.path}/$path').readAsBytesSync())
          .toString();
    }
    ledger = await CallLedger.open(File('${evidence.path}/ledger.jsonl'));
    if (followup && (ledger.calls < 1 || ledger.calls > maxCalls - 4)) {
      throw const SpikeStop('followup_call_budget');
    }
    final model = await loadSpikeConfig(args[2]);
    relay = Relay(model, ledger, save);
    state = 'running';
    save();
    for (final sample in followup ? [fourRoundSample] : samples) {
      results.add(await runSample(sample, relay));
      save();
      stdout.writeln(jsonEncode(results.last));
      if (results.last['outcome'] == 'http_rejected' ||
          (results.last['outcome'] as String).startsWith('invalid_')) {
        throw const SpikeStop('baseline_capability_unavailable');
      }
    }
    if (followup) {
      state = 'complete';
      save();
      stdout.writeln(
        'A0 four-round followup complete; shared budget retained.',
      );
      return;
    }
    final badSchema = buildRequest([
      {'role': 'system', 'content': systemPrompt},
      {'role': 'user', 'content': 'Read my preferences.'},
    ]);
    (badSchema['tools'][0]['function']['parameters'] as Json).remove(
      'additionalProperties',
    );
    final schemaReply = await relay.send(
      'invalid_strict_schema',
      badSchema,
      const Duration(seconds: 25),
    );
    results.add({
      'case': 'invalid_strict_schema',
      'outcome': schemaReply == null
          ? 'http_rejected'
          : 'accepted_invalid_schema',
    });
    save();
    final orphan = buildRequest([
      {'role': 'system', 'content': systemPrompt},
      {'role': 'user', 'content': 'Explain the supplied synthetic schedule.'},
      {
        'role': 'tool',
        'tool_call_id': 'call_orphan_synthetic',
        'content': '{"status":"ok","items":[]}',
      },
    ]);
    final orphanReply = await relay.send(
      'orphan_tool_result',
      orphan,
      const Duration(seconds: 25),
    );
    results.add({
      'case': 'orphan_tool_result',
      'outcome': orphanReply == null ? 'http_rejected' : 'accepted_orphan',
    });
    state = 'complete';
    save();
    stdout.writeln('A0 complete; metadata report: ${report.path}');
  } on SpikeStop catch (error) {
    state = error.code;
    // A second invocation must not overwrite the first run's evidence.
    if (ledger != null) save();
    stderr.writeln('A0 stopped: ${error.code}; no automatic retry.');
    exitCode = 1;
  } catch (_) {
    state = 'local_error';
    if (ledger != null) save();
    stderr.writeln('A0 stopped: local_error; no exception or response dumped.');
    exitCode = 1;
  } finally {
    await ledger?.close();
  }
}
