import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/sync/identity_store.dart';
import 'package:habit_checkin/features/analysis/analysis_providers.dart';
import 'package:habit_checkin/features/analysis/data/local_day_analysis_store.dart';
import 'package:habit_checkin/features/analysis/presentation/day_analysis_controller.dart';
import 'package:habit_checkin/features/assistant/data/assistant_service.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'support/analysis_fixtures.dart';
import 'support/layout_capture.dart';
import 'support/sync_fixtures.dart';
import 'support/ui_harness.dart';

void main() {
  final capture = LayoutCapture();
  setUpAll(() async {
    tzdata.initializeTimeZones();
    await capture.prepare();
  });
  Future<void> open(WidgetTester tester, {bool waiting = false}) => tapVisible(
    tester,
    find.byKey(const ValueKey('open-day-analysis')),
    settle: !waiting,
  );
  Future<void> agree(WidgetTester tester, {bool waiting = false}) async {
    await tapVisible(tester, find.byKey(const ValueKey('analyze-today')));
    await tapVisible(
      tester,
      find.byKey(const ValueKey('consent-day-analysis')),
      settle: !waiting,
    );
  }

  testUiWidgets('slow consent keeps the action disabled until dispatch', (
    tester,
  ) async {
    final harness = UiHarness();
    final service = TestDayAnalysisService();
    final controller = _SlowConsentController(
      store: LocalDayAnalysisStore(harness.repository),
      service: service,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await harness.mount(
      tester,
      dayAnalysisService: service,
      wrapApp: (child) => ProviderScope(
        overrides: [
          dayAnalysisControllerProvider.overrideWith((ref) => controller),
        ],
        child: child,
      ),
    );
    await open(tester);
    await agree(tester);
    final button = tester.widget<FilledButton>(
      find.byKey(const ValueKey('analyze-today')),
    );
    expect(button.onPressed, isNull);
    controller.gate.complete();
    await tester.pumpAndSettle();
    expect(service.requests, hasLength(1));
  });

  testUiWidgets('retry after re-enabling requests independent consent again', (
    tester,
  ) async {
    final harness = UiHarness();
    final service = TestDayAnalysisService()
      ..failure = const AssistantFailure(AssistantFailureKind.network);
    await harness.mount(tester, dayAnalysisService: service);
    await open(tester);
    await agree(tester);
    final controller = await harness.container.read(
      dayAnalysisControllerProvider.future,
    );
    final row = controller.results.single;
    await controller.setEnabled(false);
    await controller.setEnabled(true);
    await tester.pumpAndSettle();
    await tapVisible(tester, find.byKey(ValueKey('retry-analysis-${row.id}')));
    expect(find.text('分析发送范围'), findsOneWidget);
    expect(service.requests, hasLength(1));
  });

  testUiWidgets(
    'analysis consent, repeated taps and navigation preserve one active request',
    (tester) async {
      final harness = UiHarness();
      final service = TestDayAnalysisService()..gate = Completer<void>();
      await harness.mount(tester, dayAnalysisService: service);
      await open(tester);
      await tapVisible(tester, find.byKey(const ValueKey('analyze-today')));
      expect(find.text('分析发送范围'), findsOneWidget);
      await tapVisible(tester, find.text('取消'));
      expect(service.requests, isEmpty);
      await agree(tester, waiting: true);
      for (var i = 0; i < 5; i++) {
        await tester.tap(find.byKey(const ValueKey('analyze-today')));
      }
      await pumpWaiting(tester);
      expect(service.requests, hasLength(1));
      await goBack(tester);
      await tapVisible(tester, find.text('回顾').last);
      await tapVisible(tester, find.text('今天').last);
      await open(tester, waiting: true);
      expect(find.text('正在等待分析结果'), findsOneWidget);
      service.gate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('TEST 合成分析结果'), findsOneWidget);
      expect(service.requests, hasLength(1));
    },
  );

  testUiWidgets(
    'analysis failure, retry, exact payload and deletion keep personal goals',
    (tester) async {
      final harness = UiHarness();
      await harness.repository.create(
        const GoalDraft(title: 'TEST private goal', kind: GoalKind.habit),
      );
      final service = TestDayAnalysisService()
        ..failure = const AssistantFailure(AssistantFailureKind.network);
      await harness.mount(tester, dayAnalysisService: service);
      await open(tester);
      await agree(tester);
      final store = await harness.container.read(
        dayAnalysisStoreProvider.future,
      );
      final first = (await store.list()).single;
      expect(first.status, 'failed');
      await tapVisible(
        tester,
        find.byKey(ValueKey('analysis-payload-${first.id}')),
      );
      expect(find.textContaining('TEST private goal'), findsOneWidget);
      expect(find.textContaining('"photos"'), findsNothing);
      await goBack(tester);
      service.failure = null;
      service.gate = Completer<void>();
      final retry = find.byKey(ValueKey('retry-analysis-${first.id}'));
      for (var i = 0; i < 5; i++) {
        await tester.tap(retry);
      }
      await pumpWaiting(tester);
      expect(service.requests, hasLength(2));
      service.gate!.complete();
      await tester.pumpAndSettle();
      final result = (await store.list()).singleWhere(
        (row) => row.status == 'succeeded',
      );
      await tapVisible(
        tester,
        find.byKey(ValueKey('delete-analysis-${result.id}')),
      );
      await tapVisible(tester, find.text('取消'));
      expect(await store.list(), hasLength(2));
      await tapVisible(
        tester,
        find.byKey(ValueKey('delete-analysis-${result.id}')),
      );
      await tapVisible(
        tester,
        find.byKey(const ValueKey('confirm-delete-analysis')),
      );
      expect(await store.list(), hasLength(1));
      expect(await harness.repository.loadGoals(), hasLength(1));
    },
  );

  testUiWidgets(
    'disable hides entry but keeps results and re-enable requires consent',
    (tester) async {
      final harness = UiHarness();
      final service = TestDayAnalysisService();
      await harness.mount(tester, dayAnalysisService: service);
      await open(tester);
      await agree(tester);
      await goBack(tester);
      await openMenu(tester, '设置');
      await tapVisible(
        tester,
        find.byKey(const ValueKey('enable-day-analysis')),
      );
      await tapVisible(tester, find.text('分析记录'));
      expect(find.text('今日分析已关闭'), findsOneWidget);
      expect(find.text('TEST 合成分析结果'), findsOneWidget);
      expect(find.byKey(const ValueKey('analyze-today')), findsNothing);
      await goBack(tester);
      await goBack(tester);
      expect(find.byKey(const ValueKey('open-day-analysis')), findsNothing);
      await openMenu(tester, '设置');
      await tapVisible(
        tester,
        find.byKey(const ValueKey('enable-day-analysis')),
      );
      await goBack(tester);
      await open(tester);
      await tapVisible(tester, find.byKey(const ValueKey('analyze-today')));
      expect(find.text('分析发送范围'), findsOneWidget);
      expect(service.requests, hasLength(1));
    },
  );

  testUiWidgets(
    'pending recovery does not resend and stale identity hides payload',
    (tester) async {
      final harness = UiHarness();
      final local = LocalDayAnalysisStore(harness.repository);
      await local.consent();
      final pending = await local.begin();
      final service = TestDayAnalysisService();
      await harness.mount(tester, dayAnalysisService: service);
      await open(tester);
      expect(find.textContaining('上次分析已中断'), findsOneWidget);
      expect(service.requests, isEmpty);
      await tapVisible(
        tester,
        find.byKey(ValueKey('analysis-payload-${pending.row.id}')),
      );
      final identities = IdentityStore(harness.database);
      await identities.finish(await identities.begin(accountA));
      await tester.pumpAndSettle();
      expect(find.textContaining('"request_id"'), findsNothing);
      expect(service.requests, isEmpty);
    },
  );

  for (final scale in [1.0, 2.0, 3.0]) {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      testUiWidgets(
        'analysis 320px scale $scale system $brightness consent/result controls',
        (tester) async {
          tester.view.physicalSize = const Size(320, 568);
          tester.view.devicePixelRatio = 1;
          tester.view.padding = const FakeViewPadding(top: 20);
          tester.view.viewPadding = const FakeViewPadding(top: 20);
          tester.view.viewInsets = const FakeViewPadding();
          tester.platformDispatcher.platformBrightnessTestValue = brightness;
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.view.resetPadding);
          addTearDown(tester.view.resetViewPadding);
          addTearDown(tester.view.resetViewInsets);
          addTearDown(
            tester.platformDispatcher.clearPlatformBrightnessTestValue,
          );
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          final harness = UiHarness();
          final service = TestDayAnalysisService();
          await harness.mount(
            tester,
            dayAnalysisService: service,
            wrapApp: capture.wrap,
          );
          await open(tester);
          expect(
            MediaQuery.textScalerOf(
              tester.element(find.byKey(const ValueKey('analyze-today'))),
            ).scale(10),
            10 * scale,
          );
          await tapVisible(tester, find.byKey(const ValueKey('analyze-today')));
          await tester.ensureVisible(
            find.byKey(const ValueKey('consent-day-analysis')),
          );
          await capture.shot(
            tester,
            scale,
            'analysis-${brightness.name}-consent',
          );
          await tapVisible(
            tester,
            find.byKey(const ValueKey('consent-day-analysis')),
          );
          expect(find.text('TEST 合成分析结果'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await capture.shot(
            tester,
            scale,
            'analysis-${brightness.name}-result',
          );
          final row = (await (await harness.container.read(
            dayAnalysisStoreProvider.future,
          )).list()).single;
          await tapVisible(
            tester,
            find.byKey(ValueKey('analysis-payload-${row.id}')),
          );
          await capture.shot(
            tester,
            scale,
            'analysis-${brightness.name}-payload',
          );
          await goBack(tester);
          await tapVisible(
            tester,
            find.byKey(ValueKey('delete-analysis-${row.id}')),
          );
          await tester.ensureVisible(
            find.byKey(const ValueKey('confirm-delete-analysis')),
          );
          await capture.shot(
            tester,
            scale,
            'analysis-${brightness.name}-delete',
          );
          await tapVisible(
            tester,
            find.byKey(const ValueKey('confirm-delete-analysis')),
          );
          expect(tester.takeException(), isNull);
          await capture.passed(tester, scale);
        },
      );
    }
  }
}

class _SlowConsentController extends DayAnalysisController {
  _SlowConsentController({required super.store, required super.service});
  final gate = Completer<void>();
  @override
  Future<void> consent() async {
    await gate.future;
    await super.consent();
  }
}
