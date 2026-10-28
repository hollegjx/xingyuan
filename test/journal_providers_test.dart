import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/app/providers.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/sync/identity_store.dart';
import 'package:habit_checkin/features/journal/domain/journal_entry.dart';
import 'package:habit_checkin/features/journal/journal_providers.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:uuid/uuid.dart';

import 'support/test_clock.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);

  test('diary changes notify independently while quick-note stream is already active', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final clock = TestClock()..setDay(2026, 10, 23);
    final goals = LocalGoalRepository(db, clock);
    final container = ProviderContainer(
      overrides: [goalRepositoryProvider.overrideWith((ref) async => goals)],
    );
    final notes = container.listen(quickNotesOnProvider(clock.day), (_, _) {});
    final diary = container.listen(diaryOnProvider(clock.day), (_, _) {});
    try {
      expect(
        await container.read(quickNotesOnProvider(clock.day).future),
        isEmpty,
      );
      expect(await container.read(diaryOnProvider(clock.day).future), isNull);
      await pumpEventQueue();
      final store = await container.read(diaryStoreProvider.future);
      var value = await store.beginDraft(clock.day);
      await pumpEventQueue();
      expect(
        container.read(diaryOnProvider(clock.day)).requireValue?.entry.id,
        value.entry.id,
      );
      value = await store.writeDraft(
        value.entry.id,
        content: 'SYNTHETIC diary-only edit',
        expectedDraftRevision: value.entry.draftRevision,
      );
      await store.save(
        value.entry.id,
        operationId: const Uuid().v4(),
        expectedRevision: value.entry.revision,
        expectedDraftRevision: value.entry.draftRevision,
      );
      await pumpEventQueue();
      expect(
        container.read(diaryOnProvider(clock.day)).requireValue?.entry.content,
        'SYNTHETIC diary-only edit',
      );
      expect(
        container.read(quickNotesOnProvider(clock.day)).requireValue,
        isEmpty,
      );
    } finally {
      notes.close();
      diary.close();
      container.dispose();
      await db.close();
    }
  });

  test('local journal providers create, watch, save and list without any HTTP client', () async {
    var networkAttempts = 0;
    await HttpOverrides.runZoned(
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
        final root = await Directory.systemTemp.createTemp('journal-provider-');
        final container = ProviderContainer(
          overrides: [
            goalRepositoryProvider.overrideWith((ref) async => goals),
            journalPhotoRootProvider.overrideWith((ref) async => root),
          ],
        );
        final notesSubscription = container.listen(
          quickNotesOnProvider(clock.day),
          (_, _) {},
        );
        final diarySubscription = container.listen(
          diaryOnProvider(clock.day),
          (_, _) {},
        );
        final listSubscription = container.listen(
          journalListProvider((
            kind: JournalKind.quickNote,
            limit: 100,
            offset: 0,
          )),
          (_, _) {},
        );
        try {
          expect(
            await container.read(quickNotesOnProvider(clock.day).future),
            isEmpty,
          );
          expect(
            await container.read(diaryOnProvider(clock.day).future),
            isNull,
          );
          final notes = await container.read(quickNoteStoreProvider.future);
          var value = await notes.beginDraft();
          value = await notes.writeDraft(
            value.entry.id,
            content: 'SYNTHETIC local',
            expectedDraftRevision: value.entry.draftRevision,
          );
          await notes.save(
            value.entry.id,
            operationId: const Uuid().v4(),
            expectedRevision: value.entry.revision,
            expectedDraftRevision: value.entry.draftRevision,
          );
          final diary = await container.read(diaryStoreProvider.future);
          await diary.beginDraft(clock.day);
          await pumpEventQueue();
          expect(
            container
                .read(quickNotesOnProvider(clock.day))
                .requireValue
                .single
                .entry
                .content,
            'SYNTHETIC local',
          );
          expect(
            container.read(diaryOnProvider(clock.day)).requireValue,
            isNotNull,
          );
          expect(
            container
                .read(
                  journalListProvider((
                    kind: JournalKind.quickNote,
                    limit: 100,
                    offset: 0,
                  )),
                )
                .requireValue,
            hasLength(1),
          );
          final files = await container.read(
            journalPhotoFilesProvider(JournalKind.quickNote).future,
          );
          expect(files.owner, goals.owner);
          expect(files.directory.path, contains('quick_note_photos'));
          expect(networkAttempts, 0);
        } finally {
          notesSubscription.close();
          diarySubscription.close();
          listSubscription.close();
          container.dispose();
          await db.close();
          await root.delete(recursive: true);
        }
      },
      createHttpClient: (_) {
        networkAttempts++;
        throw StateError('J1 must stay offline');
      },
    );
  });
}
