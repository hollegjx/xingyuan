import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import 'object_store.dart';

class CompanionBackupFailure implements Exception {
  const CompanionBackupFailure(this.code);
  final String code;
}

const _rootMarker = '.xingyuan-backups.json';
const _rootFormat = 'xingyuan.backups.v1';
const _snapshotFormat = 'xingyuan.snapshot.v1';
final _snapshotPattern = RegExp(
  r'^snapshot-[0-9]{20}-[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$',
);

void _require(bool value, String code) {
  if (!value) throw CompanionBackupFailure(code);
}

Future<void> _type(String path, FileSystemEntityType expected) async =>
    _require(
      await FileSystemEntity.type(path, followLinks: false) == expected,
      'unexpected_file_type',
    );

Future<void> _permissions(String path, String mode) async {
  final result = await Process.run('chmod', [mode, path]);
  _require(result.exitCode == 0, 'private_permissions');
}

Future<Map<String, dynamic>> _json(String path) async {
  await _type(path, FileSystemEntityType.file);
  final file = File(path);
  _require(await file.length() <= 16 * 1024 * 1024, 'manifest_size');
  final value = jsonDecode(await file.readAsString());
  _require(value is Map<String, dynamic>, 'invalid_manifest');
  return value as Map<String, dynamic>;
}

Future<void> _writeJson(String path, Object value) async {
  final file = File(path);
  await file.create(exclusive: true);
  await _permissions(path, '600');
  await file.writeAsString(jsonEncode(value), flush: true);
}

Future<Map<String, Object>> _fileDigest(String path) async {
  await _type(path, FileSystemEntityType.file);
  final file = File(path);
  return {
    'bytes': await file.length(),
    'sha256': (await sha256.bind(file.openRead()).first).toString(),
  };
}

void _database(Database db) {
  _require(
    db.userVersion == 4 &&
        db.select('PRAGMA application_id').single.values.single == 1481065296,
    'unsupported_database',
  );
  _require(
    db.select('PRAGMA integrity_check').single.values.single == 'ok' &&
        db.select('PRAGMA foreign_key_check').isEmpty,
    'database_integrity',
  );
}

List<Map<String, Object?>> _photos(Database db) => db
    .select(
      "SELECT id,sha256,byte_count,width,height FROM companion_photos WHERE status='ready' ORDER BY id",
    )
    .map((row) => Map<String, Object?>.from(row))
    .toList();

Future<void> _standalone(String path) async {
  await _type(path, FileSystemEntityType.file);
  for (final suffix in ['-wal', '-shm', '-journal']) {
    await _type('$path$suffix', FileSystemEntityType.notFound);
  }
}

String _name(int sequence, String id) =>
    'snapshot-${sequence.toString().padLeft(20, '0')}-$id';

class BackupSnapshot {
  const BackupSnapshot(
    this.name,
    this.sequence,
    this.createdAt,
    this.photoCount,
  );
  final String name;
  final int sequence;
  final DateTime createdAt;
  final int photoCount;

  Map<String, Object> toJson() => {
    'snapshot': name,
    'sequence': sequence,
    'created_at': createdAt.toIso8601String(),
    'photos': photoCount,
  };
}

/// A private collection, never a web root. It contains no credential registry.
class CompanionBackups {
  CompanionBackups._(this.directory);
  final String directory;
  static final Set<String> _busy = {};
  static const retention = 7;

