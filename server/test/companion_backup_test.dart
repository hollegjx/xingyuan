import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:xingyuan_core/xingyuan_core.dart';
import 'package:xingyuan_server/src/companion_backup.dart';
import 'package:xingyuan_server/src/companion_media.dart';
import 'package:xingyuan_server/src/companion_store.dart';
import 'package:xingyuan_server/src/object_store.dart';

import 'support/media_fixtures.dart';
import 'support/sharing_fixtures.dart';

class _ReadHook implements ObjectStore {
  _ReadHook(this.delegate, this.beforeRead);
  final ObjectStore delegate;
  final Future<void> Function(String) beforeRead;
  @override
  Future<Uint8List?> read(String key) async {
    await beforeRead(key);
    return delegate.read(key);
  }

  @override
  Future<void> put(String key, Uint8List bytes) => delegate.put(key, bytes);
  @override
  Future<void> delete(String key) => delegate.delete(key);
  @override
  Future<List<String>> keys({bool includePending = false}) =>
      delegate.keys(includePending: includePending);
}

Map<String, Object> dump(String file) {
  final db = sqlite3.open(file, mode: OpenMode.readOnly);
  try {
    return {
      for (final row in db.select(
        "SELECT name FROM sqlite_schema WHERE type='table' ORDER BY name",
      ))
        row['name'] as String:
            db
                .select('SELECT * FROM "${row['name']}"')
                .map((r) => jsonEncode(r.values.toList()))
                .toList()
              ..sort(),
    };
  } finally {
    db.close();
  }
}

