import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xingyuan_core/xingyuan_core.dart' hide ChatPage;

import '../../../app/theme.dart';
import '../../../data/local/local_goal_repository.dart';
import '../../../shared/local_identity_boundary.dart';
import '../../../shared/presentation.dart';
import '../../../shared/ui/sky.dart';
import '../../../shared/ui/sparkle.dart';
import '../../assistant/assistant_providers.dart';
import '../../assistant/presentation/assistant_settings_page.dart';
import '../../records/record_providers.dart';
import '../companion_providers.dart';
import '../data/companion_service.dart';
import 'chat_page.dart';
import 'pairing_controller.dart';
import 'sharing_page.dart'
    show SharingPage, SharingRepliesScreen, SharedRecordCard;

/// The 陪伴 tab: pairing when alone, the partner's shares and chat once paired.
class CompanionHomeView extends ConsumerStatefulWidget {
  const CompanionHomeView({super.key});

  @override
  ConsumerState<CompanionHomeView> createState() => _CompanionHomeViewState();
}

class _CompanionHomeViewState extends ConsumerState<CompanionHomeView>
    with WidgetsBindingObserver {
  late Future<LocalGoalRepository> _repository = _readRepository();
  int _generation = 0;

  /// Set when the device credential changes under this view. Content from
  /// the old credential never comes back; the person reopens explicitly.
  bool _expired = false;

  Future<LocalGoalRepository> _readRepository() =>
      ref.read(dayRecordStoreProvider.future).then((store) => store.goals);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _refresh() {
    ref.read(pairingControllerProvider.future).then((controller) {
      if (mounted) unawaited(controller.refresh());
    }).ignore();
  }

  void _reopen() => setState(() {
    _expired = false;
    _generation++;
    _repository = _readRepository();
    ref.invalidate(pairingControllerProvider);
    _refresh();
  });

  @override
  Widget build(BuildContext context) {
    ref.listen(assistantCredentialRevisionProvider, (_, _) {
      if (!mounted) return;
      // Old dialogs and pages belong to the previous credential.
      Navigator.of(context).popUntil((route) => route.isFirst);
      setState(() {
        _expired = true;
        _generation++;
      });
    });
    if (_expired) {
      return _CompanionFrame(
        title: '已关闭',
        status: '为了安全，旧内容已关闭',
        children: [
          StatusPanel(
            message: '设备凭证已变化，请重新打开陪伴。',
            icon: CupertinoIcons.lock_shield,
          ),
          Center(
            child: OutlinedButton(
              onPressed: _reopen,
              child: const Text('重新打开'),
            ),
          ),
        ],
      );
    }
    final pairing = ref.watch(pairingControllerProvider);
    return LocalIdentityBoundary(
      key: ValueKey(_generation),
      repository: _repository,
      onReopen: _reopen,
      child: pairing.when(
        loading: () => const _CompanionFrame(
          title: '配对状态',
          status: '正在读取配对状态',
          children: [],
        ),
        error: (error, _) => _CompanionFrame(
          title: '配对状态',
          status: '和朋友互相陪伴，各自的目标仍然私密',
          actions: const [_CredentialButton()],
          children: [
            if (error is CompanionServiceFailure &&
                (error.code == 'credential' || error.code == 'unauthorized'))
              const _NeedsCredential()
            else
              StatusPanel(
                message: error is CompanionServiceFailure
                    ? error.message
                    : '无法读取配对状态，请重试。',
                retry: _reopen,
              ),
          ],
        ),
        data: (controller) =>
            _CompanionBody(key: ObjectKey(controller), controller: controller),
      ),
    );
  }
}

class _NeedsCredential extends StatelessWidget {
  const _NeedsCredential();

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(top: 20),
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(
            CupertinoIcons.lock_shield_fill,
            size: 36,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 10),
          Text(
            const CompanionServiceFailure('credential').message,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          Text(
            '配对、分享和私聊都经过星愿的服务器转发，需要先录入这台设备的访问凭证。',
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(color: context.xy.muted),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const AssistantSettingsPage(),
              ),
            ),
            child: const Text('去设置凭证'),
          ),
        ],
      ),
    ),
  );
}

