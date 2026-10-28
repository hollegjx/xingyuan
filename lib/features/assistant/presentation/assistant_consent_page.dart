import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../shared/presentation.dart';
import '../assistant_providers.dart';
import 'assistant_identity_boundary.dart';

class AssistantConsentPage extends StatelessWidget {
  const AssistantConsentPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: pageAppBar(context, '发送范围'),
    body: SafeArea(
      child: AssistantConsentBody(
        onConfirmed: () => Navigator.of(context).pop(true),
      ),
    ),
  );
}

class AssistantConsentBody extends ConsumerStatefulWidget {
  const AssistantConsentBody({this.onConfirmed, this.onReopen, super.key});
  final VoidCallback? onConfirmed;
  final VoidCallback? onReopen;

  @override
  ConsumerState<AssistantConsentBody> createState() =>
      _AssistantConsentBodyState();
}

class _AssistantConsentBodyState extends ConsumerState<AssistantConsentBody> {
  late final _store = ref.read(assistantStoreProvider.future);
  bool _saving = false;
  Future<void> _confirm() async {
    setState(() => _saving = true);
    try {
      final store = await _store;
      await store.memories.consent();
      ref.invalidate(assistantSettingsProvider);
      if (mounted) widget.onConfirmed?.call();
    } catch (error) {
      if (mounted) showSaveError(context, error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AssistantIdentityBoundary(
    store: _store,
    onReopen: widget.onReopen,
    child: PageScroll(
      children: [
        const SizedBox(height: 8),
        Icon(
          CupertinoIcons.hand_raised_fill,
          size: 44,
          color: Theme.of(context).colorScheme.primary,
        ),
        const SizedBox(height: 10),
        Text(
          'AI 数据授权',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 4),
        Text(
          '请确认 AI 的发送范围',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium
              ?.copyWith(color: context.xy.muted),
        ),
        const SizedBox(height: 20),
        const Card(
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: Column(
              children: [
                _ConsentPoint(
                  icon: CupertinoIcons.arrow_branch,
                  text: '确认后，你发送的内容会经过所配置的星愿后端和模型服务。请先向服务提供方确认处理位置与数据留存规则。',
                ),
                _ConsentPoint(
                  icon: CupertinoIcons.tray_arrow_up,
                  text: '发送内容包括当前对话、会话摘要、有效记忆、今天起 14 天的已有安排，以及活跃目标近 14 天的完成次数。记忆、已有安排、完成情况可在 AI 设置中分别关闭。',
                ),
                _ConsentPoint(
                  icon: CupertinoIcons.lock,
                  text: '规划不自动发送私密笔记。主动点“润色”只发送当前这一条随手记的文字；点“用今天生成”只发送今天的目标名称、完成状态、已保存打卡文字和随手记文字。不发送照片、历史日记或其他身份的数据。',
                ),
                _ConsentPoint(
                  icon: CupertinoIcons.hand_raised,
                  text: '日记 AI 与规划的可选上下文开关分开：只有主动点对应按钮才发送上述文字。星愿后端不保存正文，中转的留存规则以中转方为准。AI 设置中可以关闭规划与日记 AI。',
                ),
                _ConsentPoint(
                  icon: CupertinoIcons.lightbulb,
                  text: '自动记忆默认开启，相关信息会保存在本机，可撤销或关闭。模型提议只有经你确认才创建目标；提醒也由你主动开启。',
                ),
                _ConsentPoint(
                  icon: CupertinoIcons.checkmark_circle,
                  text: '不确认也能继续使用目标、打卡和本地提醒。确认前不会访问 AI 服务。',
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        FilledButton(
          key: const ValueKey('assistant-consent-confirm'),
          onPressed: _saving ? null : _confirm,
          child: Text(_saving ? '正在保存' : '同意并继续'),
        ),
      ],
    ),
  );
}

class _ConsentPoint extends StatelessWidget {
  const _ConsentPoint({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(
            icon,
            size: 22,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
        ),
      ],
    ),
  );
}
