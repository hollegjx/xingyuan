// Former R7 explicit probe, retained in normal discovery after the R8 fix.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/journal/presentation/chat_diary_page.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'chat_diary_initial_read_guard_test.dart' show ReadFixture, retry;
import 'chat_diary_initial_read_recovery_test.dart' show proposalId;
import 'support/ui_harness.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);
  testUiWidgets(
    'R7 provider failure keeps identity boundary return, no retry',
    (tester) async {
      final app = ReadFixture();
      await app.mount(tester, providerFailure: true);
      final context = tester.element(find.byType(NavigationBar));
      unawaited(
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => const ChatDiaryPage(proposalId: proposalId),
          ),
        ),
      );
      await pumpWaiting(tester);
      app.unavailableStore.completeError(
        StateError('R7 separate provider failure'),
      );
      await tester.pumpAndSettle();
      expect(find.text('身份已变化或不可用。'), findsOneWidget);
      expect(retry, findsNothing);
      expect(app.fault.proposalReads, 0);
      await tapVisible(tester, find.widgetWithText(OutlinedButton, '返回'));
      expect(find.byType(ChatDiaryPage), findsNothing);
      await app.expectUnchanged();
      expect(tester.takeException(), isNull);
    },
  );
}
