import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/local/app_database.dart';
import '../../../data/sync/identity_store.dart';
import '../../../shared/local_date.dart';
import '../../../shared/presentation.dart';
import '../../assistant/assistant_providers.dart';
import '../../assistant/data/local_conversation_store.dart';
import '../../assistant/presentation/assistant_identity_boundary.dart';
import '../data/chat_diary_store.dart';
import '../data/local_journal_store.dart';
import '../domain/journal_entry.dart';
import '../domain/journal_suggestion.dart';
import 'diary_preview_body.dart';
import 'journal_editor_page.dart';

class ChatDiaryPage extends ConsumerStatefulWidget {
  const ChatDiaryPage({required this.proposalId, super.key});
  final String proposalId;

  @override
  ConsumerState<ChatDiaryPage> createState() => _ChatDiaryPageState();
}

class _ChatDiaryPageState extends ConsumerState<ChatDiaryPage> {
  late final Future<LocalConversationStore> _conversation;
  late final Future<ChatDiaryStore> _store;
  StoredDiaryProposal? _row;
  ChatDiaryPreview? _preview;
  ChatDiaryMode? _mode;
  LocalDate? _recoveryDay;
  bool _refreshRequired = false;
  bool _refreshingOriginal = false;
  bool _busy = false;
  String? _error;
  final _editedText = TextEditingController();
  bool get _hasEdits =>
      _row?.status == 'pending' && _editedText.text != _row!.content;
  String? get _editError => journalSuggestionError(
    _editedText.text,
    kind: JournalKind.diary,
    original: _preview?.original ?? '',
    append: _mode == ChatDiaryMode.append,
  );

  @override
  void initState() {
    super.initState();
    _conversation = ref.read(assistantStoreProvider.future);
    _store = _conversation.then((store) => ChatDiaryStore(store.goals));
    _editedText.addListener(_textChanged);
    _loadProposal();
  }

  Future<void> _loadProposal() async {
    if (_row != null) return;
    await _change((store) async {
      final row = await store.proposal(widget.proposalId);
      if (!mounted) return;
      _row = row;
      _editedText.text = row.content;
    });
  }

