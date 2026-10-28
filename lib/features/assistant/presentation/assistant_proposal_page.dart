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
    final task = await showModalBottomSheet<PlanTask>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _ProposalItemEditor(
        item: item,
        today: today,
        agent: _row?.agentMetadata != null,
      ),
    );
    if (task != null && mounted) await _edit(_preview!.replace(item.id, task));
  }

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

  Widget _item(PreviewItem item, List<PreviewIssue> issues, bool draft) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 4, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(item.task.title, style: Theme.of(context).textTheme.bodyLarge),
            if (draft && _agentValidation != null)
              for (final issue in _agentValidation!.issues.where(
                (row) => row['index'] == _preview!.items.indexOf(item),
              ))
                _AgentIssue(
                  partial: issue['code'] == 'unknown_schedule',
                  text: Text(switch (issue['code']) {
                    'unknown_schedule' => '无法完整判断此项的冲突',
                    'conflict' => '与已有安排或本计划其他项冲突',
                    'duplicate' => '同一天已有同名安排',
                    'daily_cap' => '超过每日时长上限',
                    'date_range' => '日期超出规划范围',
                    _ => '请补全并检查日期、开始时间和时长',
                  }, key: ValueKey('agent-item-issue-${item.id}')),
                ),
            if (item.task.isHabit)
              Text(
                item.task.weekdays!
                    .map((day) => weekdayLabels[day - 1])
                    .join('、'),
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: context.xy.muted),
              ),
            if (item.timing.label.isNotEmpty)
              Text(
                item.timing.label,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: context.xy.muted),
              ),
            for (final kind
                in issues
                    .where((issue) => draft && issue.itemId == item.id)
                    .map((issue) => issue.kind)
                    .toSet())
              Text(
                _issue(kind),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (draft) ...[
              SwitchListTile.adaptive(
                contentPadding: const EdgeInsets.only(right: 12),
                title: const Text('提醒'),
                value: item.reminder,
                onChanged: _busy || item.task.time == null
                    ? null
                    : (value) => _change((store) async {
                        if (value) await _permission();
                        await store.proposals.editDraft(
                          widget.proposalId,
                          _preview!.setReminder(item.id, value),
                        );
                      }),
              ),
              Wrap(
                alignment: WrapAlignment.end,
                children: [
                  IconButton(
                    key: ValueKey('edit-plan-${item.id}'),
                    tooltip: '编辑条目',
                    color: Theme.of(context).colorScheme.primary,
                    onPressed: _busy ? null : () => _itemEditor(item),
                    icon: const Icon(CupertinoIcons.pencil),
                  ),
                  IconButton(
                    key: ValueKey('delete-plan-${item.id}'),
                    tooltip: '删除条目',
                    color: Theme.of(context).colorScheme.error,
                    onPressed: _busy
                        ? null
                        : () => _edit(_preview!.remove(item.id)),
                    icon: const Icon(CupertinoIcons.trash),
                  ),
                ],
              ),
            ] else if (_row!.status == 'applied')
              Align(
                alignment: Alignment.centerRight,
                child: IconButton(
                  tooltip: '查看对应日期',
                  onPressed: () => _view(item),
                  icon: const Icon(CupertinoIcons.calendar),
                ),
              ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final today = CalendarDate.parse(
      (ref.watch(environmentProvider).value?.day ??
              ref.read(clockProvider).read().day)
          .key,
    );
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
    return AssistantIdentityBoundary(
      store: _store,
      child: Scaffold(
        appBar: pageAppBar(
          context,
          '计划',
          actions: [
            if (draft && row?.agentMetadata == null)
              IconButton(
                tooltip: '清除全部时间',
                onPressed: _busy ? null : () => _edit(preview!.clearTimes()),
                icon: const Icon(CupertinoIcons.timer),
              ),
          ],
        ),
        body: SafeArea(
          child: PageScroll(
            controller: _scroll,
            children: [
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: NoticeBanner(tone: NoticeTone.error, message: _error!),
                ),
              if (row == null || preview == null)
                StatusPanel(
                  message: _error == null ? '正在读取计划' : '计划暂不可用',
                  loading: _error == null,
                  retry: _error == null ? null : _load,
                )
              else ...[
                if (row.agentMetadata != null)
                  AgentRunDetails(
                    metadata: AgentRunMetadata.decode(row.agentMetadata!),
                    scope: 'proposal',
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
                  child: Text(
                    draft
                        ? '待确认 · ${preview.items.length} 项'
                        : row.status == 'undone'
                        ? '已撤销'
                        : '已创建 ${(jsonDecode(row.appliedGoalIdsJson!) as List).length} 项',
                    style: Theme.of(context).textTheme.headlineSmall,
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
                if (draft)
                  XyGroup(
                    margin: const EdgeInsets.only(top: 16),
                    children: [
                      SwitchListTile.adaptive(
                        title: const Text('开启定时提醒'),
                        value:
                            preview.items.any(
                              (item) => item.task.time != null,
                            ) &&
                            preview.items
                                .where((item) => item.task.time != null)
                                .every((item) => item.reminder),
                        onChanged:
                            _busy ||
                                !preview.items.any(
                                  (item) => item.task.time != null,
                                )
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
                for (final day in days)
                  XyGroup(
                    header:
                        '${dateLabel(LocalDate.parse(day))} ${weekdayLabels[CalendarDate.parse(day).weekday - 1]}',
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
                    header: '重复习惯',
                    children: [
                      for (final item in preview.items.where(
                        (item) => item.task.isHabit,
                      ))
                        _item(item, issues, draft),
                    ],
                  ),
                const SizedBox(height: 28),
                if (draft && _scheduleChanged) ...[
                  const NoticeBanner(
                    key: ValueKey('agent-schedule-changed'),
                    tone: NoticeTone.warning,
                    message: '安排有变化',
                  ),
                  const SizedBox(height: 8),
                  if (!(_agentValidation?.hasErrors ?? false))
                    const Text('计划内容或无法判断的安排已变化，请重新检查逐项提示。未创建任何内容。'),
                  OutlinedButton.icon(
                    key: const ValueKey('agent-replan'),
                    onPressed: _busy
                        ? null
                        : () =>
                              Navigator.of(context)
                                  .pop(AgentProposalAction.replan),
                    icon: const Icon(CupertinoIcons.arrow_clockwise),
                    label: const Text('重新规划'),
                  ),
                  TextButton.icon(
                    key: const ValueKey('agent-return-edit'),
                    onPressed: _busy ? null : _returnEdit,
                    icon: const Icon(CupertinoIcons.pencil),
                    label: const Text('返回修改'),
                  ),
                ],
                if (draft &&
                    (_agentValidation?.partialIndexes.isNotEmpty ?? false))
                  CheckboxListTile.adaptive(
                    key: const ValueKey('agent-partial-acknowledgement'),
                    title: const Text('我已了解有无法判断的项'),
                    contentPadding: EdgeInsets.zero,
                    value: _partialAcknowledged,
                    onChanged: _busy
                        ? null
                        : (value) => setState(
                            () => _partialAcknowledged = value == true,
                          ),
                  ),
                if (draft && (_agentValidation?.hasErrors ?? false))
                  const NoticeBanner(
                    key: ValueKey('agent-invalid-draft'),
                    tone: NoticeTone.error,
                    message: '没能排出不冲突的方案，请调整后再确认。',
                  ),
                if (draft &&
                    !_scheduleChanged &&
                    !(_agentValidation?.hasErrors ?? false))
                  FilledButton(
                    key: const ValueKey('assistant-apply-plan'),
                    onPressed:
                        _busy ||
                            preview.items.isEmpty ||
                            ((_agentValidation?.partialIndexes.isNotEmpty ??
                                    false) &&
                                !_partialAcknowledged) ||
                            issues.any((issue) => issue.blocksConfirmation)
                        ? null
                        : _apply,
                    child: Text(_busy ? '正在保存' : '确认创建'),
                  ),
                if (row.status == 'applied')
                  OutlinedButton(
                    key: const ValueKey('assistant-undo-plan'),
                    onPressed: _busy ? null : _undo,
                    child: const Text('撤销本批'),
                  ),
                if (row.status == 'undone') ...[
                  for (final item in ProposalUndoResult.decode(
                    row.undoResultJson!,
                  ).items)
                    Text('${item.title}：${_disposition(item.disposition)}'),
                ],
                if (!draft) const ReminderOverview(compact: true),
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
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .85,
      child: SafeArea(
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '编辑条目',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('assistant-save-plan-item'),
                      tooltip: '保存条目',
                      onPressed: _save,
                      icon: const Icon(CupertinoIcons.checkmark),
                    ),
                  ],
                ),
                SizedBox(height: MediaQuery.textScalerOf(context).scale(12)),
                TextFormField(
                  key: const ValueKey('assistant-plan-title'),
                  controller: _title,
                  maxLength: 60,
                  decoration: InputDecoration(
                    labelText: '名称',
                    fillColor: context.xy.cardSoft,
                  ),
                  validator: (value) =>
                      value == null || value.trim().isEmpty ? '请输入名称' : null,
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  key: const ValueKey('assistant-plan-date'),
                  onPressed: _pickDate,
                  icon: const Icon(CupertinoIcons.calendar),
                  label: Text(_date.key),
                ),
                if (widget.item.task.isHabit) ...[
                  for (var day = 1; day <= 7; day++)
                    CheckboxListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: Text(weekdayLabels[day - 1]),
                      value: _weekdays.contains(day),
                      onChanged: (value) => setState(() {
                        if (value == true) {
                          _weekdays.add(day);
                        } else {
                          _weekdays.remove(day);
                        }
                      }),
                    ),
                ],
                const SizedBox(height: 12),
                Card(
                  color: context.xy.cardSoft,
                  child: GoalTimingFields(
                    startMinute: _time,
                    durationMinutes: _minutes,
                    onStartChanged: (value) => setState(() => _time = value),
                    onDurationChanged: (value) =>
                        setState(() => _minutes = value),
                  ),
                ),
                if (_error != null)
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// A per-item agent check result: amber for "can't fully judge", red for a
/// hard problem.
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
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              partial
                  ? CupertinoIcons.exclamationmark_triangle_fill
                  : CupertinoIcons.xmark_octagon_fill,
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
