import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

import '../../../data/local/app_database.dart';
import '../../../data/local/local_goal_repository.dart';
import '../../assistant/data/assistant_service.dart';
import '../../goals/domain/goal.dart';

const dayAnalysisConsentVersion = 1;

class DayAnalysisAttempt {
  const DayAnalysisAttempt(this.row, this.request, this.consentedAt);
  final StoredDayAnalysis row;
  final DayAnalysisRequest request;
  final int consentedAt;
}

class LocalDayAnalysisStore {
  LocalDayAnalysisStore(this.goals);
  final LocalGoalRepository goals;
  AppDatabase get db => goals.db;
  String get owner => goals.owner;
  int get _now => goals.clock.read().instant.microsecondsSinceEpoch;

  Future<StoredDayAnalysisSettings> settings() => db.transaction(() async {
    await goals.requireActiveIdentity();
    return await (db.select(
          db.dayAnalysisSettings,
        )..where((row) => row.owner.equals(owner))).getSingleOrNull() ??
        StoredDayAnalysisSettings(
          owner: owner,
          enabled: true,
          consentVersion: 0,
        );
  });

  Future<void> consent() => db.transaction(() async {
    final current = await settings();
    if (!current.enabled) throw const GoalRuleException('今日分析已关闭');
    await db
        .into(db.dayAnalysisSettings)
        .insertOnConflictUpdate(
          current.copyWith(
            consentVersion: dayAnalysisConsentVersion,
            consentedAt: Value(_now),
          ),
        );
  });

  Future<void> setEnabled(bool enabled) => db.transaction(() async {
    final current = await settings();
    await db
        .into(db.dayAnalysisSettings)
        .insertOnConflictUpdate(
          DayAnalysisSettingsCompanion.insert(
            owner: owner,
            enabled: Value(enabled),
            consentVersion: Value(enabled ? current.consentVersion : 0),
            consentedAt: enabled
                ? Value(current.consentedAt)
                : const Value(null),
          ),
        );
    if (!enabled) await _interrupt('discarded');
  });

  Future<bool> authorized(int consentedAt) async {
    try {
      final current = await settings();
      return current.enabled &&
          current.consentVersion == dayAnalysisConsentVersion &&
          current.consentedAt == consentedAt;
    } catch (_) {
      return false;
    }
  }

  Future<List<StoredDayAnalysis>> list() => db.transaction(() async {
    await goals.requireActiveIdentity();
    return (db.select(db.dayAnalyses)
          ..where((row) => row.owner.equals(owner))
          ..orderBy([
            (row) => OrderingTerm.desc(row.createdAt),
            (row) => OrderingTerm.desc(row.id),
          ]))
        .get();
  });

  Future<StoredDayAnalysis?> _find(String id) =>
      (db.select(db.dayAnalyses)
            ..where((row) => row.owner.equals(owner) & row.id.equals(id)))
          .getSingleOrNull();

  Future<DayAnalysisRequest> preview() => db.transaction(() async {
    await goals.requireActiveIdentity();
    return _snapshot(const Uuid().v4());
  });

  Future<DayAnalysisRequest> _snapshot(String id) async {
    final now = goals.clock.read();
    final all = await goals.loadGoals();
    final today = TodayOverview(all, now.day);
    final records =
        await (db.select(db.dayRecords)..where(
              (row) =>
                  row.owner.equals(owner) &
                  row.day.equals(now.day.key) &
                  row.savedAt.isNotNull() &
                  row.deletedAt.isNull(),
            ))
            .get();
    final texts = {for (final row in records) row.goalId: row.content};
    final included = {
      ...today.pending.map((view) => view.goal.id),
      ...today.completed.map((view) => view.goal.id),
      ...texts.keys,
    };
    final views = all
        .where((goal) => included.contains(goal.id))
        .map((goal) => goal.dayView(now.day, today: now.day))
        .toList();
    return DayAnalysisRequest.fromJson({
      'protocol': assistantProtocol,
      'request_id': id,
      'now': {
        'date': now.day.key,
        'time': formatMinute(now.localTime.hour * 60 + now.localTime.minute),
        'weekday': now.localTime.weekday,
        'time_zone': now.zone,
      },
      'entries': [
        for (var index = 0; index < views.length; index++)
          {
            'id': 'e${index + 1}',
            'title': views[index].title,
            'planned_time': views[index].schedule.startMinute == null
                ? null
                : formatMinute(views[index].schedule.startMinute!),
            'planned_minutes': views[index].schedule.durationMinutes,
            'completed': views[index].status == GoalDayStatus.completed,
            'completed_at': views[index].status == GoalDayStatus.completed
                ? views[index].completion!.instant.toUtc().toIso8601String()
                : null,
            'text': texts[views[index].goal.id] ?? '',
          },
      ],
    });
  }