  void _textChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _editedText.dispose();
    super.dispose();
  }

  Future<void> _leave() => _change((_) async {
    FocusScope.of(context).unfocus();
    final discard =
        !_hasEdits || await confirmDiscardDiaryEdits(context, 'chat-diary');
    if (discard && mounted) Navigator.pop(context);
  });

  Future<void> _cancel() => _change((store) async {
    FocusScope.of(context).unfocus();
    final discard =
        !_hasEdits || await confirmDiscardDiaryEdits(context, 'chat-diary');
    if (discard && mounted) _row = await store.cancel(widget.proposalId);
  });

  Future<void> _change(
    Future<void> Function(ChatDiaryStore) action, {
    bool refreshingOriginal = false,
  }) async {
    if (!mounted || _busy) return;
    setState(() {
      _busy = true;
      _refreshingOriginal = refreshingOriginal;
      _error = null;
    });
    try {
      await action(await _store);
    } catch (error) {
      if (_row?.status == 'pending' &&
          (error is ChatDiaryDraftConflict || error is JournalConflict)) {
        final day = _preview?.day;
        if (day != null) {
          try {
            final store = await _store;
            final current = await LocalDiaryStore(store.goals).atDay(day);
            if (mounted) {
              _recoveryDay = current?.hasDraftChanges == true ? day : null;
              _refreshRequired =
                  error is JournalConflict && _recoveryDay == null;
            }
          } catch (_) {
            _recoveryDay = null;
            _refreshRequired = error is JournalConflict;
          }
        }
      }
      if (mounted) {
        _error = switch (error) {
          JournalConflict() when _refreshRequired => null,
          JournalRuleException() => error.message,
          StaleIdentity() => '身份已变化，请重新打开；原有日记未改动。',
          _ when _refreshingOriginal => '刷新未完成，请重试。当前修改已保留。',
          _ => '操作未完成，请重试。原有日记和建议已保留。',
        };
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _refreshingOriginal = false;
        });
      }
    }
  }

  Future<void> _selectDay(LocalDate day) => _change((store) async {
    final preview = await store.preview(widget.proposalId, day);
    if (!mounted) return;
    _preview = preview;
    _recoveryDay = null;
    _refreshRequired = false;
    _mode = preview.original.isEmpty ? ChatDiaryMode.replace : null;
  });

  Future<void> _pickDay() => _change((store) async {
    FocusScope.of(context).unfocus();
    final today = store.goals.clock.read().day;
    final proposed =
        _preview?.day ??
        (_row?.suggestedDay == null
            ? today
            : LocalDate.parse(_row!.suggestedDay!));
    final initial = proposed.isAfter(today) ? today : proposed;
    if (!mounted) return;
    final day = await showDatePicker(
      context: context,
      initialDate: DateTime(initial.year, initial.month, initial.day),
      firstDate: DateTime(1),
      lastDate: DateTime(today.year, today.month, today.day),
    );
    if (day == null || !mounted) return;
    _preview = await store.preview(
      widget.proposalId,
      LocalDate.fromDateTime(day),
    );
    _mode = _preview!.original.isEmpty ? ChatDiaryMode.replace : null;
    _recoveryDay = null;
    _refreshRequired = false;
  });

  Future<bool> _refreshDiary(ChatDiaryStore store, LocalDate day) async {
    final previous = _preview;
    final previousMode = _mode;
    final row = await store.proposal(widget.proposalId);
    if (!mounted) return false;
    await store.goals.requireActiveIdentity();
    if (!mounted) return false;
    _row = row;
    if (row.status != 'pending') {
      _preview = null;
      _mode = null;
      _recoveryDay = null;
      _refreshRequired = false;
      return false;
    }
    final ChatDiaryPreview preview;
    try {
      preview = await store.preview(widget.proposalId, day);
    } on JournalRuleException {
      // The proposal may be handled between the two local reads.
      final latest = await store.proposal(widget.proposalId);
      if (!mounted) return false;
      await store.goals.requireActiveIdentity();
      if (!mounted) return false;
      _row = latest;
      if (latest.status == 'pending') rethrow;
      _preview = null;
      _mode = null;
      _recoveryDay = null;
      _refreshRequired = false;
      return false;
    }
    if (!mounted) return false;
    await store.goals.requireActiveIdentity();
    if (!mounted) return false;
    _row = preview.proposal;
    _preview = preview;
    _recoveryDay = null;
    final originalChanged =
        previous?.existing?.id != preview.existing?.id ||
        previous?.existing?.revision != preview.existing?.revision ||
        previous?.original != preview.original;
    _mode = preview.original.isEmpty
        ? ChatDiaryMode.replace
        : originalChanged
        ? null
        : previousMode;
    return true;
  }

  Future<void> _refreshOriginal() => _change((store) async {
    final day = _preview?.day;
    if (!_refreshRequired || day == null || _row?.status != 'pending') return;
    if (!await _refreshDiary(store, day)) return;
    final current = await LocalDiaryStore(store.goals).atDay(day);
    if (!mounted) return;
    await store.goals.requireActiveIdentity();
    if (!mounted) return;
    _refreshRequired = false;
    if (current?.hasDraftChanges == true) {
      _recoveryDay = day;
      _error = const ChatDiaryDraftConflict().message;
    }
  }, refreshingOriginal: true);

  Future<void> _recoverDiary() => _change((store) async {
    final day = _recoveryDay;
    if (day == null || _row?.status != 'pending') return;
    FocusScope.of(context).unfocus();
    if (!await _refreshDiary(store, day)) return;
    final current = await LocalDiaryStore(store.goals).atDay(day);
    if (!mounted || current?.hasDraftChanges != true) return;
    // Keep the corrected preview alive; navigation does not apply either text.
    await openJournalEditor(context, kind: JournalKind.diary, day: day);
    if (!mounted || !await _refreshDiary(store, day)) return;
    final remaining = await LocalDiaryStore(store.goals).atDay(day);
    if (!mounted) return;
    if (remaining?.hasDraftChanges == true) {
      _recoveryDay = day;
      _error = const ChatDiaryDraftConflict().message;
    }
  });

  Future<void> _save() => _change((store) async {
    if (_row?.status != 'pending' || _refreshRequired) return;
    final preview = _preview;
    final mode = _mode;
    if (preview == null || mode == null || !mounted) return;
    final editedText = _editedText.text;
    final error = _editError;
    if (error != null) throw JournalRuleException(error);
    FocusScope.of(context).unfocus();
    final message = preview.original.isEmpty
        ? '保存预览中的文字。'
        : mode == ChatDiaryMode.append
        ? '保留原文，将建议接在后面。'
        : '用预览中的文字替换原文，照片保持不变。';
    final large =
        MediaQuery.textScalerOf(context).scale(17) * 4 >
        (MediaQuery.sizeOf(context).width - 32) / 2;
    final confirmed = large
        ? await showModalBottomSheet<bool>(
                context: context,
                isScrollControlled: true,
                useSafeArea: true,
                builder: (context) => SafeArea(
                  child: SizedBox(
                    height: MediaQuery.sizeOf(context).height * .85,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            '保存日记？',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          _DiaryDate(preview.day.key),
                          const SizedBox(height: 12),
                          Text(message),
                          const SizedBox(height: 20),
                          FilledButton(
                            key: const ValueKey('chat-diary-confirm-save'),
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 12,
                              ),
                            ),
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text('确认保存'),
                          ),
                          TextButton(
                            key: const ValueKey('chat-diary-abort-save'),
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text('取消'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ) ??
              false
        : await confirmAction(
            context,
            title: '保存日记？',
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _DiaryDate(preview.day.key, confirmation: true),
                const SizedBox(height: 12),
                Text(message),
              ],
            ),
            confirm: '确认保存',
            confirmKey: const ValueKey('chat-diary-confirm-save'),
            cancelKey: const ValueKey('chat-diary-abort-save'),
          );
    if (!confirmed || !mounted) return;
    _row = await store.apply(preview, mode, editedText: editedText);
  });

  Future<void> _undo() => _change((store) async {
    if (!mounted) return;
    final confirmed = await confirmAction(
      context,
      title: '撤销本次日记写入？',
      message: '仅恢复本次写入前的内容；有后续修改时不会覆盖。',
      confirm: '确认撤销',
      confirmKey: const ValueKey('chat-diary-confirm-undo'),
    );
    if (!confirmed || !mounted) return;
    _row = await store.undo(widget.proposalId);
  });

  @override
  Widget build(BuildContext context) => AssistantIdentityBoundary(
    store: _conversation,
    child: PopScope(
      canPop: (!_busy || _row == null) && !_hasEdits,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('写进日记')),
        body: SafeArea(
          child: PageScroll(
            children: [
              if (_error != null && _row != null)
                NoticeBanner(tone: NoticeTone.warning, message: _error!),
              if (_row == null)
                StatusPanel(
                  message: _error ?? '正在读取日记建议',
                  loading: _busy,
                  icon: CupertinoIcons.doc_text,
                  retry: !_busy && _error != null ? _loadProposal : null,
                ),
              if (_row case final row?) ...[
                if (row.status == 'pending') ...[
                  if (_refreshRequired) ...[
                    if (_error == null)
                      const NoticeBanner(
                        tone: NoticeTone.warning,
                        message: '原文已有更新，请先刷新原文。当前修改已保留。',
                      ),
                    TextButton(
                      key: const ValueKey('chat-diary-refresh-original'),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 12,
                        ),
                      ),
                      onPressed: _busy ? null : _refreshOriginal,
                      child: Wrap(
                        alignment: WrapAlignment.center,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 8,
                        children: [
                          const Icon(CupertinoIcons.refresh),
                          Text(_refreshingOriginal ? '刷新中' : '刷新原文'),
                        ],
                      ),
                    ),
                  ],
                  if (_recoveryDay != null)
                    TextButton(
                      key: const ValueKey('chat-diary-view'),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 12,
                        ),
                      ),
                      onPressed: _busy ? null : _recoverDiary,
                      child: const Wrap(
                        alignment: WrapAlignment.center,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 8,
                        children: [Icon(CupertinoIcons.book), Text('处理草稿')],
                      ),
                    ),
                  const Text('尚未保存'),
                  ListTile(
                    key: const ValueKey('chat-diary-date'),
                    contentPadding: EdgeInsets.zero,
                    title: const Row(
                      children: [
                        Expanded(child: Text('日期', semanticsLabel: '日记日期')),
                        SizedBox(width: 8),
                        Icon(CupertinoIcons.calendar),
                      ],
                    ),
                    subtitle: _preview == null
                        ? const Text('尚未选择')
                        : _DiaryDate(_preview!.day.key),
                    onTap: _busy ? null : _pickDay,
                  ),
                  if (_preview == null && row.suggestedDay != null)
                    TextButton(
                      key: const ValueKey('chat-diary-suggested-date'),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 8,
                        ),
                      ),
                      onPressed: _busy
                          ? null
                          : () =>
                                _selectDay(LocalDate.parse(row.suggestedDay!)),
                      child: Column(
                        children: [
                          const Text('选择日期'),
                          _DiaryDate(row.suggestedDay!),
                        ],
                      ),
                    ),
                  DiaryPreviewBody(
                    original: _preview?.original ?? '',
                    suggestion: row.content,
                    editedText: _editedText,
                    append: _mode == null
                        ? null
                        : _mode == ChatDiaryMode.append,
                    onChanged: (append) => setState(() {
                      _mode = append
                          ? ChatDiaryMode.append
                          : ChatDiaryMode.replace;
                    }),
                    enabled: !_busy,
                    keyPrefix: 'chat-diary',
                  ),
                  const SizedBox(height: 20),
                  FilledButton(
                    key: const ValueKey('chat-diary-save'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 12,
                      ),
                    ),
                    onPressed:
                        _busy ||
                            _refreshRequired ||
                            _preview == null ||
                            _mode == null ||
                            _editError != null
                        ? null
                        : _save,
                    child: const Text('保存日记'),
                  ),
                  TextButton(
                    key: const ValueKey('chat-diary-cancel'),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 8,
                      ),
                    ),
                    onPressed: _busy ? null : _cancel,
                    child: const Text('取消建议'),
                  ),
                ] else if (row.status == 'applied') ...[
                  Semantics(
                    label: '已保存到 ${row.targetDay} 日记',
                    excludeSemantics: true,
                    key: const ValueKey('chat-diary-receipt'),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [const Text('已保存'), _DiaryDate(row.targetDay!)],
                    ),
                  ),
                  const Text('只保存在本机'),
                  TextButton.icon(
                    key: const ValueKey('chat-diary-view'),
                    onPressed: _busy
                        ? null
                        : () => openJournalEditor(
                            context,
                            kind: JournalKind.diary,
                            day: LocalDate.parse(row.targetDay!),
                          ),
                    icon: const Icon(CupertinoIcons.book),
                    label: const Text('查看日记'),
                  ),
                  TextButton.icon(
                    key: const ValueKey('chat-diary-undo'),
                    onPressed: _busy ? null : _undo,
                    icon: const Icon(CupertinoIcons.arrow_uturn_left),
                    label: const Text('撤销本次写入'),
                  ),
                ] else
                  Text(row.status == 'undone' ? '本次写入已撤销' : '建议已取消，未写入日记'),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

