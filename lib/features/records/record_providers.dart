import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../app/providers.dart';
import '../../data/local/local_goal_repository.dart';
import '../../data/sync/identity_store.dart';
import '../../data/local/app_database.dart';
import '../../shared/local_date.dart';
import 'data/local_day_record_store.dart';
import 'data/record_photo_files.dart';
import 'data/record_photo_picker.dart';

final dayRecordStoreProvider = FutureProvider<LocalDayRecordStore>((ref) async {
  final goals = await ref.watch(goalRepositoryProvider.future);
  final lease = await IdentityStore(goals.db).active();
  if (lease.identity.owner != goals.owner) throw const StaleIdentity();
  return LocalDayRecordStore(
    LocalGoalRepository(
      goals.db,
      goals.clock,
      owner: goals.owner,
      identityLease: lease,
    ),
  );
}, retry: (count, error) => null);

final dayRecordsProvider = StreamProvider.autoDispose
    .family<List<DayRecordSnapshot>, LocalDate>((ref, day) async* {
      final store = await ref.watch(dayRecordStoreProvider.future);
      if (!ref.mounted) return;
      yield* store.watchOn(day);
    }, retry: (count, error) => null);

final recordPhotoRootProvider = FutureProvider<Directory>(
  (ref) async => Directory(
    p.join((await getApplicationDocumentsDirectory()).path, 'record_photos'),
  ),
  retry: (count, error) => null,
);

final recordPhotoFilesProvider = FutureProvider<RecordPhotoFiles>((ref) async {
  final store = await ref.watch(dayRecordStoreProvider.future);
  final root = await ref.watch(recordPhotoRootProvider.future);
  return RecordPhotoFiles(root, store.owner);
}, retry: (count, error) => null);

final recordPhotoPickerProvider = Provider((ref) => RecordPhotoPicker());

final recordPhotoBytesProvider = FutureProvider.autoDispose
    .family<Uint8List, StoredRecordPhoto>((ref, photo) async {
      final store = await ref.watch(dayRecordStoreProvider.future);
      await store.goals.requireActiveIdentity();
      final bytes = await (await ref.watch(recordPhotoFilesProvider.future))
          .read(photo);
      await store.goals.requireActiveIdentity();
      return bytes;
    }, retry: (count, error) => null);
