import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../data/local/app_database.dart';
import '../../../shared/presentation.dart';
import '../data/local_conversation_store.dart';

class AssistantConversationDetailsPage extends StatefulWidget {
  const AssistantConversationDetailsPage({
    required this.store,
    required this.sessionId,
    this.messageId,
    super.key,
  });
  final LocalConversationStore store;
  final String sessionId;
  final String? messageId;
  @override
  State<AssistantConversationDetailsPage> createState() =>
      _AssistantConversationDetailsPageState();
}

class _AssistantConversationDetailsPageState
    extends State<AssistantConversationDetailsPage> {
  late final _session = widget.store.session(widget.sessionId);
  late final _messages = widget.store.messages(widget.sessionId);
  late final _identity = widget.store.db
      .select(widget.store.db.identityStates)
      .watchSingle();

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: pageAppBar(context, widget.messageId == null ? '会话信息' : '本轮发送内容'),
    body: SafeArea(
      child: StreamBuilder<StoredIdentityState>(
        stream: _identity,
        builder: (context, identity) {
          final lease = widget.store.goals.identityLease;
          if (identity.hasError ||
              (identity.hasData &&
                  (lease == null ||
                      identity.data!.owner != lease.identity.owner ||
                      identity.data!.generation != lease.generation ||
                      identity.data!.targetOwner != null))) {
            return const PageScroll(
              children: [StatusPanel(message: '身份已变化，请返回后重新打开。')],
            );
          }
          if (!identity.hasData) {
            return const Center(child: XyActivity(radius: 11));
          }
          return FutureBuilder(
            future: _session,
            builder: (context, session) {
              if (session.hasError) {
                return const PageScroll(
                  children: [StatusPanel(message: '会话不可用，原记录未被清空。')],
                );
              }
              if (!session.hasData) {
                return const Center(child: XyActivity(radius: 11));
              }
              if (widget.messageId == null) {
                return PageScroll(
                  children: [
                    Text(
                      session.data!.title,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 24),
                    Text(
                      '会话摘要',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 12),
                    SelectableText(session.data!.summary ?? '尚无摘要'),
                    if (session.data!.summaryThrough != null) ...[
                      const SizedBox(height: 12),
                      SelectableText('摘要截至消息：${session.data!.summaryThrough}'),
                    ],
                    const Divider(height: 32),
                    const Text('删除会话不删除长期记忆或已创建目标；删除记忆不删除来源聊天。'),
                  ],
                );
              }
              return FutureBuilder(
                future: _messages,
                builder: (context, messages) {
                  if (messages.hasError) {
                    return const PageScroll(
                      children: [StatusPanel(message: '无法读取发送记录')],
                    );
                  }
                  if (!messages.hasData) {
                    return const Center(child: XyActivity(radius: 11));
                  }
                  final message = messages.data!
                      .where((row) => row.id == widget.messageId)
                      .firstOrNull;
                  final payload = message?.sentPayload;
                  return PageScroll(
                    children: [
                      const Text('本轮交给网络层的请求正文，不含凭证。有记录不代表服务器已收到。'),
                      const SizedBox(height: 16),
                      SelectableText(
                        payload == null
                            ? '本轮尚无发送记录'
                            : const JsonEncoder.withIndent('  ')
                                  .convert(jsonDecode(payload)),
                        key: const ValueKey('assistant-sent-payload'),
                      ),
                    ],
                  );
                },
              );
            },
          );
        },
      ),
    ),
  );
}
