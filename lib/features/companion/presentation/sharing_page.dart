import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

import '../../../app/providers.dart';
import '../../../shared/local_identity_boundary.dart';
import '../../../app/theme.dart';
import '../../../shared/presentation.dart';
import '../../../shared/ui/composer.dart';
import '../../../shared/ui/sparkle.dart';
import '../../assistant/assistant_providers.dart';
import '../../records/record_providers.dart';
import '../companion_providers.dart';
import '../data/companion_service.dart';
import '../data/local_sharing_store.dart';
import 'sharing_controller.dart';
import 'publication_status.dart';

class SharingPage extends ConsumerStatefulWidget {
  const SharingPage({this.initialTab = 0, super.key});

  /// 0 opens the feed, 1 opens「我的分享」.
  final int initialTab;
  @override
  ConsumerState<SharingPage> createState() => _SharingPageState();
}

class _SharingPageState extends ConsumerState<SharingPage>
    with WidgetsBindingObserver {
  late final _repository = ref
      .read(dayRecordStoreProvider.future)
      .then((value) => value.goals);
  late Future<SharingController> _controller;
  bool _expired = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  void _load() {
    _controller = ref.read(sharingControllerProvider.future);
    _controller.then((value) {
      if (mounted && !_expired) unawaited(value.refresh());
    }).ignore();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_expired) {
      _controller.then((value) => value.refresh()).ignore();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _invalidate() {
    if (!mounted || _expired) return;
    setState(() => _expired = true);
    final route = ModalRoute.of(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && route != null && route.isActive) {
        Navigator.of(context)
            .popUntil((value) => value == route || value.isFirst);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(assistantCredentialRevisionProvider, (_, _) => _invalidate());
    return LocalIdentityBoundary(
      repository: _repository,
      child: Scaffold(
        appBar: pageAppBar(context, '分享'),
        body: SafeArea(
          child: _expired
              ? const PageScroll(
                  children: [StatusPanel(message: '设备凭证已变化，请返回后重新打开。')],
                )
              : FutureBuilder<SharingController>(
                  future: _controller,
                  builder: (context, result) {
                    if (result.hasError) {
                      return PageScroll(
                        children: [
                          StatusPanel(
                            message: result.error is CompanionServiceFailure
                                ? (result.error as CompanionServiceFailure)
                                      .message
                                : '分享状态暂时不可用。',
                            retry: () {
                              ref.invalidate(sharingControllerProvider);
                              setState(_load);
                            },
                          ),
                        ],
                      );
                    }
                    if (!result.hasData) {
                      return const PageScroll(
                        children: [
                          StatusPanel(message: '正在读取分享', loading: true),
                        ],
                      );
                    }
                    return SharingSessionBoundary(
                      controller: result.data!,
                      child: _SharingBody(
                        controller: result.data!,
                        initialTab: widget.initialTab,
                      ),
                    );
                  },
                ),
        ),
      ),
    );
  }
}

class SharingSessionBoundary extends StatefulWidget {
  const SharingSessionBoundary({
    required this.controller,
    required this.child,
    this.recordId,
    this.photoId,
    super.key,
  });
  final SharingController controller;
  final Widget child;
  final String? recordId;
  final String? photoId;
  @override
  State<SharingSessionBoundary> createState() => _SharingSessionBoundaryState();
}

class _SharingSessionBoundaryState extends State<SharingSessionBoundary> {
  bool _expired = false;
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void didUpdateWidget(covariant SharingSessionBoundary oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
      _expire();
    }
  }

  bool get _accessible {
    if (widget.controller.invalidated) return false;
    if (widget.recordId == null) return true;
    final record = widget.controller.snapshot?.records
        .where((r) => r.id == widget.recordId)
        .firstOrNull;
    return record != null &&
        (widget.photoId == null || record.photoIds.contains(widget.photoId));
  }

  void _changed() {
    if (!_accessible) _expire();
  }

  void _expire() {
    if (!mounted || _expired) return;
    setState(() => _expired = true);
    final route = ModalRoute.of(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && route != null && route.isActive) {
        Navigator.of(context)
            .popUntil((value) => value == route || value.isFirst);
      }
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _expired || !_accessible
      ? const PageScroll(
          children: [StatusPanel(message: '分享或配对状态已变化，请返回后重新打开。')],
        )
      : widget.child;
}

Future<bool> _confirm(
  BuildContext context,
  String title,
  String message,
  String action,
) async => await confirmAction(
  context,
  title: title,
  message: message,
  confirm: action,
  confirmKey: const ValueKey('confirm-sharing'),
  destructive: _destructive(action),
);

class _SharingBody extends StatefulWidget {
  const _SharingBody({required this.controller, this.initialTab = 0});
  final SharingController controller;
  final int initialTab;
  @override
  State<_SharingBody> createState() => _SharingBodyState();
}

class _SharingBodyState extends State<_SharingBody> {
  bool _dialog = false;
  SharingController get controller => widget.controller;
  Future<void> _toggle(SharingLocalGoal goal, SharingGrant? grant) async {
    if (_dialog || !controller.canStart) return;
    setState(() => _dialog = true);
    try {
      final approved = await _confirm(
        context,
        grant == null ? '分享这个目标？' : '停止分享这个目标？',
        grant == null
            ? '对方将看到之后的打卡目标与完成时间。文字和照片仍需在每条记录上单独勾选，不会补发历史。'
            : '对方将无法再查看这个目标的分享记录、照片和回复。个人目标与记录仍然保留。',
        grant == null ? '开启分享' : '停止分享',
      );
      if (approved && mounted) {
        if (grant == null) {
          await controller.enable(goal.globalId);
        } else {
          await controller.stop(grant.id);
        }
      }
    } finally {
      if (mounted) setState(() => _dialog = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final xy = context.xy;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => DefaultTabController(
        length: 2,
        initialIndex: widget.initialTab,
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: _SegmentedTabs(labels: ['动态', '我的分享']),
            ),
            Expanded(
              child: TabBarView(
                children: [
                  RefreshIndicator.adaptive(
                    onRefresh: controller.refresh,
                    child: ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 40),
                      children: [
                        _SharingStatus(controller: controller),
                        const PublicationQueueView(),
                        if (controller.snapshot?.records.isEmpty ?? true)
                          const StatusPanel(
                            message: '还没有分享动态。',
                            detail: '开启分享的目标，在记录里勾选「分享给 TA」后会出现在这里。',
                          ),
                        for (final record
                            in controller.snapshot?.records ?? <SharedRecord>[])
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: SharedRecordCard(
                              controller: controller,
                              record: record,
                              onOpen: () => Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => SharingRepliesScreen(
                                    controller: controller,
                                    recordId: record.id,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  RefreshIndicator.adaptive(
                    onRefresh: controller.refresh,
                    child: ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 40),
                      children: [
                        _SharingStatus(controller: controller),
                        if (controller.localGoals.isEmpty)
                          const StatusPanel(message: '还没有个人目标。')
                        else
                          XyGroup(
                            margin: EdgeInsets.zero,
                            footer: '开启后，TA 能看到这个目标之后的打卡和完成时间。文字和照片要在每条记录里单独勾选「分享给 TA」，不会补发以前的内容。',
                            children: [
                              for (final goal in controller.localGoals)
                                Builder(
                                  builder: (context) {
                                    final grant = controller.snapshot?.grants
                                        .where((g) => g.goalId == goal.globalId)
                                        .firstOrNull;
                                    return SwitchListTile.adaptive(
                                      key: ValueKey(
                                        'share-goal-${goal.goal.id}',
                                      ),
                                      title: Text(
                                        goal.goal.titleOn(
                                          controller.store.pairing.goals.clock
                                              .read()
                                              .day,
                                        ),
                                      ),
                                      subtitle: Text(
                                        grant != null
                                            ? '已开启分享'
                                            : goal.goal.isArchived
                                            ? '已归档 · 私密'
                                            : '私密',
                                        style: TextStyle(
                                          color: grant != null
                                              ? xy.success
                                              : xy.muted,
                                        ),
                                      ),
                                      value: grant != null,
                                      onChanged:
                                          controller.canStart &&
                                              !_dialog &&
                                              (!goal.goal.isArchived ||
                                                  grant != null)
                                          ? (_) => _toggle(goal, grant)
                                          : null,
                                    );
                                  },
                                ),
                            ],
                          ),
                      ],
                    ),
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

/// An iOS segmented control driving the surrounding [DefaultTabController].
class _SegmentedTabs extends StatefulWidget {
  const _SegmentedTabs({required this.labels});
  final List<String> labels;

  @override
  State<_SegmentedTabs> createState() => _SegmentedTabsState();
}

class _SegmentedTabsState extends State<_SegmentedTabs> {
  TabController? _tabs;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final tabs = DefaultTabController.of(context);
    if (!identical(tabs, _tabs)) {
      _tabs?.removeListener(_changed);
      _tabs = tabs..addListener(_changed);
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _tabs?.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tabs = _tabs!;
    return XySegmented<int>(
      segments: [for (final (i, label) in widget.labels.indexed) (i, label)],
      selected: tabs.indexIsChanging
          ? tabs.index
          : tabs.animation!.value.round(),
      onChanged: tabs.animateTo,
    );
  }
}

class _SharingStatus extends StatelessWidget {
  const _SharingStatus({required this.controller});
  final SharingController controller;
  @override
  Widget build(BuildContext context) {
    final xy = context.xy;
    final waiting = controller.busy || controller.refreshing;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // A fixed-height row: refreshing changes its text, not its size.
        SizedBox(
          height: 44,
          child: Row(
            children: [
              const SizedBox(width: 4),
              QuietActivity(active: waiting),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  controller.refreshing
                      ? '正在刷新…'
                      : controller.confirmed
                      ? ''
                      : '上次保存的内容，尚未联网确认。',
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: xy.muted),
                ),
              ),
              if (waiting)
                IconButton(
                  tooltip: '取消等待',
                  color: Theme.of(context).colorScheme.primary,
                  onPressed: controller.cancelWaiting,
                  icon: const Icon(CupertinoIcons.xmark_circle, size: 22),
                )
              else
                IconButton(
                  tooltip: '刷新动态',
                  color: Theme.of(context).colorScheme.primary,
                  onPressed: controller.canStart ? controller.refresh : null,
                  icon: const Icon(CupertinoIcons.arrow_clockwise, size: 22),
                ),
            ],
          ),
        ),
        if (controller.error case final error?)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: NoticeBanner(
              key: const ValueKey('sharing-error'),
              tone: NoticeTone.error,
              message: error,
            ),
          ),
        for (final pending in controller.pending)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Container(
              padding: const EdgeInsets.fromLTRB(14, 6, 4, 6),
              decoration: BoxDecoration(
                color: xy.card,
                borderRadius: BorderRadius.circular(xyButtonRadius),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${_operationName(pending.command.kind)}：${pending.row.status == 'sending'
                          ? '正在发送'
                          : pending.row.status == 'pending'
                          ? '尚未发送'
                          : CompanionServiceFailure(pending.row.errorCode ?? 'interrupted', outcomeUnknown: pending.row.status == 'uncertain').message}',
                    ),
                  ),
                  if (controller.canRetry(pending))
                    IconButton(
                      tooltip: '重试上次操作',
                      key: ValueKey(
                        'retry-sharing-${pending.command.operationId}',
                      ),
                      onPressed: () => controller.retry(pending),
                      icon: const Icon(CupertinoIcons.arrow_clockwise),
                    ),
                  if (pending.row.status == 'failed')
                    IconButton(
                      tooltip: '移除失败操作',
                      onPressed: controller.canStart
                          ? () => controller.discardFailed(pending)
                          : null,
                      icon: const Icon(CupertinoIcons.xmark),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

String _operationName(SharingCommandKind kind) => switch (kind) {
  SharingCommandKind.enable => '开启分享',
  SharingCommandKind.stop => '停止分享',
  SharingCommandKind.publish => '发布记录',
  SharingCommandKind.remove => '移除分享',
  SharingCommandKind.reply => '回复',
  SharingCommandKind.deleteReply => '删除回复',
};

/// A small round mark: gold star for you, coral star for TA.
class AuthorMark extends StatelessWidget {
  const AuthorMark({required this.mine, this.size = 28, super.key});
  final bool mine;
  final double size;
  @override
  Widget build(BuildContext context) {
    final xy = context.xy;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: mine ? xy.cardSoft : xy.partnerSoft,
      ),
      child: StarMark(
        lit: true,
        size: size * 0.55,
        color: mine ? xy.star : xy.partner,
        glow: false,
      ),
    );
  }
}

/// One shared record in a feed: who, which goal, the note and photos.
class SharedRecordCard extends ConsumerWidget {
  const SharedRecordCard({
    required this.controller,
    required this.record,
    this.onOpen,
    this.showPhotos = true,
    super.key,
  });
  final SharingController controller;
  final SharedRecord record;
  final VoidCallback? onOpen;

  /// When false, photos are counted instead of downloaded.
  final bool showPhotos;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(environmentProvider);
    final now = ref.read(clockProvider).read().instant;
    final theme = Theme.of(context);
    final xy = context.xy;
    final mine = record.authorId == controller.store.memberId;
    final replies = controller.replies[record.id]?.length ?? 0;
    return Card(
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  AuthorMark(mine: mine),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: mine ? '我' : 'TA',
                            style: theme.textTheme.labelLarge?.copyWith(
                              color: mine ? null : xy.partnerText,
                            ),
                          ),
                          TextSpan(
                            text:
                                ' · ${momentLabel(record.occurredAt, now: now)}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: xy.muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (onOpen != null)
                    IconButton(
                      key: ValueKey('open-replies-${record.id}'),
                      tooltip: '查看和回复',
                      onPressed: onOpen,
                      color: xy.muted,
                      icon: Badge.count(
                        count: replies,
                        isLabelVisible: replies > 0,
                        backgroundColor: xy.partner,
                        child: const Icon(CupertinoIcons.chat_bubble),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        StarMark(
                          lit: record.completedAt != null,
                          size: 16,
                          glow: false,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            record.title,
                            style: theme.textTheme.titleMedium,
                          ),
                        ),
                      ],
                    ),
                    if (record.completedAt != null)
                      Padding(
                        padding: const EdgeInsets.only(left: 22),
                        child: Text(
                          '已完成 · ${momentLabel(record.completedAt!, now: now)}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: xy.success,
                          ),
                        ),
                      ),
                    if (record.text.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Text(
                          record.text,
                          style: theme.textTheme.bodyLarge,
                        ),
                      ),
                    if (record.photoIds.isNotEmpty && !showPhotos)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Row(
                          children: [
                            Icon(
                              CupertinoIcons.photo,
                              size: 18,
                              color: xy.muted,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '${record.photoIds.length} 张照片',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: xy.muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (record.photoIds.isNotEmpty && showPhotos)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final photo in record.photoIds)
                              _SharedPhoto(
                                key: ValueKey(
                                  '${controller.store.sessionId}:${record.id}:$photo',
                                ),
                                controller: controller,
                                recordId: record.id,
                                id: photo,
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SharedPhoto extends ConsumerStatefulWidget {
  const _SharedPhoto({
    required this.controller,
    required this.recordId,
    required this.id,
    super.key,
  });
  final SharingController controller;
  final String recordId;
  final String id;
  @override
  ConsumerState<_SharedPhoto> createState() => _SharedPhotoState();
}

class _SharedPhotoState extends ConsumerState<_SharedPhoto> {
  late Future<CompanionPhotoDownload> _download;
  final _cancel = CompanionCancellation();
  MemoryImage? _image;
  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _download =
        Future.sync(
          () => widget.controller.downloadPhoto(
            widget.recordId,
            widget.id,
            ref.read(companionMediaServiceProvider),
            cancellation: _cancel,
          ),
        ).then((photo) {
          if (mounted && !_cancel.isCancelled) {
            _image = MemoryImage(photo.bytes);
          }
          return photo;
        });
  }

  @override
  void dispose() {
    _cancel.cancel();
    _image?.evict().ignore();
    super.dispose();
  }

  void _openPhoto(CompanionPhotoDownload photo) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => Scaffold(
          appBar: pageAppBar(context, '分享照片'),
          body: SafeArea(
            child: SharingSessionBoundary(
              controller: widget.controller,
              recordId: widget.recordId,
              photoId: widget.id,
              child: Center(
                child: InteractiveViewer(
                  minScale: 1,
                  maxScale: 4,
                  child: Image.memory(photo.bytes, fit: BoxFit.contain),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(12),
    child: ColoredBox(
      color: context.xy.cardSoft,
      child: SizedBox.square(
        dimension: 96,
        child: FutureBuilder<CompanionPhotoDownload>(
          future: _download,
          builder: (context, result) {
            if (result.hasError) {
              return IconButton(
                tooltip: '重试读取照片',
                onPressed: () => setState(_load),
                icon: const Icon(CupertinoIcons.photo),
              );
            }
            if (!result.hasData) {
              return Center(
                child: Icon(
                  CupertinoIcons.photo,
                  color: context.xy.muted.withValues(alpha: 0.5),
                ),
              );
            }
            return InkWell(
              key: ValueKey('shared-photo-${widget.id}'),
              onTap: () => _openPhoto(result.data!),
              child: Image.memory(
                result.data!.bytes,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) =>
                    const Icon(CupertinoIcons.photo, semanticLabel: '照片无法显示'),
              ),
            );
          },
        ),
      ),
    ),
  );
}

class SharingRepliesScreen extends StatefulWidget {
  const SharingRepliesScreen({
    required this.controller,
    required this.recordId,
    super.key,
  });
  final SharingController controller;
  final String recordId;
  @override
  State<SharingRepliesScreen> createState() => _SharingRepliesScreenState();
}

class _SharingRepliesScreenState extends State<SharingRepliesScreen>
    with WidgetsBindingObserver {
  final _text = TextEditingController();
  String? _openingError;
  bool _dialog = false;
  bool _leaving = false;
  SharingController get controller => widget.controller;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    controller.addListener(_changed);
    unawaited(_open());
  }

  Future<void> _open() async {
    try {
      await controller.openReplies(widget.recordId);
      if (mounted) setState(() => _openingError = null);
      _changed();
      await controller.refresh(record: widget.recordId);
    } catch (failure) {
      if (mounted) {
        setState(
          () => _openingError = failure is CompanionServiceFailure
              ? failure.message
              : '无法读取回复草稿。',
        );
      }
    }
  }

  void _changed() {
    if (!mounted) return;
    final draft = controller.replyText(widget.recordId);
    if (_text.text != draft) {
      _text.value = TextEditingValue(
        text: draft,
        selection: TextSelection.collapsed(offset: draft.length),
      );
    }
    setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(controller.refresh(record: widget.recordId));
    } else {
      controller.flushReply(widget.recordId).ignore();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller.removeListener(_changed);
    _text.dispose();
    super.dispose();
  }

  Future<void> _back() async {
    await controller.flushReply(widget.recordId);
    if (!mounted || !controller.replyDraftSaved(widget.recordId)) return;
    setState(() => _leaving = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  Future<void> _remove({SharedReply? reply}) async {
    if (_dialog || !controller.canStart) return;
    setState(() => _dialog = true);
    try {
      final approved = await _confirm(
        context,
        reply == null ? '移除这条分享？' : '删除这条回复？',
        reply == null ? '这条分享、照片和回复将从配对中删除。个人记录不受影响。' : '删除后双方都无法再查看这条回复。',
        reply == null ? '移除分享' : '删除回复',
      );
      if (approved && mounted) {
        if (reply == null) {
          await controller.remove(widget.recordId);
        } else {
          await controller.deleteReply(reply.id, widget.recordId);
        }
      }
    } finally {
      if (mounted) setState(() => _dialog = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final record = controller.snapshot?.records
        .where((r) => r.id == widget.recordId)
        .firstOrNull;
    return LocalIdentityBoundary(
      repository: Future.value(controller.store.pairing.goals),
      child: Scaffold(
        appBar: pageAppBar(context, '分享与回复'),
        body: SafeArea(
          child: SharingSessionBoundary(
            controller: controller,
            child: PopScope(
              canPop: _leaving || controller.replyDraftSaved(widget.recordId),
              onPopInvokedWithResult: (didPop, _) {
                if (!didPop) unawaited(_back());
              },
              child: LayoutBuilder(
                builder: (context, constraints) => Column(
                  children: [
                    Expanded(
                      child: RefreshIndicator.adaptive(
                        onRefresh: () =>
                            controller.refresh(record: widget.recordId),
                        child: ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                          children: [
                            _SharingStatus(controller: controller),
                            if (_openingError case final error?)
                              StatusPanel(message: error, retry: _open),
                            if (record == null)
                              const StatusPanel(message: '这条分享已不可访问。')
                            else ...[
                              SharedRecordCard(
                                controller: controller,
                                record: record,
                              ),
                              if (record.authorId == controller.store.memberId)
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: TextButton(
                                    onPressed: controller.canStart && !_dialog
                                        ? _remove
                                        : null,
                                    style: TextButton.styleFrom(
                                      foregroundColor: Theme.of(context)
                                          .colorScheme
                                          .error,
                                    ),
                                    child: const Tooltip(
                                      message: '移除分享',
                                      excludeFromSemantics: true,
                                      child: Text('移除这条分享'),
                                    ),
                                  ),
                                ),
                              SectionLabel(
                                '回复',
                                count:
                                    controller
                                        .replies[widget.recordId]
                                        ?.length ??
                                    0,
                              ),
                              if (controller
                                      .replies[widget.recordId]
                                      ?.isEmpty ??
                                  true)
                                Padding(
                                  padding: const EdgeInsets.only(left: 4),
                                  child: Text(
                                    '还没有回复，说点什么吧。',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(color: context.xy.muted),
                                  ),
                                ),
                              for (final (i, reply)
                                  in (controller.replies[widget.recordId] ??
                                          <SharedReply>[])
                                      .indexed)
                                _ReplyBubble(
                                  reply: reply,
                                  previous: i == 0
                                      ? null
                                      : controller
                                            .replies[widget.recordId]![i - 1]
                                            .createdAt,
                                  mine:
                                      reply.authorId ==
                                      controller.store.memberId,
                                  onDelete:
                                      reply.authorId ==
                                              controller.store.memberId &&
                                          controller.canStart &&
                                          !_dialog
                                      ? () => _remove(reply: reply)
                                      : null,
                                ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    if (record != null)
                      XyComposer(
                        maxHeight: constraints.maxHeight * 0.5,
                        notices: [
                          if (!controller.replyDraftSaved(widget.recordId))
                            NoticeBanner(
                              tone: NoticeTone.warning,
                              message: '回复草稿尚未保存',
                              action: '保存草稿',
                              onAction: () => controller.editReply(
                                widget.recordId,
                                _text.text,
                              ),
                            ),
                        ],
                        field: TextField(
                          key: const ValueKey('sharing-reply-input'),
                          controller: _text,
                          enabled: controller.replyReady(widget.recordId),
                          onChanged: (value) =>
                              controller.editReply(widget.recordId, value),
                          minLines: 1,
                          maxLines: 6,
                          maxLength: 300,
                          maxLengthEnforcement: MaxLengthEnforcement.none,
                          decoration: composerDecoration(
                            context,
                            hint: '回复 TA…',
                            errorText: controller.replyDraftError(
                              widget.recordId,
                            ),
                          ),
                        ),
                        send: sendButton(
                          context,
                          key: const ValueKey('send-sharing-reply'),
                          tooltip: '发送回复',
                          onPressed:
                              controller.canStart &&
                                  !_dialog &&
                                  controller.replyReady(widget.recordId) &&
                                  !controller.hasPendingReply(widget.recordId)
                              ? () => controller.sendReply(widget.recordId)
                              : null,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ReplyBubble extends ConsumerWidget {
  const _ReplyBubble({
    required this.reply,
    required this.previous,
    required this.mine,
    required this.onDelete,
  });
  final SharedReply reply;
  final DateTime? previous;
  final bool mine;
  final VoidCallback? onDelete;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(environmentProvider);
    final now = ref.read(clockProvider).read().instant;
    final theme = Theme.of(context);
    final xy = context.xy;
    final bubble = Container(
      constraints: const BoxConstraints(maxWidth: 480),
      padding: const EdgeInsets.fromLTRB(13, 8, 13, 9),
      decoration: BoxDecoration(
        color: mine ? theme.colorScheme.primary : xy.card,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(18),
          topRight: const Radius.circular(18),
          bottomLeft: Radius.circular(mine ? 18 : 5),
          bottomRight: Radius.circular(mine ? 5 : 18),
        ),
      ),
      child: Text(
        reply.text,
        style: theme.textTheme.bodyLarge?.copyWith(
          color: mine ? Colors.white : null,
        ),
      ),
    );
    final divider = chatDividerLabel(reply.createdAt, previous, now: now);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: mine
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          if (divider != null)
            SizedBox(width: double.infinity, child: ChatTimeDivider(divider)),
          Row(
            mainAxisAlignment: mine
                ? MainAxisAlignment.end
                : MainAxisAlignment.start,
            children: [
              if (mine)
                IconButton(
                  tooltip: '删除回复',
                  onPressed: onDelete,
                  color: xy.faint,
                  icon: const Icon(CupertinoIcons.trash, size: 18),
                ),
              Flexible(child: bubble),
              if (!mine) const SizedBox(width: 40),
            ],
          ),
        ],
      ),
    );
  }
}

bool _destructive(String action) =>
    ['删除', '解除', '停止', '取消', '撤回', '关闭'].any(action.contains);
