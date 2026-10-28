import 'dart:io';

import 'package:drift/drift.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/features/companion/data/chat_photo_files.dart';
import 'package:habit_checkin/features/companion/data/local_chat_store.dart';
import 'package:habit_checkin/features/records/data/record_photo.dart';
import 'package:uuid/uuid.dart';

class MemoryChatPhotoFiles extends ChatPhotoFiles {
  MemoryChatPhotoFiles(AppDatabase db)
    : super(Directory('/unused-chat-test'), db);
  final entries = <String, Uint8List>{};
  int sweeps = 0;

  @override
  Future<ChatPhotoInput> write(
    LocalChatStore store,
    SanitizedRecordPhoto photo,
  ) async {
    final id = const Uuid().v4();
    entries[id] = photo.bytes;
    return ChatPhotoInput(
      id: id,
      owner: store.owner,
      sessionId: store.sessionId,
      width: photo.width,
      height: photo.height,
      byteCount: photo.bytes.length,
      sha256: photo.sha256,
    );
  }

  @override
  Future<Uint8List> read(LocalChatStore store, String id) async {
    await store.photo(id);
    return entries[id]!;
  }

  @override
  Future<void> removeUnregistered(ChatPhotoInput input) async {
    final row = await (db.select(
      db.chatPhotos,
    )..where((r) => r.id.equals(input.id))).getSingleOrNull();
    if (row == null) entries.remove(input.id);
  }

  @override
  Future<void> sweep() async {
    sweeps++;
    final rows = await (db.select(
      db.chatPhotos,
    )..where((r) => r.retired.equals(true))).get();
    for (final row in rows) {
      entries.remove(row.id);
      await (db.delete(
        db.chatPhotos,
      )..where((r) => r.id.equals(row.id) & r.retired.equals(true))).go();
    }
  }
}
