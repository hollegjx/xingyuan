import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';
import 'package:xingyuan_core/xingyuan_core.dart' show companionPhotoByteLimit;

export 'package:xingyuan_core/xingyuan_core.dart' show companionPhotoByteLimit;

class ObjectStoreFailure implements Exception {
  const ObjectStoreFailure(this.code);
  final String code;
}

abstract interface class ObjectStore {
  Future<void> put(String key, Uint8List bytes);
  Future<Uint8List?> read(String key);
  Future<void> delete(String key);
  Future<List<String>> keys({bool includePending = false});
}

class DiskObjectStore implements ObjectStore {
  DiskObjectStore._(this.directory);
  final String directory;
  final Map<String, Future<void>> _pending = {};
  static const _format = 'xingyuan.objects.v1';
  static const _marker = '.xingyuan-object-store.json';
  static final _uuid = RegExp(
    r'^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$',
  );

  static Future<DiskObjectStore> openExisting(String path) async {
    final root = Directory(path);
    if (!root.isAbsolute ||
        root.parent.path == root.path ||
        await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.directory) {
      throw const ObjectStoreFailure('invalid_directory');
    }
    final store = DiskObjectStore._(await root.resolveSymbolicLinks());
    await store._guard();
    return store;
  }

  static Future<DiskObjectStore> open(String path) async {
    final root = Directory(path);
    if (!root.isAbsolute || root.parent.path == root.path) {
      throw const ObjectStoreFailure('invalid_directory');
    }
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      await root.create(recursive: true);
    } else if (type != FileSystemEntityType.directory) {
      throw const ObjectStoreFailure('invalid_directory');
    }
    final resolved = await root.resolveSymbolicLinks();
    final store = DiskObjectStore._(resolved);
    final marker = File('$resolved/$_marker');
    if (await FileSystemEntity.type(marker.path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      if (!await root.list(followLinks: false).isEmpty) {
        throw const ObjectStoreFailure('unrecognized_directory');
      }
      await marker.create(exclusive: true);
      await marker.writeAsString(jsonEncode({'format': _format}), flush: true);
    }
    await store._guard();
    final permissions = await Process.run('chmod', ['700', resolved]);
    if (permissions.exitCode != 0) {
      throw const ObjectStoreFailure('directory_permissions');
    }
    return store;
  }

  Future<void> _guard() async {
    if (await FileSystemEntity.type(directory, followLinks: false) !=
            FileSystemEntityType.directory ||
        await Directory(directory).resolveSymbolicLinks() != directory) {
      throw const ObjectStoreFailure('invalid_directory');
    }
    final marker = File('$directory/$_marker');
    if (await FileSystemEntity.type(marker.path, followLinks: false) !=
            FileSystemEntityType.file ||
        await marker.length() > 1024) {
      throw const ObjectStoreFailure('invalid_store_marker');
    }
    try {
      final value = jsonDecode(await marker.readAsString());
      if (value is! Map || value.length != 1 || value['format'] != _format) {
        throw const ObjectStoreFailure('invalid_store_marker');
      }
    } on FormatException {
      throw const ObjectStoreFailure('invalid_store_marker');
    }
  }

  String _path(String key) {
    if (!_uuid.hasMatch(key)) {
      throw const ObjectStoreFailure('invalid_object_key');
    }
    return '$directory/$key.jpg';
  }

  Future<T> _serialized<T>(String key, Future<T> Function() action) async {
    _path(key);
    final previous = _pending[key];
    final result = () async {
      if (previous != null) await previous;
      return action();
    }();
    final settled = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    _pending[key] = settled;
    try {
      return await result;
    } finally {
      if (identical(_pending[key], settled)) _pending.remove(key);
    }
  }

  Future<Uint8List?> _read(String key) async {
    final path = _path(key);
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file) {
      throw const ObjectStoreFailure('invalid_object_file');
    }
    final file = File(path);
    if (await file.length() > companionPhotoByteLimit) {
      throw const ObjectStoreFailure('object_too_large');
    }
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty || bytes.length > companionPhotoByteLimit) {
      throw const ObjectStoreFailure('invalid_object_file');
    }
    return bytes;
  }

  @override
  Future<Uint8List?> read(String key) => _serialized(key, () async {
    await _guard();
    return _read(key);
  });

  @override
  Future<void> put(String key, Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > companionPhotoByteLimit) {
      return Future.error(const ObjectStoreFailure('object_too_large'));
    }
    final frozen = Uint8List.fromList(bytes);
    return _serialized(key, () async {
      await _guard();
      final existing = await _read(key);
      if (existing != null) {
        if (sha256.convert(existing) != sha256.convert(frozen)) {
          throw const ObjectStoreFailure('object_conflict');
        }
        return;
      }
      final temporary = File('$directory/.pending-$key-${const Uuid().v4()}');
      try {
        await temporary.create(exclusive: true);
        await temporary.writeAsBytes(frozen, flush: true);
        final permissions = await Process.run('chmod', ['600', temporary.path]);
        if (permissions.exitCode != 0) {
          throw const ObjectStoreFailure('object_permissions');
        }
        await _guard();
        if (await FileSystemEntity.type(_path(key), followLinks: false) !=
            FileSystemEntityType.notFound) {
          throw const ObjectStoreFailure('object_conflict');
        }
        await temporary.rename(_path(key));
      } finally {
        if (await FileSystemEntity.type(temporary.path, followLinks: false) ==
            FileSystemEntityType.file) {
          await temporary.delete();
        }
      }
    });
  }

  @override
  Future<void> delete(String key) => _serialized(key, () async {
    await _guard();
    final path = _path(key);
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.file) {
      await File(path).delete();
    } else if (type != FileSystemEntityType.notFound) {
      throw const ObjectStoreFailure('invalid_object_file');
    }
    await for (final entry in Directory(directory).list(followLinks: false)) {
      if (entry.path.startsWith('$directory/.pending-$key-')) {
        if (entry is! File) {
          throw const ObjectStoreFailure('invalid_object_file');
        }
        await entry.delete();
      }
    }
  });

  @override
  Future<List<String>> keys({bool includePending = false}) async {
    await _guard();
    final result = <String>{};
    await for (final entry in Directory(directory).list(followLinks: false)) {
      final name = entry.path.substring(directory.length + 1);
      if (name == _marker) continue;
      if (name.startsWith('.pending-')) {
        final suffix = name.substring('.pending-'.length);
        if (entry is! File || suffix.length != 73 || suffix[36] != '-') {
          throw const ObjectStoreFailure('invalid_object_file');
        }
        final key = suffix.substring(0, 36);
        _path(key);
        _path(suffix.substring(37));
        if (includePending) result.add(key);
        continue;
      }
      if (entry is! File || !name.endsWith('.jpg')) {
        throw const ObjectStoreFailure('invalid_object_file');
      }
      final key = name.substring(0, name.length - 4);
      _path(key);
      result.add(key);
    }
    return result.toList()..sort();
  }
}
