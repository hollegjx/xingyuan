import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:xingyuan_core/xingyuan_core.dart' show agentTools, CalendarDate;

import '../../../app/theme.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../journal/domain/journal_entry.dart';
import '../../journal/presentation/journal_editor_page.dart';
import '../../../shared/presentation.dart';
import '../../../shared/ui/sparkle.dart';
import '../domain/agent_run_metadata.dart';
import 'assistant_settings_page.dart';

/// Data-status banners plus a collapsible step list of one agent run: which
/// tool ran, how it ended and how long it took. Never shows tool contents.
class AgentRunDetails extends StatefulWidget {
  const AgentRunDetails({
    required this.metadata,
    required this.scope,
    super.key,
  });
  final AgentRunMetadata metadata;
  final String scope;

  @override
  State<AgentRunDetails> createState() => _AgentRunDetailsState();
}

class _AgentRunDetailsState extends State<AgentRunDetails> {
  // A run in progress shows its steps as they happen; a finished one keeps
  // them folded under a one-line summary.
  late bool _open = widget.scope == 'running';
  bool _openingSettings = false;

  Future<void> _settings() async {
    if (_openingSettings) return;
    _openingSettings = true;
    try {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const AssistantSettingsPage()),
      );
    } finally {
      _openingSettings = false;
    }
  }

  Map<String, String> _dataMessages(AgentRunMetadata metadata) {
    const conflictTools = {
      'find_free_slots',
      'validate_plan',
      'submit_plan_draft',
    };
    final unauthorized = metadata.trace
        .where((row) => row.status == 'not_authorized')
        .map((row) => row.tool)
        .toSet();
    final switches = [
      if (unauthorized.contains('query_schedule') ||
          unauthorized.any(conflictTools.contains))
        '「发送已有安排」',
      if (unauthorized.contains('get_planning_preferences')) '「发送记忆」',
    ];
    // C39 changes display only; persisted statuses and wire results stay intact.
    return {
      for (final entry in agentDataMessages.entries)
        if (metadata.statuses.contains(entry.key) &&
            (metadata.readReceipts.isEmpty ||
                metadata.trace.any(
                  (row) =>
                      agentTools.contains(row.tool) && row.status == entry.key,
                )) &&
            (entry.key != 'partial' ||
                metadata.trace.any(
                  (row) =>
                      row.status == 'partial' &&
                      conflictTools.contains(row.tool),
                )))
          entry.key: entry.key == 'not_authorized' && switches.isNotEmpty
              ? '本轮未获${switches.join('、')}授权，相关内容未纳入规划。'
              : entry.value,
    };
  }

  @override
  void didUpdateWidget(AgentRunDetails oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scope != widget.scope) _open = widget.scope == 'running';
  }

  /// What the run looked at, in plain words: "看过日程，找了空档".
  static String _digest(List<AgentTraceEntry> trace) {
    final words = <String>[];
    for (final row in trace) {
      final word = switch (row.tool) {
        'get_planning_preferences' => '读了偏好',
        'query_schedule' => '看过日程',
        'find_free_slots' => '找了空档',
        'get_day_summary' => '读取回顾',
        'get_journal_text' => '读取记录',
        'create_diary_draft' => '准备日记建议',
        _ => '查了冲突',
      };
      if (!words.contains(word)) words.add(word);
    }
    return words.join('，');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final xy = context.xy;
    final metadata = widget.metadata;
    final scope = widget.scope;
    final seconds =
        metadata.trace.fold<int>(0, (sum, row) => sum + row.milliseconds) /
        1000;
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final small = theme.textTheme.bodySmall?.copyWith(color: xy.muted);
    final arrow = Icon(CupertinoIcons.chevron_right, size: 12, color: xy.faint);
    final steps = _open
        ? Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < metadata.trace.length; i++)
                  _Step(
                    key: ValueKey('agent-trace-$scope-$i'),
                    tool: metadata.trace[i].tool,
                    status: metadata.trace[i].status,
                    milliseconds: metadata.trace[i].milliseconds,
                    last: i == metadata.trace.length - 1,
                  ),
              ],
            ),
          )
        : const SizedBox(width: double.infinity);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (metadata.recordHistoryWithheld)
          const Text(
            '为了保护你的记录，这一轮只发送你刚才说的话；之前读过记录的对话没有一起发送。',
            key: ValueKey('assistant-record-history-withheld'),
          ),
        if (metadata.assistantFallback) ...[
          const Text(
            '现在的星愿服务还不支持读取记录。想用今天写日记，可以打开今天的日记，点底部的「AI 写日记」。',
            key: ValueKey('assistant-capability-fallback'),
          ),
          TextButton(
            key: ValueKey('assistant-fallback-open-diary-$scope'),
            onPressed: () => openJournalEditor(
              context,
              kind: JournalKind.diary,
              day: ProviderScope.containerOf(context)
                  .read(clockProvider)
                  .read()
                  .day,
            ),
            child: const Text('打开今天的日记'),
          ),
        ],
        for (var i = 0; i < metadata.readReceipts.length; i++)
          Text(
            _recordReceipt(metadata.readReceipts[i]),
            key: ValueKey('assistant-read-receipt-$scope-$i'),
          ),
        for (final entry in _dataMessages(metadata).entries)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Material(
              type: MaterialType.transparency,
              child: NoticeBanner(
                key: ValueKey('agent-data-$scope-${entry.key}'),
                tone: NoticeTone.warning,
                message: entry.value,
                action: entry.key == 'not_authorized' ? '去打开' : null,
                onAction: entry.key == 'not_authorized' ? _settings : null,
              ),
            ),
          ),
        if (metadata.trace.isNotEmpty) ...[
          Align(
            alignment: Alignment.centerLeft,
            child: Semantics(
              button: true,
              expanded: _open,
              // The row sits on whatever is behind it, but still owns its ink.
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(
                  key: ValueKey('agent-trace-$scope'),
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => setState(() => _open = !_open),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 44),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const StarMark(lit: true, size: 13, glow: false),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Wrap(
                            spacing: 6,
                            runSpacing: 2,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(
                                scope == 'running'
                                    ? '已完成'
                                    : _digest(metadata.trace),
                                style: small,
                              ),
                              Text(
                                '${metadata.trace.length} 步 · '
                                '${seconds.toStringAsFixed(1)} 秒',
                                style: small?.copyWith(
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 4),
                        if (still)
                          RotatedBox(quarterTurns: _open ? 1 : 0, child: arrow)
                        else
                          AnimatedRotation(
                            turns: _open ? 0.25 : 0,
                            duration: const Duration(milliseconds: 200),
                            child: arrow,
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (still)
            steps
          else
            AnimatedSize(
              alignment: Alignment.topCenter,
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              child: steps,
            ),
        ],
      ],
    );
  }
}

/// One tool step on a thin timeline: outcome dot, name, and time taken.
class _Step extends StatelessWidget {
  const _Step({
    required this.tool,
    required this.status,
    required this.milliseconds,
    required this.last,
    super.key,
  });

  final String tool;
  final String status;
  final int milliseconds;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final xy = context.xy;
    final ok = status == 'ok';
    final (IconData mark, Color tone) = switch (status) {
      'ok' => (CupertinoIcons.checkmark_alt, theme.colorScheme.primary),
      'failed' => (CupertinoIcons.xmark, theme.colorScheme.error),
      'not_authorized' => (CupertinoIcons.lock_fill, xy.muted),
      'duplicate' => (CupertinoIcons.arrow_uturn_left, xy.muted),
      _ => (CupertinoIcons.exclamationmark, xy.warning),
    };
    final stacked = MediaQuery.textScalerOf(context).scale(14) > 22;
    final elapsed = Text(
      '${(milliseconds / 1000).toStringAsFixed(1)} 秒',
      style: theme.textTheme.bodySmall?.copyWith(
        color: xy.muted,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 18,
            child: Column(
              children: [
                Container(
                  width: 18,
                  height: 18,
                  margin: const EdgeInsets.only(top: 1),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: tone.withValues(alpha: 0.14),
                  ),
                  child: Icon(mark, size: 11, color: tone),
                ),
                if (!last)
                  Expanded(
                    child: Container(
                      width: 1,
                      margin: const EdgeInsets.symmetric(vertical: 3),
                      color: xy.line,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: last ? 2 : 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    agentToolLabels[tool] ?? tool,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: ok ? xy.muted : theme.colorScheme.onSurface,
                    ),
                  ),
                  if (!ok)
                    Text(
                      agentStatusLabels[status] ?? status,
                      style: theme.textTheme.bodySmall?.copyWith(color: tone),
                    ),
                  if (stacked) elapsed,
                ],
              ),
            ),
          ),
          if (!stacked) ...[const SizedBox(width: 8), elapsed],
        ],
      ),
    );
  }
}

