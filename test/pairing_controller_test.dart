import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/sync/identity_store.dart';
import 'package:habit_checkin/features/companion/data/companion_service.dart';
import 'package:habit_checkin/features/companion/data/local_pairing_store.dart';
import 'package:habit_checkin/features/companion/presentation/pairing_controller.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'support/pairing_fixtures.dart';
import 'support/test_clock.dart';

class _FinishDelay extends QueryInterceptor {
  bool armed = false;
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    if (armed && statement.contains('INSERT INTO "pairing_states"')) {
      armed = false;
      entered.complete();
      await release.future;
    }
    return executor.runInsert(statement, args);
  }
}

void main() {
  setUpAll(tzdata.initializeTimeZones);
  late AppDatabase db;
  late LocalPairingStore store;
  late PairingController controller;
  late TestCompanionService service;
  late _FinishDelay delay;
  setUp(() async {
    delay = _FinishDelay();
    db = AppDatabase(NativeDatabase.memory().interceptWith(delay));
    final lease = await IdentityStore(db).active();
    store = await LocalPairingStore.open(
      LocalGoalRepository(db, TestClock(), identityLease: lease),
      credentialScope: 'a' * 64,
    );
    service = TestCompanionService();
    controller = PairingController(store: store, service: service);
    await controller.initialize();
  });
  tearDown(() async {
    controller.dispose();
    await db.close();
  });
  Future<void> waitForCommand() async {
    for (var i = 0; i < 200 && service.commands.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(service.commands, hasLength(1));
  }

  test(
    'no automatic connection, drafts serialize and five taps send one command',
    () async {
      expect(service.reads, 0);
      await Future.wait([
        controller.editDraft('A'),
        controller.editDraft('ABCDEFGH'),
      ]);
      expect((await store.snapshot()).row.draftCode, 'ABCDEFGH');
      service.gate = Completer<void>();
      final runs = List.generate(5, (_) => controller.join());
      await waitForCommand();
      await controller.editDraft('NEXT😀\n');
      service.gate!.complete();
      await Future.wait(runs);
      expect(controller.snapshot!.state!.group!.id, testGroupId);
      expect(controller.draft, 'NEXT😀\n');
      expect((await store.snapshot()).row.draftCode, controller.draft);
    },
  );

  test(
    'new text during slow success storage is saved without stale revision',
    () async {
      await controller.editDraft('ABCDEFGH');
      service.gate = Completer<void>();
      final join = controller.join();
      await waitForCommand();
      delay.armed = true;
      service.gate!.complete();
      await delay.entered.future.timeout(const Duration(seconds: 2));
      final edit = controller.editDraft('NEXT-DRAFT');
      delay.release.complete();
      await join;
      await edit;
      expect(controller.draftError, isNull);
      expect(controller.draftSaved, true);
      expect((await store.snapshot()).row.draftCode, 'NEXT-DRAFT');
    },
  );

  test(
    'uncertain result blocks new actions and retries frozen request once',
    () async {
      await controller.editDraft('ABCDEFGH');
      service.failure = const CompanionServiceFailure(
        'timeout',
        outcomeUnknown: true,
      );
      await controller.join();
      expect(controller.hasUncertainOperation, true);
      await controller.createInvite();
      expect(service.commands, hasLength(1));
      await controller.editDraft('NEXT');
      service.failure = null;
      await Future.wait(List.generate(5, (_) => controller.retry()));
      expect(service.commands, hasLength(2));
      expect(service.commands.last.toJson(), service.commands.first.toJson());
      expect(controller.snapshot!.command, isNull);
      expect(controller.draft, 'NEXT');
    },
  );

  test(
    'confirmed invalid invite preserves draft and a new join uses a new ID',
    () async {
      await controller.editDraft('WRONG');
      service.failure = const CompanionServiceFailure('invite_invalid');
      await controller.join();
      expect(controller.canRetry, false);
      expect(controller.canStart, true);
      expect(controller.draft, 'WRONG');
      await controller.editDraft('ABCDEFGH');
      service.failure = null;
      await controller.join();
      expect(service.commands, hasLength(2));
      expect(
        service.commands.last.operationId,
        isNot(service.commands.first.operationId),
      );
      expect(controller.draft, isEmpty);
    },
  );

  test(
    'empty and overlong input stays local and drafts remain complete',
    () async {
      await controller.join();
      await controller.editDraft('😀' * 65);
      await controller.join();
      expect(service.commands, isEmpty);
      expect((await store.snapshot()).row.draftCode, '😀' * 65);
      expect(controller.error, isNotNull);
    },
  );

  test(
    'refresh and command cannot race, unauthorized refresh hides cached pair',
    () async {
      service.current = testPairingState(paired: true);
      await controller.refresh();
      expect(controller.confirmed, true);
      service.readGate = Completer<void>();
      service.readFailure = const CompanionServiceFailure('unauthorized');
      final reading = controller.refresh();
      await controller.leave(testGroupId);
      expect(service.commands, isEmpty);
      service.readGate!.complete();
      await reading;
      expect(controller.snapshot!.state, isNull);
      expect(controller.confirmed, false);
    },
  );

  test(
    'cancelled waiting never accepts late success and keeps a retry',
    () async {
      service.gate = Completer<void>();
      final running = controller.createInvite();
      await waitForCommand();
      controller.cancelWaiting();
      service.gate!.complete();
      await running;
      expect(controller.snapshot!.state, isNull);
      expect(controller.hasUncertainOperation, true);
      expect(controller.canRetry, true);
    },
  );

  test(
    'recreated controller recovers interrupted action without sending',
    () async {
      service.failure = const CompanionServiceFailure(
        'network',
        outcomeUnknown: true,
      );
      await controller.createInvite();
      controller.dispose();
      controller = PairingController(store: store, service: service);
      await controller.initialize();
      expect(service.commands, hasLength(1));
      expect(controller.hasUncertainOperation, true);
      expect(controller.confirmed, false);
    },
  );
}
