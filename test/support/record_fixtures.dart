import 'dart:io';
import 'dart:typed_data';

import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/features/records/data/local_day_record_store.dart';
import 'package:habit_checkin/features/records/data/record_photo.dart';
import 'package:habit_checkin/features/records/data/record_photo_files.dart';
import 'package:habit_checkin/features/records/data/record_photo_picker.dart';
import 'package:uuid/uuid.dart';

class MemoryRecordPhotoFiles extends RecordPhotoFiles {
  MemoryRecordPhotoFiles()
    : super(Directory('/unused-test-record-photos'), 'guest');
  final entries = <String, Uint8List>{};

  @override
  Future<RecordPhotoInput> write(SanitizedRecordPhoto photo) async {
    final id = const Uuid().v4();
    entries[id] = photo.bytes;
    return RecordPhotoInput(
      id: id,
      width: photo.width,
      height: photo.height,
      byteCount: photo.bytes.length,
      sha256: photo.sha256,
    );
  }

  @override
  Future<Uint8List> read(StoredRecordPhoto photo) async => entries[photo.id]!;

  @override
  Future<void> remove(String id) async {
    entries.remove(id);
  }

  @override
  Future<void> clean(LocalDayRecordStore store) =>
      store.cleanDetachedPhotos((photo) => remove(photo.id));
}

class StubRecordPhotoPicker extends RecordPhotoPicker {
  Future<Uint8List?> Function()? onPick;
  int calls = 0;

  @override
  Future<Uint8List?> pick(RecordPhotoSource source) async {
    calls++;
    return onPick?.call();
  }
}
