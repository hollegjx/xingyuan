import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../features/goals/presentation/goal_management_page.dart';
import '../features/journal/domain/journal_entry.dart';
import '../features/journal/presentation/journal_list_page.dart';
import '../features/journal/presentation/journal_style.dart';
import '../shared/presentation.dart';
import '../shared/ui/sparkle.dart';
import 'settings_page.dart';
import 'theme.dart';

/// 我的: the user's own places first, then everything from 设置.
class MyView extends StatelessWidget {
  const MyView({super.key});

  @override
  Widget build(BuildContext context) {
    final xy = context.xy;
    Widget destination(
      String label,
      IconData icon,
      Color tint,
      Widget page,
      String key,
    ) => ListTile(
      key: ValueKey(key),
      leading: XyIconTile(icon, color: tint),
      title: Text(label),
      trailing: Icon(CupertinoIcons.chevron_right, size: 16, color: xy.faint),
      onTap: () =>
          Navigator.of(context)
              .push(MaterialPageRoute<void>(builder: (_) => page)),
    );
    return SettingsContent(
      leading: [
        const TabHeader(title: '我的', padding: EdgeInsets.fromLTRB(4, 0, 0, 10)),
        const _JournalPrivacy(),
        XyGroup(
          margin: const EdgeInsets.only(top: 20),
          dividerIndent: 60,
          children: [
            destination(
              '目标管理',
              CupertinoIcons.flag_fill,
              Theme.of(context).brightness == Brightness.dark
                  ? const Color(0xFF63E6E2)
                  : const Color(0xFF00A8A0),
              const GoalManagementPage(),
              'my-goals',
            ),
            destination(
              '日记本',
              CupertinoIcons.book_fill,
              Theme.of(context).colorScheme.primary,
              const JournalListPage(kind: JournalKind.diary),
              'my-diary',
            ),
            destination(
              '全部随手记',
              CupertinoIcons.square_pencil_fill,
              journalNoteTint(context),
              const JournalListPage(kind: JournalKind.quickNote),
              'my-quick-notes',
            ),
          ],
        ),
      ],
    );
  }
}

class _JournalPrivacy extends StatelessWidget {
  const _JournalPrivacy();

  @override
  Widget build(BuildContext context) {
    final xy = context.xy;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      child: Row(
        children: [
          const SizedBox(
            width: 52,
            height: 52,
            child: Center(child: StarMark(lit: true, size: 26)),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '我的星愿',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '随手记和日记默认仅存本机。主动使用 AI 时，润色发送本条文字；生成日记发送当天打卡和随手记文字。不发送照片。',
                  style: theme.textTheme.bodySmall?.copyWith(color: xy.muted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
