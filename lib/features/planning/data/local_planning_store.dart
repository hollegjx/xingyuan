import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../data/local/app_database.dart';
import '../../../data/local/local_goal_repository.dart';
import '../../../shared/local_date.dart';
import '../../goals/domain/goal.dart';
import '../domain/daily_plan.dart';

class LocalPlanningStore {
  LocalPlanningStore(this.goals);
  final LocalGoalRepository goals;
  AppDatabase get db => goals.db;

  Future<String> loadPreferences() => db.transaction(() async {
    await goals.requireActiveIdentity();
    final row = await (db.select(
      db.planningProfiles,
    )..where((row) => row.owner.equals(goals.owner))).getSingleOrNull();
    return row?.preferences ?? '';
  });

  Future<void> savePreferences(String value) => db.transaction(() async {
    await goals.requireActiveIdentity();
    final text = planningText(value, max: 500, empty: true);
    await db
        .into(db.planningProfiles)
        .insertOnConflictUpdate(
          PlanningProfilesCompanion.insert(
            owner: goals.owner,
            preferences: text,
            updatedAt: goals.clock.read().instant.microsecondsSinceEpoch,
          ),
        );
  });

  Future<DailyPlan?> latestDraft() => db.transaction(() async {
    await goals.requireActiveIdentity();
    final row =
        await (db.select(db.planningDrafts)
              ..where(
                (row) =>
                    row.owner.equals(goals.owner) &
                    row.day.equals(goals.clock.read().day.key) &
                    row.appliedGoalIdsJson.isNull(),
              )
              ..orderBy([(row) => OrderingTerm.desc(row.createdAt)])
              ..limit(1))
            .getSingleOrNull();
    return row == null ? null : _decode(row);
  });

  Future<DailyPlan> saveDraft(PlanningRequest request, List<PlanTask> tasks) =>
      db.transaction(() async {
        await goals.requireActiveIdentity();
        final now = goals.clock.read();
        if (now.day != request.day) {
          throw const PlanningException('日期已经变化，请为今天重新生成计划。');
        }
        final plan = DailyPlan(
          id: const Uuid().v4(),
          day: request.day,
          budget: request.availableMinutes,
          tasks: tasks,
        );
        await db
            .into(db.planningDrafts)
            .insert(
              PlanningDraftsCompanion.insert(
                id: plan.id,
                owner: goals.owner,
                day: plan.day.key,
                budget: plan.budget,
                tasksJson: encodePlanTasks(plan.tasks),
                createdAt: now.instant.microsecondsSinceEpoch,
              ),
            );
        return plan;
      });

  Future<List<int>> apply(
    String id,
    List<PlanTask> confirmedTasks,
  ) => db.transaction(() async {
    await goals.requireActiveIdentity();
    final row =
        await (db.select(db.planningDrafts)..where(
              (row) => row.id.equals(id) & row.owner.equals(goals.owner),
            ))
            .getSingleOrNull();
    if (row == null) throw const PlanningException('找不到当前身份的计划草稿。');
    final tasks = validatePlanTasks(confirmedTasks, row.budget);
    final encoded = encodePlanTasks(tasks);
    // The receipt and all goals/outbox writes commit together. Retrying the
    // exact confirmed snapshot returns the original IDs, even after restart.
    if (row.appliedGoalIdsJson != null) {
      if (row.tasksJson != encoded) {
        throw const PlanningException('这份计划已创建，请返回今天查看。');
      }
      return List<int>.from(jsonDecode(row.appliedGoalIdsJson!) as List);
    }
    if (row.day != goals.clock.read().day.key) {
      throw const PlanningException('日期已经变化，请为今天重新生成计划。');
    }
    final ids = <int>[];
    for (final task in tasks) {
      ids.add(
        await goals.create(
          GoalDraft(
            title: task.title,
            kind: GoalKind.single,
            plannedDay: LocalDate.parse(row.day),
          ),
        ),
      );
    }
    if (row.day != goals.clock.read().day.key) {
      throw const PlanningException('日期已经变化，未创建目标，请重新规划。');
    }
    await (db.update(
      db.planningDrafts,
    )..where((entry) => entry.id.equals(id))).write(
      PlanningDraftsCompanion(
        tasksJson: Value(encoded),
        appliedGoalIdsJson: Value(jsonEncode(ids)),
      ),
    );
    return ids;
  });

  DailyPlan _decode(StoredPlanningDraft row) => DailyPlan(
    id: row.id,
    day: LocalDate.parse(row.day),
    budget: row.budget,
    tasks: parsePlanTasks(jsonDecode(row.tasksJson), row.budget),
    appliedGoalIds: row.appliedGoalIdsJson == null
        ? null
        : List<int>.from(jsonDecode(row.appliedGoalIdsJson!) as List),
  );
}
