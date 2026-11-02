import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

import '../../../app/providers.dart';
import '../../../data/local/app_database.dart';
import '../../../shared/local_date.dart';
import '../../../app/theme.dart';
import '../../../shared/presentation.dart';
import '../../goals/domain/goal.dart';
import '../../goals/presentation/goal_timing_fields.dart';
import '../../reminders/notification_permissions.dart';
import '../../reminders/reminder_status_view.dart';
import '../../review/review_view.dart';
import '../assistant_providers.dart';
import '../data/local_conversation_store.dart';
import '../data/local_proposal_store.dart';
import '../domain/plan_preview.dart';
import 'assistant_identity_boundary.dart';
import '../domain/agent_run_metadata.dart';
import '../domain/agent_planning.dart';
import 'agent_run_details.dart';

enum AgentProposalAction { replan }

class AssistantProposalPage extends ConsumerStatefulWidget {
  const AssistantProposalPage({
    required this.proposalId,
    this.requestUndo = false,
    super.key,
  });
  final String proposalId;
  final bool requestUndo;
  @override
  ConsumerState<AssistantProposalPage> createState() =>
      _AssistantProposalPageState();
}

class _AssistantProposalPageState extends ConsumerState<AssistantProposalPage> {
  late final Future<LocalConversationStore> _store;
  final _scroll = ScrollController();
  StoredPlanProposal? _row;
  PlanPreview? _preview;
  List<Goal> _goals = [];
  bool _busy = false;
  bool _notificationDenied = false;
  String? _error;
  AgentPlanValidation? _agentValidation;
  String? _agentConfirmationToken;
  bool _partialAcknowledged = false;
  bool _scheduleChanged = false;

  @override
  void initState() {
    super.initState();
    _store = ref.read(assistantStoreProvider.future);
    _load().then((_) {
      if (mounted && widget.requestUndo && _row?.status == 'applied') _undo();
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final store = await _store;
      final row = await store.proposals.read(widget.proposalId);
      final preview = PlanPreview.decode(
        row.status == 'draft' ? row.itemsJson : row.appliedItemsJson!,
      );
      final check = row.status == 'draft' && preview.items.isNotEmpty
          ? await store.proposals.inspectAgent(widget.proposalId, preview)
          : null;
      final goals = row.agentMetadata == null
          ? await store.goals.loadGoals()
          : <Goal>[];
      if (!mounted) return;
      setState(() {
        _row = row;
        _preview = preview;
        _agentValidation = check?.validation;
        _agentConfirmationToken = check?.token;
        _partialAcknowledged = false;
        _scheduleChanged = check?.validation.hasErrors ?? false;
        _goals = goals;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _row = null;
          _error = '无法读取当前身份的计划，原有记录未被清空。';
        });
      }
    }
  }