void main() {
  late Directory directory;
  late String database;
  late CompanionStore store;
  late DiskObjectStore objects;
  late CompanionMedia media;
  late CompanionBackups backups;
  late String group;
  late DateTime now;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('companion-backup-');
    now = DateTime.utc(2026, 10, 21, 10);
    database = '${directory.path}/data.db';
    store = CompanionStore.open(database, now: () => now);
    objects = await DiskObjectStore.open('${directory.path}/objects');
    media = CompanionMedia(store, objects);
    backups = await CompanionBackups.open('${directory.path}/backups');
    group = pairForSharing(store);
  });
  tearDown(() async {
    store.close();
    await directory.delete(recursive: true);
  });

  Future<String> upload([String? grant]) async => (await media.upload(
    'qa-a',
    mediaUpload(group, grant),
    () async {},
  )).photo.id;
  Future<BackupSnapshot> create({ObjectStore? from, DateTime? time}) => backups
      .create(database: database, objects: from ?? objects, now: time ?? now);
  Matcher failure(String code) =>
      isA<CompanionBackupFailure>().having((e) => e.code, 'code', code);

  test('whole database and all ready photos restore; source and secrets stay separate', () async {
    final grant = store
        .executeSharing(
          'qa-a',
          shareCommand(SharingCommandKind.enable, group, {
            'goal_id': sharingId(),
          }),
        )
        .resourceId;
    final recordPhoto = await upload(grant);
    final publication = publishRecord(group, grant, now, photos: [recordPhoto]);
    final record = store.executeSharing('qa-a', publication).resourceId;
    store.executeSharing(
      'qa-b',
      shareCommand(SharingCommandKind.reply, group, {
        'record_id': record,
        'text': 'SYNTHETIC reply',
      }),
    );
    final chatPhoto = await upload();
    final chat = ChatCommand.fromJson(ChatCommandKind.send, {
      'protocol': companionProtocol,
      'group_id': group,
      'operation_id': sharingId(),
      'text': 'SYNTHETIC chat',
      'photo_id': chatPhoto,
    });
    final chatReceipt = store.executeChat('qa-a', chat);
    final stagedPhoto = await upload();
    final pending = mediaUpload(group, null);
    store.reservePhoto('qa-a', pending);
    final orphan = sharingId();
    await objects.put(orphan, (await objects.read(stagedPhoto))!);
    await File('${directory.path}/devices.json')
        .writeAsString('PRIVATE_TEST_CREDENTIAL_REGISTRY');
    final before = dump(database);
    final snapshot = await create();
    expect(snapshot.photoCount, 3);
    expect(dump(database), before);
    final destination = '${directory.path}/restored';
    await backups.restore(snapshot.name, destination);
    expect(dump('$destination/data.db'), before);
    expect(dump(database), before);
    final restoredObjects = await DiskObjectStore.openExisting(
      '$destination/objects',
    );
    expect((await restoredObjects.keys()).toSet(), {
      recordPhoto,
      chatPhoto,
      stagedPhoto,
    });
    expect(await restoredObjects.read(orphan), isNull);
    expect(await File('$destination/devices.json').exists(), isFalse);
    final restored = CompanionStore.open(
      '$destination/data.db',
      now: () => now,
    );
    try {
      expect(restored.executeSharing('qa-a', publication).resourceId, record);
      expect(restored.executeChat('qa-a', chat).toJson(), chatReceipt.toJson());
      final restoredMedia = CompanionMedia(restored, restoredObjects);
      final download = await restoredMedia.download(
        'qa-b',
        mediaRequest(group, chatPhoto),
        () async {},
      );
      expect(download.bytes, await objects.read(chatPhoto));
      final recovered = await restoredMedia.upload(
        'qa-a',
        pending,
        () async {},
      );
      expect(await restoredObjects.read(recovered.photo.id), isNotNull);
    } finally {
      restored.close();
    }
  });

  test(
    'nine successful daily runs retain seven and leave unknown files alone',
    () async {
      await upload();
      final unknown = await Directory('${backups.directory}/owner-notes')
          .create();
      await File('${unknown.path}/keep.txt').writeAsString('keep');
      final incomplete = await Directory(
        '${backups.directory}/.building-abandoned',
      ).create();
      await File('${incomplete.path}/keep.txt').writeAsString('keep');
      final names = <String>[];
      for (var day = 0; day < 9; day++) {
        names.add((await create(time: now.add(Duration(days: day)))).name);
      }
      expect(
        (await backups.list()).map((s) => s.name),
        names.skip(2).toList().reversed,
      );
      expect(
        await Directory('${backups.directory}/${names.first}').exists(),
        isFalse,
      );
      expect(await File('${unknown.path}/keep.txt').readAsString(), 'keep');
      expect(await File('${incomplete.path}/keep.txt').readAsString(), 'keep');
    },
  );

  test(
    'missing source photo retries a fresh snapshot after concurrent deletion',
    () async {
      final photo = await upload();
      var reads = 0;
      final hook = _ReadHook(objects, (key) async {
        if (reads++ != 0) return;
        store.removePhoto(
          'qa-a',
          mediaRequest(group, photo, operation: sharingId()),
        );
        await store.drainPhotoDeletions(objects);
      });
      final result = await create(from: hook);
      expect(result.photoCount, 0);
      expect((await backups.list()).length, 1);
      expect(
        dump('${backups.directory}/${result.name}/data.db'),
        dump(database),
      );
      expect(
        await Directory(backups.directory)
            .list()
            .where((e) => e.path.contains('.building-'))
            .isEmpty,
        isTrue,
      );
    },
  );

  test(
    'clock reversal keeps and selects the last completed snapshot',
    () async {
      final previous = <String>[];
      for (var i = 0; i < 7; i++) {
        previous.add((await create(time: now.add(Duration(days: i)))).name);
      }
      final finalTime = now.subtract(const Duration(days: 1));
      final latest = await create(time: finalTime);
      expect(latest.createdAt, finalTime);
      expect(
        await Directory('${backups.directory}/${latest.name}').exists(),
        isTrue,
      );
      final remaining = await backups.list();
      expect(remaining.first.name, latest.name);
      expect(remaining.map((s) => s.name), [
        latest.name,
        ...previous.skip(1).toList().reversed,
      ]);
      expect((await backups.verify(latest.name)).toJson(), latest.toJson());
    },
  );

  test('reading a photo before concurrent deletion preserves the old consistent snapshot', () async {
    final photo = await upload();
    final before = dump(database);
    final hook = ControlledObjects(objects);
    hook.afterRead = (_) async {
      hook.afterRead = null;
      store.removePhoto(
        'qa-a',
        mediaRequest(group, photo, operation: sharingId()),
      );
      await store.drainPhotoDeletions(objects);
    };
    final snapshot = await create(from: hook);
    expect(snapshot.photoCount, 1);
    expect(dump('${backups.directory}/${snapshot.name}/data.db'), before);
    expect(await objects.read(photo), isNull);
    expect((await backups.verify(snapshot.name)).photoCount, 1);
  });

  test('permanently missing or corrupt source cannot replace or prune good backups', () async {
    final photo = await upload();
    final snapshot = await create();
    final bytes = (await objects.read(photo))!;
    await objects.delete(photo);
    var reads = 0;
    await expectLater(
      create(
        from: _ReadHook(objects, (_) async {
          reads++;
        }),
      ),
      throwsA(failure('snapshot_changed')),
    );
    expect(reads, 3);
    await File('${objects.directory}/$photo.jpg').writeAsBytes([1, 2, 3]);
    await expectLater(create(), throwsA(failure('source_photo_integrity')));
    expect((await backups.list()).single.name, snapshot.name);
    await File('${objects.directory}/$photo.jpg').writeAsBytes(bytes);
    expect((await backups.verify(snapshot.name)).photoCount, 1);
    expect(
      await Directory(backups.directory)
          .list()
          .where((e) => e.path.contains('.building-'))
          .isEmpty,
      isTrue,
    );
  });

  test('same-process overlapping backups fail busy without releasing the first lock', () async {
    await upload();
    final entered = Completer<void>();
    final release = Completer<void>();
    final first = create(
      from: _ReadHook(objects, (_) async {
        entered.complete();
        await release.future;
      }),
    );
    await entered.future;
    try {
      final another = await CompanionBackups.open(backups.directory);
      for (var i = 0; i < 2; i++) {
        await expectLater(
          another.create(database: database, objects: objects),
          throwsA(failure('backup_busy')),
        );
      }
    } finally {
      release.complete();
    }
    await first;
    expect((await backups.list()).length, 1);
  });

  test('equal timestamps preserve completion order after reopening', () async {
    final first = await create();
    final second = await create();
    final reopened = await CompanionBackups.open(backups.directory);
    final third = await reopened.create(
      database: database,
      objects: objects,
      now: now,
    );
    expect([first.sequence, second.sequence, third.sequence], [1, 2, 3]);
    expect((await reopened.list()).map((s) => s.name), [
      third.name,
      second.name,
      first.name,
    ]);
    expect((await reopened.list()).map((s) => s.createdAt), everyElement(now));
  });

  test('copy failure keeps previous snapshots and releases the lock', () async {
    await upload();
    final previous = await create();
    await expectLater(
      create(
        from: _ReadHook(
          objects,
          (_) async => throw const FileSystemException('synthetic failure'),
        ),
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect((await backups.list()).single.name, previous.name);
    expect(
      await Directory(backups.directory)
          .list()
          .where((e) => e.path.contains('.building-'))
          .isEmpty,
      isTrue,
    );
    expect((await create()).sequence, previous.sequence + 1);
  });

  for (final version in [3, 5]) {
    test(
      'unsupported schema $version is refused without changing source',
      () async {
        final path = '${directory.path}/unsupported.db';
        final db = sqlite3.open(path);
        db.userVersion = version;
        db.execute('PRAGMA application_id=1481065296');
        db.execute('CREATE TABLE owner_data (value TEXT)');
        db.execute("INSERT INTO owner_data VALUES ('SYNTHETIC preservation')");
        db.close();
        final before = await File(path).readAsBytes();
        await expectLater(
          backups.create(database: path, objects: objects),
          throwsA(failure('unsupported_database')),
        );
        expect(await File(path).readAsBytes(), before);
        expect(await backups.list(), isEmpty);
      },
    );
  }

  for (final damage in [
    'photo',
    'database',
    'manifest',
    'extra',
    'link',
    'pending',
    'sequence',
  ]) {
    test(
      'restore refuses $damage corruption and leaves destination absent',
      () async {
        final photo = await upload();
        final snapshot = await create();
        final root = '${backups.directory}/${snapshot.name}';
        switch (damage) {
          case 'photo':
            await File('$root/objects/$photo.jpg').writeAsBytes([9, 9, 9]);
          case 'database':
            await File('$root/data.db').writeAsBytes([9, 9, 9]);
          case 'manifest':
            final file = File('$root/manifest.json');
            final json = jsonDecode(await file.readAsString()) as Map;
            json['photos'] = [];
            await file.writeAsString(jsonEncode(json));
          case 'extra':
            await File('$root/owner.txt').writeAsString('unknown');
          case 'link':
            await File('$root/objects/$photo.jpg').delete();
            await Link('$root/objects/$photo.jpg')
                .create('${objects.directory}/$photo.jpg');
          case 'pending':
            await File('$root/objects/.pending-$photo-${sharingId()}')
                .writeAsBytes([1]);
          case 'sequence':
            final file = File('$root/manifest.json');
            final json = jsonDecode(await file.readAsString()) as Map;
            json['sequence'] = snapshot.sequence + 1;
            await file.writeAsString(jsonEncode(json));
        }
        final before = dump(database);
        await expectLater(
          backups.restore(snapshot.name, '${directory.path}/restore'),
          throwsA(isA<Exception>()),
        );
        expect(await Directory('${directory.path}/restore').exists(), isFalse);
        expect(dump(database), before);
      },
    );
  }

  test('restore refuses existing file, empty directory, populated directory and symlink', () async {
    final snapshot = await create();
    final file = await File('${directory.path}/owner.txt')
        .writeAsString('owner');
    final empty = await Directory('${directory.path}/empty').create();
    final full = await Directory('${directory.path}/full').create();
    await File('${full.path}/owner.txt').writeAsString('owner');
    final link = await Link('${directory.path}/link').create(empty.path);
    for (final path in [file.path, empty.path, full.path, link.path]) {
      await expectLater(
        backups.restore(snapshot.name, path),
        throwsA(isA<Exception>()),
      );
    }
    expect(await file.readAsString(), 'owner');
    expect(await empty.list().isEmpty, isTrue);
    expect(await File('${full.path}/owner.txt').readAsString(), 'owner');
    expect(await link.target(), empty.path);
    await expectLater(
      backups.restore(snapshot.name, '${backups.directory}/restore'),
      throwsA(failure('restore_inside_backups')),
    );
    await expectLater(
      backups.verify('../data.db'),
      throwsA(failure('invalid_snapshot_name')),
    );
  });

  test(
    'unknown root, symlink root and missing source do not get initialized',
    () async {
      final unknown = await Directory('${directory.path}/unknown').create();
      await File('${unknown.path}/keep').writeAsString('keep');
      await expectLater(
        CompanionBackups.open(unknown.path),
        throwsA(failure('unknown_root')),
      );
      final link = await Link('${directory.path}/linked').create(unknown.path);
      await expectLater(
        CompanionBackups.open(link.path),
        throwsA(failure('invalid_root')),
      );
      await expectLater(
        DiskObjectStore.openExisting('${directory.path}/missing'),
        throwsA(isA<ObjectStoreFailure>()),
      );
      expect(await Directory('${directory.path}/missing').exists(), isFalse);
      await expectLater(
        backups.create(
          database: '${directory.path}/missing.db',
          objects: objects,
        ),
        throwsA(isA<Exception>()),
      );
      expect(await File('${directory.path}/missing.db').exists(), isFalse);
      expect(await File('${unknown.path}/keep').readAsString(), 'keep');
    },
  );

  test('corrupt recognized backup blocks retention and does not delete good or unknown data', () async {
    final all = <BackupSnapshot>[];
    for (var i = 0; i < 7; i++) {
      all.add(await create(time: now.add(Duration(days: i))));
    }
    await File('${backups.directory}/${all.first.name}/unknown')
        .writeAsString('owner');
    await expectLater(
      create(time: now.add(const Duration(days: 7))),
      throwsA(isA<CompanionBackupFailure>()),
    );
    for (final snapshot in all) {
      expect(
        await Directory('${backups.directory}/${snapshot.name}').exists(),
        isTrue,
      );
    }
    expect(
      await File('${backups.directory}/${all.first.name}/unknown')
          .readAsString(),
      'owner',
    );
  });

  test(
    'exported private archive verifies and restores in another collection',
    () async {
      await upload();
      final snapshot = await create();
      final archive = File('${directory.path}/export.tar.gz');
      final sink = archive.openWrite();
      try {
        await backups.export(snapshot.name, sink);
      } finally {
        await sink.close();
      }
      final imported = await Directory('${directory.path}/imported').create();
      final result = await Process.run('tar', [
        '-xzf',
        archive.path,
        '-C',
        imported.path,
      ]);
      expect(result.exitCode, 0);
      final collection = await CompanionBackups.open(imported.path);
      expect(
        (await collection.verify(snapshot.name)).toJson(),
        snapshot.toJson(),
      );
      await collection.restore(snapshot.name, '${directory.path}/migrated');
      expect(dump('${directory.path}/migrated/data.db'), dump(database));
    },
  );
}
