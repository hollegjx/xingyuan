import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../app/theme.dart';
import '../features/goals/domain/goal.dart';
import 'local_date.dart';
import 'ui/sparkle.dart';

String dateLabel(LocalDate date) => '${date.year}年${date.month}月${date.day}日';

const weekdayLabels = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

String scheduleLabel(GoalKind kind, ScheduleVersion schedule) {
  final timing = schedule.timing.label;
  final rule = _scheduleRuleLabel(kind, schedule);
  return timing.isEmpty ? rule : '$rule · $timing';
}

String _scheduleRuleLabel(GoalKind kind, ScheduleVersion schedule) {
  if (kind == GoalKind.single) {
    return '计划 ${dateLabel(schedule.plannedDay!)}';
  }
  if (schedule.weekdays == 127) return '每天';
  return [
    for (var day = 0; day < 7; day++)
      if ((schedule.weekdays & (1 << day)) != 0) weekdayLabels[day],
  ].join('、');
}

String dayStatusLabel(GoalDayStatus status) => switch (status) {
  GoalDayStatus.notCreated => '尚未创建',
  GoalDayStatus.notScheduled => '不在计划内',
  GoalDayStatus.notRecorded => '未记录',
  GoalDayStatus.completed => '已完成',
  GoalDayStatus.completedEarlier => '此前已完成',
  GoalDayStatus.archived => '已归档',
  GoalDayStatus.future => '尚未到期',
};

Goal? findGoal(List<Goal> goals, int id) {
  for (final goal in goals) {
    if (goal.id == id) return goal;
  }
  return null;
}

void showSaveError(BuildContext context, Object error) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        error is GoalRuleException ? error.message : '未能保存，原有记录未被清空。请重试。',
      ),
    ),
  );
}

PreferredSizeWidget pageAppBar(
  BuildContext context,
  String title, {
  List<Widget>? actions,
}) => XyNavBar(
  title: title,
  actions: actions,
  height: math.max(48, MediaQuery.textScalerOf(context).scale(17) * 1.35 + 18),
);

/// A compact iOS navigation bar: it sits flush with the page at rest and
/// gains bar chrome and a hairline once content scrolls beneath it.
class XyNavBar extends StatefulWidget implements PreferredSizeWidget {
  const XyNavBar({
    required this.title,
    this.actions,
    this.height = 48,
    super.key,
  });

  final String title;
  final List<Widget>? actions;
  final double height;

  @override
  Size get preferredSize => Size.fromHeight(height);

  @override
  State<XyNavBar> createState() => _XyNavBarState();
}

class _XyNavBarState extends State<XyNavBar> {
  ScrollNotificationObserverState? _observer;
  bool _scrolled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _observer?.removeListener(_onScroll);
    _observer = ScrollNotificationObserver.maybeOf(context);
    _observer?.addListener(_onScroll);
  }

  @override
  void dispose() {
    _observer?.removeListener(_onScroll);
    super.dispose();
  }

  void _onScroll(ScrollNotification notification) {
    if (notification is! ScrollUpdateNotification ||
        notification.depth != 0 ||
        notification.metrics.axis != Axis.vertical) {
      return;
    }
    final scrolled = notification.metrics.extentBefore > 0;
    if (scrolled != _scrolled) setState(() => _scrolled = scrolled);
  }

  @override
  Widget build(BuildContext context) {
    return AppBar(
      title: Text(widget.title),
      toolbarHeight: widget.height,
      actions: [...?widget.actions, const SizedBox(width: 4)],
      shape: Border(
        bottom: BorderSide(
          color: _scrolled ? context.xy.line : Colors.transparent,
          width: 0.5,
        ),
      ),
    );
  }
}

class PageScroll extends StatelessWidget {
  const PageScroll({
    required this.children,
    this.controller,
    this.padding = const EdgeInsets.fromLTRB(16, 8, 16, 40),
    super.key,
  });

  final List<Widget> children;
  final ScrollController? controller;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    controller: controller,
    padding: padding,
    child: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    ),
  );
}

/// Defers shared-controller notifications received during a frame's build.
class FrameSafeListenableBuilder extends StatefulWidget {
  const FrameSafeListenableBuilder({
    required this.listenable,
    required this.builder,
    this.child,
    super.key,
  });

  final Listenable listenable;
  final TransitionBuilder builder;
  final Widget? child;

  @override
  State<FrameSafeListenableBuilder> createState() =>
      _FrameSafeListenableBuilderState();
}

