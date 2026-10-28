import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../../../shared/local_date.dart';

/// Accent for 随手记, matching its entry bubble on 今天.
Color journalNoteTint(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? const Color(0xFFFF6B8E)
    : const Color(0xFFF2557D);

/// "10月23日"; earlier years keep the year: "2025年10月23日".
String journalDayLabel(LocalDate day, {LocalDate? today}) {
  final now = today ?? LocalDate.fromDateTime(DateTime.now());
  return day.year == now.year
      ? '${day.month}月${day.day}日'
      : '${day.year}年${day.month}月${day.day}日';
}

/// Small amber "草稿" tag.
class JournalDraftBadge extends StatelessWidget {
  const JournalDraftBadge({super.key});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(
      color: context.xy.warningSoft,
      borderRadius: BorderRadius.circular(5),
    ),
    child: Text(
      '草稿',
      style: Theme.of(context).textTheme.labelSmall
          ?.copyWith(color: context.xy.warning, fontWeight: FontWeight.w600),
    ),
  );
}