  static Future<CompanionBackups> open(String path) async {
    final root = Directory(path);
    _require(root.isAbsolute && root.parent.path != root.path, 'invalid_root');
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      await root.create(recursive: true);
    } else {
      _require(type == FileSystemEntityType.directory, 'invalid_root');
    }
    final resolved = await root.resolveSymbolicLinks();
    final marker = '$resolved/$_rootMarker';
    if (await FileSystemEntity.type(marker, followLinks: false) ==
        FileSystemEntityType.notFound) {
      _require(await root.list(followLinks: false).isEmpty, 'unknown_root');
      await _permissions(resolved, '700');
      await _writeJson(marker, {'format': _rootFormat});
    }
    final result = CompanionBackups._(resolved);
    await result._guard();
    await _permissions(resolved, '700');
    return result;
  }

  Future<void> _guard() async {
    await _type(directory, FileSystemEntityType.directory);
    _require(
      await Directory(directory).resolveSymbolicLinks() == directory,
      'root_changed',
    );
    final marker = await _json('$directory/$_rootMarker');
    _require(
      marker.length == 1 && marker['format'] == _rootFormat,
      'unknown_root',
    );
  }

  Future<T> _locked<T>(Future<T> Function() action) async {
    _require(_busy.add(directory), 'backup_busy');
    RandomAccessFile? lock;
    try {
      await _guard();
      final file = File('$directory/.lock');
      final type = await FileSystemEntity.type(file.path, followLinks: false);
      _require(
        type == FileSystemEntityType.notFound ||
            type == FileSystemEntityType.file,
        'invalid_lock',
      );
      lock = await file.open(mode: FileMode.append);
      await _permissions(file.path, '600');
      await lock.lock();
      return await action();
    } finally {
      await lock?.close();
      _busy.remove(directory);
    }
  }

  Future<BackupSnapshot> create({
    required String database,
    required ObjectStore objects,
    DateTime? now,
  }) => _locked(() async {
    final previous = await _list();
    final sequence = previous.isEmpty ? 1 : previous.first.sequence + 1;
    _require(sequence > 0, 'sequence_exhausted');
    await _type(database, FileSystemEntityType.file);
    _require(File(database).isAbsolute, 'invalid_source');
    final resolved = await File(database).resolveSymbolicLinks();
    _require(!resolved.startsWith('$directory/'), 'source_inside_backups');
    for (final suffix in ['-wal', '-shm', '-journal']) {
      final type = await FileSystemEntity.type(
        '$resolved$suffix',
        followLinks: false,
      );
      _require(
        type == FileSystemEntityType.notFound ||
            type == FileSystemEntityType.file,
        'invalid_source_sidecar',
      );
    }
    // A disappearing immutable photo invalidates this snapshot, not the last
    // good backup. Retry from a new DB snapshot, never mix snapshot generations.
    for (var attempt = 0; attempt < 3; attempt++) {
      final staging = await Directory(directory).createTemp('.building-');
      await _permissions(staging.path, '700');
      try {
        final target = '${staging.path}/data.db';
        final source = sqlite3.open(resolved, mode: OpenMode.readOnly);
        try {
          source.execute('PRAGMA busy_timeout=5000');
          _database(source);
          final copy = sqlite3.open(target);
          try {
            await source.backup(copy, nPage: 128).drain<void>();
            _database(copy);
            copy.execute('PRAGMA journal_mode=DELETE');
          } finally {
            copy.close();
          }
        } finally {
          source.close();
        }
        await _permissions(target, '600');
        await _standalone(target);
        final db = sqlite3.open(target, mode: OpenMode.readOnly);
        late List<Map<String, Object?>> photos;
        try {
          photos = _photos(db);
        } finally {
          db.close();
        }
        final destination = await DiskObjectStore.open(
          '${staging.path}/objects',
        );
        var disappeared = false;
        for (final photo in photos) {
          final bytes = await objects.read(photo['id'] as String);
          if (bytes == null) {
            disappeared = true;
            break;
          }
          _require(
            bytes.length == photo['byte_count'] &&
                sha256.convert(bytes).toString() == photo['sha256'],
            'source_photo_integrity',
          );
          await destination.put(photo['id'] as String, bytes);
        }
        if (disappeared) continue;
        final instant = (now ?? DateTime.now()).toUtc();
        final id = const Uuid().v4();
        final name = _name(sequence, id);
        _require(_snapshotPattern.hasMatch(name), 'invalid_snapshot_name');
        await _writeJson('${staging.path}/manifest.json', {
          'format': _snapshotFormat,
          'id': id,
          'sequence': sequence,
          'created_at': instant.toIso8601String(),
          'database': await _fileDigest(target),
          'photos': photos,
        });
        final verified = await _verify(staging.path, name);
        await _guard();
        await _type('$directory/$name', FileSystemEntityType.notFound);
        await staging.rename('$directory/$name');
        await _prune();
        return verified;
      } finally {
        if (await staging.exists()) await staging.delete(recursive: true);
      }
    }
    throw const CompanionBackupFailure('snapshot_changed');
  });

  Future<BackupSnapshot> verify(String name) => _locked(() => _named(name));

  Future<BackupSnapshot> _named(String name) async {
    _require(_snapshotPattern.hasMatch(name), 'invalid_snapshot_name');
    return _verify('$directory/$name', name);
  }

  Future<List<BackupSnapshot>> list() => _locked(_list);

  Future<List<BackupSnapshot>> _list() async {
    final result = <BackupSnapshot>[];
    await for (final entry in Directory(directory).list(followLinks: false)) {
      final name = entry.path.substring(directory.length + 1);
      if (!_snapshotPattern.hasMatch(name)) continue;
      // Refuse retention if a recognized snapshot is damaged. Never delete it
      // or reduce the good copies on the strength of an unverified entry.
      result.add(await _named(name));
    }
    _require(
      result.map((snapshot) => snapshot.sequence).toSet().length ==
          result.length,
      'duplicate_sequence',
    );
    result.sort((a, b) => b.sequence.compareTo(a.sequence));
    return result;
  }

  Future<void> _prune() async {
    final valid = await _list();
    for (final snapshot in valid.skip(retention)) {
      await _named(snapshot.name);
      final path = '$directory/${snapshot.name}';
      final photos = await Directory('$path/objects')
          .list(followLinks: false)
          .toList();
      for (final file in photos) {
        await _type(file.path, FileSystemEntityType.file);
        await file.delete();
      }
      await Directory('$path/objects').delete();
      await File('$path/data.db').delete();
      await File('$path/manifest.json').delete();
      await Directory(path).delete();
    }
  }

  Future<BackupSnapshot> restore(String name, String destination) => _locked(
    () async {
      final snapshot = await _named(name);
      final target = Directory(destination);
      _require(
        target.isAbsolute && target.parent.existsSync(),
        'invalid_restore_path',
      );
      await _type(destination, FileSystemEntityType.notFound);
      final parent = await target.parent.resolveSymbolicLinks();
      _require(
        parent != directory && !parent.startsWith('$directory/'),
        'restore_inside_backups',
      );
      final staging = await Directory(parent).createTemp('.xingyuan-restore-');
      await _permissions(staging.path, '700');
      try {
        final source = '$directory/$name';
        for (final file in ['data.db', 'manifest.json']) {
          await File('$source/$file').copy('${staging.path}/$file');
          await _permissions('${staging.path}/$file', '600');
        }
        final objects = await DiskObjectStore.openExisting('$source/objects');
        final copied = await DiskObjectStore.open('${staging.path}/objects');
        for (final key in await objects.keys()) {
          final bytes = await objects.read(key);
          _require(bytes != null, 'snapshot_changed');
          await copied.put(key, bytes!);
        }
        await _verify(staging.path, name);
        await _type(destination, FileSystemEntityType.notFound);
        final reserved = await Process.run('mkdir', ['-m', '700', destination]);
        _require(reserved.exitCode == 0, 'restore_destination_exists');
        // mkdir reserves the previously absent name atomically. rename may only
        // replace our empty directory, never a pre-existing destination.
        await staging.rename(destination);
        return snapshot;
      } finally {
        if (await staging.exists()) await staging.delete(recursive: true);
      }
    },
  );

  Future<BackupSnapshot> export(String name, IOSink output) =>
      _locked(() async {
        final snapshot = await _named(name);
        final process = await Process.start('tar', [
          '-C',
          directory,
          '-czf',
          '-',
          _rootMarker,
          name,
        ]);
        final errors = process.stderr.drain<void>();
        try {
          await output.addStream(process.stdout);
          _require(await process.exitCode == 0, 'archive_failed');
          await errors;
          return snapshot;
        } catch (_) {
          process.kill(ProcessSignal.sigterm);
          await process.exitCode;
          await errors;
          rethrow;
        }
      });
}