/// Large title, a status card and a scrolling body; keeps the same shape in
/// every state so refreshing never moves the page.
class _CompanionFrame extends StatelessWidget {
  const _CompanionFrame({
    required this.title,
    required this.status,
    required this.children,
    this.paired = false,
    this.actions = const [],
    this.onRefresh,
  });

  final String title;
  final String status;
  final bool paired;
  final List<Widget> actions;
  final List<Widget> children;
  final Future<void> Function()? onRefresh;

  @override
  Widget build(BuildContext context) {
    final xy = context.xy;
    final theme = Theme.of(context);
    // As a tab it carries its own large title; pushed as a page, the
    // navigation bar already says 陪伴.
    final inTab = ModalRoute.of(context)?.isFirst ?? true;
    final list = SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (inTab)
                TabHeader(title: '陪伴', trailing: actions)
              else if (actions.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: actions,
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 40),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SkyPanel(
                      seed: 21,
                      radius: BorderRadius.circular(20),
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                      child: Row(
                        children: [
                          _TwinStars(paired: paired),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  title,
                                  style: theme.textTheme.titleLarge?.copyWith(
                                    color: xy.onSky,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  status,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: xy.onSkyMuted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    ...children,
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return onRefresh == null
        ? list
        : RefreshIndicator.adaptive(onRefresh: onRefresh!, child: list);
  }
}

/// Gold for you, coral for TA; apart until paired.
class _TwinStars extends StatelessWidget {
  const _TwinStars({required this.paired});

  final bool paired;

  @override
  Widget build(BuildContext context) {
    final xy = context.xy;
    return ExcludeSemantics(
      child: SizedBox(
        width: 52,
        height: 52,
        child: Stack(
          children: [
            Positioned(
              left: 2,
              top: 6,
              child: StarMark(lit: true, size: 26, color: xy.star),
            ),
            Positioned(
              right: 2,
              bottom: 4,
              child: StarMark(
                lit: paired,
                size: 22,
                color: xy.partner,
                outline: xy.onSkyMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CompanionBody extends StatefulWidget {
  const _CompanionBody({required this.controller, super.key});

  final PairingController controller;

  @override
  State<_CompanionBody> createState() => _CompanionBodyState();
}

class _CompanionBodyState extends State<_CompanionBody> {
  late final _code = TextEditingController(text: widget.controller.draft);
  bool _dialog = false;
  PairingController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    controller.addListener(_changed);
  }

  void _changed() {
    if (!mounted) return;
    if (_code.text != controller.draft) {
      _code.value = TextEditingValue(
        text: controller.draft,
        selection: TextSelection.collapsed(offset: controller.draft.length),
      );
    }
    setState(() {});
  }

  @override
  void dispose() {
    controller.removeListener(_changed);
    unawaited(controller.flushDraft());
    _code.dispose();
    super.dispose();
  }

  Future<void> _confirm({
    required String title,
    required String detail,
    required String action,
    required Future<void> Function() run,
  }) async {
    if (_dialog || !controller.canStart) return;
    setState(() => _dialog = true);
    try {
      final yes = await confirmAction(
        context,
        title: title,
        message: detail,
        confirm: action,
        confirmKey: const ValueKey('confirm-pairing'),
        destructive: _destructive(action),
      );
      if (yes == true && mounted) await run();
    } finally {
      if (mounted) setState(() => _dialog = false);
    }
  }

  Future<void> _open(Widget page) async {
    await Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => page));
    if (mounted) await controller.refresh();
  }

  @override
  Widget build(BuildContext context) {
    final state = controller.snapshot?.state;
    final group = state?.group;
    final pending = controller.snapshot?.command;
    final pendingMessage = pending == null
        ? null
        : controller.busy
        ? '正在提交配对操作…'
        : CompanionServiceFailure(
            pending.row.errorCode ?? 'interrupted',
            outcomeUnknown: pending.row.status == 'uncertain',
          ).message;
    final waiting = controller.busy || controller.refreshing;
    // One status line whose text changes in place, so refreshing never
    // pushes the page around.
    final status = controller.refreshing
        ? '正在确认配对状态…'
        : !controller.confirmed && state != null
        ? '上次保存的状态，尚未联网确认。'
        : state == null
        ? '配对状态尚未确认。'
        : group != null
        ? '只有你主动分享的内容，TA 才看得到'
        : '邀请一位朋友，互相陪伴';
    return _CompanionFrame(
      title: state == null
          ? '配对状态'
          : group == null
          ? '尚未配对'
          : '已配对',
      status: status,
      paired: group != null,
      onRefresh: controller.refresh,
      actions: [
        if (waiting)
          IconButton(
            tooltip: '取消等待',
            color: Theme.of(context).colorScheme.primary,
            onPressed: controller.cancelWaiting,
            icon: const Icon(CupertinoIcons.xmark_circle),
          )
        else
          IconButton(
            tooltip: '刷新配对',
            color: Theme.of(context).colorScheme.primary,
            onPressed: controller.refresh,
            icon: const Icon(CupertinoIcons.arrow_clockwise),
          ),
        const _CredentialButton(),
      ],
      children: [
        if (controller.error case final error? when error != pendingMessage)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: NoticeBanner(tone: NoticeTone.error, message: error),
          ),
        if (pendingMessage != null)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: NoticeBanner(
              tone: controller.busy ? NoticeTone.info : NoticeTone.warning,
              message: pendingMessage,
              action: controller.canRetry ? '重试上次操作' : null,
              actionKey: const ValueKey('retry-pairing'),
              onAction: controller.canRetry ? controller.retry : null,
            ),
          ),
        if (group != null)
          _PairedSection(
            controller: controller,
            onOpen: _open,
            onLeave: !_dialog && controller.canStart
                ? () => _confirm(
                    title: '解除配对？',
                    detail:
                        '将永久删除双方在这段配对中的分享、回复、私聊和图片，并清空配对缓存。各自的个人目标、打卡和记录不受影响。',
                    action: '解除配对',
                    run: () => controller.leave(group.id),
                  )
                : null,
          )
        else
          _UnpairedSection(
            controller: controller,
            code: _code,
            allowed: !_dialog && controller.canStart,
            onCancelInvite: (invitation) => _confirm(
              title: '取消邀请码？',
              detail: '取消后，对方不能再用这个邀请码加入。',
              action: '确认取消',
              run: () => controller.cancelInvite(invitation.id),
            ),
            onJoin: () => _confirm(
              title: '与对方配对？',
              detail: '配对后，个人目标仍然默认私密。只有你主动开启的分享内容才会发送给对方。',
              action: '确认配对',
              run: controller.join,
            ),
          ),
      ],
    );
  }
}

class _UnpairedSection extends StatelessWidget {
  const _UnpairedSection({
    required this.controller,
    required this.code,
    required this.allowed,
    required this.onCancelInvite,
    required this.onJoin,
  });

  final PairingController controller;
  final TextEditingController code;
  final bool allowed;
  final void Function(PairingInvitation invitation) onCancelInvite;
  final VoidCallback onJoin;

  String _expiry(PairingInvitation invitation) {
    final value = invitation.expiresAt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${value.month}月${value.day}日 ${two(value.hour)}:${two(value.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final xy = context.xy;
    final invitation = controller.snapshot?.state?.invitation;
    final error = theme.colorScheme.error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        XyGroup(
          header: '邀请 TA',
          footer: '生成一个邀请码，发给想一起坚持的朋友。',
          children: [
            if (invitation != null) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
                child: Column(
                  children: [
                    SelectableText(
                      invitation.code,
                      key: const ValueKey('pairing-invite-code'),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineMedium?.copyWith(
                        letterSpacing: 4,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '有效期至 ${_expiry(invitation)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: xy.muted,
                      ),
                    ),
                  ],
                ),
              ),
              ListTile(
                leading: const Icon(CupertinoIcons.doc_on_doc),
                title: Text(
                  '复制邀请码',
                  style: TextStyle(color: theme.colorScheme.primary),
                ),
                onTap: () async {
                  try {
                    await Clipboard.setData(
                      ClipboardData(text: invitation.code),
                    );
                    if (context.mounted) {
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(const SnackBar(content: Text('邀请码已复制')));
                    }
                  } catch (_) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(const SnackBar(content: Text('未能复制邀请码')));
                    }
                  }
                },
              ),
              ListTile(
                key: const ValueKey('cancel-pairing-invite'),
                enabled: allowed,
                leading: Icon(CupertinoIcons.xmark_circle, color: error),
                title: Text('取消邀请码', style: TextStyle(color: error)),
                onTap: () => onCancelInvite(invitation),
              ),
            ] else
              ListTile(
                key: const ValueKey('create-pairing-invite'),
                enabled: allowed,
                leading: const Icon(CupertinoIcons.link_circle),
                title: Text(
                  '生成邀请码',
                  style: TextStyle(
                    color: allowed ? theme.colorScheme.primary : xy.faint,
                  ),
                ),
                onTap: controller.createInvite,
              ),
          ],
        ),
        XyGroup(
          header: '收到了邀请码？',
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
              child: TextField(
                key: const ValueKey('pairing-code-input'),
                controller: code,
                onChanged: controller.editDraft,
                autocorrect: false,
                enableSuggestions: false,
                textCapitalization: TextCapitalization.characters,
                minLines: 1,
                maxLines: 3,
                maxLength: 64,
                maxLengthEnforcement: MaxLengthEnforcement.none,
                style: theme.textTheme.bodyLarge?.copyWith(letterSpacing: 1),
                decoration: InputDecoration(
                  hintText: '输入对方的邀请码',
                  errorText: controller.draftError,
                  counterText: '',
                ),
              ),
            ),
            if (controller.draftError != null)
              ListTile(
                leading: const Icon(CupertinoIcons.tray_arrow_down),
                title: const Text('重试保存草稿'),
                onTap: () => controller.editDraft(code.text),
              ),
            ListTile(
              key: const ValueKey('join-pairing'),
              enabled: allowed,
              leading: const Icon(CupertinoIcons.person_2),
              title: Text(
                '加入配对',
                style: TextStyle(
                  color: allowed ? theme.colorScheme.primary : xy.faint,
                  fontWeight: FontWeight.w600,
                ),
              ),
              onTap: onJoin,
            ),
          ],
        ),
        const SizedBox(height: 20),
        const _PrivacyNote(
          text: '配对后，你的目标和记录仍然默认私密。只有你在「分享设置」里开启的目标、并在记录里勾选「分享给 TA」的内容，对方才看得到。',
        ),
      ],
    );
  }
}

class _PrivacyNote extends StatelessWidget {
  const _PrivacyNote({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final xy = context.xy;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(CupertinoIcons.lock, size: 16, color: xy.muted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: xy.muted),
            ),
          ),
        ],
      ),
    );
  }
}

