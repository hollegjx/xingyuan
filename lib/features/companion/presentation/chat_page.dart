import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

import '../../../app/providers.dart';
import '../../../app/theme.dart';
import '../../../shared/local_identity_boundary.dart';
import '../../../shared/presentation.dart';
import '../../../shared/ui/composer.dart';
import '../../assistant/assistant_providers.dart';
import '../../records/data/record_photo.dart';
import '../../records/data/record_photo_picker.dart';
import '../../records/record_providers.dart';
import '../companion_providers.dart';
import '../data/companion_service.dart';
import '../data/local_chat_store.dart';
import 'chat_controller.dart';

class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({super.key});
  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  late final _repository = ref
      .read(dayRecordStoreProvider.future)
      .then((store) => store.goals);
  late Future<ChatController> _controller;
  bool _expired = false;

  @override
  void initState() {
    super.initState();
    _controller = ref.read(chatControllerProvider.future);
  }

  void _expire() {
    if (!mounted || _expired) return;
    setState(() => _expired = true);
    _closeOverlays(context, () => mounted);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(assistantCredentialRevisionProvider, (_, _) => _expire());
    return LocalIdentityBoundary(
      repository: _repository,
      child: Scaffold(
        appBar: pageAppBar(
          context,
          '私聊',
          actions: [if (!_expired) _ChatBarAction(controller: _controller)],
        ),
        body: SafeArea(
          child: _expired
              ? const PageScroll(
                  children: [StatusPanel(message: '设备凭证已变化，请返回后重新打开。')],
                )
              : FutureBuilder<ChatController>(
                  future: _controller,
                  builder: (context, result) {
                    if (result.hasError) {
                      return PageScroll(
                        children: [
                          StatusPanel(
                            message: result.error is CompanionServiceFailure
                                ? (result.error as CompanionServiceFailure)
                                      .message
                                : '聊天暂时不可用。',
                            retry: () => setState(() {
                              ref.invalidate(chatControllerProvider);
                              _controller = ref.read(
                                chatControllerProvider.future,
                              );
                            }),
                          ),
                        ],
                      );
                    }
                    if (!result.hasData) {
                      return const PageScroll(
                        children: [
                          StatusPanel(message: '正在打开私聊', loading: true),
                        ],
                      );
                    }
                    return _ChatBoundary(
                      controller: result.data!,
                      child: _ChatBody(controller: result.data!),
                    );
                  },
                ),
        ),
      ),
    );
  }
}

/// Refresh, or cancel while waiting, in the navigation bar.
class _ChatBarAction extends StatelessWidget {
  const _ChatBarAction({required this.controller});
  final Future<ChatController> controller;

  @override
  Widget build(BuildContext context) => FutureBuilder<ChatController>(
    future: controller,
    builder: (context, result) {
      final controller = result.data;
      if (controller == null) return const SizedBox.shrink();
      return FrameSafeListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          if (!controller.available) return const SizedBox.shrink();
          return controller.busy
              ? IconButton(
                  tooltip: '取消等待',
                  onPressed: controller.cancelWaiting,
                  icon: const Icon(CupertinoIcons.xmark_circle),
                )
              : IconButton(
                  tooltip: '刷新消息',
                  onPressed: controller.refresh,
                  icon: const Icon(CupertinoIcons.arrow_clockwise),
                );
        },
      );
    },
  );
}

bool get _building =>
    SchedulerBinding.instance.schedulerPhase ==
    SchedulerPhase.persistentCallbacks;

void _closeOverlays(BuildContext context, bool Function() mounted) {
  final route = ModalRoute.of(context);
  final navigator = Navigator.of(context);
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted() && route != null && route.isActive) {
      navigator.popUntil(
        (candidate) => candidate == route || candidate.isFirst,
      );
    }
  });
}