Future<BackupSnapshot> _verify(String path, String name) async {
  await _type(path, FileSystemEntityType.directory);
  final entries = await Directory(path).list(followLinks: false).toList();
  final names = entries.map((e) => e.path.substring(path.length + 1)).toSet();
  _require(
    names.length == 3 &&
        names.containsAll(['data.db', 'manifest.json', 'objects']),
    'unexpected_snapshot_files',
  );
  final manifest = await _json('$path/manifest.json');
  _require(
    manifest.length == 6 && manifest['format'] == _snapshotFormat,
    'invalid_manifest',
  );
  final created = DateTime.parse(manifest['created_at'] as String);
  final sequence = manifest['sequence'];
  _require(
    sequence is int &&
        sequence > 0 &&
        created.isUtc &&
        _name(sequence, manifest['id'] as String) == name,
    'invalid_manifest',
  );
  await _standalone('$path/data.db');
  _require(
    jsonEncode(await _fileDigest('$path/data.db')) ==
        jsonEncode(manifest['database']),
    'database_digest',
  );
  final db = sqlite3.open('$path/data.db', mode: OpenMode.readOnly);
  late List<Map<String, Object?>> photos;
  try {
    _database(db);
    photos = _photos(db);
  } finally {
    db.close();
  }
  _require(
    jsonEncode(photos) == jsonEncode(manifest['photos']),
    'photo_manifest',
  );
  final objects = await DiskObjectStore.openExisting('$path/objects');
  final keys = await objects.keys();
  _require(
    jsonEncode(keys) == jsonEncode(photos.map((p) => p['id']).toList()),
    'photo_set',
  );
  final objectEntries = await Directory('$path/objects')
      .list(followLinks: false)
      .length;
  _require(objectEntries == photos.length + 1, 'unexpected_photo_files');
  for (final photo in photos) {
    final bytes = await objects.read(photo['id'] as String);
    _require(
      bytes != null &&
          bytes.length == photo['byte_count'] &&
          sha256.convert(bytes).toString() == photo['sha256'],
      'photo_digest',
    );
  }
  return BackupSnapshot(name, sequence as int, created, photos.length);
}
