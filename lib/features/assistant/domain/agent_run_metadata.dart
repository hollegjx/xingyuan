import 'dart:convert';

import 'package:xingyuan_core/xingyuan_core.dart';

export 'package:xingyuan_core/xingyuan_core.dart' show agentDataMessages;

const agentToolLabels = {
  'get_planning_preferences': '读取规划偏好',
  'query_schedule': '查询安排',
  'find_free_slots': '寻找空档',
  'validate_plan': '检查候选计划',
  'submit_plan_draft': '检查最终草稿',
};
const agentStatusLabels = {
  'ok': '完成',
  'not_authorized': '未授权',
  'failed': '失败',
  'truncated': '部分结果',
  'partial': '无法完整判断',
  'invalid': '需调整',
  'duplicate': '使用本轮缓存',
};

class AgentTraceEntry {
  const AgentTraceEntry(this.tool, this.status, this.milliseconds);
  final String tool;
  final String status;
  final int milliseconds;
  Map<String, dynamic> toJson() => {
    'tool': tool,
    'status': status,
    'duration_ms': milliseconds,
  };
}

class AgentRunMetadata {
  AgentRunMetadata({
    required this.date,
    Iterable<String> statuses = const [],
    Iterable<AgentTraceEntry> trace = const [],
    Iterable<int> partial = const [],
    Map<String, int> dailyCaps = const {},
  }) : statuses = Set.unmodifiable(statuses),
       trace = List.unmodifiable(trace),
       partial = Set.unmodifiable(partial),
       dailyCaps = Map.unmodifiable(dailyCaps);
  final CalendarDate date;
  final Set<String> statuses;
  final List<AgentTraceEntry> trace;
  final Set<int> partial;
  final Map<String, int> dailyCaps;
  List<String> get banners => agentDataBanners(statuses);
  String encode() => jsonEncode({
    'date': date.key,
    'statuses': statuses.toList()..sort(),
    'trace': trace.map((row) => row.toJson()).toList(),
    'partial': partial.toList()..sort(),
    'daily_caps': dailyCaps,
  });
  factory AgentRunMetadata.decode(String text) {
    final map = agentObject(decodeAssistantJson(text), {
      'date',
      'statuses',
      'trace',
      'partial',
      'daily_caps',
    });
    final date = CalendarDate.parse(map['date'] as String);
    if (map['statuses'] is! List ||
        map['trace'] is! List ||
        map['partial'] is! List ||
        map['daily_caps'] is! Map<String, dynamic>) {
      throw const FormatException('Invalid agent metadata');
    }
    final statuses = (map['statuses'] as List).cast<String>();
    if (statuses.length > 6 ||
        statuses.any(
          (s) => !agentStatusLabels.containsKey(s) || s == 'duplicate',
        )) {
      throw const FormatException('Invalid data status');
    }
    final partial = (map['partial'] as List).cast<int>();
    if (partial.length > 14 || partial.any((i) => i < 0 || i >= 14)) {
      throw const FormatException('Invalid partial indexes');
    }
    final trace = <AgentTraceEntry>[];
    for (final row in map['trace'] as List) {
      final value = agentObject(row, {'tool', 'status', 'duration_ms'});
      if (!agentTools.contains(value['tool']) ||
          !agentStatusLabels.containsKey(value['status']) ||
          value['duration_ms'] is! int ||
          (value['duration_ms'] as int) < 0 ||
          (value['duration_ms'] as int) > 60000) {
        throw const FormatException('Invalid trace');
      }
      trace.add(
        AgentTraceEntry(
          value['tool'] as String,
          value['status'] as String,
          value['duration_ms'] as int,
        ),
      );
    }
    if (trace.length > 6) throw const FormatException('Too many tool traces');
    final caps = (map['daily_caps'] as Map<String, dynamic>)
        .cast<String, int>();
    for (final cap in caps.entries) {
      final day = CalendarDate.parse(cap.key);
      if (day.isBefore(date) ||
          day.isAfter(date.addDays(14)) ||
          cap.value < 5 ||
          cap.value > 1440) {
        throw const FormatException('Invalid daily cap');
      }
    }
    return AgentRunMetadata(
      date: date,
      statuses: statuses,
      trace: trace,
      partial: partial,
      dailyCaps: caps,
    );
  }
}