class _FrameSafeListenableBuilderState
    extends State<FrameSafeListenableBuilder> {
  bool _queued = false;

  @override
  void initState() {
    super.initState();
    widget.listenable.addListener(_changed);
  }

  @override
  void didUpdateWidget(covariant FrameSafeListenableBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.listenable != widget.listenable) {
      oldWidget.listenable.removeListener(_changed);
      widget.listenable.addListener(_changed);
    }
  }

  void _changed() {
    if (!mounted || _queued) return;
    if (SchedulerBinding.instance.schedulerPhase !=
        SchedulerPhase.persistentCallbacks) {
      setState(() {});
      return;
    }
    // A shared controller can notify while a different route is building.
    _queued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _queued = false;
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    widget.listenable.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, widget.child);
}

/// Empty, loading and error states with space reserved during delayed loading.
class StatusPanel extends StatelessWidget {
  const StatusPanel({
    required this.message,
    this.retry,
    this.loading = false,
    this.detail,
    this.icon,
    this.lit = false,
    super.key,
  });

  final String message;
  final VoidCallback? retry;
  final bool loading;
  final String? detail;
  final IconData? icon;

  /// Shows a lit star instead of an empty one, for finished states.
  final bool lit;

  @override
  Widget build(BuildContext context) {
    final panel = _panel(context);
    // Quick loads finish before this appears, so nothing flashes.
    return loading ? DelayedReveal(child: panel) : panel;
  }

  Widget _panel(BuildContext context) {
    final xy = context.xy;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 44,
            child: Center(
              child: loading
                  ? const XyActivity(radius: 11)
                  : icon != null || retry != null
                  ? Icon(
                      icon ?? CupertinoIcons.wifi_slash,
                      size: 36,
                      color: retry == null ? xy.faint : xy.muted,
                    )
                  : StarMark(lit: lit, size: 36, outline: xy.faint),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            message,
            textAlign: TextAlign.center,
            style: loading
                ? theme.textTheme.bodyMedium?.copyWith(color: xy.muted)
                : theme.textTheme.titleMedium,
          ),
          if (detail case final detail?) ...[
            const SizedBox(height: 6),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: xy.muted),
            ),
          ],
          if (retry != null) ...[
            const SizedBox(height: 18),
            Center(
              child: OutlinedButton.icon(
                onPressed: retry,
                icon: const Icon(CupertinoIcons.arrow_clockwise, size: 18),
                label: const Text('重试'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The platform activity indicator: the iOS spinner on Apple devices.
class XyActivity extends StatelessWidget {
  const XyActivity({this.radius = 9, this.color, super.key});

  final double radius;
  final Color? color;

  @override
  Widget build(BuildContext context) => context.isCupertino
      ? CupertinoActivityIndicator(radius: radius, color: color)
      : SizedBox.square(
          dimension: radius * 2,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: color ?? context.xy.muted,
          ),
        );
}

/// A section heading with an optional count and trailing action.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.title, {this.count, this.trailing, super.key});

  final String title;
  final int? count;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 26, 0, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.end,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (count != null)
                  Text(
                    '$count',
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: context.xy.muted,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

enum NoticeTone { info, warning, error }

/// An inline message that sits in the flow without replacing content.
class NoticeBanner extends StatelessWidget {
  const NoticeBanner({
    required this.message,
    this.tone = NoticeTone.info,
    this.action,
    this.onAction,
    this.actionKey,
    this.icon,
    super.key,
  });

  final String message;
  final NoticeTone tone;
  final String? action;
  final VoidCallback? onAction;
  final Key? actionKey;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final xy = context.xy;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (background, accent, foreground) = switch (tone) {
      NoticeTone.info => (xy.card, scheme.primary, scheme.onSurface),
      NoticeTone.warning => (xy.warningSoft, xy.warning, scheme.onSurface),
      NoticeTone.error => (
        scheme.errorContainer,
        scheme.error,
        scheme.onErrorContainer,
      ),
    };
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(xyButtonRadius),
      ),
      child: Row(
        children: [
          Icon(
            icon ??
                switch (tone) {
                  NoticeTone.info => CupertinoIcons.info_circle,
                  NoticeTone.warning => CupertinoIcons.bell_slash,
                  NoticeTone.error => CupertinoIcons.exclamationmark_circle,
                },
            size: 20,
            color: accent,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(color: foreground),
            ),
          ),
          if (action != null && onAction != null)
            TextButton(
              key: actionKey,
              onPressed: onAction,
              style: TextButton.styleFrom(
                foregroundColor: accent,
                textStyle: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              child: Text(action!),
            )
          else
            const SizedBox(width: 8),
        ],
      ),
    );
  }
}

/// A fixed-size slot for background activity, so refreshing never shifts
/// the layout around it.
class QuietActivity extends StatelessWidget {
  const QuietActivity({required this.active, this.color, super.key});

  final bool active;
  final Color? color;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 18,
    child: AnimatedOpacity(
      opacity: active ? 1 : 0,
      duration: const Duration(milliseconds: 200),
      child: active ? XyActivity(radius: 8, color: color) : null,
    ),
  );
}

