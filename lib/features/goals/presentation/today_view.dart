import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/theme.dart';
import '../../../shared/app_clock.dart';
import '../../../shared/presentation.dart';
import '../../../shared/ui/sky.dart';
import '../../../shared/ui/sparkle.dart';
import '../../../shared/ui/entry_bubbles.dart';
import '../../journal/domain/journal_entry.dart';
import '../../journal/presentation/journal_day_sections.dart';
import '../../journal/presentation/journal_editor_page.dart';
import '../../analysis/presentation/day_analysis_controls.dart';
import '../../reminders/reminder_status_view.dart';
import '../domain/goal.dart';
import 'goal_detail_page.dart';
import 'goal_form_page.dart';
import 'goal_tile.dart';

String greetingFor(int hour) => switch (hour) {
  >= 5 && < 11 => '早上好',
  >= 11 && < 14 => '中午好',
  >= 14 && < 18 => '下午好',
  >= 18 && < 23 => '晚上好',
  _ => '夜深了',
};

class TodayView extends ConsumerStatefulWidget {
  const TodayView({this.onOpenCompanion, super.key});

  /// Switches the home screen to the companion tab.
  final VoidCallback? onOpenCompanion;

  @override
  ConsumerState<TodayView> createState() => _TodayViewState();
}

class _TodayViewState extends ConsumerState<TodayView> {
  final _goalsAnchor = GlobalKey();
  Timer? _highlightTimer;
  bool _highlight = false;

  @override
  void dispose() {
    _highlightTimer?.cancel();
    super.dispose();
  }

  void _newGoal() =>
      Navigator.of(context)
          .push(MaterialPageRoute<int>(builder: (_) => const GoalFormPage()));

