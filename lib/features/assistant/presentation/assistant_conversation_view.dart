import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/local/app_database.dart';
import '../../../app/theme.dart';
import '../../../shared/presentation.dart';
import '../../../shared/ui/composer.dart';
import '../../../shared/ui/sparkle.dart';
import '../../journal/presentation/chat_diary_page.dart';
import '../assistant_providers.dart';
import '../data/assistant_conversation_runner.dart';
import '../data/assistant_service.dart';
import '../domain/plan_preview.dart';
import 'assistant_consent_page.dart';
import 'assistant_conversation_controller.dart';
import 'assistant_conversation_details_page.dart';
import 'assistant_proposal_page.dart';
import '../domain/agent_run_metadata.dart';
import 'agent_run_details.dart';
import 'assistant_sessions_page.dart';
import 'assistant_settings_page.dart';

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
  }

  Future<void> _send(
    AssistantConversationController controller, {
    StoredAssistantMessage? retry,
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
    final submitted = _input.text;
    await controller.send(
      retry?.content ?? submitted,
      retryMessageId: retry?.id,
      onAccepted: (sessionId) {
        if (mounted && retry == null) {
          // First sends create a session; adopt any new typing into it.
          _inputSession = sessionId;
          if (_input.text == submitted) _input.clear();
        }
        _toComposer();
      },
    );
    if (mounted) {
      ref.invalidate(assistantMemoriesProvider);
      ref.invalidate(assistantSessionsProvider);
    }
  }

  Widget _memory(
    StoredMemoryEvent event,
    AssistantConversationController controller,
  ) {
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
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(skipped ? '记忆已达 200 条，本条未保存，请先清理。' : '$label：$text'),
        ),
        if (!skipped)
          IconButton(
            key: ValueKey('undo-memory-${event.id}'),
            tooltip: '撤销记忆操作',
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
    final failed = message.status == 'failed' || message.status == 'discarded';
    final diary = controller.diaryProposals
        .where((row) => row.messageId == message.id)
        .firstOrNull;
    final theme = Theme.of(context);
    final xy = context.xy;
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!user || message.sentPayload != null)
          Row(
            children: [
              Expanded(
                child: user
                    ? const SizedBox.shrink()
                    : Text(
                        '星愿',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: xy.muted,
                        ),
                      ),
              ),
              if (user && message.sentPayload != null)
                IconButton(
                  key: ValueKey('payload-${message.id}'),
                  tooltip: '本轮发送内容',
                  visualDensity: VisualDensity.compact,
                  color: Colors.white.withValues(alpha: 0.8),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => AssistantConversationDetailsPage(
                        store: controller.store,
                        sessionId: message.sessionId,
                        messageId: message.id,
                      ),
                    ),
                  ),
                  icon: const Icon(CupertinoIcons.doc_text_search, size: 18),
                ),
            ],
          ),
        if (message.agentMetadata != null)
          AgentRunDetails(
            metadata: AgentRunMetadata.decode(message.agentMetadata!),
            scope: message.id,
          ),
        SelectableText(
          message.content,
          style: theme.textTheme.bodyLarge?.copyWith(
            color: user ? Colors.white : null,
          ),
        ),
        if (failed) ...[
          const SizedBox(height: 8),
          NoticeBanner(
            tone: NoticeTone.warning,
            message:
                controller.failures[message.id] ??
                (message.status == 'discarded'
                    ? const AssistantFailure(AssistantFailureKind.cancelled)
                          .message
                    : '本轮未完成，未创建任何内容。重试可能再次调用模型。'),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: IconButton(
              key: ValueKey('retry-${message.id}'),
              tooltip: '重试消息',
              color: user ? Colors.white : null,
              onPressed: controller.busy
                  ? null
                  : () => _send(controller, retry: message),
              icon: const Icon(CupertinoIcons.arrow_clockwise),
            ),
          ),
        ],
        if (proposal != null) ...[
          const SizedBox(height: 12),
          if (proposal.agentMetadata != null && proposal.status == 'draft')
            Align(
              alignment: Alignment.centerLeft,
              child: Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary
                      .withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      CupertinoIcons.hourglass,
                      size: 13,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        '等你确认',
                        key: const ValueKey('agent-awaiting-confirmation'),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          FilledButton.tonalIcon(
            key: ValueKey('open-proposal-${proposal.id}'),
            onPressed: () => _proposal(proposal),
            icon: const Icon(CupertinoIcons.calendar_badge_plus),
            label: Text(switch (proposal.status) {
              'applied' =>
                '已创建 ${(jsonDecode(proposal.appliedGoalIdsJson!) as List).length} 项 · 查看',
              'undone' => '已撤销 · 查看结果',
              _ =>
                '预览 ${PlanPreview.decode(proposal.itemsJson).items.length} 项',
            }),
          ),
          if (proposal.status == 'applied')
            Align(
              alignment: Alignment.centerRight,
              child: IconButton(
                key: ValueKey('undo-proposal-${proposal.id}'),
                tooltip: '撤销本批计划',
                color: user ? Colors.white : null,
                onPressed: () => _proposal(proposal, undo: true),
                icon: const Icon(CupertinoIcons.arrow_uturn_left),
              ),
            ),
        ],
        for (final event
            in controller.events[message.id] ?? <StoredMemoryEvent>[]) ...[
          const Divider(height: 24),
          _memory(event, controller),
        ],
        if (diary != null) ...[
          const SizedBox(height: 12),
          if (diary.status == 'pending') const Text('尚未写入日记'),
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
            icon: const Icon(CupertinoIcons.book),
            label: Text(switch (diary.status) {
              'applied' => '${diary.targetDay} 日记保存回执',
              'undone' => '日记写入已撤销',
              'cancelled' => '日记建议已取消',
              _ => '预览日记建议',
            }),
          ),
        ],
      ],
    );
    final bubble = Container(
      padding: EdgeInsets.fromLTRB(14, user ? 9 : 8, user ? 6 : 10, 10),
      decoration: BoxDecoration(
        color: user ? theme.colorScheme.primary : xy.card,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(18),
          topRight: const Radius.circular(18),
          bottomLeft: Radius.circular(user ? 18 : 5),
          bottomRight: Radius.circular(user ? 5 : 18),
        ),
      ),
      child: body,
    );
    return Padding(
      key: ValueKey('assistant-message-${message.id}'),
      padding: const EdgeInsets.only(bottom: 12),
      child: user
          ? Padding(
              padding: const EdgeInsets.only(left: 48),
              child: Align(alignment: Alignment.centerRight, child: bubble),
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 30,
                  height: 30,
                  margin: const EdgeInsets.only(right: 8, top: 2),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: xy.sky,
                    shape: BoxShape.circle,
                  ),
                  child: const StarMark(lit: true, size: 16, glow: false),
                ),
                Expanded(child: bubble),
              ],
            ),
    );
  }

  Widget _conversation(AssistantConversationController controller) {
    _observe(controller);
    final configured = ref.watch(assistantServiceProvider).configured;
    final credential = ref.watch(assistantCredentialReadyProvider);
    return ListenableBuilder(
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
        final xy = context.xy;
        return LayoutBuilder(
          builder: (context, constraints) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _PlanningTools(
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
                    _PlanningBar(session: controller.session?.title ?? '新会话'),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
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
                          if (controller.messages.isEmpty) ...[
                            const StatusPanel(
                              message: '还没有对话',
                              detail: '说说你想做的事，星愿会帮你排进日程。确认之前什么都不会创建。',
                            ),
                            XyGroup(
                              header: '试试这样说',
                              margin: EdgeInsets.zero,
                              children: [
                                for (final example in const [
                                  '这周每天读书 20 分钟',
                                  '明天下午整理一小时房间',
                                  '周一三五早上跑步 30 分钟',
                                ])
                                  ListTile(
                                    onTap: () {
                                      _input.text = example;
                                      _input.selection =
                                          TextSelection.collapsed(
                                            offset: example.length,
                                          );
                                    },
                                    leading: const Icon(
                                      CupertinoIcons.text_bubble,
                                      size: 20,
                                    ),
                                    title: Text(example),
                                    trailing: Icon(
                                      CupertinoIcons.arrow_up_left,
                                      size: 15,
                                      color: xy.faint,
                                    ),
                                  ),
                              ],
                            ),
                          ],
                          for (final message in controller.messages)
                            _message(message, controller),
                          if (controller.error != null) ...[
                            NoticeBanner(
                              tone: NoticeTone.error,
                              message: controller.error!,
                            ),
                            const SizedBox(height: 12),
                          ],
                          if (controller.busy)
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Row(
                                  children: [
                                    const XyActivity(radius: 8),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Semantics(
                                        liveRegion: true,
                                        child: Text(
                                          switch (controller.stage) {
                                            AssistantRunStage.summarizing =>
                                              '正在生成会话摘要',
                                            AssistantRunStage.sending =>
                                              '正在等待回复',
                                            AssistantRunStage.saving =>
                                              '正在保存回复',
                                            AssistantRunStage.querying =>
                                              '正在查询安排',
                                            AssistantRunStage.finding =>
                                              '正在找空档',
                                            AssistantRunStage.preferences =>
                                              '正在读取偏好',
                                            AssistantRunStage.validating =>
                                              '正在检查计划',
                                            AssistantRunStage.adjusting =>
                                              '发现冲突，正在调整',
                                            AssistantRunStage.confirming =>
                                              '等你确认',
                                            null => '正在准备发送',
                                          },
                                          key: const ValueKey('agent-stage'),
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodyMedium
                                              ?.copyWith(color: xy.muted),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                if (controller.agentProgress != null)
                                  AgentRunDetails(
                                    metadata: controller.agentProgress!,
                                    scope: 'running',
                                  ),
                                TextButton(
                                  key: const ValueKey('assistant-cancel'),
                                  onPressed: controller.cancel,
                                  style: TextButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                      vertical: 12,
                                    ),
                                  ),
                                  child: const Text('取消等待'),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              XyComposer(
                key: _composer,
                maxHeight: constraints.maxHeight * 0.5,
                field: TextField(
                  key: const ValueKey('assistant-input'),
                  controller: _input,
                  minLines: 1,
                  maxLines: 5,
                  maxLength: 2000,
                  decoration: composerDecoration(context, hint: '说说你想安排的事…'),
                  textInputAction: TextInputAction.newline,
                ),
                send: ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _input,
                  builder: (context, value, _) => sendButton(
                    context,
                    key: const ValueKey('assistant-send'),
                    onPressed:
                        !ready || controller.busy || value.text.trim().isEmpty
                        ? null
                        : () => _send(controller),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// The tab title for states that have no conversation header of their own.
  Widget _titled(Widget child) => PageScroll(
    padding: EdgeInsets.zero,
    children: [
      const TabHeader(title: '规划', subtitle: '说说想做的事，AI 帮你排进日程'),
      child,
    ],
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

/// The scalable heading scrolls independently of the compact navigation tools.
class _PlanningBar extends StatelessWidget {
  const _PlanningBar({required this.session});

  final String session;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 6, 6, 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text('规划', style: Theme.of(context).textTheme.titleLarge),
        ),
        Text(
          session,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: context.xy.muted),
        ),
      ],
    ),
  );
}

class _PlanningTools extends StatelessWidget {
  const _PlanningTools({
    required this.onSessions,
    required this.onDetails,
    required this.onSettings,
  });

  final VoidCallback onSessions;
  final VoidCallback? onDetails;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final xy = context.xy;
    final tint = Theme.of(context).colorScheme.primary;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: xy.line, width: 0.5)),
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
                color: tint,
                onPressed: onSessions,
                icon: const Icon(CupertinoIcons.chat_bubble_2),
              ),
              IconButton(
                tooltip: '会话信息',
                color: tint,
                onPressed: onDetails,
                icon: const Icon(CupertinoIcons.info_circle),
              ),
              IconButton(
                tooltip: 'AI 设置',
                color: tint,
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
