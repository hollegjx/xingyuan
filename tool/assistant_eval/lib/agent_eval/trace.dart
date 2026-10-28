import 'dart:convert';

import 'package:xingyuan_server/agent_diagnostics.dart';

import 'fixtures.dart';

const traceChannels = {
  'model',
  'tools',
  'validation',
  'presentation',
  'confirmation',
  'writes',
  'privacy',
  'boundaries',
};
const trajectoryChannels = {
  'model',
  'tools',
  'validation',
  'data_state',
  'confirmation',
  'writes',
  'privacy',
  'boundaries',
};
const toolNames = {
  'get_planning_preferences',
  'query_schedule',
  'find_free_slots',
  'validate_plan',
  'submit_plan_draft',
};
const businessStatuses = {
  'ok',
  'not_authorized',
  'failed',
  'truncated',
  'partial',
  'invalid',
};
const stopReasons = {
  'none',
  'duplicate',
  'round_limit',
  'token_limit',
  'deadline',
  'usage_invalid',
  'cancel',
  'identity',
  'revoked',
  'background',
  'size',
  'protocol',
  'upstream',
};

const rejectionCategories = {
  'multiple_tool_calls',
  'invalid_args',
  'refusal',
  'length',
  'upstream_error',
  'protocol_other',
  'deadline',
  'size',
  'budget',
  'duplicate',
  'cancel',
  'identity',
  'revoked',
  'background',
};

const _eventFields = <String, Set<String>>{
  'model': {
    'bytes',
    'dispatched',
    'reservation',
    'usage',
    'layer',
    'rejection_category',
    'rejection_detail',
  },
  'stop': {'category', 'layer', 'rejection_detail'},
  'data_state': {'statuses', 'messages', 'source'},
  'size_probe': {'bytes', 'reservation', 'code', 'model_calls', 'layer'},
  'tool': {
    'name',
    'call_id',
    'arguments',
    'status',
    'original_status',
    'result',
    'executed',
    'sent',
    'data_revision',
    'necessity',
  },
  'validation': {'digest', 'status', 'phase', 'data_revision', 'issues'},
  'draft': {'items', 'warning_items', 'confirm_enabled'},
  'preview': {'items'},
  'banner': {'status', 'text', 'above_response'},
  'boundary': {'reason'},
  'confirm': {'digest', 'accepted', 'partial_ack'},
  'write': {'digest', 'count', 'receipt', 'valid_rows'},
  'privacy': {'channel', 'leaks'},
  'terminal': {'status', 'reason', 'text'},
};

void _require(bool condition) {
  if (!condition) throw const FormatException('Invalid trajectory schema');
}

bool _hash(Object? value) =>
    value is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(value);

