import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

import '../../../data/local/local_goal_repository.dart';
import '../../../shared/local_date.dart';
import '../../assistant/data/assistant_service.dart';
import '../../assistant/data/local_memory_store.dart';
import '../../goals/domain/goal.dart';
import '../data/local_journal_store.dart';

class JournalAiContext {
  JournalAiContext(this.goals, {required this.credentialRevision});
  final LocalGoalRepository goals;
  final int Function() credentialRevision;

  Future<AssistantAccess> authorize() async {
    final memories = LocalMemoryStore(goals);
    final settings = await memories.settings();
    if (settings.consentVersion != assistantConsentVersion ||
        settings.consentedAt == null) {
      throw const AssistantFailure(AssistantFailureKind.consent);
    }
    final revision = credentialRevision();
    if (revision < 0) {
      throw const AssistantFailure(AssistantFailureKind.credential);
    }
    return AssistantAccess(
      consentVersion: assistantConsentVersion,
      isCurrent: () async {
        try {
          return credentialRevision() == revision &&
              await memories.settings() == settings;
        } catch (_) {
          return false;
        }
      },
    );
  }

  Future<PolishNoteRequest> polish(String text) async {
    await goals.requireActiveIdentity();
    return PolishNoteRequest.fromJson({
      'protocol': assistantProtocol,
      'request_id': const Uuid().v4(),
      'text': text,
    });
  }

  Future<GenerateDiaryRequest> diary(LocalDate day) =>
      goals.db.transaction(() async {
        await goals.requireActiveIdentity();
        final today = goals.clock.read().day;
        if (day != today) throw const JournalRuleException('只能用今天的记录生成今天的日记');
        final db = goals.db;
        final all = await goals.loadGoals();
        final overview = TodayOverview(all, day);
        final records =
            await (db.select(db.dayRecords)..where(
                  (row) =>
                      row.owner.equals(goals.owner) &
                      row.day.equals(day.key) &
                      row.savedAt.isNotNull() &
                      row.deletedAt.isNull(),
                ))
                .get();
        final notes =
            await (db.select(db.quickNotes)
                  ..where(
                    (row) =>
                        row.owner.equals(goals.owner) &
                        row.day.equals(day.key) &
                        row.savedAt.isNotNull() &
                        row.deletedAt.isNull(),
                  )
                  ..orderBy([
                    (row) => OrderingTerm.asc(row.createdAt),
                    (row) => OrderingTerm.asc(row.id),
                  ]))
                .get();
        final texts = {for (final row in records) row.goalId: row.content};
        final included = {
          ...overview.pending.map((view) => view.goal.id),
          ...overview.completed.map((view) => view.goal.id),
          ...texts.keys,
        };
        final views = all
            .where((goal) => included.contains(goal.id))
            .map((goal) => goal.dayView(day, today: today));
        final entries = [
          for (final view in views)
            {
              'title': view.title,
              'completed': view.status == GoalDayStatus.completed,
              'text': texts[view.goal.id] ?? '',
            },
        ];
        if (entries.length > 1000 || notes.length > 1000) {
          throw const AssistantFailure(AssistantFailureKind.tooLarge);
        }
        final payload = {
          'protocol': assistantProtocol,
          'request_id': const Uuid().v4(),
          'day': day.key,
          'entries': entries,
          'notes': [for (final row in notes) row.content],
        };
        if (utf8.encode(jsonEncode(payload)).length > diaryRequestBodyLimit) {
          throw const AssistantFailure(AssistantFailureKind.tooLarge);
        }
        return GenerateDiaryRequest.fromJson(payload);
      });
}
