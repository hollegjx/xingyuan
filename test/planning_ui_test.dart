import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/app/providers.dart';
import 'package:habit_checkin/features/planning/data/local_planning_store.dart';
import 'package:habit_checkin/features/planning/domain/daily_plan.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'support/ui_harness.dart';
import 'support/legacy_planning/planning_service.dart';
import 'support/legacy_planning/daily_planning_page.dart';

class FakePlanner implements PlanningService {
  final requests = <PlanningRequest>[];
  Future<List<PlanTask>> Function()? onGenerate;
  @override
  bool get available => true;
  @override
  String get destination => 'TEST 模型服务';
  @override
  Future<List<PlanTask>> generate(PlanningRequest request) async {
    requests.add(request);
    return onGenerate?.call() ?? [PlanTask(title: 'TEST 阅读一章', minutes: 20)];
  }
}

Future<void> openLegacyPlanning(WidgetTester tester) async {
  Navigator.of(tester.element(find.byKey(const ValueKey('entry-new-goal'))))
      .push(MaterialPageRoute<void>(builder: (_) => const DailyPlanningPage()));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(tzdata.initializeTimeZones);

  testUiWidgets(
    'small-screen large-text preview remains editable and enforces budget',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final app = UiHarness();
      await LocalPlanningStore(app.repository).saveDraft(
        PlanningRequest(
          day: app.clock.day,
          zone: 'Asia/Shanghai',
          intent: 'TEST',
          preferences: '',
          availableMinutes: 30,
        ),
        [PlanTask(title: 'TEST 长名称目标' * 5, minutes: 20)],
      );
      await app.mount(tester);
      await openLegacyPlanning(tester);
      await tester.enterText(
        find.byKey(const ValueKey('plan-task-minutes-0')),
        '40',
      );
      await tapVisible(tester, find.byKey(const ValueKey('apply-daily-plan')));
      expect(await app.repository.loadGoals(), isEmpty);
      expect(find.text('预计总时长超过可用时间，请调整后再确认。'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('plan-task-minutes-0')),
        '20',
      );
      await tapVisible(tester, find.byKey(const ValueKey('apply-daily-plan')));
      expect(await app.repository.loadGoals(), hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testUiWidgets(
    'unconfigured planner is honest and does not affect manual goals',
    (tester) async {
      final app = UiHarness();
      await app.mount(tester);
      expect(find.byKey(const ValueKey('entry-new-goal')), findsOneWidget);
      await openLegacyPlanning(tester);
      expect(find.text('AI 服务尚未连接'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('generate-daily-plan')),
            )
            .onPressed,
        isNull,
      );
      expect(await app.repository.loadGoals(), isEmpty);
      await goBack(tester);
      expect(find.byKey(const ValueKey('entry-new-goal')), findsOneWidget);
    },
  );

  testUiWidgets(
    'no transmission before consent; preview can be edited before atomic creation',
    (tester) async {
      final app = UiHarness();
      final planner = FakePlanner();
      final store = LocalPlanningStore(app.repository);
      await store.savePreferences('TEST 喜欢短任务');
      await app.mount(tester, planningService: planner);
      await openLegacyPlanning(tester);
      await tester.enterText(
        find.byKey(const ValueKey('planning-intent')),
        'TEST 想阅读',
      );
      await tapVisible(
        tester,
        find.byKey(const ValueKey('generate-daily-plan')),
      );
      expect(planner.requests, isEmpty);
      expect(find.textContaining('TEST 模型服务'), findsOneWidget);
      expect(find.textContaining('TEST 喜欢短任务'), findsOneWidget);
      await tapVisible(tester, find.text('取消').last);
      expect(planner.requests, isEmpty);
      await tapVisible(
        tester,
        find.byKey(const ValueKey('generate-daily-plan')),
      );
      await tapVisible(
        tester,
        find.byKey(const ValueKey('confirm-planning-send')),
      );
      expect(planner.requests, hasLength(1));
      expect(planner.requests.single.preferences, 'TEST 喜欢短任务');
      expect(find.text('计划草稿'), findsOneWidget);
      expect(await app.repository.loadGoals(), isEmpty);
      await tester.enterText(
        find.byKey(const ValueKey('plan-task-title-0')),
        'TEST 用户确认的阅读',
      );
      await tapVisible(tester, find.byKey(const ValueKey('apply-daily-plan')));
      final goals = await app.repository.loadGoals();
      expect(goals.single.titleOn(app.clock.day), 'TEST 用户确认的阅读');
      expect(goals.single.reminder.enabled, isFalse);
      expect(app.permissions.requests, 0);
      expect(find.byKey(const ValueKey('entry-new-goal')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testUiWidgets(
    'midnight rejects a stale preview and regenerating unmounts fields cleanly',
    (tester) async {
      final app = UiHarness();
      final store = LocalPlanningStore(app.repository);
      await store.saveDraft(
        PlanningRequest(
          day: app.clock.day,
          zone: 'Asia/Shanghai',
          intent: 'TEST',
          preferences: '',
          availableMinutes: 30,
        ),
        [PlanTask(title: 'TEST 草稿', minutes: 10)],
      );
      await app.mount(tester, planningService: FakePlanner());
      await openLegacyPlanning(tester);
      app.clock.setDay(2026, 10, 10);
      await app.container.read(environmentProvider.notifier).refresh();
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('apply-daily-plan')),
            )
            .onPressed,
        isNull,
      );
      await tapVisible(tester, find.text('重新规划'));
      expect(find.byKey(const ValueKey('planning-intent')), findsOneWidget);
      expect(await app.repository.loadGoals(), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testUiWidgets('cancelled wait never persists a late model response', (
    tester,
  ) async {
    final app = UiHarness();
    final completer = Completer<List<PlanTask>>();
    final planner = FakePlanner()..onGenerate = () => completer.future;
    await app.mount(tester, planningService: planner);
    await openLegacyPlanning(tester);
    await tester.enterText(
      find.byKey(const ValueKey('planning-intent')),
      'TEST 取消',
    );
    await tapVisible(tester, find.byKey(const ValueKey('generate-daily-plan')));
    await tester.tap(find.byKey(const ValueKey('confirm-planning-send')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.ensureVisible(find.text('取消等待'));
    await tester.tap(find.text('取消等待'));
    await tester.pumpAndSettle();
    completer.complete([PlanTask(title: 'TEST 不应保存', minutes: 5)]);
    await tester.pumpAndSettle();
    expect(await LocalPlanningStore(app.repository).latestDraft(), isNull);
    expect(await app.repository.loadGoals(), isEmpty);
  });
}
