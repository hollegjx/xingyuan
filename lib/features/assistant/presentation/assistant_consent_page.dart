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
        const SizedBox(height: 12),
        Center(
          child: Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary.withValues(
                alpha: Theme.of(context).brightness == Brightness.dark
                    ? 0.24
                    : 0.12,
              ),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Icon(
              CupertinoIcons.hand_raised_fill,
              size: 32,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
        const SizedBox(height: 14),
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
        XyGroup(
          key: const ValueKey('consent-group-route'),
          header: '去向',
          dividerIndent: 50,
          children: const [
            _ConsentPoint(
              icon: CupertinoIcons.arrow_branch,
              text: '确认后，你发给助手的内容会经过星愿后端、所有者的模型中转 model-relay.example.com，由 gpt-6-luna 处理。星愿后端不保存正文，中转的留存规则以中转方为准。',
            ),
          ],
        ),
        XyGroup(
          key: const ValueKey('consent-group-content'),
          header: '内容',
          dividerIndent: 50,
          children: const [
            _ConsentPoint(
              icon: CupertinoIcons.tray_arrow_up,
              text: '每次对话会发送：当前对话、会话摘要、有效记忆、今天起 14 天的已有安排，以及活跃目标近 14 天的完成次数。记忆、已有安排和完成情况可以在 AI 设置里分别关闭。',
            ),
          ],
        ),
        XyGroup(
          key: const ValueKey('assistant-record-consent'),
          header: '你的记录',
          dividerIndent: 50,
          children: const [
            _ConsentPoint(
              icon: CupertinoIcons.book,
              text: '你让助手写日记或回顾某一天时，它会读取那一天的目标完成情况、打卡文字、随手记和日记文字，只限今天和之前 7 天。读今天不再询问；读更早的日子会先问你。每次读了什么，对话里都会写明。',
            ),
          ],
        ),
        XyGroup(
          key: const ValueKey('consent-group-boundary'),
          header: '隐私边界',
          dividerIndent: 50,
          children: const [
            _ConsentPoint(
              icon: CupertinoIcons.lock,
              text: '照片从不发送。助手不会自己翻看你的历史记录，也不会把你没点名的日子发出去。生成的日记只是草稿，你确认之前不会保存。',
            ),
          ],
        ),
        XyGroup(
          key: const ValueKey('consent-group-choice'),
          header: '你的选择',
          dividerIndent: 50,
          children: const [
            _ConsentPoint(
              icon: CupertinoIcons.hand_raised,
              text: '可以在 AI 设置里关闭“按请求读取随手记和日记”，关闭后助手照样能聊天和排日程。不确认授权也能继续使用目标、打卡、日记和本地提醒；确认前不会访问 AI 服务。',
            ),
          ],
        ),
        const SizedBox(height: 28),
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
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
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