class AgentTrace {
  AgentTrace.fromJson(Json json) : data = object(jsonDecode(jsonEncode(json))) {
    _require(
      data.keys.toSet().difference({
        'case_id',
        'fixture_digest',
        'attempt',
        'channels',
        'protected_before',
        'protected_after',
        'events',
        'assessment',
      }).isEmpty,
    );
    _require(
      data['case_id'] is String &&
          RegExp(r'^S(0[1-9]|1[0-9]|20)$').hasMatch(data['case_id'] as String),
    );
    _require(_hash(data['fixture_digest']));
    _require(data['attempt'] is int && (data['attempt'] as int) > 0);
    _require(data['channels'] is List);
    _require(
      !data.containsKey('assessment') || data['assessment'] == 'trajectory-v1',
    );
    _require(
      (data['channels'] as List).every(
        {...traceChannels, ...trajectoryChannels}.contains,
      ),
    );
    _require(_hash(data['protected_before']) && _hash(data['protected_after']));
    _require(data['events'] is List);
    var lastMs = 0;
    for (final e in events) {
      final fields = _eventFields[e['kind']];
      _require(
        fields != null &&
            e.keys.toSet().difference({'kind', 'ms', ...fields}).isEmpty,
      );
      _require(e['ms'] is int && (e['ms'] as int) >= lastMs);
      lastMs = e['ms'] as int;
      if (e.containsKey('rejection_detail')) {
        _require(
          agentRejectionDetails.contains(e['rejection_detail']) &&
              (e['kind'] == 'stop' || e['rejection_category'] != null),
        );
      }
      switch (e['kind']) {
        case 'model':
          _require(
            !e.containsKey('rejection_category') ||
                e['rejection_category'] == null ||
                rejectionCategories.contains(e['rejection_category']),
          );
          _require(
            !e.containsKey('layer') ||
                {'app_request', 'model_request'}.contains(e['layer']),
          );
          _require(e['bytes'] is int && (e['bytes'] as int) >= 0);
          _require(e['reservation'] is int && (e['reservation'] as int) >= 0);
          _require(e['dispatched'] is bool);
          // Malformed usage is intentionally representable for D2 scoring.
          _require(e.containsKey('usage'));
        case 'stop':
          _require(rejectionCategories.contains(e['category']));
          _require(
            {
              'backend_response',
              'app_loop',
              'app_failure',
              'confirmation',
            }.contains(e['layer']),
          );
        case 'data_state':
          _require(
            e['statuses'] is List &&
                (e['statuses'] as List).every((v) => v is String),
          );
          _require(
            e['messages'] is List &&
                (e['messages'] as List).every((v) => v is String),
          );
          _require({'committed', 'progress'}.contains(e['source']));
        case 'size_probe':
          _require(e['bytes'] is int && (e['bytes'] as int) >= 0);
          _require(e['reservation'] is int && (e['reservation'] as int) >= 0);
          _require(e['model_calls'] is int && (e['model_calls'] as int) >= 0);
          _require(e['code'] is String && e['layer'] == 'model_request');
        case 'tool':
          _require(e['name'] is String && e['call_id'] is String);
          _require(e['arguments'] is Map);
          _require(
            businessStatuses.contains(e['status']) ||
                e['status'] == 'duplicate',
          );
          _require(e['executed'] is bool && e['sent'] is bool);
          _require(e['data_revision'] is String && e.containsKey('result'));
          _require(
            {'necessary', 'unnecessary', 'unknown'}.contains(e['necessity']),
          );
          if (e['status'] == 'duplicate') {
            _require(businessStatuses.contains(e['original_status']));
          }
        case 'validation':
          _require(_hash(e['digest']));
          _require({'ok', 'partial', 'invalid'}.contains(e['status']));
          _require({'candidate', 'final', 'save'}.contains(e['phase']));
          _require(e['data_revision'] is String && e['issues'] is List);
          _require((e['issues'] as List).every((v) => v is String));
        case 'draft':
        case 'preview':
          _require(e['items'] is List && (e['items'] as List).isNotEmpty);
          for (final item in (e['items'] as List).map(object)) {
            _require(
              item.keys.toSet().difference({
                'day',
                'start',
                'minutes',
                'title',
              }).isEmpty,
            );
            _require(
              item['day'] is String &&
                  item['start'] is int &&
                  item['minutes'] is int &&
                  item['title'] is String,
            );
          }
          if (e['kind'] == 'draft') {
            _require(
              e['warning_items'] is List &&
                  (e['warning_items'] as List).every((v) => v is int && v >= 0),
            );
            _require(e['confirm_enabled'] is bool);
          }
        case 'banner':
          _require(
            {
              'partial',
              'truncated',
              'failed',
              'not_authorized',
            }.contains(e['status']),
          );
          _require(e['text'] is String && e['above_response'] is bool);
        case 'boundary':
          _require(
            {
              'cancel',
              'identity',
              'revoked',
              'background',
            }.contains(e['reason']),
          );
        case 'confirm':
          _require(
            _hash(e['digest']) &&
                e['accepted'] is bool &&
                e['partial_ack'] is bool,
          );
        case 'write':
          _require(!e.containsKey('valid_rows') || e['valid_rows'] is bool);
          _require(
            _hash(e['digest']) && e['count'] is int && (e['count'] as int) > 0,
          );
          _require(
            e['receipt'] is String && (e['receipt'] as String).isNotEmpty,
          );
        case 'privacy':
          _require({'outbound', 'log', 'process'}.contains(e['channel']));
          _require(e['leaks'] is int && (e['leaks'] as int) >= 0);
        case 'terminal':
          _require(
            {
              'answer',
              'needs_input',
              'draft',
              'stopped',
              'saved',
            }.contains(e['status']),
          );
          _require(stopReasons.contains(e['reason']) && e['text'] is String);
      }
    }
  }

  final Json data;
  String get caseId => data['case_id'] as String;
  List<Json> get events => (data['events'] as List).map(object).toList();
}

class AgentRunMetadata {
  AgentRunMetadata.fromJson(Json value) : data = Map.of(value) {
    _require(
      value.keys.toSet().difference({
        'product',
        'test',
        'prompt',
        'tool_schema',
        'model',
        'parameters',
        'fixture_version',
        'seed',
        'evidence_kind',
        'scoring_policy',
        'scorer',
      }).isEmpty,
    );
    for (final key in [
      'product',
      'test',
      'prompt',
      'tool_schema',
      'model',
      'parameters',
    ]) {
      _require(_hash(value[key]));
    }
    _require(agentFixtureVersions.contains(value['fixture_version']));
    _require(value['seed'] is int);
    _require(!value.containsKey('scorer') || _hash(value['scorer']));
    _require(
      !value.containsKey('scoring_policy') ||
          value['scoring_policy'] == 'trajectory-v1',
    );
    _require(
      {
        'scripted_trace',
        'app_offline',
        'live',
      }.contains(value['evidence_kind']),
    );
  }
  final Json data;
}

/// Future App adapters implement this boundary; this package has no live driver.
abstract interface class AgentEvaluationDriver {
  AgentRunMetadata get metadata;
  Future<AgentTrace?> run(AgentScenario scenario);
}

class ScriptedTrajectoryDriver implements AgentEvaluationDriver {
  ScriptedTrajectoryDriver.fromJson(Json json)
    : metadata = AgentRunMetadata.fromJson(object(json['metadata'])),
      traces = (json['traces'] as List)
          .map((v) => AgentTrace.fromJson(object(v)))
          .toList() {
    _require(json.keys.toSet().difference({'metadata', 'traces'}).isEmpty);
    _require(metadata.data['evidence_kind'] == 'scripted_trace');
    _require(traces.map((t) => t.caseId).toSet().length == traces.length);
    final policy = metadata.data['scoring_policy'] ?? 'full-evidence-v1';
    _require(
      traces.every(
        (trace) => (trace.data['assessment'] ?? 'full-evidence-v1') == policy,
      ),
    );
  }
  @override
  final AgentRunMetadata metadata;
  final List<AgentTrace> traces;
  @override
  Future<AgentTrace?> run(AgentScenario scenario) async {
    for (final trace in traces) {
      if (trace.caseId == scenario.id) return trace;
    }
    return null;
  }
}
