import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/sync/identity_store.dart';
import 'package:habit_checkin/features/analysis/data/local_day_analysis_store.dart';
import 'package:habit_checkin/features/analysis/presentation/day_analysis_controller.dart';
import 'package:habit_checkin/features/assistant/data/assistant_service.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'support/analysis_fixtures.dart';
import 'support/test_clock.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);
  late AppDatabase db;
  late LocalDayAnalysisStore store;
  late DayAnalysisController controller;
  late TestDayAnalysisService service;
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    final lease = await IdentityStore(db).active();
    store = LocalDayAnalysisStore(
      LocalGoalRepository(
        db,
        TestClock(),
        owner: lease.identity.owner,
        identityLease: lease,
      ),
    );
    service = TestDayAnalysisService();
    controller = DayAnalysisController(store: store, service: service);
    await controller.initialize();
  });
  tearDown(() async {
    controller.dispose();
    await db.close();
  });
  Future<void> waitForRequest() async {
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (service.requests.isEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(service.requests, hasLength(1));
  }

  test(
    'consent is required, five taps produce one frozen request and result',
    () async {
      await controller.analyze();
      expect(service.requests, isEmpty);
      expect(await store.list(), isEmpty);
      await controller.consent();
      service.gate = Completer<void>();
      final operations = List.generate(5, (_) => controller.analyze());
      await waitForRequest();
      expect((await store.list()).single.status, 'pending');
      service.gate!.complete();
      await Future.wait(operations);
      expect(service.requests, hasLength(1));
      expect(controller.results.single.status, 'succeeded');
    },
  );
  test(
    'network failure remains readable and explicit retry has one result',
    () async {
      await controller.consent();
      service.failure = const AssistantFailure(AssistantFailureKind.network);
      await controller.analyze();
      final failed = controller.results.single;
      expect(failed.failureCode, 'network');
      service.failure = null;
      await controller.analyze(retryOf: failed.id);
      expect(service.requests, hasLength(2));
      expect(
        controller.results.where((row) => row.status == 'succeeded'),
        hasLength(1),
      );
      expect(service.requests.first.entries, isEmpty);
    },
  );
  test(
    'disabled during response and re-enabled cannot commit late output',
    () async {
      await controller.consent();
      service.gate = Completer<void>();
      final running = controller.analyze();
      await waitForRequest();
      await controller.setEnabled(false);
      await controller.setEnabled(true);
      await controller.consent();
      service.gate!.complete();
      await running;
      expect(controller.results.single.responseJson, isNull);
      expect(controller.results.single.status, 'cancelled');
    },
  );
  test('deleting pending analysis prevents response resurrection', () async {
    await controller.consent();
    service.gate = Completer<void>();
    final running = controller.analyze();
    await waitForRequest();
    await controller.remove(controller.results.single.id);
    service.gate!.complete();
    await running;
    expect(await store.list(), isEmpty);
  });
}
