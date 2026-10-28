import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/shared/presentation.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'chat_diary_initial_read_guard_test.dart'
    show DeferredProposalRead, ReadFixture, control, retry;
import 'chat_diary_initial_read_recovery_test.dart' show proposalId, readState;
import 'support/ui_harness.dart';

class QueuedRead extends DeferredProposalRead {
  Completer<void>? beforeRead;
  bool waiting = false;

  @override
  Future<bool> ensureOpen(
    QueryExecutor executor,
    QueryExecutorUser user,
  ) async {
    final gate = beforeRead;
    if (gate != null && executor is TransactionExecutor) {
      beforeRead = null;
      waiting = true;
      await gate.future;
    }
    return executor.ensureOpen(user);
  }
}

void main() {
  setUpAll(tzdata.initializeTimeZones);
  for (final missing in [false, true]) {
    testUiWidgets(
      'R7 queued retry observes ${missing ? 'missing' : 'cancelled'} row',
      (tester) async {
        final fault = QueuedRead();
        final app = ReadFixture(fault: fault);
        await app.mount(tester);
        await app.openFailed(tester);
        final gate = fault.beforeRead = Completer<void>();
        addTearDown(() {
          if (!gate.isCompleted) gate.complete();
        });
        final reads = fault.proposalReads;
        await tapVisible(tester, retry, settle: false);
        expect(fault.waiting, isTrue);
        expect(fault.proposalReads, reads);
        expect(
          tester.widget<StatusPanel>(find.byType(StatusPanel)).loading,
          isTrue,
        );
        if (missing) {
          await (app.db.delete(
            app.db.assistantDiaryProposals,
          )..where((p) => p.id.equals(proposalId))).go();
        } else {
          await (app.db.update(
            app.db.assistantDiaryProposals,
          )..where((p) => p.id.equals(proposalId))).write(
            const AssistantDiaryProposalsCompanion(status: Value('cancelled')),
          );
        }
        final expected = await readState(app.db);
        gate.complete();
        await tester.pumpAndSettle();
        expect(fault.proposalReads, reads + 1);
        expect(
          find.text(missing ? '找不到这条日记建议' : '建议已取消，未写入日记'),
          findsOneWidget,
        );
        expect(control('save'), findsNothing);
        expect(control('suggestion'), findsNothing);
        await app.expectUnchanged(expected: expected);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
