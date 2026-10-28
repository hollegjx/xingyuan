import 'dart:io';
import 'dart:typed_data';

import 'package:habit_checkin/features/journal/data/journal_photo_files.dart';
import 'package:habit_checkin/features/journal/data/local_journal_store.dart';
import 'package:habit_checkin/features/journal/domain/journal_entry.dart';
import 'package:habit_checkin/features/records/data/local_day_record_store.dart';
import 'package:habit_checkin/features/records/data/record_photo.dart';
import 'package:uuid/uuid.dart';

Future<void> saveJournalNotes(
  LocalQuickNoteStore store,
  Iterable<String> texts,
) async {
  for (final text in texts) {
    var row = await store.beginDraft();
    row = await store.writeDraft(
      row.entry.id,
      content: text,
      expectedDraftRevision: row.entry.draftRevision,
    );
    await store.save(
      row.entry.id,
      operationId: const Uuid().v4(),
      expectedRevision: row.entry.revision,
      expectedDraftRevision: row.entry.draftRevision,
    );
  }
}

class MemoryJournalPhotoFiles extends JournalPhotoFiles {
  MemoryJournalPhotoFiles(JournalKind kind)
    : super(Directory('/unused-synthetic-journal'), 'guest', kind);

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
  Future<Uint8List> read(JournalPhoto photo) async => entries[photo.id]!;

  @override
  Future<void> remove(String id) async {
    entries.remove(id);
  }

  @override
  Future<void> clean(LocalJournalStore store) =>
      store.cleanDetachedPhotos((photo) => remove(photo.id));
}