String _recordReceipt(Map<String, dynamic> receipt) {
  final date = CalendarDate.parse(receipt['day'] as String);
  final day = '${date.month}月${date.day}日';
  if (receipt['status'] == 'not_authorized') {
    return switch (receipt['reason']) {
      'disabled' => '“按请求读取”已关闭，可以在 AI 设置里打开',
      'denied' => '你选择了不读取，我只根据你说的内容来写',
      'context_disabled' => '相关的发送选项已关闭，可以在 AI 设置里打开',
      _ => '这次没有允许读取这些记录',
    };
  }
  if (receipt['status'] == 'failed') return '没能读取 $day 的记录，请稍后再试';
  final lines = <String>[];
  for (final kind in receipt['kinds'] as List) {
    final count =
        (receipt['counts'] as Map?)?[kind] as int? ?? receipt['count'] as int;
    if (count == 0) {
      lines.add(
        receipt['status'] == 'truncated'
            ? '内容较多，这次还没读到这类文字'
            : kind == 'quickNote'
            ? '$day 没有随手记'
            : kind == 'diary'
            ? '$day 还没有保存的日记'
            : '$day 没有完成记录',
      );
    } else {
      lines.add(switch (kind) {
        'quickNote' => '已读取 $day 的 $count 条随手记',
        'diary' => '已读取 $day 的日记',
        _ => '已读取 $day 的完成情况',
      });
    }
  }
  return '${lines.join('\n')}${receipt['status'] == 'truncated' ? '（内容较多，只读了前面一部分）' : ''}';
}
