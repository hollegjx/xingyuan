import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

import '../../../app/providers.dart';
import '../../../data/local/app_database.dart';
import '../../../data/sync/identity_store.dart';
import '../../../app/theme.dart';
import '../../../shared/presentation.dart';
import '../../../shared/ui/composer.dart';
import '../../../shared/ui/sparkle.dart';
import '../../journal/domain/journal_entry.dart';
import '../../journal/presentation/chat_diary_page.dart';
import '../../journal/presentation/journal_editor_page.dart';
import '../../reminders/notification_permissions.dart';
import '../assistant_providers.dart';
import '../data/assistant_conversation_runner.dart';
import '../data/assistant_service.dart';
import '../data/assistant_record_tools.dart';
import '../domain/plan_preview.dart';
import 'assistant_consent_page.dart';
import 'assistant_conversation_controller.dart';
import 'assistant_conversation_details_page.dart';
import 'assistant_proposal_page.dart';
import '../domain/agent_run_metadata.dart';
import 'agent_run_details.dart';
import 'assistant_sessions_page.dart';
import 'assistant_settings_page.dart';

/// The conversation is one quiet sheet: white in light mode, black in dark.
Color _sheet(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? Theme.of(context).colorScheme.surface
    : context.xy.card;

/// A soft rounded pill for secondary actions in the conversation.
ButtonStyle _pill(BuildContext context, {bool tinted = false}) {
  final scheme = Theme.of(context).colorScheme;
  return FilledButton.styleFrom(
    backgroundColor: tinted ? scheme.primaryContainer : context.xy.cardSoft,
    foregroundColor: tinted ? scheme.onPrimaryContainer : scheme.onSurface,
    minimumSize: const Size(0, 36),
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    shape: const StadiumBorder(),
    tapTargetSize: MaterialTapTargetSize.padded,
    textStyle: Theme.of(context).textTheme.bodyMedium
        ?.copyWith(fontWeight: FontWeight.w600),
  );
}

class AssistantConversationView extends ConsumerStatefulWidget {
  const AssistantConversationView({super.key});
  @override
  ConsumerState<AssistantConversationView> createState() =>
      _AssistantConversationViewState();
}

class _AssistantConversationViewState
    extends ConsumerState<AssistantConversationView>
    with WidgetsBindingObserver {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _composer = GlobalKey();
  final _drafts = <String, TextEditingValue>{};
  String? _inputSession;
  AssistantConversationController? _observed;
  int _messageCount = 0;
  int _consentRevision = 0;
  bool _confirmingProposal = false;
  bool _openingProposal = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _observed?.setAgentForeground(state == AppLifecycleState.resumed);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _observed?.setAgentForeground(false);
    _observed?.removeListener(_changed);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _observe(AssistantConversationController controller) {
    if (identical(_observed, controller)) return;
    _observed?.removeListener(_changed);
    if (_observed != null) {
      _drafts.clear();
      _input.clear();
    }
    _observed = controller;
    controller.setAgentForeground(
      WidgetsBinding.instance.lifecycleState == null ||
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
    );
    _inputSession = controller.session?.id;
    _messageCount = controller.messages.length;
    controller.addListener(_changed);
  }

  void _changed() {
    final controller = _observed!;
    if (controller.identityChanged) {
      _drafts.clear();
      _input.clear();
      _inputSession = null;
    } else {
      final ids = controller.sessions.map((session) => session.id).toSet();
      _drafts.removeWhere((id, _) => !ids.contains(id));
      final selected = controller.session?.id;
      if (_inputSession != selected) {
        if (_inputSession != null && ids.contains(_inputSession)) {
          _drafts[_inputSession!] = _input.value;
        }
        _input.value = _drafts[selected] ?? TextEditingValue.empty;
        _inputSession = selected;
      }
    }
    if (_messageCount != controller.messages.length) _toComposer();
    _messageCount = controller.messages.length;
  }

  /// Brings the newest message into view above the pinned composer.
  void _toComposer() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!mounted || !_scroll.hasClients) return;
    final end = _scroll.position.maxScrollExtent;
    if (MediaQuery.disableAnimationsOf(context)) {
      _scroll.jumpTo(end);
    } else {
      _scroll.animateTo(
        end,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
    }
  });

  Future<void> _settings() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const AssistantSettingsPage()),
    );
    if (mounted) {
      ref.invalidate(assistantCredentialReadyProvider);
      await _observed?.refresh();
    }
  }

  Future<void> _proposal(
    StoredPlanProposal proposal, {
    bool undo = false,
  }) async {
    if (_openingProposal) return;
    _openingProposal = true;
    try {
      final action = await Navigator.of(context).push<AgentProposalAction>(
        MaterialPageRoute<AgentProposalAction>(
          builder: (_) =>
              AssistantProposalPage(proposalId: proposal.id, requestUndo: undo),
        ),
      );
      if (mounted) {
        await _observed?.refresh();
        if (mounted && action == AgentProposalAction.replan) {
          if (_input.text.trim().isEmpty) {
            _input.text = '请根据最新安排重新规划。';
            _input.selection = TextSelection.collapsed(
              offset: _input.text.length,
            );
          }
          _toComposer();
        }
      }
    } finally {
      _openingProposal = false;
    }
  }

  Future<void> _confirmProposal(
    StoredPlanProposal proposal,
    AssistantConversationController controller,
  ) async {
    bool current() =>
        mounted &&
        identical(_observed, controller) &&
        !controller.identityChanged &&
        !controller.busy &&
        controller.session?.id == proposal.sessionId &&
        ModalRoute.of(context)?.isCurrent == true;
    if (_confirmingProposal || _openingProposal || !current()) return;
    setState(() => _confirmingProposal = true);
    try {
      final store = controller.store;
      final row = await store.proposals.read(proposal.id);
      if (!current()) return;
      // Confirm only the exact draft shown on the card, never an unseen edit.
      if (row.status != 'draft' ||
          row.agentMetadata == null ||
          row.itemsJson != proposal.itemsJson) {
        await _proposal(row);
        return;
      }
      final preview = PlanPreview.decode(row.itemsJson);
      final check = await store.proposals.inspectAgent(row.id, preview);
      if (!current()) return;
      final issues = preview.inspect(
        today: CalendarDate.parse(store.goals.clock.read().day.key),
        goals: const [],
        agent: true,
      );
      if (preview.items.isEmpty ||
          check == null ||
          check.validation.hasErrors ||
          check.validation.partialIndexes.isNotEmpty ||
          issues.any((issue) => issue.blocksConfirmation)) {
        await _proposal(row);
        return;
      }
      if (preview.items.any((item) => item.reminder)) {
        await ref.read(notificationAccessProvider.notifier).refresh();
        if (!current()) return;
        final access = ref.read(notificationAccessProvider);
        if (access.hasError ||
            (access.value != NotificationAccess.allowed &&
                access.value != NotificationAccess.quiet)) {
          await _proposal(row);
          return;
        }
      }
      await store.proposals.apply(
        row.id,
        preview,
        expectedAgentValidation: check.token,
      );
      if (!current()) return;
      await ref.read(reminderReportProvider.notifier).refresh();
      if (!current()) return;
      // Refresh reports failures through AsyncValue, not only exceptions.
      if (ref.read(reminderReportProvider).hasError) {
        await _proposal(row);
        return;
      }
      await controller.refresh();
    } on StaleIdentity {
      if (mounted && identical(_observed, controller)) {
        await controller.refresh();
      }
    } catch (_) {
      if (current()) await _proposal(proposal);
    } finally {
      if (mounted) setState(() => _confirmingProposal = false);
    }
  }

  Future<void> _send(
    AssistantConversationController controller, {
    StoredAssistantMessage? retry,
    String? entryText,
    AssistantRecordScope? recordScope,
  }) async {
    if (retry != null) {
      final approved = await confirmAction(
        context,
        title: '重试这条消息？',
        message: '将使用新的请求编号，可能再次调用模型；之前的失败记录会保留。',
        confirm: '重试',
        confirmKey: const ValueKey('assistant-confirm-retry'),
      );
      if (approved != true || !mounted) return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    final submitted = entryText ?? _input.text;
    Future<bool> confirmRead(CalendarDate day, Set<String> kinds) async {
      if (!mounted || !controller.busy) return false;
      BuildContext? dialog;
      void closeIfCancelled() {
        final current = dialog;
        if (current != null &&
            current.mounted &&
            !controller.busy &&
            ModalRoute.of(current)?.isCurrent == true) {
          Navigator.pop(current, false);
        }
      }

      controller.addListener(closeIfCancelled);
      try {
        return await showDialog<bool>(
              context: context,
              builder: (dialogContext) {
                dialog = dialogContext;
                if (!controller.busy) {
                  WidgetsBinding.instance.addPostFrameCallback(
                    (_) => closeIfCancelled(),
                  );
                }
                return AlertDialog(
                  key: const ValueKey('assistant-read-confirm'),
                  title: Text('读取 ${day.month}月${day.day}日 的记录？'),
                  content: const Text('只读这一天的完成情况、随手记和日记，用来写日记或回顾。'),
                  actions: [
                    TextButton(
                      key: const ValueKey('assistant-read-deny'),
                      onPressed: () => Navigator.pop(dialogContext, false),
                      child: const Text('不用'),
                    ),
                    TextButton(
                      key: const ValueKey('assistant-read-allow'),
                      onPressed: () => Navigator.pop(dialogContext, true),
                      child: const Text('允许'),
                    ),
                  ],
                );
              },
            ) ??
            false;
      } finally {
        controller.removeListener(closeIfCancelled);
      }
    }

    await controller.send(
      retry?.content ?? submitted,
      retryMessageId: retry?.id,
      confirmRead: confirmRead,
      recordScope: recordScope,
      onAccepted: (sessionId) {
        if (mounted && retry == null) {
          // First sends create a session; adopt any new typing into it.
          _inputSession = sessionId;
          if (entryText == null && _input.text == submitted) _input.clear();
        }
        _toComposer();
      },
    );
    if (mounted) {
      ref.invalidate(assistantMemoriesProvider);
      ref.invalidate(assistantSessionsProvider);
    }
  }

  void _suggest(String text) {
    _input.text = text;
    _input.selection = TextSelection.collapsed(offset: text.length);
  }

  Widget _memory(
    StoredMemoryEvent event,
    AssistantConversationController controller,
  ) {
    final xy = context.xy;
    final raw = event.afterJson ?? event.beforeJson;
    final text = raw == null
        ? ''
        : StoredAssistantMemory.fromJson(
            jsonDecode(raw) as Map<String, dynamic>,
          ).content;
    final skipped = event.afterJson == null && event.beforeJson == null;
    final label = event.reverted
        ? '已撤销记忆操作'
        : switch (event.op) {
            'add' => '已记住',
            'update' => '已更新',
            _ => '已忘掉',
          };
    return Row(
      children: [
        Icon(CupertinoIcons.bookmark, size: 14, color: xy.muted),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            skipped ? '记忆已达 200 条，本条未保存，请先清理。' : '$label：$text',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: xy.muted),
          ),
        ),
        if (!skipped)
          IconButton(
            key: ValueKey('undo-memory-${event.id}'),
            tooltip: '撤销记忆操作',
            color: xy.muted,
            iconSize: 17,
            onPressed: event.reverted
                ? null
                : () async {
                    await controller.undoMemory(event.id);
                    if (mounted) ref.invalidate(assistantMemoriesProvider);
                  },
            icon: const Icon(CupertinoIcons.arrow_uturn_left),
          ),
      ],
    );
  }

  Widget _message(
    StoredAssistantMessage message,
    AssistantConversationController controller,
  ) {
    final user = message.role == 'user';
    final proposal = controller.proposals
        .where((row) => row.messageId == message.id)
        .firstOrNull;
    final failed =
        message.status == 'failed' ||
        message.status == 'discarded' ||
        (message.status == 'pending' &&
            controller.failures.containsKey(message.id));
    final diary = controller.diaryProposals
        .where((row) => row.messageId == message.id)
        .firstOrNull;
    final theme = Theme.of(context);
    final xy = context.xy;
    final text = SelectableText(
      message.content,
      style: theme.textTheme.bodyLarge?.copyWith(height: user ? 1.45 : 1.6),
    );
    final extras = <Widget>[
      if (message.agentMetadata != null)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: AgentRunDetails(
            metadata: AgentRunMetadata.decode(message.agentMetadata!),
            scope: message.id,
          ),
        ),
      if (failed)
        Padding(
          padding: const EdgeInsets.only(top: 14),
          child: _FailureNote(
            title: message.status == 'discarded' ? '已停止' : '这次没有完成',
            message:
                controller.failures[message.id] ??
                (message.status == 'discarded'
                    ? const AssistantFailure(AssistantFailureKind.cancelled)
                          .message
                    : '本轮未完成，未创建任何内容。重试可能再次调用模型。'),
            action: FilledButton.icon(
              key: ValueKey('retry-${message.id}'),
              style: _pill(context, tinted: true),
              onPressed: controller.busy
                  ? null
                  : () => _send(controller, retry: message),
              icon: const Icon(CupertinoIcons.arrow_clockwise, size: 15),
              label: const Text('重试'),
            ),
          ),
        ),
      if (proposal != null)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: _PlanCard(
            proposal: proposal,
            busy: _confirmingProposal || controller.busy,
            onOpen: () {
              if (!_confirmingProposal) _proposal(proposal);
            },
            onConfirm: () => _confirmProposal(proposal, controller),
            onUndo: () => _proposal(proposal, undo: true),
          ),
        ),
      for (final event
          in controller.events[message.id] ?? <StoredMemoryEvent>[])
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: _memory(event, controller),
        ),
      if (diary != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (diary.status == 'pending' &&
                  message.agentMetadata != null &&
                  diary.suggestedDay != null)
                Text(
                  '${CalendarDate.parse(diary.suggestedDay!).month}月${CalendarDate.parse(diary.suggestedDay!).day}日 的日记草稿',
                ),
              if (diary.status == 'pending')
                Text(
                  message.agentMetadata != null
                      ? '还没有保存，打开后可以修改，再确认保存。'
                      : '尚未写入日记',
                  style: theme.textTheme.bodySmall?.copyWith(color: xy.muted),
                ),
              TextButton.icon(
                key: ValueKey('open-diary-proposal-${diary.id}'),
                onPressed: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => ChatDiaryPage(proposalId: diary.id),
                    ),
                  );
                  if (mounted) await controller.refresh();
                },
                icon: const Icon(CupertinoIcons.book, size: 17),
                label: Text(switch (diary.status) {
                  'applied' => '${diary.targetDay} 日记保存回执',
                  'undone' => '日记写入已撤销',
                  'cancelled' => '日记建议已取消',
                  _ => message.agentMetadata != null ? '打开草稿' : '预览日记建议',
                }),
              ),
            ],
          ),
        ),
    ];
    if (!user) {
      // Replies read as plain text on the sheet, with no bubble or avatar.
      return Padding(
        key: ValueKey('assistant-message-${message.id}'),
        padding: const EdgeInsets.only(bottom: 26),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [text, ...extras],
        ),
      );
    }
    return Padding(
      key: ValueKey('assistant-message-${message.id}'),
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 40),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (message.sentPayload != null)
                  IconButton(
                    key: ValueKey('payload-${message.id}'),
                    tooltip: '本轮发送内容',
                    color: xy.faint,
                    iconSize: 17,
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => AssistantConversationDetailsPage(
                          store: controller.store,
                          sessionId: message.sessionId,
                          messageId: message.id,
                        ),
                      ),
                    ),
                    icon: const Icon(CupertinoIcons.doc_text_search),
                  ),
                Flexible(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer,
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(20),
                        topRight: Radius.circular(20),
                        bottomLeft: Radius.circular(20),
                        bottomRight: Radius.circular(6),
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(15, 10, 15, 10),
                      child: text,
                    ),
                  ),
                ),
              ],
            ),
          ),
          ...extras,
        ],
      ),
    );
  }

  Widget _running(AssistantConversationController controller) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const XyActivity(radius: 8),
              const SizedBox(width: 10),
              Flexible(
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    switch (controller.stage) {
                      AssistantRunStage.summarizing => '正在整理会话',
                      AssistantRunStage.sending => '正在思考',
                      AssistantRunStage.saving => '正在保存',
                      AssistantRunStage.querying => '正在查看日程',
                      AssistantRunStage.finding => '正在找空档',
                      AssistantRunStage.preferences => '正在读取偏好',
                      AssistantRunStage.validating => '正在检查冲突',
                      AssistantRunStage.adjusting => '有冲突，正在调整',
                      AssistantRunStage.confirming => '等你确认',
                      null => '正在准备',
                    },
                    key: const ValueKey('agent-stage'),
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              const _Elapsed(),
            ],
          ),
          if (controller.agentProgress != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: AgentRunDetails(
                metadata: controller.agentProgress!,
                scope: 'running',
              ),
            ),
          const SizedBox(height: 6),
          FilledButton.icon(
            key: const ValueKey('assistant-cancel'),
            style: _pill(context),
            onPressed: controller.cancel,
            icon: const Icon(CupertinoIcons.stop_fill, size: 12),
            label: const Text('停止'),
          ),
        ],
      ),
    );
  }

  Widget _conversation(AssistantConversationController controller) {
    _observe(controller);
    final configured = ref.watch(assistantServiceProvider).configured;
    final credential = ref.watch(assistantCredentialReadyProvider);
    return ColoredBox(
      color: _sheet(context),
      child: SafeArea(
        bottom: false,
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            if (controller.identityChanged) {
              return PageScroll(
                children: [
                  StatusPanel(
                    message: controller.error!,
                    retry: () => ref.invalidate(assistantStoreProvider),
                  ),
                ],
              );
            }
            final ready = configured && credential.value == true;
            return LayoutBuilder(
              builder: (context, constraints) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _PlanningTools(
                    scroll: _scroll,
                    onSessions: () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              AssistantSessionsPage(controller: controller),
                        ),
                      );
                      if (mounted) _toComposer();
                    },
                    onDetails: controller.session == null
                        ? null
                        : () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => AssistantConversationDetailsPage(
                                store: controller.store,
                                sessionId: controller.session!.id,
                              ),
                            ),
                          ),
                    onSettings: _settings,
                  ),
                  // Let the heading scroll too; it must not crowd out the composer.
                  Expanded(
                    child: PageScroll(
                      key: const ValueKey('assistant-conversation-scroll'),
                      controller: _scroll,
                      padding: EdgeInsets.zero,
                      children: [
                        const _PlanningTitle(),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (!ready) ...[
                                NoticeBanner(
                                  tone: NoticeTone.info,
                                  message: !configured
                                      ? 'AI 服务未连接；目标、打卡和本地提醒仍可使用。'
                                      : credential.hasError
                                      ? '无法读取访问凭证，请解锁设备后在 AI 设置中重试。'
                                      : credential.isLoading
                                      ? '正在读取凭证状态'
                                      : '尚未录入访问凭证，请在 AI 设置中录入。',
                                ),
                                const SizedBox(height: 16),
                              ],
                              if (controller.messages.isEmpty)
                                _Welcome(
                                  onPick: _suggest,
                                  onDiary: () => openJournalEditor(
                                    context,
                                    kind: JournalKind.diary,
                                    day: ref.read(clockProvider).read().day,
                                  ),
                                ),
                              if (ready && controller.messages.isEmpty)
                                TextButton(
                                  key: const ValueKey('assistant-record-entry'),
                                  onPressed: controller.busy
                                      ? null
                                      : () => _send(
                                          controller,
                                          entryText: '请使用今天的目标、打卡文字、随手记和日记，帮我整理一份日记建议。',
                                          recordScope: AssistantRecordScope(
                                            CalendarDate.parse(
                                              ref
                                                  .read(clockProvider)
                                                  .read()
                                                  .day
                                                  .key,
                                            ),
                                            {'summary', 'quickNote', 'diary'},
                                          ),
                                        ),
                                  child: const Text('请助手按今天的记录写日记'),
                                ),
                              for (final message in controller.messages)
                                _message(message, controller),
                              if (controller.error != null) ...[
                                NoticeBanner(
                                  tone: NoticeTone.error,
                                  message: controller.error!,
                                ),
                                const SizedBox(height: 12),
                              ],
                              if (controller.busy) _running(controller),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  // A pinned bar: its type grows only to 2x and it takes at
                  // most 40% of the height, so the plan above stays readable.
                  MediaQuery.withClampedTextScaling(
                    maxScaleFactor: 2,
                    child: XyComposer(
                      key: _composer,
                      maxHeight: constraints.maxHeight * 0.4,
                      field: TextField(
                        key: const ValueKey('assistant-input'),
                        controller: _input,
                        minLines: 1,
                        maxLines: 5,
                        maxLength: 2000,
                        decoration: composerDecoration(
                          context,
                          hint: '想写日记、排日程，都可以跟我说',
                        ),
                        textInputAction: TextInputAction.newline,
                      ),
                      send: ValueListenableBuilder<TextEditingValue>(
                        valueListenable: _input,
                        builder: (context, value, _) => sendButton(
                          context,
                          key: const ValueKey('assistant-send'),
                          onPressed:
                              !ready ||
                                  controller.busy ||
                                  value.text.trim().isEmpty
                              ? null
                              : () => _send(controller),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  /// The tab title for states that have no conversation header of their own.
  Widget _titled(Widget child) => SafeArea(
    bottom: false,
    child: PageScroll(
      padding: EdgeInsets.zero,
      children: [
        const TabHeader(title: '助手', subtitle: '帮你把今天写成日记，也帮你排日程'),
        child,
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => ref
      .watch(assistantSettingsProvider)
      .when(
        loading: () => _titled(
          const PageScroll(
            children: [StatusPanel(message: '正在读取规划设置', loading: true)],
          ),
        ),
        error: (_, _) => _titled(
          PageScroll(
            children: [
              StatusPanel(
                message: '无法读取规划设置',
                retry: () => ref.invalidate(assistantSettingsProvider),
              ),
            ],
          ),
        ),
        data: (settings) {
          if (settings.consentVersion != assistantConsentVersion ||
              settings.consentedAt == null) {
            return _titled(
              AssistantConsentBody(
                key: ValueKey(_consentRevision),
                onReopen: () {
                  ref.invalidate(assistantStoreProvider);
                  setState(() => _consentRevision++);
                },
              ),
            );
          }
          return ref
              .watch(assistantConversationProvider)
              .when(
                loading: () => _titled(
                  const PageScroll(
                    children: [StatusPanel(message: '正在读取会话', loading: true)],
                  ),
                ),
                error: (_, _) => _titled(
                  PageScroll(
                    children: [
                      StatusPanel(
                        message: '无法读取会话，原聊天未被清空。',
                        retry: () =>
                            ref.invalidate(assistantConversationProvider),
                      ),
                    ],
                  ),
                ),
                data: _conversation,
              );
        },
      );
}

/// The large title; it scrolls with the conversation, iOS style.
class _PlanningTitle extends StatelessWidget {
  const _PlanningTitle();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
    child: Semantics(
      header: true,
      child: Text(
        '助手',
        style: Theme.of(context).textTheme.headlineMedium?.copyWith(
          fontSize: 30,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
        ),
      ),
    ),
  );
}

/// Quiet navigation icons; a hairline appears once the conversation scrolls.
class _PlanningTools extends StatelessWidget {
  const _PlanningTools({
    required this.scroll,
    required this.onSessions,
    required this.onDetails,
    required this.onSettings,
  });

  final ScrollController scroll;
  final VoidCallback onSessions;
  final VoidCallback? onDetails;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final xy = context.xy;
    return ListenableBuilder(
      listenable: scroll,
      builder: (context, child) => DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: scroll.hasClients && scroll.offset > 0
                  ? xy.line
                  : Colors.transparent,
              width: 0.5,
            ),
          ),
        ),
        child: child,
      ),
      child: SizedBox(
        key: const ValueKey('assistant-navigation'),
        height: 48,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              IconButton(
                tooltip: '会话列表',
                color: xy.muted,
                onPressed: onSessions,
                icon: const Icon(CupertinoIcons.clock),
              ),
              IconButton(
                tooltip: '会话信息',
                color: xy.muted,
                onPressed: onDetails,
                icon: const Icon(CupertinoIcons.info),
              ),
              IconButton(
                tooltip: 'AI 设置',
                color: xy.muted,
                onPressed: onSettings,
                icon: const Icon(CupertinoIcons.slider_horizontal_3),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The empty conversation: one question and a few things to try.
class _Welcome extends StatelessWidget {
  const _Welcome({required this.onPick, required this.onDiary});

  final ValueChanged<String> onPick;
  final VoidCallback onDiary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final xy = context.xy;
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Align(
            alignment: Alignment.centerLeft,
            child: StarMark(lit: true, size: 28, glow: false),
          ),
          const SizedBox(height: 14),
          Text('今天想做点什么？', style: theme.textTheme.headlineSmall),
          const SizedBox(height: 6),
          Text(
            '我可以把今天的打卡和随手记整理成一篇日记，也可以把想做的事排进日程。你确认之前，什么都不会保存。',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: xy.muted,
              height: 1.6,
            ),
          ),
          const SizedBox(height: 20),
          // The day's diary is the most asked-for help; it gets a card of
          // its own instead of hiding behind the diary editor.
          Material(
            color: xy.card,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(xyCardRadius),
              side: BorderSide(color: xy.line),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: const ValueKey('assistant-write-diary'),
              onTap: onDiary,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 12, 16),
                child: Row(
                  children: [
                    Icon(CupertinoIcons.book, color: scheme.primary, size: 24),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('用今天写日记', style: theme.textTheme.titleMedium),
                          const SizedBox(height: 2),
                          Text(
                            '打开今天的日记，点底部的「AI 写日记」，星愿会用今天的打卡和随手记起个头。',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: xy.muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      CupertinoIcons.chevron_right,
                      size: 16,
                      color: xy.faint,
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 22),
          Text(
            '排进日程',
            style: theme.textTheme.titleSmall?.copyWith(color: xy.muted),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final example in const [
                '这周每天读书 20 分钟',
                '明天下午整理一小时房间',
                '周一三五早上跑步 30 分钟',
              ])
                FilledButton(
                  style: _pill(context).copyWith(
                    textStyle: WidgetStatePropertyAll(
                      theme.textTheme.bodyMedium,
                    ),
                  ),
                  onPressed: () => onPick(example),
                  child: Text(example),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Seconds since the current run started, so a long wait never looks frozen.
class _Elapsed extends StatefulWidget {
  const _Elapsed();

  @override
  State<_Elapsed> createState() => _ElapsedState();
}

class _ElapsedState extends State<_Elapsed> {
  final _watch = Stopwatch()..start();
  late final Timer _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final seconds = _watch.elapsed.inSeconds;
    if (seconds < 1) return const SizedBox.shrink();
    return Text(
      '· $seconds 秒',
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
        color: context.xy.muted,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

/// A turn that did not finish: what happened, and one way forward.
class _FailureNote extends StatelessWidget {
  const _FailureNote({
    required this.title,
    required this.message,
    required this.action,
  });

  final String title;
  final String message;
  final Widget action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final xy = context.xy;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(
            CupertinoIcons.exclamationmark_circle,
            size: 20,
            color: xy.warning,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: theme.textTheme.bodyLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                message,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: xy.muted,
                  height: 1.55,
                ),
              ),
              const SizedBox(height: 4),
              action,
            ],
          ),
        ),
      ],
    );
  }
}

/// The plan inline in the conversation: each item at a glance, then the
/// decision. Details, editing and undo live on [AssistantProposalPage].
class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.proposal,
    required this.onOpen,
    required this.onConfirm,
    required this.onUndo,
    this.busy = false,
  });

  final StoredPlanProposal proposal;
  final VoidCallback onOpen;
  final VoidCallback onConfirm;
  final VoidCallback onUndo;
  final bool busy;

  static const _shown = 4;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final xy = context.xy;
    final dark = theme.brightness == Brightness.dark;
    final status = proposal.status;
    final draft = status == 'draft';
    var items = const <PreviewItem>[];
    try {
      items = PlanPreview.decode(
        draft
            ? proposal.itemsJson
            : proposal.appliedItemsJson ?? proposal.itemsJson,
      ).items;
    } on FormatException {
      // The detail page explains unreadable plans; keep the card usable.
    }
    final count = status == 'applied'
        ? (jsonDecode(proposal.appliedGoalIdsJson!) as List).length
        : items.length;
    final header = switch (status) {
      'applied' => Row(
        children: [
          Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              color: xy.success,
              shape: BoxShape.circle,
            ),
            child: Icon(
              CupertinoIcons.checkmark_alt,
              size: 13,
              color: dark ? Colors.black : Colors.white,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '已添加 $count 项',
              style: theme.textTheme.bodyLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          TextButton.icon(
            key: ValueKey('undo-proposal-${proposal.id}'),
            onPressed: onUndo,
            icon: const Icon(CupertinoIcons.arrow_uturn_left, size: 15),
            label: const Text('撤销'),
          ),
        ],
      ),
      'undone' => Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Text(
          '已撤销',
          style: theme.textTheme.bodyLarge?.copyWith(
            fontWeight: FontWeight.w600,
            color: xy.muted,
          ),
        ),
      ),
      _ => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '计划草稿 · $count 项',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: xy.muted,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (proposal.agentMetadata != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '等你确认',
                  key: const ValueKey('agent-awaiting-confirmation'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
          ],
        ),
      ),
    };
    final stacked = MediaQuery.textScalerOf(context).scale(16) > 28;
    final buttons = [
      FilledButton(
        key: ValueKey('adjust-proposal-${proposal.id}'),
        style: FilledButton.styleFrom(
          backgroundColor: xy.cardSoft,
          foregroundColor: theme.colorScheme.onSurface,
          minimumSize: const Size(0, 46),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(13),
          ),
        ),
        onPressed: busy ? null : onOpen,
        child: const Text('调整'),
      ),
      FilledButton(
        key: ValueKey('open-proposal-${proposal.id}'),
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 46),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(13),
          ),
        ),
        onPressed: busy ? null : onConfirm,
        child: const Text('确认添加'),
      ),
    ];
    return Material(
      color: xy.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: dark ? BorderSide.none : BorderSide(color: xy.fill),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 8, 2),
            child: header,
          ),
          for (var i = 0; i < items.length && i < _shown; i++)
            _PlanRow(item: items[i], divided: i > 0, muted: status == 'undone'),
          if (items.length > _shown)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
              child: Text(
                '还有 ${items.length - _shown} 项',
                style: theme.textTheme.bodySmall?.copyWith(color: xy.muted),
              ),
            ),
          if (draft)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: stacked
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        buttons[1],
                        const SizedBox(height: 8),
                        buttons[0],
                      ],
                    )
                  : Row(
                      children: [
                        Expanded(child: buttons[0]),
                        const SizedBox(width: 10),
                        Expanded(flex: 2, child: buttons[1]),
                      ],
                    ),
            )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 4),
                Divider(height: 0.5, thickness: 0.5, color: xy.line),
                InkWell(
                  key: ValueKey('open-proposal-${proposal.id}'),
                  onTap: onOpen,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 46),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '查看详情',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.primary,
                              ),
                            ),
                          ),
                          Icon(
                            CupertinoIcons.chevron_right,
                            size: 14,
                            color: theme.colorScheme.primary,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// One plan item: when and how long on the left, what and which day on
/// the right; stacked when large text leaves no room for two columns.
class _PlanRow extends StatelessWidget {
  const _PlanRow({
    required this.item,
    required this.divided,
    required this.muted,
  });

  final PreviewItem item;
  final bool divided;
  final bool muted;

  static const _weekdays = ['一', '二', '三', '四', '五', '六', '日'];

  String get _when {
    final task = item.task;
    final start = '${task.date.month}月${task.date.day}日';
    final days = task.weekdays;
    final when = days == null
        ? '周${_weekdays[task.date.weekday - 1]} $start'
        : '${days.length == 7 ? '每天' : '每周${days.map((day) => _weekdays[day - 1]).join()}'} · $start起';
    return item.reminder ? '$when · 提醒' : when;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final xy = context.xy;
    final task = item.task;
    final ink = muted ? xy.muted : theme.colorScheme.onSurface;
    final time = Text(
      task.time ?? '不定时',
      style: task.time == null
          ? theme.textTheme.bodyMedium?.copyWith(color: xy.muted)
          : theme.textTheme.titleMedium?.copyWith(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: ink,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
    );
    final length = task.minutes == null
        ? null
        : Text(
            '${task.minutes} 分钟',
            style: theme.textTheme.bodySmall?.copyWith(color: xy.muted),
          );
    final what = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          task.title,
          style: theme.textTheme.bodyLarge?.copyWith(color: ink),
        ),
        const SizedBox(height: 2),
        Text(
          _when,
          style: theme.textTheme.bodySmall?.copyWith(color: xy.muted),
        ),
      ],
    );
    final stacked = MediaQuery.textScalerOf(context).scale(18) > 30;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: divided
            ? Border(top: BorderSide(color: xy.line, width: 0.5))
            : null,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: stacked
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [time, ?length, const SizedBox(height: 4), what],
              )
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 66,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [time, ?length],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: what),
                ],
              ),
      ),
    );
  }
}
