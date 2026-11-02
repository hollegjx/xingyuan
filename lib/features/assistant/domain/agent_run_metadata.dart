import 'dart:convert';

import 'package:xingyuan_core/xingyuan_core.dart';

export 'package:xingyuan_core/xingyuan_core.dart' show agentDataMessages;

const agentToolLabels = {
  'get_planning_preferences': '读取规划偏好',
  'query_schedule': '查询安排',
  'find_free_slots': '寻找空档',
  'validate_plan': '检查候选计划',
  'submit_plan_draft': '检查最终草稿',
  'get_day_summary': '读取当天回顾',
  'get_journal_text': '读取记录文字',
  'create_diary_draft': '准备日记建议',
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

String agentUnknownScheduleMessage(Map<String, dynamic> issue) {
  final reference = issue['with'];
  if (reference is Map<String, dynamic> &&
      reference['title'] is String &&
      reference['start_minute'] is int) {
    return '可能和「${reference['title']}」${formatMinute(reference['start_minute'] as int)} 冲突';
  }
  return '无法完整判断此项的冲突';
}

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
    List<Map<String, dynamic>> readReceipts = const [],
    this.assistantFallback = false,
    this.recordHistoryWithheld = false,
  }) : readReceipts = List.unmodifiable(
         readReceipts.map((r) => Map<String, dynamic>.unmodifiable(r)),
       ),
       statuses = Set.unmodifiable(statuses),
       trace = List.unmodifiable(trace),
       partial = Set.unmodifiable(partial),
       dailyCaps = Map.unmodifiable(dailyCaps);
  final CalendarDate date;
  final List<Map<String, dynamic>> readReceipts;
  final bool assistantFallback;
  final bool recordHistoryWithheld;
  final Set<String> statuses;
  final List<AgentTraceEntry> trace;
  final Set<int> partial;
  final Map<String, int> dailyCaps;
  List<String> get banners => agentDataBanners(
    readReceipts.isEmpty
        ? statuses
        : statuses.where(
            (status) => trace.any(
              (row) => agentTools.contains(row.tool) && row.status == status,
            ),
          ),
  );
  String encode() => jsonEncode({
    'date': date.key,
    'statuses': statuses.toList()..sort(),
    'trace': trace.map((row) => row.toJson()).toList(),
    'partial': partial.toList()..sort(),
    'daily_caps': dailyCaps,
    if (readReceipts.isNotEmpty) 'read_receipts': readReceipts,
    if (assistantFallback) 'assistant_fallback': true,
    if (recordHistoryWithheld) 'record_history_withheld': true,
  });
  factory AgentRunMetadata.decode(String text) {
    final decoded = decodeAssistantJson(text);
    final map = agentObject(decoded, {
      'date',
      'statuses',
      'trace',
      'partial',
      'daily_caps',
      if (decoded is Map && decoded.containsKey('read_receipts'))
        'read_receipts',
      if (decoded is Map && decoded.containsKey('record_history_withheld'))
        'record_history_withheld',
      if (decoded is Map && decoded.containsKey('assistant_fallback'))
        'assistant_fallback',
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
      if (!assistantAgentTools.contains(value['tool']) ||
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
    if (map.containsKey('record_history_withheld') &&
        map['record_history_withheld'] != true) {
      throw const FormatException('Invalid history notice');
    }
    final rawReceipts = map['read_receipts'] ?? const [];
    if (rawReceipts is! List ||
        rawReceipts.length > 6 ||
        (map.containsKey('assistant_fallback') &&
            map['assistant_fallback'] != true)) {
      throw const FormatException('Invalid read receipts');
    }
    final receipts = <Map<String, dynamic>>[];
    for (final raw in rawReceipts) {
      final r = agentObject(raw, {
        'day',
        'kinds',
        'count',
        'status',
        'cached',
        if (raw is Map && raw.containsKey('reason')) 'reason',
        if (raw is Map && raw.containsKey('counts')) 'counts',
      });
      assistantRecordDay(r['day'], date);
      if (r['kinds'] is! List ||
          (r['kinds'] as List).isEmpty ||
          (r['kinds'] as List).length > 2 ||
          (r['kinds'] as List).any(
            (k) => !['summary', 'quickNote', 'diary'].contains(k),
          ) ||
          r['count'] is! int ||
          (r['count'] as int) < 0 ||
          (r['count'] as int) > 60 ||
          ![
            'ok',
            'truncated',
            'failed',
            'not_authorized',
          ].contains(r['status']) ||
          r['cached'] is! bool ||
          (['failed', 'not_authorized'].contains(r['status']) &&
              r['count'] != 0)) {
        throw const FormatException('Invalid read receipt');
      }
      if (r['reason'] != null &&
          ![
            'disabled',
            'denied',
            'scope',
            'context_disabled',
          ].contains(r['reason'])) {
        throw const FormatException('Invalid receipt reason');
      }
      if (r.containsKey('counts')) {
        final counts = agentObject(
          r['counts'],
          (r['kinds'] as List).cast<String>().toSet(),
        );
        if (counts.values.any((n) => n is! int || n < 0 || n > 60) ||
            counts.values.fold<int>(0, (total, n) => total + (n as int)) !=
                r['count']) {
          throw const FormatException('Invalid receipt counts');
        }
      }
      receipts.add(r);
    }
    return AgentRunMetadata(
      date: date,
      statuses: statuses,
      trace: trace,
      partial: partial,
      dailyCaps: caps,
      readReceipts: receipts,
      assistantFallback: map['assistant_fallback'] == true,
      recordHistoryWithheld: map['record_history_withheld'] == true,
    );
  }
}
