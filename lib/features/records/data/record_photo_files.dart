import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../../data/local/app_database.dart';
import '../../../data/sync/sync_identity.dart';
import 'local_day_record_store.dart';
import 'record_photo.dart';

class RecordPhotoFiles {
  RecordPhotoFiles(Directory root, this.owner)
    : directory = Directory(
        p.join(root.path, crypto.sha256.convert(utf8.encode(owner)).toString()),
      ) {
    if (SyncIdentity.tryParse(owner) == null) {
      throw ArgumentError('Invalid photo owner');
    }
  }

  final String owner;
  final Directory directory;

  File _file(String id) {
    if (!SyncIdentity.isUuid(id)) throw const RecordPhotoException('照片标识无效');
    return File(p.join(directory.path, '$id.jpg'));
  }

  Future<RecordPhotoInput> write(SanitizedRecordPhoto photo) async {
    final id = const Uuid().v4();
    final input = RecordPhotoInput(
      id: id,
      width: photo.width,
      height: photo.height,
      byteCount: photo.bytes.length,
      sha256: photo.sha256,
    );
    input.validate();
    await directory.create(recursive: true);
    final target = _file(id);
    final temporary = File('${target.path}.part');
    try {
      await temporary.writeAsBytes(photo.bytes, flush: true);
      await temporary.rename(target.path);
      return input;
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<Uint8List> read(StoredRecordPhoto photo) => readVerified(
    id: photo.id,
    photoOwner: photo.owner,
    filename: photo.filename,
    byteCount: photo.byteCount,
    sha256: photo.sha256,
  );

  Future<Uint8List> readVerified({
    required String id,
    required String photoOwner,
    required String filename,
    required int byteCount,
    required String sha256,
  }) async {
    if (photoOwner != owner || filename != '$id.jpg') {
      throw const RecordPhotoException('照片不属于当前身份');
    }
    final file = _file(id);
    if (byteCount < 1 ||
        byteCount > maxRecordPhotoBytes ||
        await file.length() != byteCount) {
      throw const RecordPhotoException('照片文件不完整');
    }
    final bytes = await file.readAsBytes();
    if (bytes.length != byteCount ||
        crypto.sha256.convert(bytes).toString() != sha256) {
      throw const RecordPhotoException('照片文件不完整');
    }
    return bytes;
  }

  Future<void> remove(String id) async {
    final file = _file(id);
    if (await file.exists()) await file.delete();
  }

  Future<void> clean(LocalDayRecordStore store) async {
    if (store.owner != owner) throw const RecordPhotoException('照片不属于当前身份');
    await store.cleanDetachedPhotos((photo) => remove(photo.id));
    final retained = (await store.photoFilenames()).toSet();
    if (!await directory.exists()) return;
    // A crash can leave an unregistered file. The grace period protects imports
    // in progress in another editor; referenced files are never age-deleted.
    final cutoff = DateTime.now().subtract(const Duration(days: 1));
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
