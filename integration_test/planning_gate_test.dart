import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/app/app.dart';
import 'package:habit_checkin/app/providers.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/local/open_database.dart';
import 'package:habit_checkin/features/planning/data/local_planning_store.dart';
import 'package:habit_checkin/features/planning/domain/daily_plan.dart';
import 'package:integration_test/integration_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import '../test/support/legacy_planning/planning_service.dart';
import '../test/support/legacy_planning/planning_providers.dart';
import '../test/support/legacy_planning/daily_planning_page.dart';

class _SyntheticPlanner implements PlanningService {
  @override
  bool get available => true;
  @override
  String get destination => 'TEST 本地替身，不连接真实模型';
  @override
  Future<List<PlanTask>> generate(PlanningRequest request) async {
    return [
      PlanTask(title: 'TEST 阅读十分钟', minutes: 10),
      PlanTask(title: 'TEST 整理桌面', minutes: 5),
    ];
  }
}

class _ObservedPlanner implements PlanningService {
  _ObservedPlanner(this.delegate);
  final PlanningService delegate;
  final requests = <PlanningRequest>[];
  @override
  bool get available => delegate.available;
  @override
  String get destination => delegate.destination;
  @override
  Future<List<PlanTask>> generate(PlanningRequest request) {
    requests.add(request);
    return delegate.generate(request);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  testWidgets('daily planning confirmation and receipt survive iOS processes', (
    tester,
  ) async {
    const phase = String.fromEnvironment('PLANNING_GATE_PHASE');
    const run = String.fromEnvironment('PLANNING_GATE_RUN');
    const live = bool.fromEnvironment('PLANNING_GATE_LIVE');
    expect(
      live,
      isFalse,
      reason: 'Legacy live gateway retired; use the assistant protocol for live verification.',
    );
    const budget = int.fromEnvironment(
      'PLANNING_GATE_BUDGET',
      defaultValue: 30,
    );
    expect(phase, anyOf('write', 'read'));
    expect(RegExp(r'^[A-Za-z0-9-]{1,60}$').hasMatch(run), isTrue);
    expect(budget, inInclusiveRange(5, 240));
    final db = openAppDatabase(name: 'habit_checkin_planning_gate');
    final clock = DeviceClock();
    await clock.refreshZone();
    final goals = LocalGoalRepository(
      db,
      clock,
      owner: live ? 'planning-live-$run' : 'planning-$run',
    );
    final store = LocalPlanningStore(goals);
    final services = ProviderContainer();
    final planner = _ObservedPlanner(
      live ? services.read(planningServiceProvider) : _SyntheticPlanner(),
    );
    Future<void> tap(Finder finder) async {
      await tester.ensureVisible(finder);
      await tester.tap(finder);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }

    try {
      if (phase == 'write') {
        expect(
          planner.available,
          isTrue,
          reason: 'No configured planning service',
        );
        expect(await goals.loadGoals(), isEmpty);
        await store.savePreferences('TEST 喜欢短任务');
      }
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            clockProvider.overrideWithValue(clock),
            refreshClockProvider.overrideWithValue(clock.refreshZone),
            goalRepositoryProvider.overrideWith((ref) => goals),
            planningServiceProvider.overrideWithValue(planner),
          ],
          child: const HabitCheckinApp(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('星愿'), findsOneWidget);
      if (phase == 'write') {
        Navigator.of(
          tester.element(find.byKey(const ValueKey('entry-new-goal'))),
        ).push(
          MaterialPageRoute<void>(builder: (_) => const DailyPlanningPage()),
        );
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('planning-intent')),
          'TEST 今天阅读并整理桌面',
        );
        await tester.enterText(
          find.byKey(const ValueKey('planning-budget')),
          '$budget',
        );
        await tap(find.byKey(const ValueKey('generate-daily-plan')));
        expect(planner.requests, isEmpty);
        await tap(find.text('取消').last);
        expect(planner.requests, isEmpty);
        await tap(find.byKey(const ValueKey('generate-daily-plan')));
        await tap(find.byKey(const ValueKey('confirm-planning-send')));
        expect(planner.requests, hasLength(1));
        final request = planner.requests.single;
        expect(request.intent, 'TEST 今天阅读并整理桌面');
        expect(request.preferences, 'TEST 喜欢短任务');
        expect(request.availableMinutes, budget);
        expect(request.toJson().keys.toSet(), {
          'day',
          'zone',
          'intent',
          'preferences',
          'available_minutes',
        });
        expect(find.text('计划草稿'), findsOneWidget);
        expect(await goals.loadGoals(), isEmpty);
        await tester.enterText(
          find.byKey(const ValueKey('plan-task-title-0')),
          'TEST 真正确认的阅读',
        );
        await tap(find.byKey(const ValueKey('apply-daily-plan')));
      }
      expect(await store.loadPreferences(), 'TEST 喜欢短任务');
      final all = await goals.loadGoals();
      expect(all.length, live ? inInclusiveRange(1, 6) : equals(2));
      expect(
        all.every((goal) => !goal.reminder.enabled && goal.completions.isEmpty),
        isTrue,
      );
      final receipts = await (db.select(
        db.planningDrafts,
      )..where((row) => row.owner.equals(goals.owner))).get();
      expect(receipts, hasLength(1));
      final receipt = receipts.single;
      final confirmed = parsePlanTasks(
        jsonDecode(receipt.tasksJson),
        receipt.budget,
      );
      expect(receipt.budget, budget);
      expect(confirmed, hasLength(all.length));
      expect(confirmed.first.title, 'TEST 真正确认的阅读');
      expect(
        all.map((goal) => goal.titleOn(clock.read().day)).toList(),
        confirmed.map((task) => task.title).toList(),
      );
      expect(
        await store.apply(receipt.id, confirmed),
        all.map((goal) => goal.id).toList(),
      );
      expect(await goals.loadGoals(), hasLength(all.length));
      if (phase == 'read') expect(planner.requests, isEmpty);
      expect(await db.customSelect('PRAGMA foreign_key_check').get(), isEmpty);
      expect(await db.select(db.syncOutbox).get(), isEmpty);
      expect(tester.takeException(), isNull);
      // Print counts only, never credentials, request text, or model output.
      debugPrint(
        'PLANNING_GATE phase=$phase goals=${all.length} budget=$budget '
        'receipt=verified provider=${live ? "live" : "synthetic"} '
        'requests=${planner.requests.length}',
      );
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      services.dispose();
      await db.close();
    }
  });
}
