import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/sync/identity_store.dart';
import 'package:habit_checkin/features/journal/data/local_journal_store.dart';
import 'package:habit_checkin/features/journal/domain/journal_entry.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'support/test_clock.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);

  for (final firstKind in JournalKind.values) {
    test(
      'both journal streams refresh when ${firstKind.name} subscribes first',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        final clock = TestClock()..setDay(2026, 10, 23);
        final lease = await IdentityStore(db).active();
        final goals = LocalGoalRepository(
          db,
          clock,
          owner: lease.identity.owner,
          identityLease: lease,
        );
        final stores = <LocalJournalStore>[
          LocalQuickNoteStore(goals),
          LocalDiaryStore(goals),
        ]..sort((a, b) => a.kind == firstKind ? -1 : 1);
        final events = [<List<JournalSnapshot>>[], <List<JournalSnapshot>>[]];
        final errors = <Object>[];
        final subscriptions = <StreamSubscription<List<JournalSnapshot>>>[];
        try {
          // Establish each subscription separately so no sibling write can wake it.
          for (var i = 0; i < stores.length; i++) {
            final ready = Completer<void>();
            subscriptions.add(
              stores[i]
                  .watchOn(clock.day)
                  .listen(
                    (rows) {
                      events[i].add(rows);
                      if (!ready.isCompleted) ready.complete();
                    },
                    onError: (Object error) {
                      errors.add(error);
                      if (!ready.isCompleted) ready.completeError(error);
                    },
                  ),
            );
            await ready.future.timeout(const Duration(seconds: 5));
            expect(events[i].last, isEmpty);
          }
          final second = stores.last;
          final value = switch (second) {
            LocalQuickNoteStore s => await s.beginDraft(),
            LocalDiaryStore s => await s.beginDraft(clock.day),
            _ => throw StateError('Unexpected journal store'),
          };
          await second.writeDraft(
            value.entry.id,
            content: 'SYNTHETIC second stream changed',
            expectedDraftRevision: value.entry.draftRevision,
          );
          expect(
            (await second.at(value.entry.id))!.entry.draftText,
            'SYNTHETIC second stream changed',
          );
          await pumpEventQueue(times: 40);
          expect(errors, isEmpty);
          expect(events.first.last, isEmpty);
          expect(events.last.last, hasLength(1));
          expect(
            events.last.last.single.entry.draftText,
            'SYNTHETIC second stream changed',
          );
        } finally {
          for (final subscription in subscriptions) {
            await subscription.cancel();
          }
          await db.close();
        }
      },
    );
  }
}