class _PairedSection extends ConsumerStatefulWidget {
  const _PairedSection({
    required this.controller,
    required this.onOpen,
    required this.onLeave,
  });

  final PairingController controller;
  final Future<void> Function(Widget page) onOpen;
  final VoidCallback? onLeave;

  @override
  ConsumerState<_PairedSection> createState() => _PairedSectionState();
}

class _PairedSectionState extends ConsumerState<_PairedSection> {
  @override
  void initState() {
    super.initState();
    ref.read(sharingControllerProvider.future).then((sharing) {
      if (mounted && sharing.available) unawaited(sharing.refresh());
    }).ignore();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canStart = widget.controller.canStart;
    final sharing = ref.watch(sharingControllerProvider);
    final controller = sharing.asData?.value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        XyGroup(
          dividerIndent: 58,
          children: [
            ChatEntry(
              onPressed: canStart
                  ? () => widget.onOpen(const ChatPage())
                  : null,
            ),
            _ActionTile(
              key: const ValueKey('open-sharing-settings'),
              icon: CupertinoIcons.slider_horizontal_3,
              color: theme.colorScheme.primary,
              title: '分享设置',
              subtitle: controller == null
                  ? '选择要分享的目标'
                  : '已分享 ${controller.snapshot?.grants.length ?? 0} 个目标',
              onPressed: canStart
                  ? () => widget.onOpen(const SharingPage(initialTab: 1))
                  : null,
            ),
          ],
        ),
        SectionLabel(
          '最近的分享',
          trailing: TextButton(
            key: const ValueKey('open-sharing'),
            onPressed: canStart
                ? () => widget.onOpen(const SharingPage())
                : null,
            child: const Text('全部动态'),
          ),
        ),
        if (controller == null)
          sharing.hasError
              ? StatusPanel(
                  message: sharing.error is CompanionServiceFailure
                      ? (sharing.error as CompanionServiceFailure).message
                      : '分享状态暂时不可用。',
                  retry: () => ref.invalidate(sharingControllerProvider),
                )
              : const StatusPanel(message: '正在读取分享', loading: true)
        else
          // No session boundary here: it would close pages opened above the
          // tab. An ended session is shown in place instead.
          ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              if (!controller.available) {
                return StatusPanel(
                  message: '分享状态已变化，请刷新确认。',
                  retry: () => ref.invalidate(sharingControllerProvider),
                );
              }
              final records = controller.snapshot?.records ?? const [];
              if (records.isEmpty) {
                return Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Icon(
                          CupertinoIcons.heart,
                          size: 28,
                          color: context.xy.partner,
                        ),
                        const SizedBox(height: 8),
                        Text('还没有分享', style: theme.textTheme.titleMedium),
                        const SizedBox(height: 6),
                        Text(
                          '在「分享设置」里开启一个目标，之后写记录时勾选「分享给 TA」，对方就能在这里看到，也可以回复你。',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: context.xy.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final record in records.take(5))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: SharedRecordCard(
                        controller: controller,
                        record: record,
                        showPhotos: false,
                        onOpen: () => widget.onOpen(
                          SharingRepliesScreen(
                            controller: controller,
                            recordId: record.id,
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        const SizedBox(height: 14),
        const _PrivacyNote(text: '未分享的内容仍然私密。'),
        XyGroup(
          margin: const EdgeInsets.only(top: 28),
          children: [
            ListTile(
              key: const ValueKey('leave-pairing'),
              enabled: widget.onLeave != null,
              onTap: widget.onLeave,
              title: Center(
                child: Text(
                  '解除配对',
                  style: TextStyle(
                    color: widget.onLeave == null
                        ? context.xy.faint
                        : theme.colorScheme.error,
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// A Settings-style row: coloured icon tile, title and detail, chevron.
class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onPressed,
    this.badge,
    super.key,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback? onPressed;
  final int? badge;

  @override
  Widget build(BuildContext context) {
    final xy = context.xy;
    final count = badge ?? 0;
    return ListTile(
      enabled: onPressed != null,
      onTap: onPressed,
      minVerticalPadding: 10,
      leading: XyIconTile(icon, color: color),
      title: Text(title),
      subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (count > 0) Badge.count(count: count),
          const SizedBox(width: 6),
          Icon(CupertinoIcons.chevron_right, size: 16, color: xy.faint),
        ],
      ),
    );
  }
}

/// Entry to private chat, showing the unread count once chat has loaded.
class ChatEntry extends ConsumerWidget {
  const ChatEntry({required this.onPressed, super.key});
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(chatControllerProvider).asData?.value;
    Widget tile(int unread) => _ActionTile(
      key: const ValueKey('open-chat'),
      icon: CupertinoIcons.chat_bubble_2_fill,
      color: const Color(0xFF34C759),
      title: unread == 0 ? '私聊' : '私聊 · $unread 条未读',
      subtitle: '只有你们两个人能看到',
      badge: unread,
      onPressed: onPressed,
    );
    return controller == null
        ? tile(0)
        : FrameSafeListenableBuilder(
            listenable: controller,
            builder: (_, _) => tile(controller.unread),
          );
  }
}

class _CredentialButton extends StatelessWidget {
  const _CredentialButton();

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: '设备凭证设置',
    color: Theme.of(context).colorScheme.primary,
    onPressed: () => Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const AssistantSettingsPage()),
    ),
    icon: const Icon(CupertinoIcons.lock_shield),
  );
}

bool _destructive(String action) =>
    ['删除', '解除', '停止', '取消', '撤回', '关闭'].any(action.contains);
