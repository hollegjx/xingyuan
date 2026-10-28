import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/reminders/notification_permissions.dart';
import '../features/reminders/reminder_status_view.dart';
import '../features/assistant/presentation/assistant_settings_page.dart';
import '../features/analysis/presentation/day_analysis_controls.dart';
import '../shared/presentation.dart';
import 'providers.dart';
import 'theme.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: pageAppBar(context, '设置'),
    body: const SafeArea(child: SettingsContent()),
  );
}

class SettingsContent extends ConsumerWidget {
  const SettingsContent({this.leading = const [], super.key});
  final List<Widget> leading;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final permissions = ref.watch(notificationAccessProvider);
    final xy = context.xy;
    final chevron = Icon(
      CupertinoIcons.chevron_right,
      size: 16,
      color: xy.faint,
    );
    return PageScroll(
      children: [
        ...leading,
        XyGroup(
          header: 'AI',
          margin: const EdgeInsets.only(top: 12),
          children: [
            ListTile(
              leading: const XyIconTile(
                CupertinoIcons.sparkles,
                color: Color(0xFF5856D6),
              ),
              title: const Text('AI 设置'),
              subtitle: const Text('访问凭证、发送范围和记忆'),
              trailing: chevron,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const AssistantSettingsPage(),
                ),
              ),
            ),
            const DayAnalysisSettingsControl(),
          ],
        ),
        XyGroup(
          header: '提醒与通知',
          footer: '仅已预排的提醒会触发。打开 App 时补排，长期不打开可能耗尽。',
          children: [
            ListTile(
              leading: const XyIconTile(
                CupertinoIcons.bell_fill,
                color: Color(0xFFFF3B30),
              ),
              title: const Text('系统通知'),
              subtitle: permissions.when(
                loading: () => const Text('正在读取通知权限'),
                error: (error, stack) => const Text('无法读取通知权限'),
                data: (access) => Text(switch (access) {
                  NotificationAccess.allowed => '系统已允许通知',
                  NotificationAccess.quiet => '系统已允许静默通知',
                  NotificationAccess.alertsOff => '系统已授权，通知提示已关闭',
                  NotificationAccess.off => '尚未授权或已在系统中关闭',
                }),
              ),
            ),
            if (permissions.hasError)
              ListTile(
                title: Text(
                  '重试',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                onTap: () => ref.invalidate(notificationAccessProvider),
              ),
            if (permissions.value == NotificationAccess.off)
              ListTile(
                key: const ValueKey('request-permission'),
                enabled: !permissions.isLoading,
                title: Text(
                  '允许通知',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                onTap: () => ref
                    .read(notificationAccessProvider.notifier)
                    .refresh(request: true),
              ),
            ListTile(
              key: const ValueKey('open-notification-settings'),
              title: const Text('在系统设置中管理'),
              trailing: Icon(
                CupertinoIcons.arrow_up_right_square,
                size: 18,
                color: xy.faint,
              ),
              onTap: () async {
                try {
                  final opened = await ref
                      .read(notificationPermissionsProvider)
                      .openSettings();
                  if (!opened) throw StateError('Settings not opened');
                } catch (_) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('未能打开系统设置，请稍后重试。')),
                    );
                  }
                }
              },
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: ReminderOverview(),
            ),
          ],
        ),
        const XyGroup(
          header: '本地记录',
          footer: '目标与打卡保存在这台设备。当前没有云端同步；卸载 App 可能丢失记录。',
          children: [
            ListTile(
              leading: XyIconTile(
                CupertinoIcons.device_phone_portrait,
                color: Color(0xFF8E8E93),
              ),
              title: Text('保存在本机'),
            ),
          ],
        ),
      ],
    );
  }
}