  Future<DayAnalysisAttempt> begin({String? retryOf}) =>
      db.transaction(() async {
        final current = await settings();
        if (!current.enabled ||
            current.consentVersion != dayAnalysisConsentVersion) {
          throw const AssistantFailure(AssistantFailureKind.consent);
        }
        if (await (db.select(db.dayAnalyses)..where(
                  (row) =>
                      row.owner.equals(owner) & row.status.equals('pending'),
                ))
                .getSingleOrNull() !=
            null) {
          throw const AssistantFailure(AssistantFailureKind.busy);
        }
        final id = const Uuid().v4();
        final DayAnalysisRequest request;
        if (retryOf == null) {
          request = await _snapshot(id);
        } else {
          final original = await _find(retryOf);
          if (original == null ||
              !['failed', 'cancelled'].contains(original.status)) {
            throw const GoalRuleException('这次分析不可重试');
          }
          if (original.day != goals.clock.read().day.key) {
            throw const GoalRuleException('日期已变化，请重新分析今天');
          }
          request = DayAnalysisRequest.fromJson({
            ...jsonDecode(original.requestJson) as Map<String, dynamic>,
            'request_id': id,
          });
        }
        final row = StoredDayAnalysis(
          id: id,
          owner: owner,
          day: request.now.date.key,
          zone: request.now.timeZone,
          requestJson: jsonEncode(request.toJson()),
          status: 'pending',
          createdAt: _now,
          updatedAt: _now,
        );
        await db.into(db.dayAnalyses).insert(row);
        return DayAnalysisAttempt(row, request, current.consentedAt!);
      });

  Future<bool> finish(
    DayAnalysisAttempt attempt,
    DayAnalysisResponse response,
  ) => db.transaction(() async {
    await goals.requireActiveIdentity();
    final row = await _find(attempt.row.id);
    if (row == null ||
        row.status != 'pending' ||
        !await authorized(attempt.consentedAt)) {
      return false;
    }
    final valid = DayAnalysisResponse.fromJson(
      response.toJson(),
      request: attempt.request,
    );
    await (db.update(db.dayAnalyses)..where(
          (entry) => entry.id.equals(row.id) & entry.owner.equals(owner),
        ))
        .write(
          DayAnalysesCompanion(
            status: const Value('succeeded'),
            responseJson: Value(jsonEncode(valid.toJson())),
            updatedAt: Value(_now),
          ),
        );
    return true;
  });

  Future<void> fail(String id, String code, {bool cancelled = false}) =>
      db.transaction(() async {
        await goals.requireActiveIdentity();
        await (db.update(db.dayAnalyses)..where(
              (row) =>
                  row.id.equals(id) &
                  row.owner.equals(owner) &
                  row.status.equals('pending'),
            ))
            .write(
              DayAnalysesCompanion(
                status: Value(cancelled ? 'cancelled' : 'failed'),
                failureCode: Value(code),
                updatedAt: Value(_now),
              ),
            );
      });

  Future<void> _interrupt(String code) =>
      (db.update(db.dayAnalyses)..where(
            (row) => row.owner.equals(owner) & row.status.equals('pending'),
          ))
          .write(
            DayAnalysesCompanion(
              status: const Value('cancelled'),
              failureCode: Value(code),
              updatedAt: Value(_now),
            ),
          )
          .then((_) {});

  Future<void> recoverInterrupted() => db.transaction(() async {
    await goals.requireActiveIdentity();
    await _interrupt('interrupted');
  });

  Future<void> remove(String id) => db.transaction(() async {
    await goals.requireActiveIdentity();
    await (db.delete(
      db.dayAnalyses,
    )..where((row) => row.id.equals(id) & row.owner.equals(owner))).go();
  });
}
