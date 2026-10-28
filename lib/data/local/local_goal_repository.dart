import 'package:characters/characters.dart';
import 'package:drift/drift.dart';

import '../../features/goals/domain/goal.dart';
import '../../features/goals/domain/goal_repository.dart';
import '../../features/goals/domain/goal_timing.dart';
import '../../features/companion/data/local_publication_store.dart';
import '../../shared/app_clock.dart';
import '../../shared/local_date.dart';
import '../sync/identity_store.dart';
import '../sync/local_sync_store.dart';
import '../sync/sync_identity.dart';
import '../sync/sync_protocol.dart';
import 'app_database.dart';

class LocalGoalRepository implements GoalRepository {
  LocalGoalRepository(
    this.db,
    this.clock, {
    this.owner = 'guest',
    this.identityLease,
  }) {
    if (owner.isEmpty) throw ArgumentError.value(owner, 'owner');
    if (identityLease != null && identityLease!.identity.owner != owner) {
      throw const StaleIdentity();
    }
  }

  final AppDatabase db;
  final AppClock clock;
  final String owner;
  final IdentityLease? identityLease;
  LocalSyncStore get _sync => LocalSyncStore(db, clock);

  Future<void> requireActiveIdentity() async {
    if (identityLease case final lease?) {
      await IdentityStore(db).require(lease);
    }
  }

  @override
  Future<List<Goal>> loadGoals() => db.transaction(() async {
    await requireActiveIdentity();
    final goals =
        await (db.select(db.goals)
              ..where((row) => row.owner.equals(owner))
              ..orderBy([(row) => OrderingTerm.asc(row.id)]))
            .get();
    return _assemble(goals);
  });

  @override
  Stream<List<Goal>> watchGoals() => db
      .customSelect(
        'SELECT id FROM goals WHERE owner = ?',
        variables: [Variable.withString(owner)],
        readsFrom: {
          db.goals,
          db.goalTitles,
          db.goalSchedules,
          db.checkIns,
          db.goalReminders,
          if (identityLease != null) db.identityStates,
        },
      )
      .watch()
      .asyncMap((_) => loadGoals());

  @override
  Future<int> create(GoalDraft draft) => db.transaction(() async {
    await requireActiveIdentity();
    final now = clock.read();
    final title = _validate(draft, now.day);
    final id = await db
        .into(db.goals)
        .insert(
          GoalsCompanion.insert(
            owner: Value(owner),
            kind: draft.kind.index,
            createdDay: now.day.key,
            createdAt: now.instant.microsecondsSinceEpoch,
          ),
        );
    await db
        .into(db.goalTitles)
        .insert(
          GoalTitlesCompanion.insert(
            goalId: id,
            effectiveDay: now.day.key,
            title: title,
          ),
        );
    await _writeSchedule(id, draft, now.day);
    await db
        .into(db.goalReminders)
        .insert(
          GoalRemindersCompanion.insert(
            goalId: Value(id),
            enabled: Value(draft.reminderEnabled),
            minuteOfDay: Value(draft.reminderMinute),
            needsReconcile: Value(draft.reminderEnabled),
            status: Value(draft.reminderEnabled ? 'pending' : 'disabled'),
          ),
        );
    await _sync.recordMutation(
      id,
      owner: owner,
      kind: SyncOperationKind.create,
    );
    return id;
  });

  @override
  Future<void> edit(int id, GoalDraft draft) => db.transaction(() async {
    await requireActiveIdentity();
    final now = clock.read();
    final goal = await _find(id);
    _requireActive(goal);
    if (goal.kind != draft.kind) {
      throw const GoalRuleException('目标类型创建后不可更改');
    }
    final previousPlan = goal.scheduleOn(now.day).plannedDay;
    final title = _validate(draft, now.day, unchangedPlan: previousPlan);
    if (goal.kind == GoalKind.single &&
        goal.singleCompletion != null &&
        draft.plannedDay != previousPlan) {
      throw const GoalRuleException('已完成任务不可改期，请先在完成当天撤销');
    }

    var changed = false;
    var cloudChanged = false;
    if (title != goal.titleOn(now.day)) {
      await db
          .into(db.goalTitles)
          .insertOnConflictUpdate(
            GoalTitlesCompanion.insert(
              goalId: id,
              effectiveDay: now.day.key,
              title: title,
            ),
          );
      changed = true;
      cloudChanged = true;
    }
    final effectiveDay = goal.kind == GoalKind.habit
        ? now.day.addDays(1)
        : now.day;
    final effective = goal.scheduleOn(effectiveDay);
    if ((goal.kind == GoalKind.habit && effective.weekdays != draft.weekdays) ||
        (goal.kind == GoalKind.single &&
            effective.plannedDay != draft.plannedDay) ||
        effective.startMinute != draft.startMinute ||
        effective.durationMinutes != draft.durationMinutes) {
      await _writeSchedule(id, draft, effectiveDay);
      changed = true;
      cloudChanged = true;
    }
    if (goal.reminder.enabled != draft.reminderEnabled ||
        goal.reminder.minuteOfDay != draft.reminderMinute) {
      changed = true;
    }
    if (changed) {
      await _queueReconcile(
        id,
        enabled: draft.reminderEnabled,
        minuteOfDay: draft.reminderMinute,
      );
    }
    if (cloudChanged) {
      await _sync.recordMutation(
        id,
        owner: owner,
        kind: SyncOperationKind.edit,
      );
    }
  });