  Future<void> _change(
    Future<void> Function(LocalConversationStore) action,
  ) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action(await _store);
      await _load();
    } on FormatException {
      if (mounted) setState(() => _error = '请检查日期、时间、分钟数和当天任务数量；未创建任何内容。');
    } on AgentPlanChanged {
      await _load();
      if (mounted) setState(() => _scheduleChanged = true);
    } catch (error) {
      if (_row?.agentMetadata != null) await _load();
      if (mounted) {
        setState(
          () => _error = error is GoalRuleException
              ? error.message
              : '操作未完成，原有记录未被清空。请重试。',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit(PlanPreview value) =>
      _change((store) => store.proposals.editDraft(widget.proposalId, value));
  void _returnEdit() {
    setState(() {
      _scheduleChanged = false;
      _partialAcknowledged = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      if (MediaQuery.disableAnimationsOf(context)) {
        _scroll.jumpTo(0);
      } else {
        _scroll.animateTo(
          0,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  Future<void> _permission() async {
    try {
      await ref
          .read(notificationAccessProvider.notifier)
          .refresh(request: true);
      if (mounted) {
        final access =
            ref.read(notificationAccessProvider).value ??
            NotificationAccess.off;
        setState(() => _notificationDenied = access == NotificationAccess.off);
      }
    } catch (_) {
      if (mounted) setState(() => _notificationDenied = true);
    }
  }

  Future<void> _reconcile() async {
    try {
      await ref.read(reminderReportProvider.notifier).refresh();
    } catch (_) {
      if (mounted) setState(() => _error = '计划已保存，提醒尚未完成核对，请在设置中重试。');
    }
  }

  Future<void> _apply() => _change((store) async {
    await store.proposals.apply(
      widget.proposalId,
      _preview!,
      partialAcknowledged: _partialAcknowledged,
      expectedAgentValidation: _agentConfirmationToken,
    );
    await _reconcile();
  });
  Future<void> _undo() async {
    try {
      final store = await _store;
      final preview = await store.proposals.previewUndo(widget.proposalId);
      if (!mounted) return;
      final approved = await confirmAction(
        context,
        title: '撤销本批计划？',
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('删除不能恢复；有打卡、记录或草稿关联的目标会保留。'),
            const SizedBox(height: 12),
            for (final item in preview.items)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text('${item.title}：${_disposition(item.disposition)}'),
              ),
          ],
        ),
        confirm: '确认撤销',
        confirmKey: const ValueKey('assistant-undo-confirm'),
        destructive: true,
      );
      if (approved != true || !mounted) return;
      await _change((store) async {
        await store.proposals.undo(widget.proposalId);
        await _reconcile();
      });
    } catch (error) {
      if (mounted) showSaveError(context, error);
    }
  }

  String _disposition(UndoDisposition value) => switch (value) {
    UndoDisposition.deleted => '删除并取消提醒',
    UndoDisposition.keptHistory => '保留，已有打卡记录',
    UndoDisposition.keptRecord => '保留，已有记录或草稿关联',
    UndoDisposition.archivedSynced => '归档，已有同步记录',
    UndoDisposition.alreadyMissing => '已不存在',
  };
  String _issue(PreviewIssueKind value) => switch (value) {
    PreviewIssueKind.expired => '已过期，请改期或删除',
    PreviewIssueKind.tooFar => '超出 14 天范围',
    PreviewIssueKind.habitStart => '习惯须从确认当天开始',
    PreviewIssueKind.sameTitle => '与已有安排同名',
    PreviewIssueKind.timeOverlap => '与已有安排时间重叠',
  };
  Future<void> _itemEditor(PreviewItem item) async {
    final today = CalendarDate.parse(ref.read(clockProvider).read().day.key);
    final result = await showModalBottomSheet<Object>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _ProposalItemEditor(
        item: item,
        today: today,
        agent: _row?.agentMetadata != null,
      ),
    );
    if (!mounted) return;
    if (result is PlanTask) await _edit(_preview!.replace(item.id, result));
    if (result == _ProposalItemEditor.removed) {
      await _edit(_preview!.remove(item.id));
    }
  }

  Future<void> _remind(PreviewItem item, bool value) => _change((store) async {
    if (value) await _permission();
    await store.proposals.editDraft(
      widget.proposalId,
      _preview!.setReminder(item.id, value),
    );
  });

  void _view(PreviewItem item) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (context) => Scaffold(
        appBar: pageAppBar(context, '回顾'),
        body: SafeArea(
          child: ReviewView(initialDate: LocalDate.parse(item.task.date.key)),
        ),
      ),
    ),
  );

  /// One plan item, laid out like a row of the planning card: time on the
  /// left, what and when on the right, quiet controls at the end.
  Widget _item(PreviewItem item, List<PreviewIssue> issues, bool draft) {
    final theme = Theme.of(context);
    final xy = context.xy;
    final task = item.task;
    final index = _preview!.items.indexOf(item);
    final applied = _row!.status == 'applied';
    final notes = [
      if (draft && _agentValidation != null)
        for (final issue in _agentValidation!.issues.where(
          (row) => row['index'] == index,
        ))
          _AgentIssue(
            partial: issue['code'] == 'unknown_schedule',
            text: Text(switch (issue['code']) {
              'unknown_schedule' => agentUnknownScheduleMessage(issue),
              'conflict' => '与已有安排或本计划其他项冲突',
              'duplicate' => '同一天已有同名安排',
              'daily_cap' => '超过每日时长上限',
              'date_range' => '日期超出规划范围',
              _ => '请补全并检查日期、开始时间和时长',
            }, key: ValueKey('agent-item-issue-${item.id}')),
          ),
      for (final kind
          in issues
              .where((issue) => draft && issue.itemId == item.id)
              .map((issue) => issue.kind)
              .toSet())
        _AgentIssue(partial: false, text: Text(_issue(kind))),
    ];
    final time = Text(
      task.time ?? '不定时',
      style: task.time == null
          ? theme.textTheme.bodyMedium?.copyWith(color: xy.muted)
          : theme.textTheme.titleMedium?.copyWith(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
    );
    final length = task.minutes == null
        ? null
        : Text(
            '${task.minutes} 分钟',
            style: theme.textTheme.bodySmall?.copyWith(color: xy.muted),
          );
    final days = task.weekdays;
    final when = days == null
        ? null
        : '${days.length == 7 ? '每天' : '每周${days.map((day) => weekdayLabels[day - 1].substring(1)).join()}'} · ${task.date.month}月${task.date.day}日起';
    final what = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(task.title, style: theme.textTheme.bodyLarge),
        if (when != null) ...[
          const SizedBox(height: 2),
          Text(
            when,
            style: theme.textTheme.bodySmall?.copyWith(color: xy.muted),
          ),
        ],
        ...notes,
      ],
    );
    final controls = [
      if (draft && task.time != null)
        IconButton(
          key: ValueKey('plan-reminder-${item.id}'),
          tooltip: item.reminder ? '关闭提醒' : '开启提醒',
          isSelected: item.reminder,
          color: xy.faint,
          selectedIcon: Icon(
            CupertinoIcons.bell_fill,
            size: 20,
            color: theme.colorScheme.primary,
          ),
          onPressed: _busy ? null : () => _remind(item, !item.reminder),
          icon: const Icon(CupertinoIcons.bell, size: 20),
        ),
      if (draft)
        IconButton(
          key: ValueKey('edit-plan-${item.id}'),
          tooltip: '编辑条目',
          color: xy.faint,
          onPressed: _busy ? null : () => _itemEditor(item),
          icon: const Icon(CupertinoIcons.chevron_right, size: 16),
        )
      else if (applied)
        IconButton(
          tooltip: '查看对应日期',
          color: xy.faint,
          onPressed: () => _view(item),
          icon: const Icon(CupertinoIcons.calendar, size: 20),
        ),
    ];
    final stacked = MediaQuery.textScalerOf(context).scale(18) > 30;
    return InkWell(
      onTap: _busy
          ? null
          : draft
          ? () => _itemEditor(item)
          : applied
          ? () => _view(item)
          : null,
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 10, controls.isEmpty ? 16 : 4, 10),
        child: stacked
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  time,
                  ?length,
                  const SizedBox(height: 4),
                  what,
                  if (controls.isNotEmpty)
                    Align(
                      alignment: Alignment.centerRight,
                      child: Wrap(children: controls),
                    ),
                ],
              )
            : Row(
                // A one-line row centres; anything taller reads from the top.
                crossAxisAlignment:
                    task.time == null && when == null && notes.isEmpty
                    ? CrossAxisAlignment.center
                    : CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: SizedBox(
                      width: 66,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [time, ?length],
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: what,
                    ),
                  ),
                  ...controls,
                ],
              ),
      ),
    );
  }

  /// What this batch is and where it stands, in the page's own large type.
  Widget _header(StoredPlanProposal row, PlanPreview preview, bool draft) {
    final theme = Theme.of(context);
    final xy = context.xy;
    final applied = row.status == 'applied';
    final count = applied
        ? (jsonDecode(row.appliedGoalIdsJson!) as List).length
        : preview.items.length;
    // Large type grows with the user's setting, but not past the point
    // where the title alone fills a small screen.
    final title = MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.6,
      child: Text(
        draft
            ? '计划草稿'
            : applied
            ? '已添加 $count 项'
            : '已撤销',
        style: theme.textTheme.headlineSmall?.copyWith(
          fontSize: 28,
          fontWeight: FontWeight.w700,
          height: 1.2,
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (applied)
            Row(
              children: [
                Icon(
                  CupertinoIcons.checkmark_circle_fill,
                  size: 26,
                  color: xy.success,
                ),
                const SizedBox(width: 8),
                Flexible(child: title),
              ],
            )
          else
            title,
          const SizedBox(height: 4),
          MediaQuery.withClampedTextScaling(
            maxScaleFactor: 2,
            child: Text(
              draft
                  ? '$count 项 · 确认后加入日程'
                  : applied
                  ? '已加入日程，可以在「今天」和「回顾」里看到'
                  : '这批计划已经撤掉',
              style: theme.textTheme.bodyMedium?.copyWith(color: xy.muted),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final today = CalendarDate.parse(
      (ref.watch(environmentProvider).value?.day ??
              ref.read(clockProvider).read().day)
          .key,
    );
    final theme = Theme.of(context);
    final xy = context.xy;
    final row = _row;
    final preview = _preview;
    final issues =
        preview?.inspect(
          today: today,
          goals: _goals,
          agent: row?.agentMetadata != null,
        ) ??
        <PreviewIssue>[];
    final days =
        preview?.items
            .where((item) => !item.task.isHabit)
            .map((item) => item.task.date.key)
            .toSet()
            .toList() ??
        <String>[];
    days.sort();
    final draft = row?.status == 'draft';
    final invalid = _agentValidation?.hasErrors ?? false;
    final partial = _agentValidation?.partialIndexes.isNotEmpty ?? false;
    final timed = preview?.items.where((item) => item.task.time != null);
    // The decision sits in a bar under the list, always in reach.
    final decide = row != null && preview != null && draft && !_scheduleChanged
        ? Material(
            color: theme.scaffoldBackgroundColor,
            shape: Border(top: BorderSide(color: xy.line, width: 0.5)),
            child: SafeArea(
              top: false,
              // The bar stays on screen, so it must leave room for the plan.
              child: MediaQuery.withClampedTextScaling(
                maxScaleFactor: 2,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (invalid)
                        const Padding(
                          padding: EdgeInsets.only(bottom: 8),
                          child: NoticeBanner(
                            key: ValueKey('agent-invalid-draft'),
                            tone: NoticeTone.error,
                            message: '没能排出不冲突的方案，请调整后再确认。',
                          ),
                        )
                      else ...[
                        if (partial)
                          CheckboxListTile.adaptive(
                            key: const ValueKey(
                              'agent-partial-acknowledgement',
                            ),
                            title: const Text('我已了解可能的冲突'),
                            controlAffinity: ListTileControlAffinity.leading,
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            value: _partialAcknowledged,
                            onChanged: _busy
                                ? null
                                : (value) => setState(
                                    () => _partialAcknowledged = value == true,
                                  ),
                          ),
                        FilledButton(
                          key: const ValueKey('assistant-apply-plan'),
                          style: FilledButton.styleFrom(
                            shape: const StadiumBorder(),
                          ),
                          onPressed:
                              _busy ||
                                  preview.items.isEmpty ||
                                  (partial && !_partialAcknowledged) ||
                                  issues.any(
                                    (issue) => issue.blocksConfirmation,
                                  )
                              ? null
                              : _apply,
                          child: Text(_busy ? '正在保存' : '确认添加'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          )
        : null;
    return AssistantIdentityBoundary(
      store: _store,
      child: Scaffold(
        appBar: pageAppBar(
          context,
          '',
          actions: [
            if (draft && row?.agentMetadata == null)
              IconButton(
                tooltip: '清除全部时间',
                onPressed: _busy ? null : () => _edit(preview!.clearTimes()),
                icon: const Icon(CupertinoIcons.timer),
              ),
          ],
        ),
        bottomNavigationBar: decide,
        body: SafeArea(
          bottom: decide == null,
          child: PageScroll(
            controller: _scroll,
            children: [
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12, bottom: 4),
                  child: NoticeBanner(tone: NoticeTone.error, message: _error!),
                ),
              if (row == null || preview == null)
                StatusPanel(
                  message: _error == null ? '正在读取计划' : '计划暂不可用',
                  loading: _error == null,
                  retry: _error == null ? null : _load,
                )
              else ...[
                _header(row, preview, draft),
                if (row.agentMetadata != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 4, top: 4),
                    child: AgentRunDetails(
                      metadata: AgentRunMetadata.decode(row.agentMetadata!),
                      scope: 'proposal',
                    ),
                  ),
                if (_notificationDenied)
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: NoticeBanner(
                      tone: NoticeTone.warning,
                      message: '通知权限未开启，仍可创建目标；目前不会提醒。',
                    ),
                  ),
                if (draft && _scheduleChanged)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const NoticeBanner(
                          key: ValueKey('agent-schedule-changed'),
                          tone: NoticeTone.warning,
                          message: '安排有变化',
                        ),
                        if (!invalid)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
                            child: Text(
                              '计划内容或无法判断的安排已变化，请重新检查逐项提示。未创建任何内容。',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: xy.muted,
                              ),
                            ),
                          ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            FilledButton.icon(
                              key: const ValueKey('agent-replan'),
                              style: FilledButton.styleFrom(
                                shape: const StadiumBorder(),
                              ),
                              onPressed: _busy
                                  ? null
                                  : () =>
                                        Navigator.of(context)
                                            .pop(AgentProposalAction.replan),
                              icon: const Icon(
                                CupertinoIcons.arrow_clockwise,
                                size: 18,
                              ),
                              label: const Text('重新规划'),
                            ),
                            TextButton(
                              key: const ValueKey('agent-return-edit'),
                              onPressed: _busy ? null : _returnEdit,
                              child: const Text('返回修改'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                for (final day in days)
                  XyGroup(
                    margin: const EdgeInsets.only(top: 20),
                    dividerIndent: 94,
                    header:
                        '${weekdayLabels[CalendarDate.parse(day).weekday - 1]} ${CalendarDate.parse(day).month}月${CalendarDate.parse(day).day}日',
                    children: [
                      for (final item in preview.items.where(
                        (item) =>
                            !item.task.isHabit && item.task.date.key == day,
                      ))
                        _item(item, issues, draft),
                    ],
                  ),
                if (preview.items.any((item) => item.task.isHabit))
                  XyGroup(
                    margin: const EdgeInsets.only(top: 20),
                    dividerIndent: 94,
                    header: '重复习惯',
                    children: [
                      for (final item in preview.items.where(
                        (item) => item.task.isHabit,
                      ))
                        _item(item, issues, draft),
                    ],
                  ),
                if (draft)
                  XyGroup(
                    margin: const EdgeInsets.only(top: 20),
                    footer: timed!.isEmpty
                        ? '这批计划都没有具体时间，不会提醒。'
                        : '也可以点每一项右侧的铃铛单独设置。',
                    children: [
                      SwitchListTile.adaptive(
                        title: const Text('开启定时提醒'),
                        value:
                            timed.isNotEmpty &&
                            timed.every((item) => item.reminder),
                        onChanged: _busy || timed.isEmpty
                            ? null
                            : (value) => _change((store) async {
                                if (value) await _permission();
                                await store.proposals.editDraft(
                                  widget.proposalId,
                                  value
                                      ? preview.enableTimedReminders()
                                      : PlanPreview([
                                          for (final item in preview.items)
                                            PreviewItem(
                                              id: item.id,
                                              task: item.task,
                                            ),
                                        ]),
                                );
                              }),
                      ),
                    ],
                  ),
                if (row.status == 'undone')
                  XyGroup(
                    margin: const EdgeInsets.only(top: 20),
                    header: '撤销结果',
                    children: [
                      for (final item in ProposalUndoResult.decode(
                        row.undoResultJson!,
                      ).items)
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(child: Text(item.title)),
                              const SizedBox(width: 12),
                              Flexible(
                                child: Text(
                                  _disposition(item.disposition),
                                  textAlign: TextAlign.end,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: xy.muted,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                if (!draft)
                  const Padding(
                    padding: EdgeInsets.only(top: 20),
                    child: ReminderOverview(compact: true),
                  ),
                if (row.status == 'applied')
                  Padding(
                    padding: const EdgeInsets.only(top: 20),
                    child: Center(
                      child: TextButton(
                        key: const ValueKey('assistant-undo-plan'),
                        style: TextButton.styleFrom(
                          foregroundColor: theme.colorScheme.error,
                        ),
                        onPressed: _busy ? null : _undo,
                        child: const Text('撤销本批'),
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ProposalItemEditor extends StatefulWidget {
  const _ProposalItemEditor({
    required this.item,
    required this.today,
    this.agent = false,
  });

  /// Popped instead of a task when the item should leave the plan.
  static const removed = #removePlanItem;

  final PreviewItem item;
  final CalendarDate today;
  final bool agent;
  @override
  State<_ProposalItemEditor> createState() => _ProposalItemEditorState();
}

class _ProposalItemEditorState extends State<_ProposalItemEditor> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _title;
  late CalendarDate _date;
  late Set<int> _weekdays;
  int? _time;
  int? _minutes;
  String? _error;
  @override
  void initState() {
    super.initState();
    final item = widget.item;
    _title = TextEditingController(text: item.task.title);
    _date = item.task.date;
    _weekdays = item.task.weekdays?.toSet() ?? {};
    _time = item.timing.startMinute;
    _minutes = item.timing.durationMinutes;
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  void _save() {
    if (!_form.currentState!.validate()) return;
    try {
      final task = PlanTask.fromJson({
        'title': _title.text.trim(),
        if (widget.item.task.isHabit)
          'start_date': _date.key
        else
          'date': _date.key,
        if (widget.item.task.isHabit) 'weekdays': _weekdays.toList()..sort(),
        'time': _time == null ? null : formatMinute(_time!),
        'minutes': _minutes,
      }, habit: widget.item.task.isHabit);
      Navigator.of(context).pop(task);
    } on FormatException {
      setState(() => _error = '请检查名称、日期、星期、时间与分钟数。');
    }
  }

  Future<void> _pickDate() async {
    final today = widget.today;
    final last = widget.item.task.isHabit
        ? today
        : today.addDays(widget.agent ? 14 : 13);
    final initial = _date.isBefore(today)
        ? today
        : _date.isAfter(last)
        ? last
        : _date;
    DateTime native(CalendarDate day) => DateTime(day.year, day.month, day.day);
    final value = await showDatePicker(
      context: context,
      initialDate: native(initial),
      firstDate: native(today),
      lastDate: native(last),
    );
    if (mounted && value != null) {
      setState(() => _date = CalendarDate(value.year, value.month, value.day));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final xy = context.xy;
    final habit = widget.item.task.isHabit;
    final action = TextButton.styleFrom(minimumSize: const Size(44, 44));
    final dot = MediaQuery.textScalerOf(context).scale(15) + 22;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .85,
        child: SafeArea(
          child: Form(
            key: _form,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // The bar stays pinned above the form, so it stays one line:
                // capped text size and a title that ellipsizes.
                MediaQuery.withClampedTextScaling(
                  maxScaleFactor: 1.6,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                    child: Row(
                      children: [
                        TextButton(
                          style: action,
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('取消'),
                        ),
                        Expanded(
                          child: Text(
                            '编辑条目',
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        TextButton(
                          key: const ValueKey('assistant-save-plan-item'),
                          style: action.copyWith(
                            textStyle: WidgetStatePropertyAll(
                              theme.textTheme.bodyLarge?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          onPressed: _save,
                          child: const Text('完成'),
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextFormField(
                          key: const ValueKey('assistant-plan-title'),
                          controller: _title,
                          maxLength: 60,
                          decoration: InputDecoration(
                            labelText: '名称',
                            fillColor: xy.cardSoft,
                          ),
                          validator: (value) =>
                              value == null || value.trim().isEmpty
                              ? '请输入名称'
                              : null,
                        ),
                        const SizedBox(height: 8),
                        Material(
                          color: xy.cardSoft,
                          borderRadius: BorderRadius.circular(12),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            key: const ValueKey('assistant-plan-date'),
                            onTap: _pickDate,
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(minHeight: 50),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 10,
                                ),
                                child: Row(
                                  children: [
                                    Text(habit ? '开始日期' : '日期'),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        '${weekdayLabels[_date.weekday - 1]} ${_date.month}月${_date.day}日',
                                        textAlign: TextAlign.end,
                                        style: theme.textTheme.bodyLarge
                                            ?.copyWith(color: xy.muted),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Icon(
                                      CupertinoIcons.chevron_right,
                                      size: 14,
                                      color: xy.faint,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                        if (habit) ...[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
                            child: Text(
                              '重复',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: xy.muted,
                              ),
                            ),
                          ),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (var day = 1; day <= 7; day++)
                                _Weekday(
                                  key: ValueKey('plan-weekday-$day'),
                                  label: weekdayLabels[day - 1],
                                  size: dot,
                                  selected: _weekdays.contains(day),
                                  onTap: () => setState(() {
                                    if (!_weekdays.remove(day)) {
                                      _weekdays.add(day);
                                    }
                                  }),
                                ),
                            ],
                          ),
                        ],
                        const SizedBox(height: 20),
                        Card(
                          color: xy.cardSoft,
                          child: GoalTimingFields(
                            startMinute: _time,
                            durationMinutes: _minutes,
                            onStartChanged: (value) =>
                                setState(() => _time = value),
                            onDurationChanged: (value) =>
                                setState(() => _minutes = value),
                          ),
                        ),
                        if (_error != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Text(
                              _error!,
                              style: TextStyle(color: theme.colorScheme.error),
                            ),
                          ),
                        const SizedBox(height: 28),
                        // Full width, so a large label wraps instead of
                        // being cut at the sheet's edge.
                        SizedBox(
                          width: double.infinity,
                          child: TextButton(
                            key: ValueKey('delete-plan-${widget.item.id}'),
                            style: action.copyWith(
                              foregroundColor: WidgetStatePropertyAll(
                                theme.colorScheme.error,
                              ),
                            ),
                            onPressed: () =>
                                Navigator.of(context)
                                    .pop(_ProposalItemEditor.removed),
                            child: const Text(
                              '从计划中删除',
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                      ],
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

/// A round weekday toggle: tinted when chosen, outlined when not.
class _Weekday extends StatelessWidget {
  const _Weekday({
    required this.label,
    required this.size,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final String label;
  final double size;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        color: selected ? scheme.primary : context.xy.cardSoft,
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: size, minHeight: size),
            child: Center(
              widthFactor: 1,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  label.substring(1),
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: selected ? scheme.onPrimary : scheme.onSurface,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A per-item check result: amber for a possible conflict, red for a hard
/// problem.
class _AgentIssue extends StatelessWidget {
  const _AgentIssue({required this.partial, required this.text});

  final bool partial;
  final Text text;

  @override
  Widget build(BuildContext context) {
    final color = partial
        ? context.xy.warning
        : Theme.of(context).colorScheme.error;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Icon(
              partial
                  ? CupertinoIcons.exclamationmark_circle
                  : CupertinoIcons.xmark_circle,
              size: 14,
              color: color,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: DefaultTextStyle.merge(
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: color),
              child: text,
            ),
          ),
        ],
      ),
    );
  }
}
