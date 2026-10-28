import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/sync/identity_store.dart';
import 'package:habit_checkin/data/sync/sync_identity.dart';
import 'package:habit_checkin/features/analysis/data/local_day_analysis_store.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:habit_checkin/features/journal/data/local_journal_store.dart';
import 'package:habit_checkin/features/journal/domain/journal_entry.dart';
import 'package:habit_checkin/features/records/data/local_day_record_store.dart';
import 'package:habit_checkin/shared/local_date.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:uuid/uuid.dart';

import 'support/test_clock.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);
  for (final kind in JournalKind.values) {
    group(kind.name, () {
      late AppDatabase db;
      late TestClock clock;
      late LocalGoalRepository goals;
      late LocalJournalStore store;

      Future<void> bind() async {
        final lease = await IdentityStore(db).active();
        goals = LocalGoalRepository(
          db,
          clock,
          owner: lease.identity.owner,
          identityLease: lease,
        );
        store = kind == JournalKind.quickNote
            ? LocalQuickNoteStore(goals)
            : LocalDiaryStore(goals);
      }

      setUp(() async {
        db = AppDatabase(NativeDatabase.memory());
        clock = TestClock()..setDay(2026, 10, 23);
        await bind();
      });
      tearDown(() => db.close());

      Future<JournalSnapshot> begin({String? id, LocalDate? day}) =>
          switch (store) {
            LocalQuickNoteStore s => s.beginDraft(id: id, day: day),
            LocalDiaryStore s => s.beginDraft(day ?? clock.day),
            _ => throw StateError('Unexpected test store'),
          };

      Future<JournalSnapshot> edit(JournalSnapshot value, String text) =>
          store.writeDraft(
            value.entry.id,
            content: text,
            expectedDraftRevision: value.entry.draftRevision,
          );

      Future<JournalSnapshot> save(
        JournalSnapshot value, {
        String? operation,
      }) => store.save(
        value.entry.id,
        operationId: operation ?? const Uuid().v4(),
        expectedRevision: value.entry.revision,
        expectedDraftRevision: value.entry.draftRevision,
      );

      Future<void> remove(JournalSnapshot value, {String? operation}) =>
          store.delete(
            value.entry.id,
            operationId: operation ?? const Uuid().v4(),
            expectedRevision: value.entry.revision,
            expectedDraftRevision: value.entry.draftRevision,
          );

      Future<JournalSnapshot> photo(JournalSnapshot value) => store.addPhoto(
        value.entry.id,
        expectedDraftRevision: value.entry.draftRevision,
        photo: RecordPhotoInput(
          id: const Uuid().v4(),
          width: 12,
          height: 8,
          byteCount: 100,
          sha256: 'a' * 64,
        ),
      );

      test(
        'works without goals and keeps saved content separate from a draft',
        () async {
          var value = await begin();
          expect(await store.savedOn(clock.day), isEmpty);
          expect(await store.onDay(clock.day), hasLength(1));
          value = await save(await edit(value, 'SYNTHETIC saved'));
          value = await begin(id: value.entry.id);
          value = await edit(value, 'SYNTHETIC draft');
          expect(value.hasDraftChanges, isTrue);
          expect(
            (await store.savedOn(clock.day)).single.entry.content,
            'SYNTHETIC saved',
          );
          expect(
            (await begin(id: value.entry.id)).entry.draftText,
            'SYNTHETIC draft',
          );
          expect(await db.select(db.goals).get(), isEmpty);
          expect(await db.select(db.checkIns).get(), isEmpty);
        },
      );

      test(
        'concurrent reopen and five save retries never duplicate entries',
        () async {
          final value = await edit(await begin(), 'SYNTHETIC one');
          final openings = await Future.wait(
            List.generate(5, (_) => begin(id: value.entry.id)),
          );
          expect(openings.map((v) => v.entry.id).toSet(), {value.entry.id});
          expect(openings.map((v) => v.entry.draftRevision).toSet(), {
            value.entry.draftRevision,
          });
          final operation = const Uuid().v4();
          final results = await Future.wait(
            List.generate(5, (_) => save(value, operation: operation)),
          );
          expect(results.map((v) => v.entry.revision).toSet(), {1});
          expect(await store.savedOn(clock.day), hasLength(1));
          await expectLater(save(value), throwsA(isA<JournalConflict>()));
        },
      );

      test('old save replay preserves a newer draft and rejects altered parameters', () async {
        final value = await edit(await begin(), 'SYNTHETIC saved');
        final operation = const Uuid().v4();
        await save(value, operation: operation);
        final next = await edit(
          await begin(id: value.entry.id),
          'SYNTHETIC later',
        );
        await save(value, operation: operation);
        expect(
          (await store.at(value.entry.id))!.entry.draftText,
          'SYNTHETIC later',
        );
        await expectLater(
          store.save(
            value.entry.id,
            operationId: operation,
            expectedRevision: value.entry.revision,
            expectedDraftRevision: next.entry.draftRevision,
          ),
          throwsA(isA<JournalConflict>()),
        );
        await save(next);
        await expectLater(
          save(value, operation: operation),
          throwsA(isA<JournalConflict>()),
        );
      });

      test(
        'stale editor and delete cannot overwrite a newer unsaved draft',
        () async {
          final first = await edit(await begin(), 'SYNTHETIC first');
          await edit(first, 'SYNTHETIC later');
          await expectLater(
            edit(first, 'SYNTHETIC stale'),
            throwsA(isA<JournalConflict>()),
          );
          await expectLater(save(first), throwsA(isA<JournalConflict>()));
          await expectLater(remove(first), throwsA(isA<JournalConflict>()));
          expect(
            (await store.at(first.entry.id))!.entry.draftText,
            'SYNTHETIC later',
          );
        },
      );

      test(
        'grapheme limits retain over-limit drafts and do not trim saved text',
        () async {
          final text = '${'👨‍👩‍👧‍👦' * (kind.maxLength - 2)}\ne\u0301';
          final saved = await save(await edit(await begin(), text));
          expect(saved.entry.content, text);
          final over = await edit(await begin(id: saved.entry.id), '$text!');
          await expectLater(save(over), throwsA(isA<JournalRuleException>()));
          expect((await store.at(saved.entry.id))!.entry.draftText, '$text!');
          final long = await edit(over, 'x' * LocalJournalStore.maxDraftLength);
          await expectLater(
            edit(long, 'x' * (LocalJournalStore.maxDraftLength + 1)),
            throwsA(isA<JournalRuleException>()),
          );
          expect(
            (await store.at(saved.entry.id))!.entry.draftText!.length,
            LocalJournalStore.maxDraftLength,
          );
        },
      );

      test('blank text requires a photo, preserves whitespace, and limits photos to three', () async {
        var value = await edit(await begin(), ' \n ');
        await expectLater(save(value), throwsA(isA<JournalRuleException>()));
        for (var i = 0; i < 3; i++) {
          value = await photo(value);
        }
        await expectLater(photo(value), throwsA(isA<JournalRuleException>()));
        value = await save(value);
        expect(value.savedPhotos, hasLength(3));
        expect(value.entry.content, ' \n ');
        expect(value.draftPhotos, isEmpty);
      });

      test(
        'removing a draft photo never detaches a saved photo prematurely',
        () async {
          var value = await save(await photo(await photo(await begin())));
          final savedIds = value.savedPhotos.map((p) => p.id).toList();
          value = await begin(id: value.entry.id);
          value = await store.removePhoto(
            value.entry.id,
            savedIds.first,
            expectedDraftRevision: value.entry.draftRevision,
          );
          expect(value.savedPhotos.map((p) => p.id), savedIds);
          expect(value.draftPhotos.map((p) => p.draftPosition), [0]);
          expect(await store.unreferencedPhotos(), isEmpty);
          value = await save(value);
          expect((await store.unreferencedPhotos()).single.id, savedIds.first);
          final operation = const Uuid().v4();
          await remove(value, operation: operation);
          await remove(value, operation: operation);
          expect(await store.savedOn(clock.day), isEmpty);
          expect(await store.unreferencedPhotos(), hasLength(2));
          expect((await store.at(value.entry.id))!.entry.content, isEmpty);
        },
      );

      test('failed photo cleanup retains metadata for retry', () async {
        var value = await photo(await begin());
        value = await store.removePhoto(
          value.entry.id,
          value.draftPhotos.single.id,
          expectedDraftRevision: value.entry.draftRevision,
        );
        await expectLater(
          store.cleanDetachedPhotos(
            (_) async => throw const FileSystemException(),
          ),
          throwsA(isA<FileSystemException>()),
        );
        expect(await store.unreferencedPhotos(), hasLength(1));
        await store.cleanDetachedPhotos((_) async {});
        expect(await store.photoFilenames(), isEmpty);
      });

      test('save rollback restores saved photos and draft after a database failure', () async {
        var value = await save(await photo(await begin()));
        final oldPhoto = value.savedPhotos.single.id;
        value = await photo(await begin(id: value.entry.id));
        final table = kind == JournalKind.quickNote
            ? 'quick_notes'
            : 'diary_entries';
        await db.customStatement(
          'CREATE TRIGGER fail_journal_save BEFORE UPDATE ON $table '
          'WHEN NEW.draft_text IS NULL BEGIN SELECT RAISE(ABORT, \'SYNTHETIC failure\'); END',
        );
        await expectLater(save(value), throwsException);
        final after = (await store.at(value.entry.id))!;
        expect(after.savedPhotos.map((p) => p.id), [oldPhoto]);
        expect(after.draftPhotos, hasLength(2));
        expect(after.entry.revision, value.entry.revision);
        expect(after.entry.draftRevision, value.entry.draftRevision);
      });

      test(
        'history remains editable and future creation is rejected',
        () async {
          final yesterday = clock.day.addDays(-1);
          var value = await save(
            await edit(await begin(day: yesterday), 'SYNTHETIC yesterday'),
          );
          value = await edit(
            await begin(id: value.entry.id, day: yesterday),
            'SYNTHETIC revised',
          );
          await save(value);
          expect(
            (await store.savedOn(yesterday)).single.entry.content,
            'SYNTHETIC revised',
          );
          expect(await store.savedOn(clock.day), isEmpty);
          await expectLater(
            begin(day: clock.day.addDays(1)),
            throwsA(isA<JournalRuleException>()),
          );
        },
      );

      test('draft and saved version survive reopen across midnight and a time zone change', () async {
        await db.close();
        final directory = await Directory.systemTemp.createTemp(
          'journal-reopen-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final file = File('${directory.path}/synthetic.sqlite');
        db = AppDatabase(NativeDatabase(file));
        clock.location = tz.getLocation('America/Los_Angeles');
        clock.setDay(2026, 10, 22, hour: 23, minute: 59);
        await bind();
        final day = clock.day;
        var value = await save(await edit(await begin(), 'SYNTHETIC saved'));
        value = await edit(await begin(id: value.entry.id), 'SYNTHETIC draft');
        await db.close();
        db = AppDatabase(NativeDatabase(file));
        clock.instant = clock.instant.add(const Duration(minutes: 2));
        clock.location = tz.getLocation('Asia/Shanghai');
        await bind();
        final restored = await begin(id: value.entry.id, day: day);
        expect(restored.entry.content, 'SYNTHETIC saved');
        expect(restored.entry.draftText, 'SYNTHETIC draft');
        expect(restored.entry.zone, 'America/Los_Angeles');
        expect(await store.onDay(clock.day), isEmpty);
        await save(restored);
        expect(
          (await store.savedOn(day)).single.entry.content,
          'SYNTHETIC draft',
        );
      });

      test('identity transition rejects stale reads, late saves and old leases after switching back', () async {
        final value = await edit(await begin(), 'SYNTHETIC guest');
        final oldStore = store;
        final identities = IdentityStore(db);
        final intent = await identities.begin(
          SyncIdentity.account('55555555-5555-4555-8555-555555555555'),
        );
        await expectLater(
          oldStore.at(value.entry.id),
          throwsA(isA<StaleIdentity>()),
        );
        await expectLater(save(value), throwsA(isA<StaleIdentity>()));
        await identities.finish(intent);
        await bind();
        expect(await store.at(value.entry.id), isNull);
        expect(await store.list(), isEmpty);
        await identities.finish(await identities.begin(SyncIdentity.guest));
        await expectLater(
          oldStore.at(value.entry.id),
          throwsA(isA<StaleIdentity>()),
        );
        await bind();
        expect(
          (await store.at(value.entry.id))!.entry.draftText,
          'SYNTHETIC guest',
        );
      });

      test(
        'streams include draft changes and invalidate on identity transitions',
        () async {
          final events = <List<JournalSnapshot>>[];
          final errors = <Object>[];
          final subscription = store
              .watchOn(clock.day)
              .listen(events.add, onError: errors.add);
          addTearDown(subscription.cancel);
          await pumpEventQueue();
          final value = await edit(await begin(), 'SYNTHETIC stream');
          await pumpEventQueue();
          expect(events.last.single.entry.draftText, 'SYNTHETIC stream');
          await save(value);
          await pumpEventQueue();
          expect(events.last.single.entry.isSaved, isTrue);
          await IdentityStore(
            db,
          ).begin(SyncIdentity.account('55555555-5555-4555-8555-555555555555'));
          await pumpEventQueue();
          expect(errors, contains(isA<StaleIdentity>()));
        },
      );

      test('journal markers never enter day analysis, publication, sync or chat state', () async {
        final goal = await goals.create(
          const GoalDraft(
            title: 'SYNTHETIC visible goal',
            kind: GoalKind.habit,
            weekdays: 127,
          ),
        );
        final records = LocalDayRecordStore(goals);
        var record = await records.beginDraft(goal, clock.day);
        record = await records.writeDraft(
          record.record.id,
          content: 'SYNTHETIC allowed record',
          expectedDraftRevision: record.record.draftRevision,
        );
        await records.save(
          record.record.id,
          operationId: const Uuid().v4(),
          expectedRevision: record.record.revision,
          expectedDraftRevision: record.record.draftRevision,
        );
        const unrelated = [
          'sync_outbox',
          'sharing_publications',
          'sharing_publication_sources',
          'sharing_publication_photos',
          'chat_commands',
          'chat_states',
          'chat_messages_cache',
          'day_records',
          'record_photos',
          'check_ins',
          'assistant_messages',
          'assistant_memories',
        ];
        Future<Map<String, List<Map<String, Object?>>>> snapshot() async => {
          for (final table in unrelated)
            table:
                (await db
                        .customSelect('SELECT * FROM $table ORDER BY rowid')
                        .get())
                    .map((r) => r.data)
                    .toList(),
        };
        final before = await snapshot();
        var value = await save(
          await edit(
            await photo(await begin()),
            'SYNTHETIC PRIVATE JOURNAL MARKER',
          ),
        );
        value = await edit(
          await begin(id: value.entry.id),
          'SYNTHETIC PRIVATE DRAFT MARKER',
        );
        final payload = jsonEncode(
          (await LocalDayAnalysisStore(goals).preview()).toJson(),
        );
        expect(payload, contains('SYNTHETIC allowed record'));
        expect(payload, isNot(contains('PRIVATE')));
        await remove(value);
        expect(await snapshot(), before);
      });

      test(
        'list pagination is stable and preserves creation time during editing',
        () async {
          final originals = <JournalSnapshot>[];
          for (var i = 0; i < 3; i++) {
            final day = kind == JournalKind.diary
                ? clock.day.addDays(-i)
                : clock.day;
            originals.add(
              await save(await edit(await begin(day: day), 'SYNTHETIC $i')),
            );
            clock.instant = clock.instant.add(const Duration(seconds: 1));
          }
          final initial = await store.list();
          final item = originals.first;
          final editing = await begin(
            id: item.entry.id,
            day: LocalDate.parse(item.entry.day),
          );
          final saved = await save(await edit(editing, 'SYNTHETIC changed'));
          expect(saved.entry.createdAt, item.entry.createdAt);
          expect(
            (await store.list()).map((v) => v.entry.id),
            initial.map((v) => v.entry.id),
          );
          expect(
            (await store.list(limit: 1, offset: 1)).single.entry.id,
            initial[1].entry.id,
          );
          expect(() => store.list(limit: 0), throwsArgumentError);
        },
      );

      test('per-day multiplicity matches the record type', () async {
        final first = await save(await edit(await begin(), 'SYNTHETIC first'));
        final second = await begin();
        expect(second.entry.id == first.entry.id, kind == JournalKind.diary);
        await save(await edit(second, 'SYNTHETIC second'));
        expect(
          await store.savedOn(clock.day),
          hasLength(kind == JournalKind.diary ? 1 : 2),
        );
      });

      test(
        'deletion retries cannot delete a revived diary or later saved version',
        () async {
          final value = await save(
            await edit(await begin(), 'SYNTHETIC initial'),
          );
          final operation = const Uuid().v4();
          await remove(value, operation: operation);
          await remove(value, operation: operation);
          if (kind == JournalKind.quickNote) {
            await expectLater(
              begin(id: value.entry.id),
              throwsA(isA<JournalConflict>()),
            );
          } else {
            final next = await edit(await begin(), 'SYNTHETIC revived');
            expect(next.entry.id, value.entry.id);
            await remove(value, operation: operation);
            expect(
              (await store.at(next.entry.id))!.entry.draftText,
              'SYNTHETIC revived',
            );
            await save(next);
            await expectLater(
              remove(value, operation: operation),
              throwsA(isA<JournalConflict>()),
            );
          }
        },
      );
    });
  }
}
