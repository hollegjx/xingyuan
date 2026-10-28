import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../app/providers.dart';
import '../../data/local/local_goal_repository.dart';
import '../../data/sync/identity_store.dart';
import '../../shared/local_date.dart';
import 'data/journal_photo_files.dart';
import 'data/local_journal_store.dart';
import 'domain/journal_entry.dart';

final journalRepositoryProvider = FutureProvider<LocalGoalRepository>((
  ref,
) async {
  final goals = await ref.watch(goalRepositoryProvider.future);
  final lease = await IdentityStore(goals.db).active();
  if (lease.identity.owner != goals.owner) throw const StaleIdentity();
  return LocalGoalRepository(
    goals.db,
    goals.clock,
    owner: goals.owner,
    identityLease: lease,
  );
}, retry: (count, error) => null);

final quickNoteStoreProvider = FutureProvider<LocalQuickNoteStore>(
  (ref) async =>
      LocalQuickNoteStore(await ref.watch(journalRepositoryProvider.future)),
  retry: (count, error) => null,
);

final diaryStoreProvider = FutureProvider<LocalDiaryStore>(
  (ref) async =>
      LocalDiaryStore(await ref.watch(journalRepositoryProvider.future)),
  retry: (count, error) => null,
);

final journalStoreProvider =
    FutureProvider.family<LocalJournalStore, JournalKind>(
      (ref, kind) => kind == JournalKind.quickNote
          ? ref.watch(quickNoteStoreProvider.future)
          : ref.watch(diaryStoreProvider.future),
      retry: (count, error) => null,
    );

final quickNotesOnProvider = StreamProvider.autoDispose
    .family<List<JournalSnapshot>, LocalDate>((ref, day) async* {
      final store = await ref.watch(quickNoteStoreProvider.future);
      if (ref.mounted) yield* store.watchOn(day);
    }, retry: (count, error) => null);

final diaryOnProvider = StreamProvider.autoDispose
    .family<JournalSnapshot?, LocalDate>((ref, day) async* {
      final store = await ref.watch(diaryStoreProvider.future);
      if (ref.mounted) {
        yield* store.watchOn(day).map((rows) => rows.firstOrNull);
      }
    }, retry: (count, error) => null);

final journalListProvider = StreamProvider.autoDispose
    .family<List<JournalSnapshot>, ({JournalKind kind, int limit, int offset})>(
      (ref, query) async* {
        final store = await ref.watch(journalStoreProvider(query.kind).future);
        if (ref.mounted) {
          yield* store.watchAll(limit: query.limit, offset: query.offset);
        }
      },
      retry: (count, error) => null,
    );

final journalPhotoRootProvider = FutureProvider<Directory>(
  (ref) => getApplicationDocumentsDirectory(),
  retry: (count, error) => null,
);

final journalPhotoFilesProvider =
    FutureProvider.family<JournalPhotoFiles, JournalKind>((ref, kind) async {
      final store = await ref.watch(journalStoreProvider(kind).future);
      final root = await ref.watch(journalPhotoRootProvider.future);
      return JournalPhotoFiles(root, store.owner, kind);
    }, retry: (count, error) => null);

final journalPhotoBytesProvider = FutureProvider.autoDispose
    .family<Uint8List, ({JournalKind kind, JournalPhoto photo})>((
      ref,
      query,
    ) async {
      final store = await ref.watch(journalStoreProvider(query.kind).future);
      await store.goals.requireActiveIdentity();
      final files = await ref.watch(
        journalPhotoFilesProvider(query.kind).future,
      );
      final bytes = await files.read(query.photo);
      await store.goals.requireActiveIdentity();
      return bytes;
    }, retry: (count, error) => null);