class _ChatBoundary extends StatefulWidget {
  const _ChatBoundary({
    required this.controller,
    required this.child,
    this.messageId,
    this.photoId,
  });
  final ChatController controller;
  final Widget child;
  final String? messageId, photoId;
  @override
  State<_ChatBoundary> createState() => _ChatBoundaryState();
}

class _ChatBoundaryState extends State<_ChatBoundary> {
  bool _expired = false;
  bool get _accessible =>
      widget.controller.available &&
      (widget.messageId == null ||
          widget.controller.snapshot?.messages.any(
                (m) => m.id == widget.messageId && m.photoId == widget.photoId,
              ) ==
              true);

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  void _changed() {
    if (_accessible || _expired || !mounted) return;
    // A controller disposed mid-build notifies here; act after the frame.
    if (_building) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _changed());
      return;
    }
    setState(() => _expired = true);
    _closeOverlays(context, () => mounted);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _expired || !_accessible
      ? const PageScroll(children: [StatusPanel(message: '消息或配对已不可访问，请返回。')])
      : widget.child;
}

class _ChatBody extends ConsumerStatefulWidget {
  const _ChatBody({required this.controller});
  final ChatController controller;
  @override
  ConsumerState<_ChatBody> createState() => _ChatBodyState();
}

class _ChatBodyState extends ConsumerState<_ChatBody>
    with WidgetsBindingObserver {
  final _text = TextEditingController();
  final _scroll = ScrollController();
  Timer? _poll;
  bool _foreground =
      WidgetsBinding.instance.lifecycleState == null ||
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  bool _dialog = false;
  bool _picking = false;
  bool _marking = false;
  bool _leaving = false;
  bool _following = true;
  String? _photoError;
  ChatController get controller => widget.controller;
  bool get _visible =>
      mounted && _foreground && ModalRoute.of(context)?.isCurrent == true;
  bool get _latest =>
      _scroll.hasClients &&
      _scroll.position.maxScrollExtent - _scroll.offset <= 24;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    controller.addListener(_changed);
    _scroll.addListener(_markRead);
    _text.text = controller.draftText;
    controller.setForeground(_foreground);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _foreground) unawaited(controller.runPending());
    });
    _poll = Timer.periodic(const Duration(seconds: 10), (_) {
      if (_visible) unawaited(controller.refresh());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    controller.setForeground(_foreground);
    if (_foreground && _visible) {
      unawaited(controller.runPending());
    } else {
      unawaited(controller.flushDraft());
    }
  }

  void _changed() {
    if (!mounted) return;
    if (_building) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _changed());
      return;
    }
    if (_text.text != controller.draftText) {
      _text.value = TextEditingValue(
        text: controller.draftText,
        selection: TextSelection.collapsed(offset: controller.draftText.length),
      );
    }
    setState(() {});
  }

  void _markRead() {
    if (!_visible || !_latest || _marking || controller.unread == 0) return;
    _marking = true;
    controller.markRead().whenComplete(() => _marking = false);
  }

  void _afterLayout() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      if (_following && _visible) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
      _markRead();
    });
  }

  Future<void> _back() async {
    await controller.flushDraft();
    if (!mounted ||
        !controller.draftSaved ||
        _picking ||
        controller.preparing) {
      return;
    }
    setState(() => _leaving = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  Future<void> _pick(RecordPhotoSource source) async {
    if (_picking || controller.preparing) return;
    setState(() {
      _picking = true;
      _photoError = null;
    });
    try {
      final bytes = await ref.read(recordPhotoPickerProvider).pick(source);
      if (bytes != null && mounted && controller.available) {
        await controller.attachPhoto(bytes);
      }
    } catch (failure) {
      if (mounted) {
        setState(() {
          _photoError = failure is RecordPhotoException
              ? failure.message
              : '无法选择照片，请重试。';
        });
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _confirm({ChatMessage? message, ChatAttempt? pending}) async {
    if (_dialog || controller.busy) return;
    setState(() => _dialog = true);
    try {
      final approved = await confirmAction(
        context,
        title: message != null ? '删除这条消息？' : '丢弃未发送的操作？',
        message: message != null ? '删除后双方都无法再查看这条消息和图片。' : '这条本地操作将被移除，不能恢复。',
        confirm: '确认删除',
        confirmKey: const ValueKey('confirm-chat'),
        destructive: true,
      );
      if (!approved || !mounted || !controller.available) return;
      if (message != null) {
        await controller.remove(message.id);
      } else {
        await controller.discard(pending!);
      }
    } finally {
      if (mounted) setState(() => _dialog = false);
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    controller.removeListener(_changed);
    unawaited(controller.flushDraft());
    _text.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final messages = controller.snapshot?.messages ?? <ChatMessage>[];
    ref.watch(environmentProvider);
    final now = ref.read(clockProvider).read().instant;
    final pending = controller.pending;
    _afterLayout();
    return PopScope(
      canPop:
          _leaving ||
          (controller.draftSaved && !_picking && !controller.preparing),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_back());
      },
      child: LayoutBuilder(
        builder: (context, constraints) => Column(
          children: [
            Expanded(
              child: NotificationListener<ScrollMetricsNotification>(
                onNotification: (notice) {
                  if (notice.depth == 0) _afterLayout();
                  return false;
                },
                child: NotificationListener<ScrollNotification>(
                  onNotification: (notice) {
                    if (notice.depth == 0) {
                      if (notice is ScrollStartNotification &&
                          notice.dragDetails != null) {
                        _following = false;
                      }
                      if (notice is ScrollEndNotification) _following = _latest;
                    }
                    return false;
                  },
                  child: RefreshIndicator.adaptive(
                    onRefresh: controller.refresh,
                    child: ListView.builder(
                      key: const ValueKey('chat-messages'),
                      controller: _scroll,
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                      itemCount: messages.length + pending.length + 1,
                      itemBuilder: (context, index) {
                        if (index == 0) {
                          return messages.isEmpty && pending.isEmpty
                              ? const StatusPanel(
                                  message: '还没有消息',
                                  detail: '这里的消息只有你们两个人能看到。',
                                )
                              : const SizedBox(height: 4);
                        }
                        if (index <= messages.length) {
                          final m = messages[index - 1];
                          final mine = m.authorId == controller.store.memberId;
                          return _Bubble(
                            key: ValueKey('chat-message-${m.id}'),
                            mine: mine,
                            divider: chatDividerLabel(
                              m.createdAt,
                              index > 1 ? messages[index - 2].createdAt : null,
                              now: now,
                            ),
                            text: m.text,
                            photo: m.photoId == null
                                ? null
                                : _ChatPhoto(
                                    key: ValueKey('chat-photo-${m.photoId}'),
                                    controller: controller,
                                    id: m.photoId!,
                                    messageId: m.id,
                                  ),
                            actions: [
                              if (mine)
                                IconButton(
                                  key: ValueKey('delete-chat-${m.id}'),
                                  tooltip: '删除消息',
                                  onPressed: controller.busy || _dialog
                                      ? null
                                      : () => _confirm(message: m),
                                  color: context.xy.faint,
                                  icon: const Icon(
                                    CupertinoIcons.trash,
                                    size: 18,
                                  ),
                                ),
                            ],
                          );
                        }
                        final job = pending[index - messages.length - 1];
                        return _Bubble(
                          key: ValueKey('pending-chat-${job.row.operationId}'),
                          mine: true,
                          pending: true,
                          meta: _status(job),
                          text: job.row.content,
                          photo: job.row.localPhotoId == null
                              ? null
                              : _ChatPhoto(
                                  key: ValueKey(
                                    'pending-photo-${job.row.localPhotoId}',
                                  ),
                                  controller: controller,
                                  id: job.row.localPhotoId!,
                                ),
                          actions: [
                            if (controller.canRetry(job))
                              IconButton(
                                key: ValueKey(
                                  'retry-chat-${job.row.operationId}',
                                ),
                                tooltip: '重试原操作',
                                onPressed: () => controller.retry(job),
                                icon: const Icon(
                                  CupertinoIcons.arrow_clockwise,
                                  size: 18,
                                ),
                              ),
                            if (controller.canDiscard(job))
                              IconButton(
                                key: ValueKey(
                                  'discard-chat-${job.row.operationId}',
                                ),
                                tooltip: '丢弃未发送的操作',
                                color: context.xy.faint,
                                onPressed: _dialog
                                    ? null
                                    : () => _confirm(pending: job),
                                icon: const Icon(
                                  CupertinoIcons.trash,
                                  size: 18,
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
            XyComposer(
              maxHeight: constraints.maxHeight * 0.5,
              notices: [
                if (controller.error case final error?)
                  NoticeBanner(tone: NoticeTone.error, message: error),
                if (controller.draftError case final error?)
                  NoticeBanner(
                    tone: NoticeTone.error,
                    message: error,
                    action: '重试',
                    onAction: () => controller.editText(_text.text),
                  ),
                if (_photoError case final error?)
                  NoticeBanner(tone: NoticeTone.warning, message: error),
              ],
              attachment: switch (controller.draftPhotoId) {
                final photo? => Stack(
                  clipBehavior: Clip.none,
                  children: [
                    _ChatPhoto(
                      key: ValueKey('draft-photo-$photo'),
                      controller: controller,
                      id: photo,
                    ),
                    Positioned(
                      top: -10,
                      right: -10,
                      child: IconButton(
                        tooltip: '移除待发图片',
                        onPressed: controller.preparing
                            ? null
                            : controller.removeDraftPhoto,
                        icon: const Icon(
                          CupertinoIcons.xmark_circle_fill,
                          size: 22,
                        ),
                      ),
                    ),
                  ],
                ),
                null => null,
              },
              leading: [
                IconButton(
                  key: const ValueKey('chat-camera'),
                  tooltip: '拍照',
                  onPressed: _picking || controller.preparing
                      ? null
                      : () => _pick(RecordPhotoSource.camera),
                  icon: const Icon(CupertinoIcons.camera_fill, size: 24),
                ),
                IconButton(
                  key: const ValueKey('chat-library'),
                  tooltip: '从相册选择',
                  onPressed: _picking || controller.preparing
                      ? null
                      : () => _pick(RecordPhotoSource.library),
                  icon: const Icon(CupertinoIcons.photo, size: 24),
                ),
              ],
              field: TextField(
                key: const ValueKey('chat-input'),
                controller: _text,
                minLines: 1,
                maxLines: 5,
                maxLength: 1000,
                maxLengthEnforcement: MaxLengthEnforcement.none,
                decoration: composerDecoration(context, hint: '说点什么…'),
                onChanged: (value) => unawaited(controller.editText(value)),
              ),
              send: sendButton(
                context,
                key: const ValueKey('send-chat'),
                onPressed: _picking || controller.preparing
                    ? null
                    : controller.send,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _status(ChatAttempt job) {
  final deleting = job.row.kind == 'remove';
  return switch (job.row.status) {
    'succeeded' => deleting ? '已删除，等待刷新' : '已发送，等待刷新',
    'sending' => deleting ? '正在删除' : '正在发送',
    'uncertain' => deleting ? '删除结果待确认，请重试原操作' : '发送结果待确认，请重试原操作',
    'failed' => deleting ? '删除失败' : '未发送',
    _ => deleting ? '待删除' : '等待发送',
  };
}

class _ChatPhoto extends StatefulWidget {
  const _ChatPhoto({
    required this.controller,
    required this.id,
    this.messageId,
    super.key,
  });
  final ChatController controller;
  final String id;
  final String? messageId;
  @override
  State<_ChatPhoto> createState() => _ChatPhotoState();
}

class _ChatPhotoState extends State<_ChatPhoto> {
  CompanionCancellation? _cancel;
  late Future<Uint8List> _bytes;
  MemoryImage? _image;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _cancel?.cancel();
    final cancel = _cancel = CompanionCancellation();
    _bytes = Future.sync(() async {
      final bytes = widget.messageId == null
          ? await widget.controller.files.read(
              widget.controller.store,
              widget.id,
            )
          : (await widget.controller.downloadPhoto(
              widget.messageId!,
              widget.id,
              cancel,
            )).bytes;
      if (!mounted || cancel.isCancelled || !widget.controller.available) {
        throw const CompanionServiceFailure('discarded');
      }
      _image?.evict().ignore();
      _image = MemoryImage(bytes);
      return bytes;
    });
  }

  @override
  void dispose() {
    _cancel?.cancel();
    _image?.evict().ignore();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(12),
    child: ColoredBox(
      color: context.xy.cardSoft,
      child: SizedBox.square(
        dimension: widget.messageId == null ? 88 : 140,
        child: FutureBuilder<Uint8List>(
          future: _bytes,
          builder: (context, result) {
            if (result.hasError) {
              return IconButton(
                tooltip: '重试读取图片',
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
              onTap: widget.messageId == null
                  ? null
                  : () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (context) => Scaffold(
                          appBar: pageAppBar(context, '聊天图片'),
                          body: SafeArea(
                            child: _ChatBoundary(
                              controller: widget.controller,
                              messageId: widget.messageId,
                              photoId: widget.id,
                              child: Center(
                                child: InteractiveViewer(
                                  minScale: 1,
                                  maxScale: 4,
                                  child: Image(
                                    image: _image!,
                                    fit: BoxFit.contain,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
              child: Image(
                image: _image!,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const Icon(CupertinoIcons.photo),
              ),
            );
          },
        ),
      ),
    ),
  );
}

/// One chat line: mine on the right in the accent colour, TA's on the left.
class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.mine,
    required this.text,
    this.meta,
    this.divider,
    this.photo,
    this.actions = const [],
    this.pending = false,
    super.key,
  });

  final bool mine;
  final bool pending;

  /// Status caption under a pending bubble ("发送中…").
  final String? meta;

  /// Time stamp shown centered above this message when it starts a new
  /// stretch of the conversation.
  final String? divider;
  final String text;
  final Widget? photo;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final xy = context.xy;
    final primary = theme.colorScheme.primary;
    final background = mine
        ? (pending ? primary.withValues(alpha: 0.45) : primary)
        : xy.card;
    final foreground = mine ? Colors.white : theme.colorScheme.onSurface;
    final bubble = Container(
      constraints: const BoxConstraints(maxWidth: 480),
      padding: EdgeInsets.fromLTRB(
        text.isEmpty ? 4 : 13,
        text.isEmpty ? 4 : 8,
        text.isEmpty ? 4 : 13,
        text.isEmpty ? 4 : 9,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(18),
          topRight: const Radius.circular(18),
          bottomLeft: Radius.circular(mine ? 18 : 5),
          bottomRight: Radius.circular(mine ? 5 : 18),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (text.isNotEmpty)
            Text(
              text,
              style: theme.textTheme.bodyLarge?.copyWith(color: foreground),
            ),
          if (photo != null) ...[
            if (text.isNotEmpty) const SizedBox(height: 6),
            photo!,
          ],
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: mine
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          if (divider != null)
            SizedBox(width: double.infinity, child: ChatTimeDivider(divider!)),
          Row(
            mainAxisAlignment: mine
                ? MainAxisAlignment.end
                : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (mine) ...actions,
              Flexible(child: bubble),
              if (!mine) ...actions,
              if (!mine) const SizedBox(width: 40),
            ],
          ),
          if (meta != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 3, 10, 2),
              child: Text(
                meta!,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: xy.muted,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
