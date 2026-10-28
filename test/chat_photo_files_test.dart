import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/companion/data/chat_photo_files.dart';
import 'package:habit_checkin/features/companion/data/companion_service.dart';
import 'package:habit_checkin/features/companion/data/local_chat_store.dart';
import 'package:habit_checkin/features/records/data/record_photo.dart';
import 'package:path/path.dart' as p;
import 'package:timezone/data/latest.dart' as tzdata;

import 'support/chat_fixtures.dart';

class _PausedCleanup extends ChatPhotoFiles {
  _PausedCleanup(super.root, super.db);
  final gate = Completer<void>();
  int calls = 0;
  @override
  Future<void> sweep() async {
    if (++calls == 1) await gate.future;
  }
}

void main() {
  late ChatFixture f;
  late ChatPhotoFiles files;
  setUp(() async {
    tzdata.initializeTimeZones();
    f = ChatFixture(await Directory.systemTemp.createTemp('chat-files-'));
    await f.open();
    files = ChatPhotoFiles(Directory('${f.directory.path}/photos'), f.db);
  });
  tearDown(() async {
    await files.dispose();
    await f.db.close();
    await f.directory.delete(recursive: true);
  });
  File path(ChatPhotoInput photo) => File(
    p.join(
      files.root.path,
      sha256.convert(utf8.encode(photo.owner)).toString(),
      photo.sessionId,
      '${photo.id}.jpg',
    ),
  );
  Future<ChatPhotoInput> pick() async =>
      files.write(f.store, await sanitizeRecordPhoto(chatJpeg()));
  Future<void> save(ChatPhotoInput photo) => f.store.writeDraft(
    '',
    photoId: photo.id,
    addedPhoto: photo,
    expectedRevision: 0,
  );

  test(
    'selected photo uses separate sandbox and integrity checked bytes',
    () async {
      final input = await pick();
      await save(input);
      final data = await files.read(f.store, input.id);
      expect(sha256.convert(data).toString(), input.sha256);
      expect(await path(input).exists(), true);
      await path(input).writeAsBytes(List.filled(input.byteCount, 1));
      await expectLater(
        files.read(f.store, input.id),
        throwsA(isA<CompanionServiceFailure>()),
      );
    },
  );

  test(
    'replacement and unpair retire only chat files, personal data is untouched',
    () async {
      final personal = File('${f.directory.path}/personal-original.jpg');
      await personal.writeAsBytes(chatJpeg());
      final before = await personal.readAsBytes();
      final input = await pick();
      await save(input);
      await f.db.clearSharingContent(f.store.owner);
      expect((await f.db.select(f.db.chatPhotos).get()).single.retired, true);
      await files.sweep();
      expect(await path(input).exists(), false);
      expect(await f.db.select(f.db.chatPhotos).get(), isEmpty);
      expect(await personal.readAsBytes(), before);
      await expectLater(
        files.read(f.store, input.id),
        throwsA(isA<CompanionServiceFailure>()),
      );
    },
  );

  test(
    'scope change before draft commit removes only its unregistered selection',
    () async {
      final input = await pick();
      await f.db.clearSharingContent(f.store.owner);
      await expectLater(save(input), throwsA(isA<CompanionServiceFailure>()));
      await files.removeUnregistered(input);
      expect(await path(input).exists(), false);
      expect(await f.db.select(f.db.chatPhotos).get(), isEmpty);
    },
  );

  test(
    'failed selection cleanup cannot remove a registered draft photo',
    () async {
      final input = await pick();
      await save(input);
      await files.removeUnregistered(input);
      expect(await path(input).exists(), true);
      expect((await f.store.snapshot()).photo?.id, input.id);
    },
  );

  test(
    'cleanup refuses symbolic links and retains durable retirement for retry',
    () async {
      final input = await pick();
      await save(input);
      final target = path(input);
      final outside = File('${f.directory.path}/untouched.jpg');
      await outside.writeAsBytes(chatJpeg());
      await target.delete();
      final link = await Link(target.path).create(outside.path);
      await f.db.clearSharingContent(f.store.owner);
      await files.sweep();
      expect(await outside.exists(), true);
      expect(await f.db.select(f.db.chatPhotos).get(), hasLength(1));
      await link.delete();
      await files.sweep();
      expect(await f.db.select(f.db.chatPhotos).get(), isEmpty);
      expect(await outside.exists(), true);
    },
  );

  test(
    'orphan grace protects in-flight imports but later removes abandoned files',
    () async {
      final input = await pick();
      final target = path(input);
      await files.sweep();
      expect(await target.exists(), true);
      await target.setLastModified(
        DateTime.now().subtract(const Duration(days: 2)),
      );
      final unknown = File(p.join(target.parent.path, 'owner-document.txt'));
      await unknown.writeAsString('SYNTHETIC unknown');
      await unknown.setLastModified(
        DateTime.now().subtract(const Duration(days: 2)),
      );
      await files.sweep();
      expect(await target.exists(), false);
      expect(await unknown.exists(), true);
    },
  );

  test('startup and scope-change watcher drain persisted retirement', () async {
    final input = await pick();
    await save(input);
    await files.startCleanup();
    await f.db.clearSharingContent(f.store.owner);
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (await path(input).exists() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(await path(input).exists(), false);
  });

  test(
    'disposing during startup cannot attach a late cleanup watcher',
    () async {
      final input = await pick();
      await save(input);
      await files.dispose();
      final delayed = _PausedCleanup(files.root, f.db);
      files = delayed;
      final startup = delayed.startCleanup();
      await delayed.dispose();
      delayed.gate.complete();
      await startup;
      await f.db.clearSharingContent(f.store.owner);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(delayed.calls, 1);
    },
  );
}
