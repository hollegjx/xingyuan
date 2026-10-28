import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/sync/identity_store.dart';
import 'package:habit_checkin/features/assistant/data/local_memory_store.dart';
import 'package:habit_checkin/features/assistant/data/local_proposal_store.dart';
import 'package:habit_checkin/features/assistant/domain/agent_run_metadata.dart';
import 'package:habit_checkin/features/assistant/domain/plan_preview.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:xingyuan_core/xingyuan_core.dart';

import 'support/assistant_fixtures.dart';
import 'support/sync_fixtures.dart';
import 'support/test_clock.dart';

class GuardedAgentRepository extends LocalGoalRepository {
  GuardedAgentRepository(
    super.db,
    super.clock, {
    super.owner,
    super.identityLease,
  });
  int reads = 0;
  bool failRead = false;
  Future<void> Function()? afterCreate;
  @override
  Future<List<Goal>> loadGoals() {
    reads++;
    if (failRead) throw StateError('TEST schedule read failure');
    return super.loadGoals();
  }

  @override
  Future<int> create(GoalDraft draft) async {
    final id = await super.create(draft);
    await afterCreate?.call();
    return id;
  }
}

void main() {
  setUpAll(tzdata.initializeTimeZones);
  late AppDatabase db;
  late TestClock clock;
  late GuardedAgentRepository goals;
  late LocalProposalStore store;
  late LocalMemoryStore memories;
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    clock = TestClock();
    final identities = IdentityStore(db);
    await identities.finish(await identities.begin(accountA));
    goals = GuardedAgentRepository(
      db,
      clock,
      owner: accountA.owner,
      identityLease: await identities.active(),
    );
    store = LocalProposalStore(goals);
    memories = LocalMemoryStore(goals);
    await memories.consent();
    await seedAssistantReply(db, owner: accountA.owner);
  });
  tearDown(() => db.close());
  PlanPreview plan({int count = 1, int day = 0}) => PlanPreview.fromAgentItems([
    for (var i = 0; i < count; i++)
      {
        'title': 'TEST item $i',
        'date': clock.day.addDays(day).key,
        'start_minute': 600 + i * 60,
        'minutes': 30,
      },
  ]);
  Future<String> save(PlanPreview preview) => store.saveDraft(
    sessionId: 'test-session',
    messageId: 'test-message',
    preview: preview,
    agentMetadata: AgentRunMetadata(date: CalendarDate.parse(clock.day.key)),
  );
  Future<String> token(String id, PlanPreview preview) async =>
      (await store.inspectAgent(id, preview))!.token;
  Future<void> unchanged(String id) async {
    for (final table in [
      'goals',
      'goal_titles',
      'goal_schedules',
      'goal_reminders',
      'sync_states',
      'sync_outbox',
    ]) {
      expect(
        await db.customSelect('SELECT * FROM $table').get(),
        isEmpty,
        reason: table,
      );
    }
    final row = await store.read(id);
    expect(row.status, 'draft');
    expect(row.appliedGoalIdsJson, isNull);
  }

  test(
    'concurrent confirms and a later-day repeat return exactly one receipt',
    () async {
      final preview = plan(count: 2);
      final id = await save(preview);
      final checked = await token(id, preview);
      final results = await Future.wait(
        List.generate(
          6,
          (_) => store.apply(id, preview, expectedAgentValidation: checked),
        ),
      );
      expect(
        results.every((ids) => ids.join(',') == results.first.join(',')),
        isTrue,
      );
      expect(await goals.loadGoals(), hasLength(2));
      expect(await db.select(db.syncOutbox).get(), hasLength(2));
      clock.setDay(2026, 10, 10);
      await memories.revokeConsent();
      expect(
        await store.apply(id, preview, expectedAgentValidation: checked),
        results.first,
      );
      expect(await db.select(db.syncOutbox).get(), hasLength(2));
    },
  );
  test('another editor changing the draft cannot be overwritten by a stale confirmation', () async {
    final preview = plan();
    final id = await save(preview);
    final checked = await token(id, preview);
    final edited = preview.replace(
      preview.items.single.id,
      PlanTask.fromJson({
        'title': 'TEST user edit',
        'date': clock.day.key,
        'time': '11:00',
        'minutes': 30,
      }, habit: false),
    );
    await store.editDraft(id, edited);
    await expectLater(
      store.apply(id, preview, expectedAgentValidation: checked),
      throwsA(isA<AgentPlanChanged>()),
    );
    await unchanged(id);
    expect((await store.read(id)).itemsJson, edited.encode());
  });
  test(
    'unrelated day unknown records do not invalidate the reviewed partial day',
    () async {
      await goals.create(
        GoalDraft(
          title: 'TEST unknown today',
          kind: GoalKind.single,
          plannedDay: clock.day,
        ),
      );
      final preview = plan();
      final id = await save(preview);
      final checked = await token(id, preview);
      await goals.create(
        GoalDraft(
          title: 'TEST unknown other day',
          kind: GoalKind.single,
          plannedDay: clock.day.addDays(1),
        ),
      );
      expect(await token(id, preview), checked);
      expect(
        await store.apply(
          id,
          preview,
          expectedAgentValidation: checked,
          partialAcknowledged: true,
        ),
        hasLength(1),
      );
    },
  );
  test(
    'future-day draft remains valid after midnight when no constraints changed',
    () async {
      final preview = plan(day: 1);
      final id = await save(preview);
      final checked = await token(id, preview);
      clock.setDay(2026, 10, 10);
      expect(
        await store.apply(id, preview, expectedAgentValidation: checked),
        hasLength(1),
      );
    },
  );
  test('second write fault rolls back the batch and a fresh retry creates only once', () async {
    final preview = plan(count: 2);
    final id = await save(preview);
    final checked = await token(id, preview);
    await db.customStatement(
      "CREATE TRIGGER fail_second BEFORE INSERT ON goal_titles WHEN new.title = 'TEST item 1' BEGIN SELECT RAISE(ABORT, 'TEST fault'); END",
    );
    await expectLater(
      store.apply(id, preview, expectedAgentValidation: checked),
      throwsException,
    );
    await unchanged(id);
    await db.customStatement('DROP TRIGGER fail_second');
    expect(
      await store.apply(
        id,
        preview,
        expectedAgentValidation: await token(id, preview),
      ),
      hasLength(2),
    );
    expect(await db.select(db.syncOutbox).get(), hasLength(2));
  });
  for (final fault in ['midnight', 'consent']) {
    test(
      '$fault after first write rolls back the complete transaction',
      () async {
        final preview = plan();
        final id = await save(preview);
        final checked = await token(id, preview);
        goals.afterCreate = () async {
          if (fault == 'midnight') {
            clock.setDay(2026, 10, 10);
          } else {
            await memories.revokeConsent();
          }
        };
        await expectLater(
          store.apply(id, preview, expectedAgentValidation: checked),
          throwsA(isA<GoalRuleException>()),
        );
        await unchanged(id);
      },
    );
  }
  test(
    'failed requery creates nothing; retry requires a successful fresh check',
    () async {
      final preview = plan();
      final id = await save(preview);
      final checked = await token(id, preview);
      goals.failRead = true;
      await expectLater(
        store.apply(id, preview, expectedAgentValidation: checked),
        throwsStateError,
      );
      await unchanged(id);
      goals.failRead = false;
      expect(
        await store.apply(
          id,
          preview,
          expectedAgentValidation: await token(id, preview),
        ),
        hasLength(1),
      );
    },
  );
  test('denied grant is checked before confirmation schedule reads', () async {
    final preview = plan();
    final id = await save(preview);
    final checked = await token(id, preview);
    await memories.updateSettings(sendSchedule: false);
    final reads = goals.reads;
    await expectLater(
      store.apply(id, preview, expectedAgentValidation: checked),
      throwsA(isA<GoalRuleException>()),
    );
    expect(goals.reads, reads);
    await unchanged(id);
  });
}