/// The iOS large title that opens a top-level tab, with bar buttons above it.
class TabHeader extends StatelessWidget {
  const TabHeader({
    required this.title,
    this.subtitle,
    this.eyebrow,
    this.trailing = const [],
    this.padding = const EdgeInsets.fromLTRB(20, 0, 8, 6),
    super.key,
  });

  final String title;
  final String? subtitle;

  /// A small line above the title, such as today's date.
  final String? eyebrow;
  final List<Widget> trailing;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final xy = context.xy;
    return Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 44,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: trailing,
            ),
          ),
          if (eyebrow case final eyebrow?)
            Text(
              eyebrow,
              style: theme.textTheme.titleSmall?.copyWith(color: xy.muted),
            ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Semantics(
              header: true,
              child: Text(title, style: theme.textTheme.displaySmall),
            ),
          ),
          if (subtitle case final subtitle?)
            Padding(
              padding: const EdgeInsets.only(top: 2, right: 12),
              child: Text(
                subtitle,
                style: theme.textTheme.bodyMedium?.copyWith(color: xy.muted),
              ),
            ),
        ],
      ),
    );
  }
}

/// An iOS inset-grouped section: rows on one rounded card, separated by
/// hairlines, with an optional caption above and note below.
class XyGroup extends StatelessWidget {
  const XyGroup({
    required this.children,
    this.header,
    this.footer,
    this.dividerIndent = 16,
    this.margin = const EdgeInsets.only(top: 24),
    this.color,
    super.key,
  });

  final List<Widget> children;
  final String? header;
  final String? footer;
  final double dividerIndent;
  final EdgeInsetsGeometry margin;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final xy = context.xy;
    final caption = theme.textTheme.bodySmall?.copyWith(color: xy.muted);
    return Padding(
      padding: margin,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (header case final header?)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 7),
              child: Text(header, style: caption),
            ),
          Card(
            color: color,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0) Divider(indent: dividerIndent, height: 0.5),
                  children[i],
                ],
              ],
            ),
          ),
          if (footer case final footer?)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 7, 16, 0),
              child: Text(footer, style: caption),
            ),
        ],
      ),
    );
  }
}

/// An iOS segmented control: a grey track with a raised white thumb.
class XySegmented<T> extends StatelessWidget {
  const XySegmented({
    required this.segments,
    required this.selected,
    required this.onChanged,
    super.key,
  });

  final List<(T, String)> segments;
  final T selected;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final xy = context.xy;
    final dark = theme.brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: xy.fill,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        children: [
          for (final (value, label) in segments)
            Expanded(
              child: Semantics(
                selected: value == selected,
                button: true,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    if (value == selected) return;
                    HapticFeedback.selectionClick().ignore();
                    onChanged(value);
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOut,
                    constraints: const BoxConstraints(minHeight: 32),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 5,
                    ),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: value == selected
                          ? (dark ? const Color(0xFF636366) : Colors.white)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(7),
                      boxShadow: value == selected && !dark
                          ? const [
                              BoxShadow(
                                color: Color(0x1F000000),
                                blurRadius: 8,
                                offset: Offset(0, 3),
                              ),
                            ]
                          : null,
                    ),
                    // Labels keep their natural size and scale down to fit,
                    // as native segments do at large text sizes.
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        label,
                        maxLines: 1,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: value == selected
                              ? FontWeight.w600
                              : FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A grouped row with a label on the left and a control on the right. At
/// large text sizes the control drops below the label instead of
/// squeezing it.
class XyValueRow extends StatelessWidget {
  const XyValueRow({required this.label, required this.value, super.key});

  final Widget label;
  final Widget value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
    child: Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 12,
      runSpacing: 6,
      children: [
        DefaultTextStyle.merge(
          style: Theme.of(context).textTheme.bodyLarge,
          child: label,
        ),
        value,
      ],
    ),
  );
}

/// An iOS-style colored square behind a row icon, as in Settings.
class XyIconTile extends StatelessWidget {
  const XyIconTile(this.icon, {required this.color, super.key});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 30,
    height: 30,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(7),
    ),
    child: Icon(icon, size: 18, color: Colors.white),
  );
}