  @override
  Future<void> setCompleted(
    int id,
    bool completed, {
    required LocalDate expectedDay,
  }) => db.transaction(() async {
    await requireActiveIdentity();
    final now = clock.read();
    if (now.day != expectedDay) {
      throw const GoalRuleException('日期已经变化，请刷新今天后重试');
    }
    final goal = await _find(id);
    _requireActive(goal);
    final existing = goal.kind == GoalKind.single
        ? goal.singleCompletion
        : goal.completionOn(now.day);
    if (existing != null) {
      if (completed) return;
      if (existing.day != now.day) {
        throw const GoalRuleException('只能撤销今天完成的记录');
      }
    } else if (!completed) {
      return;
    }
    if (!goal.isScheduledOn(now.day)) {
      throw const GoalRuleException('今天不在该目标的计划内');
    }
    final occurrenceKey = goal.kind == GoalKind.single ? 'once' : now.day.key;
    if (completed) {
      await db
          .into(db.checkIns)
          .insertOnConflictUpdate(
            CheckInsCompanion.insert(
              goalId: id,
              goalKind: goal.kind.index,
              occurrenceKey: occurrenceKey,
              completed: true,
              completedDay: now.day.key,
              completedAt: now.instant.microsecondsSinceEpoch,
              zone: now.zone,
              titleSnapshot: goal.titleOn(now.day),
              plannedDay: Value(goal.scheduleOn(now.day).plannedDay?.key),
            ),
          );
    } else {
      await (db.update(db.checkIns)..where(
            (row) =>
                row.goalId.equals(id) & row.occurrenceKey.equals(occurrenceKey),
          ))
          .write(const CheckInsCompanion(completed: Value(false)));
    }
    await _queueReconcile(id);
    await _sync.recordMutation(
      id,
      owner: owner,
      kind: completed
          ? SyncOperationKind.setCompleted
          : SyncOperationKind.setUncompleted,
    );
    await LocalPublicationStore(this)
        .capture(id, now.day.key, completionMutation: true);
  });

  @override
  Future<void> archive(int id) => db.transaction(() async {
    await requireActiveIdentity();
    final now = clock.read();
    final goal = await _find(id);
    if (goal.isArchived) return;
    await (db.update(
      db.goals,
    )..where((row) => row.id.equals(id) & row.owner.equals(owner))).write(
      GoalsCompanion(
        archivedDay: Value(now.day.key),
        archivedAt: Value(now.instant.microsecondsSinceEpoch),
      ),
    );
    await _queueReconcile(id, enabled: false);
    await _sync.recordMutation(
      id,
      owner: owner,
      kind: SyncOperationKind.archive,
    );
  });

  String _validate(
    GoalDraft draft,
    LocalDate today, {
    LocalDate? unchangedPlan,
  }) {
    final title = draft.title.trim();
    if (title.isEmpty || title.characters.length > 60) {
      throw const GoalRuleException('名称需要 1 至 60 个字符');
    }
    if (draft.kind == GoalKind.habit &&
        (draft.weekdays < 1 || draft.weekdays > 127)) {
      throw const GoalRuleException('至少选择一周中的一天');
    }
    if (draft.kind == GoalKind.single) {
      final planned = draft.plannedDay;
      if (planned == null ||
          (planned.isBefore(today) && planned != unchangedPlan)) {
        throw const GoalRuleException('计划日期须为今天或未来');
      }
    }
    if (draft.reminderMinute < 0 || draft.reminderMinute >= 1440) {
      throw const GoalRuleException('提醒时间无效');
    }
    try {
      GoalTiming(
        startMinute: draft.startMinute,
        durationMinutes: draft.durationMinutes,
      );
    } on FormatException catch (error) {
      throw GoalRuleException(error.message);
    }
    return title;
  }

  void _requireActive(Goal goal) {
    if (goal.isArchived) {
      throw const GoalRuleException('已归档目标只可查看');
    }
  }