  Future<void> _checkIn(List<Goal> goals) async {
    if (goals.isEmpty) {
      _newGoal();
      return;
    }
    final target = _goalsAnchor.currentContext;
    if (target == null) return;
    await Scrollable.ensureVisible(
      target,
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 250),
    );
    if (!mounted) return;
    setState(() => _highlight = true);
    _highlightTimer?.cancel();
    _highlightTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _highlight = false);
    });
  }

  void _open(BuildContext context, Widget page) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

  @override
  Widget build(BuildContext context) {
    final reading = ref.watch(environmentProvider).requireValue;
    final goals = ref.watch(goalsProvider);
    final overview = goals.whenOrNull(
      data: (items) => TodayOverview(items, reading.day),
    );
    final body = goals.when(
      loading: () => [const StatusPanel(message: '正在读取记录', loading: true)],
      error: (error, stack) => [
        StatusPanel(
          message: '无法读取本地记录，原有数据未被清空。',
          retry: () => retryLocalRecords(ref),
        ),
      ],
      data: (items) => _content(context, items, overview!),
    );
    final day = reading.day;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: SingleChildScrollView(
        padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TabHeader(
                  eyebrow:
                      '${day.month}月${day.day}日 ${weekdayLabels[day.weekday - 1]}',
                  title: greetingFor(reading.localTime.hour),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _TodaySummary(reading: reading, overview: overview),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: XyEntryBubbles(
                          entries: todayEntries(
                            context,
                            onCheckIn: goals.asData == null
                                ? null
                                : () => _checkIn(goals.requireValue),
                            onQuickNote: () => openJournalEditor(
                              context,
                              kind: JournalKind.quickNote,
                              day: day,
                            ),
                            onDiary: () => openJournalEditor(
                              context,
                              kind: JournalKind.diary,
                              day: day,
                            ),
                            onNewGoal: _newGoal,
                          ),
                        ),
                      ),
                      // 「打卡」 scrolls here and the section glows briefly.
                      AnimatedContainer(
                        key: _goalsAnchor,
                        duration: MediaQuery.disableAnimationsOf(context)
                            ? Duration.zero
                            : const Duration(milliseconds: 320),
                        curve: Curves.easeOut,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(18),
                          color: Theme.of(context).colorScheme.primary
                              .withValues(alpha: _highlight ? .09 : 0),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const SectionLabel('今天的目标'),
                            // Sections grow and shrink smoothly as stars are
                            // lit.
                            AnimatedSize(
                              alignment: Alignment.topCenter,
                              duration: MediaQuery.disableAnimationsOf(context)
                                  ? Duration.zero
                                  : const Duration(milliseconds: 260),
                              curve: Curves.easeOutCubic,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: body,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (goals.asData != null) JournalDaySections(day: day),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _content(
    BuildContext context,
    List<Goal> goals,
    TodayOverview overview,
  ) {
    Widget group(List<GoalDay> views) => XyGroup(
      margin: EdgeInsets.zero,
      dividerIndent: 60,
      children: [
        for (final view in views)
          GoalTile(
            view: view,
            interactive: true,
            onOpen: () => _open(context, GoalDetailPage(goalId: view.goal.id)),
          ),
      ],
    );
    return [
      const SizedBox(height: 12),
      const ReminderOverview(compact: true),
      if (goals.isEmpty)
        const StatusPanel(message: '还没有目标')
      else if (overview.pending.isEmpty)
        StatusPanel(
          message: overview.completed.isEmpty ? '今天没有待办' : '今天的计划已完成',
          lit: overview.completed.isNotEmpty,
        ),
      if (overview.pending.isNotEmpty) ...[
        SectionLabel('等待点亮', count: overview.pending.length),
        group(overview.pending),
      ],
      if (overview.completed.isNotEmpty) ...[
        SectionLabel('已点亮', count: overview.completed.length),
        group(overview.completed),
      ],
    ];
  }
}

/// Today's progress as a small night-sky card, with the 今日星语 entry.
class _TodaySummary extends StatelessWidget {
  const _TodaySummary({required this.reading, required this.overview});

  final ClockReading reading;
  final TodayOverview? overview;

  @override
  Widget build(BuildContext context) {
    final xy = context.xy;
    final theme = Theme.of(context);
    final overview = this.overview;
    final done = overview?.completed.length ?? 0;
    final waiting = overview?.pending.length ?? 0;
    return SkyPanel(
      seed: reading.day.day,
      radius: BorderRadius.circular(20),
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        '今日已完成 $done 项',
                        key: const ValueKey('today-count'),
                        style: theme.textTheme.titleLarge?.copyWith(
                          color: xy.onSky,
                        ),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      overview == null
                          ? '正在读取今天的安排'
                          : waiting > 0
                          ? '还有 $waiting 项等待点亮'
                          : done > 0
                          ? '今天的星星都点亮了'
                          : '今天没有安排',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: xy.onSkyMuted,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              _Ring(done: done, total: done + waiting),
            ],
          ),
          if (done + waiting > 0) ...[
            const SizedBox(height: 14),
            StarProgress(
              lit: done,
              total: done + waiting,
              size: 16,
              outline: xy.onSkyMuted,
            ),
          ],
          const DayAnalysisButton(spacing: EdgeInsets.only(top: 16)),
        ],
      ),
    );
  }
}

/// An activity-style ring with today's completion share.
class _Ring extends StatelessWidget {
  const _Ring({required this.done, required this.total});

  final int done;
  final int total;

  @override
  Widget build(BuildContext context) {
    final xy = context.xy;
    final value = total == 0 ? 0.0 : done / total;
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: 52,
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: value),
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 600),
          curve: Curves.easeOutCubic,
          builder: (context, value, _) => CustomPaint(
            painter: _RingPainter(
              value: value,
              track: xy.onSky.withValues(alpha: 0.14),
              color: xy.star,
            ),
            child: Center(
              child: StarMark(lit: done > 0, size: 20, outline: xy.onSkyMuted),
            ),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter({
    required this.value,
    required this.track,
    required this.color,
  });

  final double value;
  final Color track;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 6.0;
    final rect = (Offset.zero & size).deflate(stroke / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, 0, 6.2832, false, paint..color = track);
    if (value > 0) {
      canvas.drawArc(
        rect,
        -1.5708,
        6.2832 * value,
        false,
        paint..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.value != value || old.track != track || old.color != color;
}
