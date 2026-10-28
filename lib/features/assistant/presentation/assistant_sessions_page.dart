import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../../data/local/app_database.dart';
import '../../../app/theme.dart';
import '../../../shared/presentation.dart';
import 'assistant_conversation_controller.dart';
import 'assistant_identity_boundary.dart';

class AssistantSessionsPage extends StatefulWidget {
  const AssistantSessionsPage({required this.controller, super.key});
  final AssistantConversationController controller;
  @override
  State<AssistantSessionsPage> createState() => _AssistantSessionsPageState();
}

class _AssistantSessionsPageState extends State<AssistantSessionsPage> {
  bool _changing = false;
  AssistantConversationController get controller => widget.controller;

  Future<void> _change(
    Future<void> Function() action, {
    bool leave = false,
    String? selectedId,
  }) async {
    if (_changing) return;
    setState(() => _changing = true);
    try {
      await action();
      if (mounted &&
          leave &&
          !controller.identityChanged &&
          (controller.error == null ||
              (selectedId != null && controller.session?.id == selectedId)) &&
          ModalRoute.of(context)?.isCurrent == true) {
        Navigator.pop(context);
      }
    } finally {
      if (mounted) setState(() => _changing = false);
    }
  }

  Future<void> _rename(
    BuildContext context,
    StoredAssistantSession session,
  ) async {
    final value = await showAdaptiveDialog<String>(
      context: context,
      builder: (_) => _SessionNameDialog(title: session.title),
    );
    if (value != null) await controller.rename(session.id, value);
  }

  Future<void> _delete(
    BuildContext context,
    StoredAssistantSession session,
  ) async {
    final approved = await confirmAction(
      context,
      title: '删除会话？',
      message: '聊天、记忆操作回执和未确认的计划草稿将被删除，不能恢复。已创建的目标和长期记忆保留；删除记忆需在记忆页单独操作。',
      confirm: '删除',
      confirmKey: const ValueKey('assistant-delete-session-confirm'),
      destructive: true,
    );
    if (approved == true) await controller.delete(session.id);
  }

  @override
  Widget build(BuildContext context) => AssistantIdentityBoundary(
    store: Future.value(controller.store),
    child: Scaffold(
      appBar: pageAppBar(
        context,
        '会话',
        actions: [
          IconButton(
            tooltip: '新建会话',
            key: const ValueKey('assistant-new-session'),
            onPressed: _changing
                ? null
                : () => _change(controller.create, leave: true),
            icon: const Icon(CupertinoIcons.add),
          ),
        ],
      ),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => PageScroll(
            children: [
              if (controller.error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: NoticeBanner(
                    tone: NoticeTone.error,
                    message: controller.error!,
                  ),
                ),
              if (controller.busy)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: NoticeBanner(
                    tone: NoticeTone.warning,
                    message: '打开另一会话或新建会话会取消当前等待；模型调用可能已经发生。',
                  ),
                ),
              if (controller.sessions.isEmpty)
                const StatusPanel(message: '没有会话')
              else
                XyGroup(
                  margin: const EdgeInsets.only(top: 12),
                  dividerIndent: 54,
                  children: [
                    for (final session in controller.sessions)
                      ListTile(
                        contentPadding: const EdgeInsets.only(left: 16),
                        leading: Icon(
                          session.id == controller.session?.id
                              ? CupertinoIcons.chat_bubble_2_fill
                              : CupertinoIcons.chat_bubble_2,
                        ),
                        title: Text(
                          session.title,
                          style: session.id == controller.session?.id
                              ? const TextStyle(fontWeight: FontWeight.w600)
                              : null,
                        ),
                        selected: session.id == controller.session?.id,
                        onTap: _changing
                            ? null
                            : () => _change(
                                () => controller.select(session.id),
                                leave: true,
                                selectedId: session.id,
                              ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              key: ValueKey('rename-session-${session.id}'),
                              tooltip: '重命名会话',
                              color: context.xy.faint,
                              onPressed: _changing
                                  ? null
                                  : () => _change(
                                      () => _rename(context, session),
                                    ),
                              icon: const Icon(CupertinoIcons.pencil, size: 20),
                            ),
                            IconButton(
                              key: ValueKey('delete-session-${session.id}'),
                              tooltip: '删除会话',
                              color: context.xy.faint,
                              onPressed: _changing
                                  ? null
                                  : () => _change(
                                      () => _delete(context, session),
                                    ),
                              icon: const Icon(CupertinoIcons.trash, size: 20),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _SessionNameDialog extends StatefulWidget {
  const _SessionNameDialog({required this.title});
  final String title;
  @override
  State<_SessionNameDialog> createState() => _SessionNameDialogState();
}

class _SessionNameDialogState extends State<_SessionNameDialog> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.title);
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog.adaptive(
    scrollable: true,
    title: const Text('会话名称'),
    content: Material(
      type: MaterialType.transparency,
      child: Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Form(
          key: _form,
          child: TextFormField(
            key: const ValueKey('assistant-session-title'),
            controller: _name,
            maxLength: 60,
            autofocus: true,
            decoration: InputDecoration(
              hintText: '名称',
              counterText: '',
              fillColor: context.xy.fill,
              isDense: true,
            ),
            validator: (value) =>
                value == null || value.trim().isEmpty ? '请输入名称' : null,
          ),
        ),
      ),
    ),
    actions: [
      XyDialogAction(label: '取消', onPressed: () => Navigator.pop(context)),
      XyDialogAction(
        label: '保存',
        primary: true,
        onPressed: () {
          if (_form.currentState!.validate()) {
            Navigator.pop(context, _name.text);
          }
        },
      ),
    ],
  );
}
