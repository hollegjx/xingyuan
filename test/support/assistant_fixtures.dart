import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/features/assistant/domain/plan_preview.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

Future<void> seedAssistantReply(
  AppDatabase db, {
  String owner = 'guest',
  String id = 'test',
}) async {
  await db
      .into(db.assistantSessions)
      .insert(
        AssistantSessionsCompanion.insert(
          id: '$id-session',
          owner: owner,
          title: 'TEST session',
          createdAt: 1,
          updatedAt: 1,
        ),
      );
  await db
      .into(db.assistantMessages)
      .insert(
        AssistantMessagesCompanion.insert(
          id: '$id-message',
          owner: owner,
          sessionId: '$id-session',
          role: 'assistant',
          content: 'TEST proposal',
          status: 'sent',
          createdAt: 1,
        ),
      );
}

PlanPreview syntheticPreview({
  String day = '2026-10-09',
  int count = 2,
  bool reminders = false,
  bool habit = false,
}) => PlanPreview([
  for (var i = 0; i < count; i++)
    PreviewItem(
      id: 'item-$i',
      reminder: reminders,
      task: PlanTask.fromJson({
        'title': 'TEST item $i',
        if (habit) 'start_date': day else 'date': day,
        if (habit) 'weekdays': [1, 3, 5],
        'time': i == 0 ? '19:00' : '20:00',
        'minutes': 30,
      }, habit: habit),
    ),
]);
