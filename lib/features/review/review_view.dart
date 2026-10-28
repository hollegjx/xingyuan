import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../shared/local_date.dart';
import '../../app/theme.dart';
import '../../shared/presentation.dart';
import '../../shared/ui/sky.dart';
import '../../shared/ui/sparkle.dart';
import '../goals/domain/goal.dart';
import '../goals/presentation/goal_detail_page.dart';
import '../goals/presentation/goal_tile.dart';
import '../journal/presentation/journal_day_sections.dart';

class ReviewView extends ConsumerStatefulWidget {
  const ReviewView({this.goalId, this.initialDate, super.key});

  final int? goalId;
  final LocalDate? initialDate;

  @override
  ConsumerState<ReviewView> createState() => _ReviewViewState();
}

class _ReviewViewState extends ConsumerState<ReviewView> {
  LocalDate? _month;
  LocalDate? _selected;
  final _calendarScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _selected = widget.initialDate;
    final initial = widget.initialDate;
    if (initial != null) _month = LocalDate(initial.year, initial.month, 1);
  }

  @override
  void dispose() {
    _calendarScroll.dispose();
    super.dispose();
  }

  void _moveMonth(LocalDate month, int delta) {
    final next = DateTime.utc(month.year, month.month + delta, 1);
    setState(() {
      _month = LocalDate.fromDateTime(next);
      _selected = _month;
    });
  }

  @override
  Widget build(BuildContext context) {
    final today =
        ref.watch(environmentProvider).value?.day ??
        ref.read(clockProvider).read().day;
    final selected = _selected ?? today;
    final month = _month ?? LocalDate(today.year, today.month, 1);
    return ref
        .watch(goalsProvider)
        .when(
          loading: () => const PageScroll(
            children: [StatusPanel(message: '正在读取历史', loading: true)],
          ),
          error: (error, stack) => PageScroll(
            children: [
              StatusPanel(
                message: '无法读取历史',
                retry: () => retryLocalRecords(ref),
              ),
            ],
          ),
          data: (allGoals) {
            final goals = allGoals
                .where(
                  (goal) => widget.goalId == null || goal.id == widget.goalId,
                )
                .toList();
            final views = goals
                .map((goal) => goal.dayView(selected, today: today))
                .toList();
            final completed = views
                .where((view) => view.status == GoalDayStatus.completed)
                .length;
            final xy = context.xy;
            final theme = Theme.of(context);
            final monthDone = [
              for (
                var day = 1;
                day <= DateTime.utc(month.year, month.month + 1, 0).day;
                day++
              )
                goals
                    .where(
                      (goal) =>
                          goal.completionOn(
                            LocalDate(month.year, month.month, day),
                          ) !=
                          null,
                    )
                    .length,
            ];
            return PageScroll(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
              children: [
                if (widget.goalId == null)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 4),
                    child: TabHeader(
                      title: '回顾',
                      subtitle: '每一颗星，都是你点亮的一天',
                      padding: EdgeInsets.fromLTRB(4, 0, 0, 10),
                    ),
                  ),
                SkyPanel(
                  seed: month.month,
                  radius: const BorderRadius.all(Radius.circular(20)),
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          IconButton(
                            key: const ValueKey('previous-month'),
                            tooltip: '上个月',
                            onPressed: month.year == 1 && month.month == 1
                                ? null
                                : () => _moveMonth(month, -1),
                            icon: const Icon(CupertinoIcons.chevron_left),
                          ),
                          Expanded(
                            child: Text(
                              '${month.year}年${month.month}月',
                              key: const ValueKey('review-month'),
                              textAlign: TextAlign.center,
                              style: theme.textTheme.titleMedium?.copyWith(
                                color: xy.onSky,
                              ),
                            ),
                          ),
                          IconButton(
                            key: const ValueKey('review-today'),
                            tooltip: '回到今天',
                            onPressed: () => setState(() {
                              _month = null;
                              _selected = null;
                            }),
                            icon: const Icon(CupertinoIcons.calendar_today),
                          ),
                          IconButton(
                            key: const ValueKey('next-month'),
                            tooltip: '下个月',
                            onPressed: month.year == 9999 && month.month == 12
                                ? null
                                : () => _moveMonth(month, 1),
                            icon: const Icon(CupertinoIcons.chevron_right),
                          ),
                        ],
                      ),
                      _calendar(context, month, selected, goals, today),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                        child: Text(
                          '这个月点亮了 ${monthDone.fold<int>(0, (a, b) => a + b)} 颗星 · ${monthDone.where((n) => n > 0).length} 天有收获',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: xy.onSkyMuted,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 26),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Wrap(
                    spacing: 10,
                    crossAxisAlignment: WrapCrossAlignment.end,
                    children: [
                      Text(
                        dateLabel(selected),
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        '已完成 $completed 项',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: xy.muted,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                if (goals.isEmpty)
                  StatusPanel(
                    message: widget.goalId == null ? '还没有记录' : '找不到这个目标',
                  )
                else
                  XyGroup(
                    margin: EdgeInsets.zero,
                    dividerIndent: 60,
                    children: [
                      for (final view in views)
                        GoalTile(
                          key: ValueKey(
                            'history-${view.goal.id}-${selected.key}',
                          ),
                          view: view,
                          onOpen: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) =>
                                  GoalDetailPage(goalId: view.goal.id),
                            ),
                          ),
                        ),
                    ],
                  ),
                if (widget.goalId == null)
                  JournalDaySections(
                    day: selected,
                    canCreate: !selected.isAfter(today),
                  ),
              ],
            );
          },
        );
  }

  Widget _calendar(
    BuildContext context,
    LocalDate month,
    LocalDate selected,
    List<Goal> goals,
    LocalDate today,
  ) {
    final days = DateTime.utc(month.year, month.month + 1, 0).day;
    final start = month.weekday - 1;
    final rows = (start + days + 6) ~/ 7;
    final textScaler = MediaQuery.textScalerOf(context);
    final theme = Theme.of(context);
    final dayStyle = theme.textTheme.labelLarge!.copyWith(
      fontSize: 14,
      letterSpacing: 0,
    );
    final measurement = TextPainter(
      text: TextSpan(text: '31', style: dayStyle),
      textDirection: Directionality.of(context),
      textScaler: textScaler,
    )..layout();
    final minimumWidth = math.max(44.0, measurement.width + 16);
    final height = math.max(48.0, measurement.height + 22);
    measurement.dispose();
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = math.max(constraints.maxWidth / 7, minimumWidth);
        return Scrollbar(
          controller: _calendarScroll,
          thumbVisibility: true,
          scrollbarOrientation: ScrollbarOrientation.bottom,
          child: SingleChildScrollView(
            controller: _calendarScroll,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.only(bottom: 12),
            child: SizedBox(
              width: width * 7,
              child: Column(
                children: [
                  Row(
                    children: [
                      for (final weekday in const [
                        '一',
                        '二',
                        '三',
                        '四',
                        '五',
                        '六',
                        '日',
                      ])
                        SizedBox(
                          width: width,
                          height: math.max(32, textScaler.scale(12) * 1.4 + 12),
                          child: Center(
                            child: Text(
                              weekday,
                              style: TextStyle(
                                fontSize: 12,
                                color: context.xy.onSkyMuted,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  for (var row = 0; row < rows; row++)
                    Row(
                      children: [
                        for (var col = 0; col < 7; col++)
                          SizedBox(
                            width: width,
                            height: height,
                            child:
                                row * 7 + col < start ||
                                    row * 7 + col >= start + days
                                ? null
                                : _dayButton(
                                    theme,
                                    dayStyle,
                                    width,
                                    height,
                                    LocalDate(
                                      month.year,
                                      month.month,
                                      row * 7 + col - start + 1,
                                    ),
                                    selected,
                                    goals,
                                    today,
                                  ),
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _dayButton(
    ThemeData theme,
    TextStyle dayStyle,
    double width,
    double height,
    LocalDate day,
    LocalDate selected,
    List<Goal> goals,
    LocalDate today,
  ) {
    final xy = context.xy;
    final count = goals.where((goal) => goal.completionOn(day) != null).length;
    final isSelected = day == selected;
    final isToday = day == today;
    return Semantics(
      label: '${dateLabel(day)}，已完成 $count 项',
      selected: isSelected,
      button: true,
      onTap: () => setState(() => _selected = day),
      child: ExcludeSemantics(
        child: TextButton(
          key: ValueKey('review-day-${day.key}'),
          onPressed: () => setState(() => _selected = day),
          style: TextButton.styleFrom(
            padding: EdgeInsets.zero,
            minimumSize: Size(width, height),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            foregroundColor: xy.onSky,
            backgroundColor: isSelected
                ? xy.onSky.withValues(alpha: 0.16)
                : null,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                height: 16,
                child: Center(
                  child: count > 0
                      ? StarMark(
                          lit: true,
                          // More finished goals, a bigger star.
                          size: 9.0 + 2.0 * (count > 4 ? 4 : count),
                          glow: count > 2,
                        )
                      : Container(
                          width: 3,
                          height: 3,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: xy.onSkyMuted.withValues(alpha: 0.35),
                          ),
                        ),
                ),
              ),
              Text(
                '${day.day}',
                style: dayStyle.copyWith(
                  color: isToday
                      ? xy.star
                      : isSelected
                      ? xy.onSky
                      : xy.onSkyMuted,
                  fontWeight: isToday || isSelected
                      ? FontWeight.w700
                      : FontWeight.w500,
                ),
                maxLines: 1,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
