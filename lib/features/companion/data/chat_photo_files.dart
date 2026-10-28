import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../../data/local/app_database.dart';
import '../../../data/sync/sync_identity.dart';
import '../../records/data/record_photo.dart';
import 'companion_service.dart';
import 'local_chat_store.dart';

class ChatPhotoFiles {
  ChatPhotoFiles(this.root, this.db);
  final Directory root;
  final AppDatabase db;
  Future<void> _tail = Future.value();
  StreamSubscription<List<StoredChatPhoto>>? _retired;
  bool _disposed = false;

  Future<T> _serial<T>(Future<T> Function() work) {
    final result = _tail.then((_) => work());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> _directory(String path, {bool create = false}) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound && create) {
      await Directory(path).create();
    } else if (type != FileSystemEntityType.directory) {
      throw const CompanionServiceFailure('photo_unavailable');
    }
  }

  Future<File> _file(
    String owner,
    String session,
    String id, {
    bool create = false,
  }) async {
    if (SyncIdentity.tryParse(owner) == null ||
        !SyncIdentity.isUuid(session) ||
        !SyncIdentity.isUuid(id)) {
      throw const CompanionServiceFailure('photo_unavailable');
    }
    await _directory(root.path, create: create);
    final owned = p.join(
      root.path,
      crypto.sha256.convert(utf8.encode(owner)).toString(),
    );
    await _directory(owned, create: create);
    final scoped = p.join(owned, session);
    await _directory(scoped, create: create);
    final target = File(p.join(scoped, '$id.jpg'));
    final type = await FileSystemEntity.type(target.path, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.file) {
      throw const CompanionServiceFailure('photo_unavailable');
    }
    return target;
  }

  Future<ChatPhotoInput> write(
    LocalChatStore store,
    SanitizedRecordPhoto photo,
  ) => _serial(() async {
    if (!await store.isCurrent()) {
      throw const CompanionServiceFailure('discarded');
    }
    final input = ChatPhotoInput(
      id: const Uuid().v4(),
      owner: store.owner,
      sessionId: store.sessionId,
      width: photo.width,
      height: photo.height,
      byteCount: photo.bytes.length,
      sha256: photo.sha256,
    );
    input.validate();
    final file = await _file(
      input.owner,
      input.sessionId,
      input.id,
      create: true,
    );
    final partial = File('${file.path}.part');
    if (await file.exists() || await partial.exists()) {
      throw const CompanionServiceFailure('operation_conflict');
    }
    try {
      await partial.writeAsBytes(photo.bytes, flush: true);
      if (!await store.isCurrent()) {
        throw const CompanionServiceFailure('discarded');
      }
      await partial.rename(file.path);
      if (!await store.isCurrent()) {
        await file.delete();
        throw const CompanionServiceFailure('discarded');
      }
      return input;
    } finally {
      if (await partial.exists()) await partial.delete();
    }
  });

  Future<Uint8List> read(LocalChatStore store, String id) => _serial(() async {
    final row = await store.photo(id);
    final file = await _file(row.owner, row.sessionId, row.id);
    final bytes = await file.readAsBytes();
    if (bytes.length != row.byteCount ||
        crypto.sha256.convert(bytes).toString() != row.sha256) {
      throw const CompanionServiceFailure('photo_unavailable');
    }
    await store.photo(id);
    return bytes;
  });

  Future<void> removeUnregistered(ChatPhotoInput input) => _serial(() async {
    input.validate();
    final registered = await (db.select(
      db.chatPhotos,
    )..where((r) => r.id.equals(input.id))).getSingleOrNull();
    if (registered != null) return;
    final file = await _file(input.owner, input.sessionId, input.id);
    if (!await file.exists()) return;
    if (crypto.sha256.convert(await file.readAsBytes()).toString() ==
        input.sha256) {
      await file.delete();
    }
  });

  Future<void> startCleanup() async {
    if (_disposed) return;
    await sweep();
    if (_disposed) return;
    _retired ??=
        (db.select(
          db.chatPhotos,
        )..where((r) => r.retired.equals(true))).watch().listen((rows) {
          if (rows.isNotEmpty) unawaited(sweep().catchError((Object _) {}));
        }, onError: (Object _) {});
  }

  Future<void> sweep() => _serial(() async {
    final retired = await (db.select(
      db.chatPhotos,
    )..where((r) => r.retired.equals(true))).get();
    for (final row in retired) {
      try {
        // Missing directories mean the file is already removed; links are never followed.
        final ownerPath = p.join(
          root.path,
          crypto.sha256.convert(utf8.encode(row.owner)).toString(),
        );
        final scopePath = p.join(ownerPath, row.sessionId);
        var missing = false;
        for (final dir in [root.path, ownerPath, scopePath]) {
          final type = await FileSystemEntity.type(dir, followLinks: false);
          if (type == FileSystemEntityType.notFound) {
            missing = true;
            break;
          }
          if (type != FileSystemEntityType.directory) {
            throw const CompanionServiceFailure('photo_unavailable');
          }
        }
        if (!missing) {
          final file = await _file(row.owner, row.sessionId, row.id);
          if (await file.exists()) await file.delete();
          final part = '${file.path}.part';
          if (await FileSystemEntity.type(part, followLinks: false) ==
              FileSystemEntityType.file) {
            await File(part).delete();
          }
        }
        await (db.delete(db.chatPhotos)..where(
              (r) =>
                  r.id.equals(row.id) &
                  r.owner.equals(row.owner) &
                  r.sessionId.equals(row.sessionId) &
                  r.retired.equals(true),
            ))
            .go();
      } on FileSystemException {
        continue;
      } on CompanionServiceFailure {
        continue;
      }
    }
    await _orphanFiles();
  });

  Future<void> _orphanFiles() async {
    if (await FileSystemEntity.type(root.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return;
    }
    final rows = await db.select(db.chatPhotos).get();
    final retained = {
      for (final row in rows)
        p.join(
          crypto.sha256.convert(utf8.encode(row.owner)).toString(),
          row.sessionId,
          '${row.id}.jpg',
        ),
    };
    final cutoff = DateTime.now().subtract(const Duration(days: 1));
    await for (final owned in root.list(followLinks: false)) {
      if (owned is! Directory ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(p.basename(owned.path))) {
        continue;
      }
      await for (final session in owned.list(followLinks: false)) {
        if (session is! Directory ||
            !SyncIdentity.isUuid(p.basename(session.path))) {
          continue;
        }
        await for (final file in session.list(followLinks: false)) {
          if (file is! File ||
              !RegExp(r'^[a-f0-9-]{36}\.jpg(?:\.part)?$')
                  .hasMatch(p.basename(file.path))) {
            continue;
          }
          final relative = p.relative(file.path, from: root.path);
          final base = relative.endsWith('.part')
              ? relative.substring(0, relative.length - 5)
              : relative;
          if (retained.contains(base) ||
              !(await file.stat()).modified.isBefore(cutoff)) {
            continue;
          }
          await file.delete();
        }
      }
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    final retired = _retired;
    _retired = null;
    await retired?.cancel();
    await _tail;
  }
}
