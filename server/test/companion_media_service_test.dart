import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';
import 'package:xingyuan_core/xingyuan_core.dart';
import 'package:xingyuan_server/src/companion_service.dart';
import 'package:xingyuan_server/src/companion_store.dart';
import 'package:xingyuan_server/src/device_registry.dart';
import 'package:xingyuan_server/src/object_store.dart';

import 'support/media_fixtures.dart';
import 'support/sharing_fixtures.dart';

void main() {
  late Directory directory;
  late CompanionStore store;
  late ControlledObjects objects;
  late DeviceRegistry devices;
  late Map<String, String> tokens;
  late HttpServer server;
  late HttpClient client;
  late String group;
  late String grant;
  late DateTime now;
  late List<Map<String, Object?>> logs;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('media-http-');
    now = DateTime.utc(2026, 10, 21, 10);
    store = CompanionStore.open('${directory.path}/data.db', now: () => now);
    objects = ControlledObjects(
      await DiskObjectStore.open('${directory.path}/objects'),
    );
    devices = DeviceRegistry('${directory.path}/devices.json');
    tokens = {};
    for (final label in ['qa-a', 'qa-b', 'qa-c', 'qa-d']) {
      tokens[label] = await devices.issue(label);
    }
    group = pairForSharing(store);
    grant = store
        .executeSharing(
          'qa-a',
          shareCommand(SharingCommandKind.enable, group, {
            'goal_id': sharingId(),
          }),
        )
        .resourceId;
    logs = [];
    final service = CompanionService(
      devices: devices,
      store: store,
      objects: objects,
      log: logs.add,
      readTimeout: const Duration(milliseconds: 250),
    );
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(service.handle);
    client = HttpClient();
  });
  tearDown(() async {
    client.close(force: true);
    await server.close(force: true);
    store.close();
    await directory.delete(recursive: true);
  });
  Future<(int, Map<String, dynamic>)> send(
    String route,
    Object? body, {
    String label = 'qa-a',
    String? credential,
    bool noAuth = false,
    String? origin,
    String? raw,
  }) async {
    final request = await client.postUrl(
      Uri.parse('http://127.0.0.1:${server.port}$route'),
    );
    if (!noAuth) {
      request.headers.set(
        'authorization',
        'Bearer ${credential ?? tokens[label]}',
      );
    }
    if (origin != null) request.headers.set('origin', origin);
    request.headers.contentType = ContentType.json;
    final bytes = utf8.encode(raw ?? jsonEncode(body));
    request.contentLength = bytes.length;
    request.add(bytes);
    final response = await request.close();
    expect(response.headers.value('cache-control'), 'no-store');
    return (
      response.statusCode,
      jsonDecode(await utf8.decoder.bind(response).join())
          as Map<String, dynamic>,
    );
  }

  Future<CompanionPhotoReceipt> upload({CompanionPhotoUpload? command}) async {
    final request = command ?? mediaUpload(group, grant);
    final result = await send(companionPhotoUploadRoute, request.toJson());
    expect(result.$1, 200, reason: result.$2.toString());
    return CompanionPhotoReceipt.fromJson(result.$2, request: request);
  }

  Future<(int, Map<String, dynamic>)> sharing(
    SharingCommand command, {
    String label = 'qa-a',
  }) => send(
    sharingCommandRoutes.entries
        .singleWhere((e) => e.value == command.kind)
        .key,
    command.toJson(),
    label: label,
  );

  test(
    'all media routes reject missing bad revoked and browser credentials',
    () async {
      for (final route in companionMediaRoutes) {
        expect((await send(route, {}, noAuth: true)).$1, 401);
        expect(
          (await send(route, {}, credential: 'synthetic-invalid')).$1,
          401,
        );
        expect(
          (await send(route, {}, origin: 'https://invalid.example')).$1,
          403,
        );
      }
      await devices.revoke('qa-a');
      for (final route in companionMediaRoutes) {
        expect((await send(route, {})).$1, 401);
      }
      expect(await objects.keys(), isEmpty);
    },
  );

  test('HTTP upload strips EXIF, sharing grants access, deletion removes physical bytes', () async {
    final source = img.Image(width: 24, height: 12);
    img.fill(source, color: img.ColorRgb8(220, 30, 40));
    source.exif.gpsIfd
      ..gpsLatitude = 12.34
      ..gpsLongitude = 56.78;
    source.exif.imageIfd
      ..orientation = 6
      ..imageDescription = 'SYNTHETIC PHOTO PRIVATE';
    final command = mediaUpload(group, grant, bytes: img.encodeJpg(source));
    final receipt = await upload(command: command);
    expect([receipt.photo.width, receipt.photo.height], [12, 24]);
    final request = mediaRequest(group, receipt.photo.id);
    final own = await send(companionPhotoReadRoute, request.toJson());
    expect(own.$1, 200);
    final download = CompanionPhotoDownload.fromJson(own.$2, request: request);
    expect(img.decodeJpg(download.bytes)!.exif.isEmpty, true);
    expect(sha256.convert(download.bytes).toString(), receipt.photo.sha256);
    expect(
      (await send(companionPhotoReadRoute, request.toJson(), label: 'qa-b')).$1,
      403,
    );
    final publish = publishRecord(
      group,
      grant,
      now,
      photos: [receipt.photo.id],
    );
    expect((await sharing(publish)).$1, 200);
    expect(
      (await send(companionPhotoReadRoute, request.toJson(), label: 'qa-b')).$1,
      200,
    );
    expect(
      (await sharing(
        shareCommand(SharingCommandKind.stop, group, {'grant_id': grant}),
      )).$1,
      200,
    );
    expect(await objects.keys(), isEmpty);
    expect(
      (await send(companionPhotoReadRoute, request.toJson(), label: 'qa-b')).$1,
      403,
    );
    final logged = jsonEncode(logs);
    for (final secret in [
      ...tokens.values,
      base64Encode(command.bytes),
      publish.text!,
      publish.title!,
      group,
      grant,
      'SYNTHETIC PHOTO PRIVATE',
    ]) {
      expect(logged, isNot(contains(secret)));
    }
    expect(
      logs.every(
        (e) => e.keys.toSet().difference({
          'time',
          'request_id',
          'device',
          'route',
          'status',
          'elapsed_ms',
        }).isEmpty,
      ),
      true,
    );
  });

  test('third parties and other pairs cannot read remove or upload into a foreign grant', () async {
    final photo = (await upload()).photo;
    final read = mediaRequest(group, photo.id);
    final remove = mediaRequest(group, photo.id, operation: sharingId());
    final body = mediaUpload(group, grant);
    for (final label in ['qa-b', 'qa-c']) {
      expect(
        (await send(companionPhotoReadRoute, read.toJson(), label: label)).$1,
        403,
      );
      expect(
        (await send(
          companionPhotoRemoveRoute,
          remove.toJson(),
          label: label,
        )).$1,
        403,
      );
      expect(
        (await send(companionPhotoUploadRoute, body.toJson(), label: label)).$1,
        403,
      );
    }
    final other = pairForSharing(store, 'qa-c', 'qa-d');
    for (final (route, payload) in [
      (companionPhotoReadRoute, read.toJson()),
      (companionPhotoRemoveRoute, remove.toJson()),
      (companionPhotoUploadRoute, body.toJson()),
    ]) {
      expect(
        (await send(route, {...payload, 'group_id': other}, label: 'qa-c')).$1,
        403,
      );
    }
    expect(await objects.keys(), [photo.id]);
  });

  test('malformed non-JPEG oversized and unknown-field bodies never persist photos', () async {
    final command = mediaUpload(group, grant);
    final body = command.toJson();
    for (final raw in ['{private-photo', 'x' * (companionMediaBodyLimit + 1)]) {
      expect(
        (await send(companionPhotoUploadRoute, {}, raw: raw)).$1,
        raw.length > companionMediaBodyLimit ? 413 : 400,
      );
    }
    for (final bytes in [
      [1, 2, 3],
      img.encodePng(img.Image(width: 2, height: 2)),
      img.encodeJpg(img.Image(width: 1601, height: 1)),
    ]) {
      expect(
        (await send(
          companionPhotoUploadRoute,
          mediaUpload(group, grant, bytes: bytes).toJson(),
        )).$1,
        400,
      );
    }
    expect(
      (await send(companionPhotoUploadRoute, {
        ...body,
        'private_note': 'private-photo',
      })).$1,
      400,
    );
    expect(
      (await send(companionPhotoUploadRoute, {
        ...body,
        'jpeg_base64': 'AA==\n',
      })).$1,
      400,
    );
    expect(
      (await send(
        companionPhotoReadRoute,
        {},
        raw: 'x' * (assistantBodyLimit + 1),
      )).$1,
      413,
    );
    expect(await objects.keys(), isEmpty);
    expect(jsonEncode(logs), isNot(contains('private-photo')));
  });

  test(
    'concurrent retry and storage failure reuse one reservation and one object',
    () async {
      final command = mediaUpload(group, grant);
      objects.failPut = true;
      expect((await send(companionPhotoUploadRoute, command.toJson())).$1, 503);
      objects.failPut = false;
      final responses = await Future.wait(
        List.generate(
          5,
          (_) => send(companionPhotoUploadRoute, command.toJson()),
        ),
      );
      expect(responses.every((r) => [200, 409, 429].contains(r.$1)), true);
      final result = await upload(command: command);
      expect(await objects.keys(), [result.photo.id]);
      expect((await upload(command: command)).toJson(), result.toJson());
    },
  );

  test(
    'failed physical deletion is durable; same command retries cleanup',
    () async {
      final photo = (await upload()).photo;
      final remove = mediaRequest(group, photo.id, operation: sharingId());
      objects.failDelete = true;
      expect((await send(companionPhotoRemoveRoute, remove.toJson())).$1, 503);
      expect(
        (await send(
          companionPhotoReadRoute,
          mediaRequest(group, photo.id).toJson(),
        )).$1,
        403,
      );
      expect(await objects.keys(), [photo.id]);
      objects.failDelete = false;
      expect((await send(companionPhotoRemoveRoute, remove.toJson())).$1, 200);
      expect(await objects.keys(), isEmpty);
    },
  );

  test(
    'unpair during a delayed upload rejects finalization and removes late file',
    () async {
      final reached = Completer<void>();
      final release = Completer<void>();
      objects.beforePut = (_) async {
        reached.complete();
        await release.future;
      };
      final pending = send(
        companionPhotoUploadRoute,
        mediaUpload(group, grant).toJson(),
      );
      await reached.future;
      final leave = PairingCommand.leave(sharingId(), group);
      final route = pairingCommandRoutes.entries
          .singleWhere((e) => e.value == leave.kind)
          .key;
      expect((await send(route, leave.toJson(), label: 'qa-b')).$1, 200);
      release.complete();
      expect((await pending).$1, 403);
      expect(await objects.keys(), isEmpty);
    },
  );

  test('revocation during upload aborts bytes and metadata without leaking response', () async {
    objects.beforePut = (_) async {
      await devices.revoke('qa-a');
    };
    expect(
      (await send(
        companionPhotoUploadRoute,
        mediaUpload(group, grant).toJson(),
      )).$1,
      401,
    );
    expect(await objects.keys(), isEmpty);
  });

  test('download rechecks credential after slow object access', () async {
    final photo = (await upload()).photo;
    objects.afterRead = (_) async {
      await devices.revoke('qa-a');
    };
    final result = await send(
      companionPhotoReadRoute,
      mediaRequest(group, photo.id).toJson(),
    );
    expect(result.$1, 401);
    expect(result.$2.keys, ['error']);
  });

  test(
    'download rechecks sharing and pairing after slow object access',
    () async {
      final photo = (await upload()).photo;
      expect(
        (await sharing(publishRecord(group, grant, now, photos: [photo.id])))
            .$1,
        200,
      );
      objects.afterRead = (_) async {
        store.executeSharing(
          'qa-a',
          shareCommand(SharingCommandKind.stop, group, {'grant_id': grant}),
        );
      };
      final result = await send(
        companionPhotoReadRoute,
        mediaRequest(group, photo.id).toJson(),
        label: 'qa-b',
      );
      expect(result.$1, 403);
      expect(result.$2.keys, ['error']);
      objects.afterRead = null;
      final chatPhoto = (await upload(command: mediaUpload(group, null))).photo;
      objects.afterRead = (_) async {
        store.execute('qa-b', PairingCommand.leave(sharingId(), group));
      };
      expect(
        (await send(
          companionPhotoReadRoute,
          mediaRequest(group, chatPhoto.id).toJson(),
        )).$1,
        403,
      );
      await store.drainPhotoDeletions(objects);
      expect(await objects.keys(), isEmpty);
    },
  );

  test('photo corruption returns no bytes', () async {
    final photo = (await upload()).photo;
    await File('${directory.path}/objects/${photo.id}.jpg')
        .writeAsBytes([1, 2, 3]);
    final result = await send(
      companionPhotoReadRoute,
      mediaRequest(group, photo.id).toJson(),
    );
    expect(result.$1, 503);
    expect(result.$2.keys, ['error']);
  });

  test('credential is rechecked after a delayed upload body', () async {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      server.port,
    );
    try {
      final response = utf8.decoder.bind(socket).join();
      final bytes = utf8.encode(jsonEncode(mediaUpload(group, grant).toJson()));
      socket.write(
        'POST $companionPhotoUploadRoute HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n'
        'Authorization: Bearer ${tokens['qa-a']}\r\nContent-Type: application/json\r\nContent-Length: ${bytes.length}\r\n\r\n',
      );
      await socket.flush();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await devices.revoke('qa-a');
      socket.add(bytes);
      await socket.flush();
      expect(
        await response.timeout(const Duration(seconds: 3)),
        startsWith('HTTP/1.1 401'),
      );
      expect(await objects.keys(), isEmpty);
    } finally {
      socket.destroy();
    }
  });

  test('unfinished upload times out and releases its active request slot', () async {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      server.port,
    );
    try {
      final response = utf8.decoder.bind(socket).join();
      socket.write(
        'POST $companionPhotoUploadRoute HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n'
        'Authorization: Bearer ${tokens['qa-a']}\r\nContent-Type: application/json\r\nContent-Length: 100\r\n\r\n',
      );
      await socket.flush();
      final result = await response.timeout(const Duration(seconds: 3));
      expect(result, startsWith('HTTP/1.1 400'));
      expect(result, contains('request_read_timeout'));
      expect(await objects.keys(), isEmpty);
    } finally {
      socket.destroy();
    }
    await upload();
  });
}