/// Give the date its own width and break only between calendar components.
class _DiaryDate extends StatelessWidget {
  const _DiaryDate(this.date, {this.confirmation = false});
  final String date;
  final bool confirmation;

  @override
  Widget build(BuildContext context) {
    final parts = date.split('-');
    // Adaptive dialogs measure intrinsic size before layout. Keep their date
    // intrinsic-friendly and use deliberate calendar lines at large sizes.
    if (confirmation) {
      return Text(
        MediaQuery.textScalerOf(context).scale(17) > 25.5
            ? parts.join('\n')
            : date,
        semanticsLabel: date,
      );
    }
    return LayoutBuilder(
      builder: (context, box) {
        final style = DefaultTextStyle.of(context).style;
        final painter = TextPainter(
          text: TextSpan(text: date, style: style),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout();
        final fits = painter.width <= box.maxWidth;
        final monthDay = '${parts[1]}-${parts[2]}';
        painter.text = TextSpan(text: monthDay, style: style);
        painter.layout();
        final monthDayFits = painter.width <= box.maxWidth;
        painter.dispose();
        return Text(
          fits
              ? date
              : monthDayFits
              ? '${parts[0]}\n$monthDay'
              : parts.join('\n'),
          semanticsLabel: date,
        );
      },
    );
  }
}