/// A dialog button: a native iOS action on Apple devices.
class XyDialogAction extends StatelessWidget {
  const XyDialogAction({
    required this.label,
    required this.onPressed,
    this.primary = false,
    this.destructive = false,
    super.key,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool primary;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    if (context.isCupertino) {
      return CupertinoDialogAction(
        onPressed: onPressed,
        isDefaultAction: primary && !destructive,
        isDestructiveAction: destructive,
        child: Text(label),
      );
    }
    if (!primary) {
      return TextButton(onPressed: onPressed, child: Text(label));
    }
    final error = Theme.of(context).colorScheme.error;
    return FilledButton(
      onPressed: onPressed,
      style: destructive
          ? FilledButton.styleFrom(backgroundColor: error)
          : null,
      child: Text(label),
    );
  }
}

/// Asks a yes/no question in a native alert. Returns true only on confirm.
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  String? message,
  Widget? content,
  required String confirm,
  String cancel = '取消',
  Key? confirmKey,
  Key? cancelKey,
  bool destructive = false,
}) async {
  final result = await showAdaptiveDialog<bool>(
    context: context,
    barrierDismissible: true,
    builder: (context) => AlertDialog.adaptive(
      scrollable: true,
      title: Text(title),
      content: content ?? (message == null ? null : Text(message)),
      actions: [
        XyDialogAction(
          key: cancelKey,
          label: cancel,
          onPressed: () => Navigator.pop(context, false),
        ),
        XyDialogAction(
          key: confirmKey,
          label: confirm,
          primary: true,
          destructive: destructive,
          onPressed: () => Navigator.pop(context, true),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// "今天 08:05", "昨天 21:40", "10月3日 07:10" — for feeds and chat.
String momentLabel(DateTime time, {DateTime? now}) {
  final local = time.toLocal();
  final current = (now ?? DateTime.now()).toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  final clock = '${two(local.hour)}:${two(local.minute)}';
  final today = LocalDate.fromDateTime(current);
  final day = LocalDate.fromDateTime(local);
  if (day == today) return '今天 $clock';
  if (day == today.addDays(-1)) return '昨天 $clock';
  if (local.year == current.year) return '${local.month}月${local.day}日 $clock';
  return '${local.year}年${local.month}月${local.day}日 $clock';
}

/// Centered time stamp in a chat: "14:05", "昨天 14:05", "周三 14:05",
/// "10月3日 14:05", "2025年10月3日 14:05".
String chatTimeLabel(DateTime time, {DateTime? now}) {
  final local = time.toLocal();
  final current = (now ?? DateTime.now()).toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  final clock = '${two(local.hour)}:${two(local.minute)}';
  final days = DateTime.utc(
    current.year,
    current.month,
    current.day,
  ).difference(DateTime.utc(local.year, local.month, local.day)).inDays;
  if (days == 0) return clock;
  if (days == 1) return '昨天 $clock';
  if (days > 1 && days < 7) {
    const names = ['一', '二', '三', '四', '五', '六', '日'];
    return '周${names[local.weekday - 1]} $clock';
  }
  if (local.year == current.year) return '${local.month}月${local.day}日 $clock';
  return '${local.year}年${local.month}月${local.day}日 $clock';
}

/// The divider label to show above a chat message, or null when it continues
/// the stretch before it (same day and less than [gap] apart).
String? chatDividerLabel(
  DateTime time,
  DateTime? previous, {
  DateTime? now,
  Duration gap = const Duration(minutes: 30),
}) {
  if (previous != null) {
    final a = previous.toLocal();
    final b = time.toLocal();
    final sameDay = a.year == b.year && a.month == b.month && a.day == b.day;
    if (sameDay && b.difference(a) < gap) return null;
  }
  return chatTimeLabel(time, now: now);
}

/// Small centered time stamp between stretches of a conversation.
class ChatTimeDivider extends StatelessWidget {
  const ChatTimeDivider(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      child: Center(
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.labelSmall
              ?.copyWith(color: context.xy.muted, fontWeight: FontWeight.w500),
        ),
      ),
    );
  }
}

/// Keeps its space but stays invisible for [delay], then fades in.
class DelayedReveal extends StatefulWidget {
  const DelayedReveal({
    required this.child,
    this.delay = const Duration(milliseconds: 350),
    super.key,
  });

  final Widget child;
  final Duration delay;

  @override
  State<DelayedReveal> createState() => _DelayedRevealState();
}

class _DelayedRevealState extends State<DelayedReveal> {
  Timer? _timer;
  bool _shown = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(widget.delay, () {
      if (mounted) setState(() => _shown = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedOpacity(
    opacity: _shown ? 1 : 0,
    duration: const Duration(milliseconds: 200),
    child: widget.child,
  );
}
