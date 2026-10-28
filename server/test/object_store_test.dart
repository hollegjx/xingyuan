import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'package:xingyuan_server/src/object_store.dart';

void main() {
  late Directory directory;
  late DiskObjectStore store;
  String id() => const Uuid().v4();
  Matcher failure(String code) =>
      isA<ObjectStoreFailure>().having((e) => e.code, 'code', code);
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('companion-objects-');
    store = await DiskObjectStore.open('${directory.path}/photos');
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test('immutable writes reads listing and deletion survive reopen', () async {
    final key = id();
    final bytes = Uint8List.fromList([1, 2, 3]);
    await store.put(key, bytes);
    await store.put(key, bytes);
    expect(await store.read(key), bytes);
    expect(await store.keys(), [key]);
    store = await DiskObjectStore.open('${directory.path}/photos');
    expect(await store.read(key), bytes);
    final rootStat = await Directory(store.directory).stat();
    final fileStat = await File('${store.directory}/$key.jpg').stat();
    expect(rootStat.mode & 0x1ff, 0x1c0);
    expect(fileStat.mode & 0x1ff, 0x180);
    await expectLater(
      store.put(key, Uint8List.fromList([4])),
      throwsA(failure('object_conflict')),
    );
    expect(await store.read(key), bytes);
    await store.delete(key);
    await store.delete(key);
    expect(await store.read(key), isNull);
    expect(await store.keys(), isEmpty);
  });

  test('concurrent writes to the same immutable key never overwrite', () async {
    final key = id();
    final bytes = Uint8List.fromList([1, 2, 3]);
    await Future.wait(List.generate(5, (_) => store.put(key, bytes)));
    expect(await store.keys(), [key]);
    final outcomes = await Future.wait(
      [4, 5].map((v) async {
        try {
          await store.put(key, Uint8List.fromList([v]));
          return 'unexpected';
        } on ObjectStoreFailure catch (e) {
          return e.code;
        }
      }),
    );
    expect(outcomes, everyElement('object_conflict'));
    expect(await store.read(key), bytes);
    expect(
      (await Directory(
        store.directory,
      ).list().toList()).where((f) => f.path.contains('.pending-')),
      isEmpty,
    );
  });

  test('caller mutation cannot alter a queued write', () async {
    final bytes = Uint8List.fromList([1, 2, 3]);
    final key = id();
    final pending = store.put(key, bytes);
    bytes.fillRange(0, bytes.length, 9);
    await pending;
    expect(await store.read(key), [1, 2, 3]);
  });

  test(
    'invalid paths sizes and symlinks never touch an outside file',
    () async {
      final outside = File('${directory.path}/outside');
      await outside.writeAsString('SYNTHETIC keep');
      for (final key in [
        '../outside',
        '/outside',
        id().toUpperCase(),
        'not-a-key',
      ]) {
        await expectLater(
          store.put(key, Uint8List.fromList([1])),
          throwsA(failure('invalid_object_key')),
        );
        await expectLater(
          store.read(key),
          throwsA(failure('invalid_object_key')),
        );
        await expectLater(
          store.delete(key),
          throwsA(failure('invalid_object_key')),
        );
      }
      await expectLater(
        store.put(id(), Uint8List(0)),
        throwsA(failure('object_too_large')),
      );
      await expectLater(
        store.put(id(), Uint8List(companionPhotoByteLimit + 1)),
        throwsA(failure('object_too_large')),
      );
      final key = id();
      await Link('${store.directory}/$key.jpg').create(outside.path);
      await expectLater(
        store.read(key),
        throwsA(failure('invalid_object_file')),
      );
      await expectLater(
        store.put(key, Uint8List.fromList([1])),
        throwsA(failure('invalid_object_file')),
      );
      await expectLater(
        store.delete(key),
        throwsA(failure('invalid_object_file')),
      );
      await expectLater(store.keys(), throwsA(failure('invalid_object_file')));
      expect(await outside.readAsString(), 'SYNTHETIC keep');
    },
  );

  test(
    'unrecognized directory and root symlink are not adopted or modified',
    () async {
      final unknown = await Directory('${directory.path}/unknown').create();
      final file = File('${unknown.path}/owner-data');
      await file.writeAsString('SYNTHETIC keep');
      await expectLater(
        DiskObjectStore.open(unknown.path),
        throwsA(failure('unrecognized_directory')),
      );
      expect(await file.readAsString(), 'SYNTHETIC keep');
      final alias = Link('${directory.path}/alias');
      await alias.create(store.directory);
      await expectLater(
        DiskObjectStore.open(alias.path),
        throwsA(failure('invalid_directory')),
      );
      await expectLater(
        DiskObjectStore.open('relative/path'),
        throwsA(failure('invalid_directory')),
      );
    },
  );

  test('replaced marker blocks later operations; unfinished own uploads can be removed', () async {
    final key = id();
    final pending = File('${store.directory}/.pending-$key-${id()}');
    await pending.writeAsString('SYNTHETIC unfinished');
    expect(await store.keys(), isEmpty);
    await store.delete(key);
    expect(await pending.exists(), false);
    final marker = File('${store.directory}/.xingyuan-object-store.json');
    await marker.writeAsString('{"format":"different"}');
    await expectLater(
      store.put(id(), Uint8List.fromList([1])),
      throwsA(failure('invalid_store_marker')),
    );
    await expectLater(store.keys(), throwsA(failure('invalid_store_marker')));
  });

  test('oversized existing objects are rejected without loading them as valid data', () async {
    final key = id();
    final file = File('${store.directory}/$key.jpg');
    await file.writeAsBytes(Uint8List(companionPhotoByteLimit + 1));
    await expectLater(store.read(key), throwsA(failure('object_too_large')));
    expect(await file.length(), companionPhotoByteLimit + 1);
    await store.delete(key);
    expect(await store.keys(), isEmpty);
  });
}
