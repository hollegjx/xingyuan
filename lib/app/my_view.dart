import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../features/goals/presentation/goal_management_page.dart';
import '../features/journal/domain/journal_entry.dart';
import '../features/journal/presentation/journal_list_page.dart';
import '../shared/presentation.dart';
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
        XyGroup(
          header: '记录',
          footer: '随手记和日记只存在这台手机上。用 AI 润色时只发送这一条；生成日记时发送当天的打卡和随手记文字。照片从不发送。',
          margin: const EdgeInsets.only(top: 8),
          dividerIndent: 60,
          children: [
            destination(
              '目标管理',
              CupertinoIcons.flag,
              Theme.of(context).colorScheme.primary,
              const GoalManagementPage(),
              'my-goals',
            ),
            destination(
              '日记本',
              CupertinoIcons.book,
              Theme.of(context).colorScheme.primary,
              const JournalListPage(kind: JournalKind.diary),
              'my-diary',
            ),
            destination(
              '全部随手记',
              CupertinoIcons.square_pencil,
              Theme.of(context).colorScheme.primary,
              const JournalListPage(kind: JournalKind.quickNote),
              'my-quick-notes',
            ),
          ],
        ),
      ],
    );
  }
}
