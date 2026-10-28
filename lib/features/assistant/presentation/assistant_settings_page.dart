import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/local/app_database.dart';
import '../../../data/sync/identity_store.dart';
import '../../../shared/presentation.dart';
import '../assistant_providers.dart';
import '../data/assistant_service.dart';
import '../data/device_credential_store.dart';
import 'assistant_consent_page.dart';
import 'assistant_identity_boundary.dart';
import 'assistant_memory_page.dart';

class AssistantSettingsPage extends ConsumerStatefulWidget {
  const AssistantSettingsPage({super.key});
  @override
  ConsumerState<AssistantSettingsPage> createState() =>
      _AssistantSettingsPageState();
}

class _AssistantSettingsPageState extends ConsumerState<AssistantSettingsPage> {
  late final _store = ref.read(assistantStoreProvider.future);
  final _credential = TextEditingController();
  String _credentialState = '正在读取凭证状态';
  String? _connection;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _readCredential();
  }

  @override
  void dispose() {
    _credential.dispose();
    super.dispose();
  }

  Future<void> _readCredential() async {
    try {
      final value = await ref.read(assistantCredentialProvider).read();
      if (mounted) {
        setState(
          () => _credentialState = value == null ? '未录入凭证' : '凭证已保存在本机钥匙串',
        );
      }
    } catch (_) {
      if (mounted) setState(() => _credentialState = '无法读取凭证，请解锁设备后重试');
    }
  }

  Future<void> _operate(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await (await _store).goals.requireActiveIdentity();
      await action();
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = switch (error) {
            AssistantFailure() => error.message,
            DeviceCredentialFailure() => error.message,
            _ => '未能保存，原有记录未被清空。请重试。',
          },
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _health(StoredAssistantSettings settings) => _operate(() async {
    final store = await _store;
    final lease = await IdentityStore(store.db).active();
    await ref
        .read(assistantServiceProvider)
        .health(
          access: AssistantAccess(
            consentVersion: settings.consentVersion,
            isCurrent: () async {
              if (!mounted) return false;
              try {
                await IdentityStore(store.db).require(lease);
                return await store.memories.settings() == settings;
              } on StaleIdentity {
                return false;
              }
            },
          ),
        );
    if (mounted) setState(() => _connection = '服务可达，访问凭证尚未通过模型请求验证');
  });

  Future<void> _update({
    bool? memories,
    bool? schedule,
    bool? stats,
    bool? automatic,
    bool? agent,
  }) => _operate(() async {
    final store = await _store;
    await store.memories.updateSettings(
      sendMemories: memories,
      sendSchedule: schedule,
      sendStats: stats,
      autoMemory: automatic,
      agentEnabled: agent,
    );
    ref.invalidate(assistantSettingsProvider);
  });

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(assistantSettingsProvider);
    final configured = ref.watch(assistantServiceProvider).configured;
    return AssistantIdentityBoundary(
      store: _store,
      child: Scaffold(
        appBar: pageAppBar(context, 'AI'),
        body: SafeArea(
          child: settings.when(
            loading: () => const PageScroll(
              children: [StatusPanel(message: '正在读取 AI 设置', loading: true)],
            ),
            error: (error, stack) => PageScroll(
              children: [
                StatusPanel(
                  message: '无法读取 AI 设置',
                  retry: () => ref.invalidate(assistantSettingsProvider),
                ),
              ],
            ),
            data: (value) => PageScroll(
              children: [
                XyGroup(
                  header: '服务状态',
                  margin: const EdgeInsets.only(top: 12),
                  children: [
                    XyValueRow(
                      label: Text(
                        configured
                            ? _connection ?? '尚未检查连接'
                            : '未连接：此构建没有配置 AI 服务',
                      ),
                      value: OutlinedButton(
                        key: const ValueKey('assistant-health'),
                        onPressed:
                            _busy ||
                                !configured ||
                                value.consentVersion != assistantConsentVersion
                            ? null
                            : () => _health(value),
                        child: const Text('检查连接'),
                      ),
                    ),
                  ],
                ),
                XyGroup(
                  header: '设备凭证',
                  footer: _credentialState,
                  children: [
                    TextField(
                      key: const ValueKey('assistant-credential'),
                      controller: _credential,
                      obscureText: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      enabled: !_busy,
                      decoration: const InputDecoration(hintText: '输入新凭证'),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                      child: Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              key: const ValueKey('assistant-save-credential'),
                              onPressed: _busy
                                  ? null
                                  : () => _operate(() async {
                                      final credentials = ref.read(
                                        assistantCredentialProvider,
                                      );
                                      final input =
                                          DeviceCredentialStore.validate(
                                            _credential.text,
                                          );
                                      await ref
                                          .read(
                                            assistantCredentialRevisionProvider
                                                .notifier,
                                          )
                                          .change(
                                            () => credentials.save(input),
                                          );
                                      if (!mounted) return;
                                      _credential.clear();
                                      ref.invalidate(
                                        assistantCredentialReadyProvider,
                                      );
                                      await _readCredential();
                                    }),
                              child: const Text('保存'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: OutlinedButton(
                              key: const ValueKey('assistant-clear-credential'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Theme.of(context)
                                    .colorScheme
                                    .error,
                                backgroundColor: Theme.of(context)
                                    .colorScheme
                                    .error
                                    .withValues(alpha: 0.10),
                              ),
                              onPressed: _busy
                                  ? null
                                  : () => _operate(() async {
                                      final credentials = ref.read(
                                        assistantCredentialProvider,
                                      );
                                      await ref
                                          .read(
                                            assistantCredentialRevisionProvider
                                                .notifier,
                                          )
                                          .change(credentials.clear);
                                      if (!mounted) return;
                                      _credential.clear();
                                      ref.invalidate(
                                        assistantCredentialReadyProvider,
                                      );
                                      await _readCredential();
                                    }),
                              child: const Text('清除'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  NoticeBanner(tone: NoticeTone.error, message: _error!),
                ],
                XyGroup(
                  header: '规划',
                  children: [
                    SwitchListTile.adaptive(
                      key: const ValueKey('assistant-agent-enabled'),
                      title: const Text('智能规划（Agent）'),
                      value: value.agentEnabled,
                      onChanged: _busy ? null : (next) => _update(agent: next),
                    ),
                  ],
                ),
                XyGroup(
                  header: '发送范围',
                  children: [
                    SwitchListTile.adaptive(
                      key: const ValueKey('assistant-enabled'),
                      title: const Text('规划与日记 AI'),
                      value:
                          value.consentVersion == assistantConsentVersion &&
                          value.consentedAt != null,
                      onChanged: _busy
                          ? null
                          : (enabled) async {
                              if (enabled) {
                                await Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                    builder: (_) =>
                                        const AssistantConsentPage(),
                                  ),
                                );
                              } else {
                                await _operate(() async {
                                  await (await _store).memories.revokeConsent();
                                  ref.invalidate(assistantSettingsProvider);
                                });
                              }
                            },
                    ),
                    XyValueRow(
                      label: Text(
                        value.consentVersion == assistantConsentVersion
                            ? '已确认当前版本的数据授权'
                            : '尚未确认，不会发送请求',
                      ),
                      value: TextButton(
                        onPressed: _busy
                            ? null
                            : () => Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => const AssistantConsentPage(),
                                ),
                              ),
                        child: const Text('查看授权'),
                      ),
                    ),
                    SwitchListTile.adaptive(
                      title: const Text('发送记忆'),
                      value: value.sendMemories,
                      onChanged: _busy
                          ? null
                          : (next) => _update(memories: next),
                    ),
                    SwitchListTile.adaptive(
                      title: const Text('发送已有安排'),
                      value: value.sendSchedule,
                      onChanged: _busy
                          ? null
                          : (next) => _update(schedule: next),
                    ),
                    SwitchListTile.adaptive(
                      title: const Text('发送完成情况'),
                      value: value.sendStats,
                      onChanged: _busy ? null : (next) => _update(stats: next),
                    ),
                  ],
                ),
                XyGroup(
                  header: '记忆',
                  children: [
                    SwitchListTile.adaptive(
                      title: const Text('自动记忆'),
                      value: value.autoMemory,
                      onChanged: _busy
                          ? null
                          : (next) => _update(automatic: next),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: OutlinedButton(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const AssistantMemoryPage(),
                          ),
                        ),
                        child: const Text('管理记忆'),
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
}
