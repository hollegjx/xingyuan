import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/theme.dart';
import '../../../shared/app_clock.dart';
import '../../../shared/presentation.dart';
import '../../../shared/ui/today_sky.dart';
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
  void _newGoal() =>
      Navigator.of(context)
          .push(MaterialPageRoute<int>(builder: (_) => const GoalFormPage()));

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
                      '${day.month}月${day.day}日 · ${weekdayLabels[day.weekday - 1]}',
                  title: greetingFor(reading.localTime.hour),
                  subtitle: '今天也慢慢来。',
                  padding: const EdgeInsets.fromLTRB(24, 0, 8, 6),
                  trailing: [
                    IconButton(
                      key: const ValueKey('entry-new-goal'),
                      tooltip: '新目标',
                      onPressed: _newGoal,
                      icon: const Icon(CupertinoIcons.plus, size: 22),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 48),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      RiseIn(
                        child: _TodaySummary(
                          reading: reading,
                          overview: overview,
                        ),
                      ),
                      const SizedBox(height: 14),
                      RiseIn(
                        order: 1,
                        child: _WriteCard(
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
                        ),
                      ),
                      SectionLabel(
                        '今天的目标',
                        count: overview == null
                            ? null
                            : overview.pending.length +
                                  overview.completed.length,
                      ),
                      // Sections grow and shrink smoothly as stars are lit.
                      // Reduced motion lays the list out directly: an
                      // AnimatedSize with a zero duration still resizes
                      // during layout.
                      if (MediaQuery.disableAnimationsOf(context))
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: body,
                        )
                      else
                        AnimatedSize(
                          alignment: Alignment.topCenter,
                          duration: const Duration(milliseconds: 260),
                          curve: Curves.easeOutCubic,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: body,
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
    Widget group(String header, List<GoalDay> views) => XyGroup(
      header: '$header · ${views.length}',
      margin: const EdgeInsets.only(top: 8),
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
      const ReminderOverview(compact: true),
      if (goals.isEmpty)
        const StatusPanel(message: '还没有目标')
      else if (overview.pending.isEmpty)
        StatusPanel(
          message: overview.completed.isEmpty ? '今天没有待办' : '今天的计划已完成',
          lit: overview.completed.isNotEmpty,
        ),
      if (overview.pending.isNotEmpty) group('等待点亮', overview.pending),
      if (overview.completed.isNotEmpty) group('已点亮', overview.completed),
    ];
  }
}

/// Today's progress as 今天的星座: the sky follows the hour, every goal is a
/// star and lit ones join into the day's constellation. 今日星语 sits below.
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
    return DecoratedBox(
      key: const ValueKey('today-summary'),
      decoration: BoxDecoration(
        color: xy.card,
        borderRadius: BorderRadius.circular(xyCardRadius),
        border: Border.all(color: xy.line),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(xyCardRadius - 1),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TodaySky(
              done: done,
              total: done + waiting,
              hour: reading.localTime.hour,
              seed:
                  reading.day.year * 400 +
                  reading.day.month * 31 +
                  reading.day.day,
              height: 176,
              builder: (context, sky) => Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    liveRegion: true,
                    child: AnimatedSwitcher(
                      duration: MediaQuery.disableAnimationsOf(context)
                          ? Duration.zero
                          : const Duration(milliseconds: 360),
                      transitionBuilder: (child, animation) => FadeTransition(
                        opacity: animation,
                        child: SlideTransition(
                          position: Tween(
                            begin: const Offset(0, 0.35),
                            end: Offset.zero,
                          ).animate(animation),
                          child: child,
                        ),
                      ),
                      child: Text(
                        '已点亮 $done 颗星',
                        key: const ValueKey('today-count'),
                        style: theme.textTheme.headlineSmall?.copyWith(
                          color: sky.text,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    overview == null
                        ? '正在读取今天的安排'
                        : waiting > 0
                        ? '还有 $waiting 项，不急。'
                        : done > 0
                        ? '今天的星座连好了。'
                        : '今天还没有安排。',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: sky.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            const DayAnalysisButton(
              spacing: EdgeInsets.fromLTRB(12, 12, 12, 12),
            ),
          ],
        ),
      ),
    );
  }
}

/// The first thing to do on a quiet day: write. The prompt opens a 随手记;
/// the pills beneath open either kind.
class _WriteCard extends StatelessWidget {
  const _WriteCard({required this.onQuickNote, required this.onDiary});

  final VoidCallback onQuickNote;
  final VoidCallback onDiary;

  @override
  Widget build(BuildContext context) {
    final xy = context.xy;
    final theme = Theme.of(context);
    return Material(
      color: xy.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(xyCardRadius),
        side: BorderSide(color: xy.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              button: true,
              label: '写一条随手记',
              excludeSemantics: true,
              child: InkWell(
                key: const ValueKey('entry-quick-note'),
                borderRadius: BorderRadius.circular(14),
                onTap: onQuickNote,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    minHeight: 52,
                    minWidth: double.infinity,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
                    child: Text(
                      '此刻在想什么……',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontSize: 17,
                        fontWeight: FontWeight.w400,
                        color: xy.faint,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Wrap(
                spacing: 10,
                runSpacing: 8,
                children: [
                  _SoftPill(
                    icon: CupertinoIcons.pencil,
                    label: '随手记',
                    onTap: onQuickNote,
                  ),
                  _SoftPill(
                    key: const ValueKey('entry-diary'),
                    icon: CupertinoIcons.book,
                    label: '写日记',
                    onTap: onDiary,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SoftPill extends StatelessWidget {
  const _SoftPill({
    required this.icon,
    required this.label,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.primaryContainer,
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16, color: scheme.primary),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    label,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: scheme.primary,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