  Future<void> _writeSchedule(int id, GoalDraft draft, LocalDate day) => db
      .into(db.goalSchedules)
      .insertOnConflictUpdate(
        GoalSchedulesCompanion.insert(
          goalId: id,
          effectiveDay: day.key,
          weekdays: draft.kind == GoalKind.habit ? draft.weekdays : 0,
          startMinute: Value(draft.startMinute),
          durationMinutes: Value(draft.durationMinutes),
          plannedDay: Value(
            draft.kind == GoalKind.single ? draft.plannedDay!.key : null,
          ),
        ),
      );

  Future<void> _queueReconcile(
    int id, {
    bool? enabled,
    int? minuteOfDay,
  }) async {
    final current = await (db.select(
      db.goalReminders,
    )..where((row) => row.goalId.equals(id))).getSingle();
    final nextEnabled = enabled ?? current.enabled;
    final needsReconcile =
        nextEnabled ||
        current.enabled ||
        current.needsReconcile ||
        current.status != 'disabled';
    await (db.update(
      db.goalReminders,
    )..where((row) => row.goalId.equals(id))).write(
      GoalRemindersCompanion(
        enabled: Value(nextEnabled),
        minuteOfDay: Value(minuteOfDay ?? current.minuteOfDay),
        revision: Value(current.revision + 1),
        needsReconcile: Value(needsReconcile),
        status: Value(needsReconcile ? 'pending' : 'disabled'),
      ),
    );
  }

  Future<Goal> _find(int id) async {
    final row =
        await (db.select(db.goals)
              ..where((row) => row.id.equals(id) & row.owner.equals(owner)))
            .getSingleOrNull();
    if (row == null) throw const GoalRuleException('找不到这个目标');
    return (await _assemble([row])).single;
  }

  Future<List<Goal>> _assemble(List<StoredGoal> goals) async {
    if (goals.isEmpty) return const [];
    final ids = goals.map((goal) => goal.id).toList();
    final titles =
        await (db.select(db.goalTitles)
              ..where((row) => row.goalId.isIn(ids))
              ..orderBy([(row) => OrderingTerm.asc(row.effectiveDay)]))
            .get();
    final schedules =
        await (db.select(db.goalSchedules)
              ..where((row) => row.goalId.isIn(ids))
              ..orderBy([(row) => OrderingTerm.asc(row.effectiveDay)]))
            .get();
    final completions =
        await (db.select(db.checkIns)
              ..where((row) => row.goalId.isIn(ids))
              ..orderBy([(row) => OrderingTerm.asc(row.completedDay)]))
            .get();
    final reminders = await (db.select(
      db.goalReminders,
    )..where((row) => row.goalId.isIn(ids))).get();
    return List.unmodifiable(
      goals.map((row) {
        final reminder = reminders.firstWhere(
          (entry) => entry.goalId == row.id,
        );
        return Goal(
          id: row.id,
          kind: GoalKind.values[row.kind],
          createdDay: LocalDate.parse(row.createdDay),
          createdAt: _instant(row.createdAt),
          archivedDay: _date(row.archivedDay),
          archivedAt: row.archivedAt == null ? null : _instant(row.archivedAt!),
          titles: titles
              .where((entry) => entry.goalId == row.id)
              .map(
                (entry) => TitleVersion(
                  LocalDate.parse(entry.effectiveDay),
                  entry.title,
                ),
              )
              .toList(),
          schedules: schedules
              .where((entry) => entry.goalId == row.id)
              .map(
                (entry) => ScheduleVersion(
                  effectiveDay: LocalDate.parse(entry.effectiveDay),
                  weekdays: entry.weekdays,
                  startMinute: entry.startMinute,
                  durationMinutes: entry.durationMinutes,
                  plannedDay: _date(entry.plannedDay),
                ),
              )
              .toList(),
          completions: completions
              .where((entry) => entry.goalId == row.id)
              .map(
                (entry) => Completion(
                  occurrenceKey: entry.occurrenceKey,
                  completed: entry.completed,
                  day: LocalDate.parse(entry.completedDay),
                  instant: _instant(entry.completedAt),
                  zone: entry.zone,
                  title: entry.titleSnapshot,
                  plannedDay: _date(entry.plannedDay),
                ),
              )
              .toList(),
          reminder: ReminderState(
            enabled: reminder.enabled,
            minuteOfDay: reminder.minuteOfDay,
            revision: reminder.revision,
            needsReconcile: reminder.needsReconcile,
            status: reminder.status,
          ),
        );
      }),
    );
  }

  static DateTime _instant(int micros) =>
      DateTime.fromMicrosecondsSinceEpoch(micros, isUtc: true);
  static LocalDate? _date(String? day) =>
      day == null ? null : LocalDate.parse(day);
}
