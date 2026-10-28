import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../records/data/local_day_record_store.dart';
import '../../records/data/record_photo.dart';
import '../../records/data/record_photo_files.dart';
import '../domain/journal_entry.dart';
import 'local_journal_store.dart';

class JournalPhotoFiles {
  JournalPhotoFiles(Directory root, String owner, this.kind)
    : _files = RecordPhotoFiles(
        Directory(p.join(root.path, kind.photoFolder)),
        owner,
      );

  final RecordPhotoFiles _files;
  final JournalKind kind;
  String get owner => _files.owner;
  Directory get directory => _files.directory;

  Future<RecordPhotoInput> write(SanitizedRecordPhoto photo) =>
      _files.write(photo);

  Future<Uint8List> read(JournalPhoto photo) => _files.readVerified(
    id: photo.id,
    photoOwner: photo.owner,
    filename: photo.filename,
    byteCount: photo.byteCount,
    sha256: photo.sha256,
  );

  Future<void> remove(String id) => _files.remove(id);

  Future<void> clean(LocalJournalStore store) async {
    if (store.owner != owner || store.kind != kind) {
      throw const RecordPhotoException('照片不属于当前内容');
    }
    await store.cleanDetachedPhotos((photo) => remove(photo.id));
    final retained = (await store.photoFilenames()).toSet();
    if (!await directory.exists()) return;
    final cutoff = store.goals.clock.read().instant.subtract(
      const Duration(days: 1),
    );
    // Never scan the day-record root: each feature owns its cleanup namespace.
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is! File) continue;
      final name = p.basename(entry.path);
      if (!RegExp(r'^[a-f0-9-]{36}\.jpg(?:\.part)?$').hasMatch(name) ||
          retained.contains(name) ||
          !(await entry.stat()).modified.isBefore(cutoff)) {
        continue;
      }
      await store.goals.requireActiveIdentity();
      await entry.delete();
    }
  }
}
