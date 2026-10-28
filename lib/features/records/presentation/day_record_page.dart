import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../shared/local_date.dart';
import '../../../shared/local_identity_boundary.dart';
import '../../../shared/presentation.dart';
import '../../companion/presentation/publication_status.dart';
import '../data/local_day_record_store.dart';
import '../data/record_photo_picker.dart';
import '../record_providers.dart';
import 'day_record_controller.dart';
import 'record_photo_view.dart';

class DayRecordPage extends ConsumerStatefulWidget {
  const DayRecordPage({
    required this.goalId,
    required this.day,
    required this.title,
    required this.editable,
    super.key,
  });

  final int goalId;
  final LocalDate day;
  final String title;
  final bool editable;

  @override
  ConsumerState<DayRecordPage> createState() => _DayRecordPageState();
}

class _DayRecordPageState extends ConsumerState<DayRecordPage> {
  late final Future<LocalDayRecordStore> _store = ref.read(
    dayRecordStoreProvider.future,
  );
  late Future<void> _opening = _open();
  final _text = TextEditingController();
  DayRecordController? _controller;
  bool _leaving = false;
  bool _allowLeave = false;
  bool _confirming = false;

  Future<void> _open() async {
    final store = await _store;
    final files = await ref.read(recordPhotoFilesProvider.future);
    if (!mounted) return;
    final controller = DayRecordController(
      store: store,
      files: files,
      picker: ref.read(recordPhotoPickerProvider),
    );
    try {
      await controller.initialize(
        widget.goalId,
        widget.day,
        editable: widget.editable,
      );
      if (!mounted) {
        controller.dispose();
        return;
      }
      _controller?.dispose();
      _controller = controller;
      _text.text = controller.text;
      controller.addListener(_changed);
      setState(() {});
    } catch (_) {
      controller.dispose();
      rethrow;
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller?.dispose();
    _text.dispose();
    super.dispose();
  }

  Future<void> _leave() async {
    final controller = _controller;
    if (_leaving || controller?.busy == true) return;
    _leaving = true;
    try {
      await controller?.flush();
      if (!mounted) return;
      setState(() => _allowLeave = true);
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(recordErrorMessage(error))));
      }
    } finally {
      _leaving = false;
    }
  }

  Future<void> _delete() async {
    if (_confirming || _controller!.busy) return;
    setState(() => _confirming = true);
    final approved = await confirmAction(
      context,
      title: '删除这条记录？',
      message: '将删除这条记录的文字、照片和草稿。打卡状态不会改变。',
      confirm: '删除',
      confirmKey: const ValueKey('confirm-delete-record'),
      destructive: true,
    );
    if (!mounted) return;
    setState(() => _confirming = false);
    if (approved == true && await _controller!.delete()) {
      if (mounted) await _leave();
    }
  }

  @override
  Widget build(BuildContext context) => LocalIdentityBoundary(
    repository: _store.then((store) => store.goals),
    child: PopScope<void>(
      canPop:
          _allowLeave ||
          (!(_controller?.dirty ?? false) && !(_controller?.busy ?? false)),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: Scaffold(
        appBar: pageAppBar(
          context,
          '记录',
          actions: [
            if (_controller?.snapshot != null)
              IconButton(
                key: const ValueKey('delete-record'),
                tooltip: '删除记录',
                onPressed: _controller!.busy || _confirming ? null : _delete,
                icon: const Icon(CupertinoIcons.trash),
              ),
          ],
        ),
        body: SafeArea(
          child: FutureBuilder<void>(
            future: _opening,
            builder: (context, state) {
              if (state.hasError) {
                return PageScroll(
                  children: [
                    StatusPanel(
                      message: recordErrorMessage(state.error!),
                      retry: () => setState(() => _opening = _open()),
                    ),
                  ],
                );
              }
              final controller = _controller;
              if (state.connectionState != ConnectionState.done ||
                  controller == null) {
                return const PageScroll(
                  children: [StatusPanel(message: '正在读取记录', loading: true)],
                );
              }
              final photos = controller.readOnly
                  ? controller.snapshot?.savedPhotos ?? []
                  : controller.snapshot!.draftPhotos;
              final enabled =
                  !controller.busy && !_confirming && !controller.closed;
              final theme = Theme.of(context);
              final xy = context.xy;
              return PageScroll(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${dateLabel(widget.day)} ${weekdayLabels[widget.day.weekday - 1]}',
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: xy.muted,
                          ),
                        ),
                        Text(
                          widget.title,
                          style: theme.textTheme.headlineMedium,
                        ),
                      ],
                    ),
                  ),
                  if (controller.syncState != 'local') ...[
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Icon(
                          CupertinoIcons.heart_fill,
                          size: 16,
                          color: xy.partner,
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            publicationStatus(controller.syncState),
                            key: const ValueKey('record-sharing-status'),
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                    PublicationQueueView(
                      goalId: widget.goalId,
                      day: widget.day.key,
                    ),
                  ],
                  const SizedBox(height: 18),
                  if (controller.readOnly)
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: xy.card,
                        borderRadius: BorderRadius.circular(xyCardRadius),
                      ),
                      child: SelectableText(
                        controller.snapshot?.record.savedAt == null
                            ? '没有已保存记录'
                            : controller.snapshot!.record.content,
                        style: theme.textTheme.bodyLarge,
                      ),
                    )
                  else
                    TextField(
                      key: const ValueKey('record-text'),
                      // A white sheet, like a note.
                      controller: _text,
                      enabled: enabled,
                      minLines: 5,
                      maxLines: null,
                      maxLength: 500,
                      maxLengthEnforcement: MaxLengthEnforcement.none,
                      textCapitalization: TextCapitalization.sentences,
                      style: theme.textTheme.bodyLarge,
                      decoration: InputDecoration(
                        contentPadding: const EdgeInsets.all(16),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(xyCardRadius),
                          borderSide: BorderSide.none,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(xyCardRadius),
                          borderSide: BorderSide.none,
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(xyCardRadius),
                          borderSide: BorderSide.none,
                        ),
                        hintText: '今天怎么样？写下一点感受、困难或者小小的得意…',
                        errorText: _text.text.characters.length > 500
                            ? '文字记录最多 500 字'
                            : null,
                      ),
                      onChanged: (value) => controller.setText(value),
                    ),
                  if (!controller.readOnly)
                    Padding(
                      padding: const EdgeInsets.only(left: 16),
                      child: Row(
                        children: [
                          Icon(
                            controller.dirty
                                ? CupertinoIcons.arrow_2_circlepath
                                : CupertinoIcons.checkmark_alt,
                            size: 13,
                            color: xy.muted,
                          ),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              controller.dirty ? '正在保存草稿' : '草稿已保存在本机',
                              key: const ValueKey('record-draft-status'),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: xy.muted,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 24),
                  if (photos.isNotEmpty || !controller.readOnly) ...[
                    Padding(
                      padding: const EdgeInsets.only(left: 16),
                      child: Wrap(
                        spacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            '照片',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: xy.muted,
                            ),
                          ),
                          if (!controller.readOnly)
                            Text(
                              '${photos.length} / 3',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: xy.muted,
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        for (final photo in photos)
                          Stack(
                            clipBehavior: Clip.none,
                            children: [
                              RecordPhotoView(photo: photo, size: 96),
                              if (!controller.readOnly)
                                Positioned(
                                  top: -10,
                                  right: -10,
                                  child: IconButton(
                                    key: ValueKey('remove-photo-${photo.id}'),
                                    tooltip: '移除照片',
                                    onPressed: enabled
                                        ? () => controller.removePhoto(photo.id)
                                        : null,
                                    icon: const DecoratedBox(
                                      decoration: BoxDecoration(
                                        color: Colors.white,
                                        shape: BoxShape.circle,
                                      ),
                                      child: Icon(
                                        CupertinoIcons.xmark_circle_fill,
                                        size: 24,
                                        color: Color(0xFF8E8E93),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        if (!controller.readOnly && photos.length < 3) ...[
                          _AddPhotoTile(
                            key: const ValueKey('record-camera'),
                            icon: CupertinoIcons.camera,
                            label: '拍照',
                            onPressed: enabled
                                ? () => controller.addPhoto(
                                    RecordPhotoSource.camera,
                                  )
                                : null,
                          ),
                          _AddPhotoTile(
                            key: const ValueKey('record-library'),
                            icon: CupertinoIcons.photo_on_rectangle,
                            label: '相册',
                            tooltip: '从相册选择',
                            onPressed: enabled
                                ? () => controller.addPhoto(
                                    RecordPhotoSource.library,
                                  )
                                : null,
                          ),
                        ],
                      ],
                    ),
                  ],
                  if (controller.readOnly &&
                      (controller.snapshot?.hasDraftChanges ?? false)) ...[
                    const SizedBox(height: 16),
                    Text('未保存草稿（只读）', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 8),
                    SelectableText(controller.snapshot!.record.draftText!),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        for (final photo in controller.snapshot!.draftPhotos)
                          RecordPhotoView(photo: photo),
                      ],
                    ),
                  ],
                  if (!controller.readOnly) ...[
                    if (controller.canShare) ...[
                      const SizedBox(height: 24),
                      Card(
                        child: CheckboxListTile.adaptive(
                          key: const ValueKey('record-share-details'),
                          controlAffinity: ListTileControlAffinity.trailing,
                          secondary: XyIconTile(
                            CupertinoIcons.heart_fill,
                            color: xy.partner,
                          ),
                          title: const Text('分享给 TA'),
                          subtitle: const Text('这条记录的文字和照片'),
                          value: controller.shareDetails,
                          onChanged: enabled
                              ? (value) =>
                                    controller.setShareDetails(value ?? false)
                              : null,
                        ),
                      ),
                    ],
                    const SizedBox(height: 28),
                    FilledButton(
                      key: const ValueKey('save-record'),
                      onPressed: enabled
                          ? () async {
                              if (await controller.save() && mounted) {
                                await _leave();
                              }
                            }
                          : null,
                      child: controller.busy
                          ? const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                XyActivity(radius: 8),
                                SizedBox(width: 8),
                                Text('保存记录'),
                              ],
                            )
                          : const Text('保存记录'),
                    ),
                  ],
                  if (controller.error case final error?) ...[
                    const SizedBox(height: 12),
                    NoticeBanner(
                      key: const ValueKey('record-error'),
                      tone: NoticeTone.error,
                      message: error,
                    ),
                    if (controller.dirty)
                      TextButton.icon(
                        onPressed: enabled
                            ? () => controller.setText(_text.text)
                            : null,
                        icon: const Icon(CupertinoIcons.arrow_clockwise),
                        label: const Text('重试草稿保存'),
                      ),
                  ],
                  if (controller.cleanupWarning case final warning?)
                    Text(warning),
                ],
              );
            },
          ),
        ),
      ),
    ),
  );
}

class _AddPhotoTile extends StatelessWidget {
  const _AddPhotoTile({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.tooltip,
    super.key,
  });

  final IconData icon;
  final String label;
  final String? tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final xy = context.xy;
    final color = onPressed == null
        ? xy.muted.withValues(alpha: 0.5)
        : Theme.of(context).colorScheme.primary;
    return Tooltip(
      message: tooltip ?? label,
      excludeFromSemantics: true,
      child: Semantics(
        button: true,
        enabled: onPressed != null,
        label: tooltip ?? label,
        excludeSemantics: true,
        child: Material(
          color: xy.card,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onPressed,
            child: SizedBox.square(
              dimension: 96,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, color: color),
                  const SizedBox(height: 4),
                  Text(
                    label,
                    style: Theme.of(context).textTheme.labelMedium
                        ?.copyWith(color: color),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
