import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

import '../../../app/providers.dart';
import '../../../data/local/app_database.dart';
import '../../../app/theme.dart';
import '../../../shared/presentation.dart';
import '../assistant_providers.dart';
import '../data/local_conversation_store.dart';
import '../data/local_memory_store.dart';
import 'assistant_identity_boundary.dart';

class AssistantMemoryPage extends ConsumerStatefulWidget {
  const AssistantMemoryPage({super.key});
  @override
  ConsumerState<AssistantMemoryPage> createState() =>
      _AssistantMemoryPageState();
}

class _AssistantMemoryPageState extends ConsumerState<AssistantMemoryPage> {
  late final _store = ref.read(assistantStoreProvider.future);
  bool _busy = false;
  Future<void> _change(Future<void> Function(LocalMemoryStore) action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final store = (await _store).memories;
      await action(store);
      ref.invalidate(assistantMemoriesProvider);
      ref.invalidate(assistantSettingsProvider);
    } catch (error) {
      if (mounted) showSaveError(context, error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirm(String title) async => await confirmAction(
    context,
    title: title,
    message: '聊天记录不会删除。',
    confirm: '删除',
    destructive: true,
  );

  @override
  Widget build(BuildContext context) {
    final memories = ref.watch(assistantMemoriesProvider);
    final settings = ref.watch(assistantSettingsProvider).value;
    final sessions = ref.watch(assistantSessionsProvider);
    final today =
        ref.watch(environmentProvider).value?.day.key ??
        ref.read(clockProvider).read().day.key;
    return AssistantIdentityBoundary(
      store: _store,
      child: Scaffold(
        appBar: pageAppBar(
          context,
          '记忆',
          actions: [
            IconButton(
              key: const ValueKey('assistant-memory-add'),
              tooltip: '新增记忆',
              onPressed: _busy
                  ? null
                  : () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const AssistantMemoryEditPage(),
                      ),
                    ),
              icon: const Icon(CupertinoIcons.add),
            ),
            IconButton(
              key: const ValueKey('assistant-memory-clear'),
              tooltip: '清空记忆',
              onPressed: _busy || !(memories.value?.isNotEmpty ?? false)
                  ? null
                  : () async {
                      if (await _confirm('清空全部记忆？') && mounted) {
                        await _change((store) => store.clear());
                      }
                    },
              icon: const Icon(CupertinoIcons.trash),
            ),
          ],
        ),
        body: SafeArea(
          child: PageScroll(
            children: [
              if (settings != null)
                XyGroup(
                  margin: const EdgeInsets.only(top: 12),
                  footer: '删除记忆不删除来源聊天；删除聊天也不删除记忆。',
                  children: [
                    SwitchListTile.adaptive(
                      title: const Text('自动记忆'),
                      value: settings.autoMemory,
                      onChanged: _busy
                          ? null
                          : (value) => _change(
                              (store) =>
                                  store.updateSettings(autoMemory: value),
                            ),
                    ),
                  ],
                )
              else
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Text('删除记忆不删除来源聊天；删除聊天也不删除记忆。'),
                ),
              const SizedBox(height: 8),
              memories.when(
                loading: () =>
                    const StatusPanel(message: '正在读取记忆', loading: true),
                error: (error, stack) => StatusPanel(
                  message: '无法读取记忆',
                  retry: () => ref.invalidate(assistantMemoriesProvider),
                ),
                data: (rows) => rows.isEmpty
                    ? const StatusPanel(message: '暂无记忆')
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                            child: Text(
                              '${rows.length} / 200',
                              textAlign: TextAlign.end,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: context.xy.muted),
                            ),
                          ),
                          for (final category in memoryCategories)
                            if (rows.any((row) => row.category == category))
                              XyGroup(
                                header: category,
                                margin: const EdgeInsets.only(top: 8),
                                children: [
                                  for (final row in rows.where(
                                    (row) => row.category == category,
                                  ))
                                    _memoryRow(context, row, sessions, today),
                                ],
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

  Widget _memoryRow(
    BuildContext context,
    StoredAssistantMemory row,
    AsyncValue<List<StoredAssistantSession>> sessions,
    String today,
  ) {
    final xy = context.xy;
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall?.copyWith(color: xy.muted);
    final updated = DateTime.fromMicrosecondsSinceEpoch(row.updatedAt);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 4, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(row.content, style: theme.textTheme.bodyLarge),
          const SizedBox(height: 4),
          Text(
            row.sourceLabel ??
                (row.sourceSessionId == null
                    ? '手动记录'
                    : sessions.isLoading
                    ? '正在读取来源会话'
                    : sessions.hasError
                    ? '来源会话暂不可用'
                    : sessions.value!
                              .where(
                                (session) => session.id == row.sourceSessionId,
                              )
                              .firstOrNull
                              ?.title ??
                          '来源会话已删除'),
            style: small,
          ),
          Text(
            '更新于 ${updated.year}/${updated.month}/${updated.day}',
            style: small,
          ),
          if (row.expiresOn != null)
            Text(
              row.expiresOn!.compareTo(today) < 0
                  ? '已过期 · ${row.expiresOn}'
                  : '有效至 ${row.expiresOn}',
              style: small?.copyWith(
                color: row.expiresOn!.compareTo(today) < 0 ? xy.warning : null,
              ),
            ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              IconButton(
                key: ValueKey('pin-${row.id}'),
                tooltip: row.pinned ? '取消置顶' : '置顶',
                color: row.pinned ? theme.colorScheme.primary : xy.faint,
                onPressed: _busy
                    ? null
                    : () => _change(
                        (store) => store.edit(
                          row.id,
                          MemoryDraft(
                            category: row.category,
                            text: row.content,
                            expiresOn: row.expiresOn == null
                                ? null
                                : CalendarDate.parse(row.expiresOn!),
                            pinned: !row.pinned,
                          ),
                        ),
                      ),
                icon: Icon(
                  row.pinned ? CupertinoIcons.pin_fill : CupertinoIcons.pin,
                  size: 20,
                ),
              ),
              IconButton(
                key: ValueKey('edit-${row.id}'),
                tooltip: '编辑记忆',
                color: theme.colorScheme.primary,
                onPressed: _busy
                    ? null
                    : () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => AssistantMemoryEditPage(memory: row),
                        ),
                      ),
                icon: const Icon(CupertinoIcons.pencil, size: 20),
              ),
              IconButton(
                key: ValueKey('delete-${row.id}'),
                tooltip: '删除记忆',
                color: theme.colorScheme.error,
                onPressed: _busy
                    ? null
                    : () async {
                        if (await _confirm('删除这条记忆？') && mounted) {
                          await _change((store) => store.remove(row.id));
                        }
                      },
                icon: const Icon(CupertinoIcons.trash, size: 20),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class AssistantMemoryEditPage extends ConsumerStatefulWidget {
  const AssistantMemoryEditPage({this.memory, super.key});
  final StoredAssistantMemory? memory;
  @override
  ConsumerState<AssistantMemoryEditPage> createState() =>
      _AssistantMemoryEditPageState();
}

class _AssistantMemoryEditPageState
    extends ConsumerState<AssistantMemoryEditPage> {
  late final Future<LocalConversationStore> _store;
  late final TextEditingController _text;
  late String _category;
  CalendarDate? _expiresOn;
  bool _pinned = false;
  bool _saving = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _store = ref.read(assistantStoreProvider.future);
    final row = widget.memory;
    _text = TextEditingController(text: row?.content ?? '');
    _category = row?.category ?? '偏好';
    _expiresOn = row?.expiresOn == null
        ? null
        : CalendarDate.parse(row!.expiresOn!);
    _pinned = row?.pinned ?? false;
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final store = (await _store).memories;
      final draft = MemoryDraft(
        category: _category,
        text: _text.text.trim(),
        expiresOn: _expiresOn,
        pinned: _pinned,
      );
      if (widget.memory == null) {
        await store.add(draft);
      } else {
        await store.edit(widget.memory!.id, draft);
      }
      ref.invalidate(assistantMemoriesProvider);
      if (mounted) Navigator.of(context).pop();
    } on FormatException {
      if (mounted) setState(() => _error = '内容需要 1 至 200 字，且不能包含敏感凭据信息。');
    } catch (error) {
      if (mounted) showSaveError(context, error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _pickDate() async {
    final today = ref.read(clockProvider).read().day;
    final initial = _expiresOn ?? CalendarDate.parse(today.key);
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(initial.year, initial.month, initial.day),
      firstDate: DateTime(1),
      lastDate: DateTime(9999, 12, 31),
    );
    if (mounted && picked != null) {
      setState(
        () => _expiresOn = CalendarDate(picked.year, picked.month, picked.day),
      );
    }
  }

  @override
  Widget build(BuildContext context) => AssistantIdentityBoundary(
    store: _store,
    child: Scaffold(
      appBar: pageAppBar(
        context,
        '记忆',
        actions: [
          IconButton(
            key: const ValueKey('assistant-memory-save'),
            tooltip: '保存记忆',
            onPressed: _saving ? null : _save,
            icon: const Icon(CupertinoIcons.checkmark_alt),
          ),
        ],
      ),
      body: SafeArea(
        child: PageScroll(
          children: [
            XyGroup(
              margin: const EdgeInsets.only(top: 12),
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: DropdownButtonFormField<String>(
                    initialValue: _category,
                    isExpanded: true,
                    itemHeight: null,
                    borderRadius: BorderRadius.circular(14),
                    dropdownColor: context.xy.card,
                    icon: Icon(
                      CupertinoIcons.chevron_up_chevron_down,
                      size: 15,
                      color: context.xy.faint,
                    ),
                    decoration: const InputDecoration(
                      labelText: '类别',
                      contentPadding: EdgeInsets.symmetric(vertical: 12),
                    ),
                    items: [
                      for (final category in memoryCategories)
                        DropdownMenuItem(
                          value: category,
                          child: Text(category),
                        ),
                    ],
                    onChanged: _saving
                        ? null
                        : (value) {
                            if (value != null) {
                              setState(() => _category = value);
                            }
                          },
                  ),
                ),
                TextField(
                  key: const ValueKey('assistant-memory-text'),
                  controller: _text,
                  maxLength: 200,
                  minLines: 3,
                  maxLines: null,
                  enabled: !_saving,
                  decoration: InputDecoration(
                    hintText: '想让星愿记住什么',
                    errorText: _error,
                    errorMaxLines: 6,
                  ),
                ),
              ],
            ),
            XyGroup(
              children: [
                ListTile(
                  title: Text(
                    _expiresOn == null ? '不设到期日' : '有效至 ${_expiresOn!.key}',
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: '选择到期日',
                        color: Theme.of(context).colorScheme.primary,
                        onPressed: _saving ? null : _pickDate,
                        icon: const Icon(CupertinoIcons.calendar),
                      ),
                      IconButton(
                        tooltip: '清除到期日',
                        color: context.xy.faint,
                        onPressed: _saving || _expiresOn == null
                            ? null
                            : () => setState(() => _expiresOn = null),
                        icon: const Icon(
                          CupertinoIcons.xmark_circle_fill,
                          size: 20,
                        ),
                      ),
                    ],
                  ),
                ),
                SwitchListTile.adaptive(
                  title: const Text('置顶'),
                  value: _pinned,
                  onChanged: _saving
                      ? null
                      : (value) => setState(() => _pinned = value),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
