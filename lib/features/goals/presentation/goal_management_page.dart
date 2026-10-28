import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../shared/presentation.dart';
import 'goal_detail_page.dart';
import 'goal_form_page.dart';
import 'goal_tile.dart';

class GoalManagementPage extends ConsumerStatefulWidget {
  const GoalManagementPage({super.key});

  @override
  ConsumerState<GoalManagementPage> createState() => _GoalManagementPageState();
}

class _GoalManagementPageState extends ConsumerState<GoalManagementPage> {
  bool _archived = false;

  @override
  Widget build(BuildContext context) {
    final today =
        ref.watch(environmentProvider).value?.day ??
        ref.read(clockProvider).read().day;
    return Scaffold(
      appBar: pageAppBar(
        context,
        '目标管理',
        actions: [
          IconButton(
            tooltip: '新建目标',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<int>(builder: (_) => const GoalFormPage()),
            ),
            icon: const Icon(CupertinoIcons.add),
          ),
        ],
      ),
      body: SafeArea(
        child: ref
            .watch(goalsProvider)
            .when(
              loading: () => const PageScroll(
                children: [StatusPanel(message: '正在读取目标', loading: true)],
              ),
              error: (error, stack) => PageScroll(
                children: [
                  StatusPanel(
                    message: '无法读取目标',
                    retry: () => retryLocalRecords(ref),
                  ),
                ],
              ),
              data: (goals) {
                final visible = goals
                    .where((goal) => goal.isArchived == _archived)
                    .toList();
                return PageScroll(
                  children: [
                    XySegmented<bool>(
                      key: const ValueKey('goal-filter'),
                      segments: const [(false, '进行中'), (true, '已归档')],
                      selected: _archived,
                      onChanged: (value) => setState(() => _archived = value),
                    ),
                    const SizedBox(height: 16),
                    if (visible.isEmpty)
                      StatusPanel(message: _archived ? '没有已归档目标' : '没有进行中的目标')
                    else
                      XyGroup(
                        margin: EdgeInsets.zero,
                        dividerIndent: 60,
                        children: [
                          for (final goal in visible)
                            GoalTile(
                              view: goal.dayView(today, today: today),
                              status: goal.singleCompletion == null
                                  ? null
                                  : '已完成于 ${dateLabel(goal.singleCompletion!.day)}',
                              onOpen: () => Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) =>
                                      GoalDetailPage(goalId: goal.id),
                                ),
                              ),
                            ),
                        ],
                      ),
                  ],
                );
              },
            ),
      ),
    );
  }
}
