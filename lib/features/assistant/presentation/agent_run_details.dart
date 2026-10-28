import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../../../shared/presentation.dart';
import '../domain/agent_run_metadata.dart';

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

  @override
  void didUpdateWidget(AgentRunDetails oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scope != widget.scope) _open = widget.scope == 'running';
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
    final arrow = Icon(CupertinoIcons.chevron_right, size: 15, color: xy.faint);
    final steps = _open
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Divider(height: 0.5, thickness: 0.5, color: xy.line),
              for (var i = 0; i < metadata.trace.length; i++)
                _Step(
                  key: ValueKey('agent-trace-$scope-$i'),
                  tool: metadata.trace[i].tool,
                  status: metadata.trace[i].status,
                  milliseconds: metadata.trace[i].milliseconds,
                  last: i == metadata.trace.length - 1,
                ),
            ],
          )
        : const SizedBox(width: double.infinity);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final status in agentDataMessages.keys)
          if (metadata.statuses.contains(status))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: NoticeBanner(
                key: ValueKey('agent-data-$scope-$status'),
                tone: NoticeTone.warning,
                message: agentDataMessages[status]!,
              ),
            ),
        if (metadata.trace.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Material(
              color: xy.card,
              borderRadius: BorderRadius.circular(xyCardRadius),
              clipBehavior: Clip.antiAlias,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Semantics(
                    button: true,
                    expanded: _open,
                    child: InkWell(
                      key: ValueKey('agent-trace-$scope'),
                      borderRadius: BorderRadius.circular(xyCardRadius),
                      onTap: () => setState(() => _open = !_open),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
                        child: Row(
                          children: [
                            Icon(
                              CupertinoIcons.list_bullet_below_rectangle,
                              size: 18,
                              color: theme.colorScheme.primary,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Wrap(
                                alignment: WrapAlignment.spaceBetween,
                                spacing: 12,
                                runSpacing: 4,
                                children: [
                                  Text(
                                    '过程记录',
                                    style: theme.textTheme.bodyLarge?.copyWith(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  Text(
                                    '${metadata.trace.length} 步 · '
                                    '${seconds.toStringAsFixed(1)} 秒',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: xy.muted,
                                      fontFeatures: const [
                                        FontFeature.tabularFigures(),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 6),
                            if (still)
                              RotatedBox(
                                quarterTurns: _open ? 1 : 0,
                                child: arrow,
                              )
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
              ),
            ),
          ),
      ],
    );
  }
}

/// One tool step: tool icon, its name and outcome, and the time it took.
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

  static const _toolIcons = {
    'get_planning_preferences': CupertinoIcons.slider_horizontal_3,
    'query_schedule': CupertinoIcons.calendar,
    'find_free_slots': CupertinoIcons.clock,
    'validate_plan': CupertinoIcons.checkmark_shield,
    'submit_plan_draft': CupertinoIcons.paperplane,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final xy = context.xy;
    final (IconData mark, Color tone) = switch (status) {
      'ok' => (CupertinoIcons.checkmark_circle_fill, xy.success),
      'failed' => (CupertinoIcons.xmark_circle_fill, theme.colorScheme.error),
      'not_authorized' => (CupertinoIcons.lock_fill, xy.muted),
      'duplicate' => (CupertinoIcons.arrow_uturn_left_circle, xy.muted),
      _ => (CupertinoIcons.exclamationmark_circle_fill, xy.warning),
    };
    final stacked = MediaQuery.textScalerOf(context).scale(14) > 22;
    final elapsed = Text(
      '${(milliseconds / 1000).toStringAsFixed(1)} 秒',
      style: theme.textTheme.bodySmall?.copyWith(
        color: xy.muted,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(14, 10, 14, last ? 12 : 10),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: theme.colorScheme.primary.withValues(alpha: 0.1),
            ),
            child: Icon(
              _toolIcons[tool] ?? CupertinoIcons.circle,
              size: 15,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  agentToolLabels[tool] ?? tool,
                  style: theme.textTheme.bodyMedium,
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(mark, size: 13, color: tone),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        agentStatusLabels[status] ?? status,
                        style: theme.textTheme.bodySmall?.copyWith(color: tone),
                      ),
                    ),
                  ],
                ),
                if (stacked) elapsed,
              ],
            ),
          ),
          if (!stacked) ...[const SizedBox(width: 8), elapsed],
        ],
      ),
    );
  }
}
