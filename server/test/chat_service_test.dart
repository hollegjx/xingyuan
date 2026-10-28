import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:xingyuan_core/xingyuan_core.dart';
import 'package:xingyuan_server/src/companion_service.dart';
import 'package:xingyuan_server/src/companion_store.dart';
import 'package:xingyuan_server/src/device_registry.dart';
import 'package:xingyuan_server/src/object_store.dart';

import 'support/media_fixtures.dart';
import 'support/sharing_fixtures.dart';

class _ObservedRegistry extends DeviceRegistry {
  _ObservedRegistry(super.path);
  Completer<void>? authenticated;
  @override
  Future<String?> authenticate(String? authorization) async {
    final label = await super.authenticate(authorization);
    final signal = authenticated;
    authenticated = null;
    signal?.complete();
    return label;
  }
}

void main() {
  late Directory directory;
  late CompanionStore store;
  late ControlledObjects objects;
  late _ObservedRegistry devices;
  late Map<String, String> tokens;
  late HttpServer server;
  late HttpClient client;
  late String group;
  late String otherGroup;
  late List<Map<String, Object?>> logs;
  const sendRoute = '/v1/companion/chat/send';
  const removeRoute = '/v1/companion/chat/remove';
  const listRoute = '/v1/companion/chat/list';

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('chat-http-');
    store = CompanionStore.open('${directory.path}/data.db');
    objects = ControlledObjects(
      await DiskObjectStore.open('${directory.path}/objects'),
    );
    devices = _ObservedRegistry('${directory.path}/devices.json');
    tokens = {};
    for (final label in ['qa-a', 'qa-b', 'qa-c', 'qa-d']) {
      tokens[label] = await devices.issue(label);
    }
    group = pairForSharing(store);
    otherGroup = pairForSharing(store, 'qa-c', 'qa-d');
    logs = [];
    final service = CompanionService(
      devices: devices,
      store: store,
      objects: objects,
      log: logs.add,
      readTimeout: const Duration(seconds: 5),
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

  Map<String, Object?> message({
    String text = 'SYNTHETIC private chat',
    String? photo,
  }) => {
    'protocol': companionProtocol,
    'group_id': group,
    'operation_id': sharingId(),
    'text': text,
    'photo_id': photo,
  };
  Map<String, Object?> remove(String id) => {
    'protocol': companionProtocol,
    'group_id': group,
    'operation_id': sharingId(),
    'message_id': id,
  };
  Future<(int, Map<String, dynamic>)> send(
    String route,
    Object? body, {
    String label = 'qa-a',
    bool noAuth = false,
    String? token,
    String? origin,
    String? raw,
    String type = 'application/json',
    String method = 'POST',
  }) async {
    final request = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:${server.port}$route'),
    );
    if (!noAuth) {
      request.headers.set('authorization', 'Bearer ${token ?? tokens[label]}');
    }
    if (origin != null) request.headers.set('origin', origin);
    request.headers.set('content-type', type);
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

  Future<String> upload({String label = 'qa-a', String? grant}) async {
    final request = mediaUpload(group, grant);
    final result = await send(
      companionPhotoUploadRoute,
      request.toJson(),
      label: label,
    );
    expect(result.$1, 200);
    return CompanionPhotoReceipt.fromJson(result.$2, request: request).photo.id;
  }

  test('chat send retries once, partner reads, only author removes', () async {
    final command = message();
    final first = await send(sendRoute, command);
    expect(first.$1, 200);
    for (var i = 0; i < 5; i++) {
      final replay = await send(sendRoute, command);
      expect(replay.$1, first.$1);
      expect(replay.$2, first.$2);
    }
    final page = await send(
      listRoute,
      sharePage(group).toJson(),
      label: 'qa-b',
    );
    expect(page.$1, 200);
    final rows = page.$2['messages'] as List;
    expect(rows, hasLength(1));
    expect(rows.single['text'], command['text']);
    final deletion = remove(first.$2['message_id'] as String);
    expect((await send(removeRoute, deletion, label: 'qa-b')).$1, 403);
    expect((await send(removeRoute, deletion)).$1, 200);
    expect((await send(removeRoute, deletion)).$1, 200);
    expect(
      (await send(
        listRoute,
        sharePage(group).toJson(),
        label: 'qa-b',
      )).$2['messages'],
      isEmpty,
    );
    expect((await send(sendRoute, command)).$1, 403);
  });

  test(
    'chat photo stays private until sent and is removed with message',
    () async {
      final photo = await upload();
      final read = mediaRequest(group, photo).toJson();
      expect(
        (await send(companionPhotoReadRoute, read, label: 'qa-b')).$1,
        403,
      );
      final accepted = await send(sendRoute, message(text: '', photo: photo));
      expect(accepted.$1, 200);
      expect(
        (await send(companionPhotoReadRoute, read, label: 'qa-b')).$1,
        200,
      );
      expect(
        (await send(
          companionPhotoRemoveRoute,
          mediaRequest(group, photo, operation: sharingId()).toJson(),
        )).$2['error'],
        'photo_attached',
      );
      expect(
        (await send(
          removeRoute,
          remove(accepted.$2['message_id'] as String),
        )).$1,
        200,
      );
      for (final label in ['qa-a', 'qa-b']) {
        expect(
          (await send(companionPhotoReadRoute, read, label: label)).$1,
          403,
        );
      }
      expect(await objects.keys(), isEmpty);
    },
  );

  test('chat routes authenticate and enforce active pair membership', () async {
    final bodies = {
      sendRoute: message(),
      removeRoute: remove(sharingId()),
      listRoute: sharePage(group).toJson(),
    };
    for (final entry in bodies.entries) {
      expect((await send(entry.key, entry.value, noAuth: true)).$1, 401);
      expect((await send(entry.key, entry.value, token: 'invalid')).$1, 401);
      expect(
        (await send(
          entry.key,
          entry.value,
          origin: 'https://example.invalid',
        )).$1,
        403,
      );
      expect((await send(entry.key, entry.value, label: 'qa-c')).$1, 403);
      expect(
        (await send(entry.key, {...entry.value, 'group_id': otherGroup})).$1,
        403,
      );
    }
    await devices.revoke('qa-d');
    for (final entry in bodies.entries) {
      expect((await send(entry.key, entry.value, label: 'qa-d')).$1, 401);
    }
    store.execute('qa-a', PairingCommand.leave(sharingId(), group));
    for (final entry in bodies.entries) {
      expect((await send(entry.key, entry.value)).$1, 403);
    }
  });

  test('five concurrent retries and simultaneous partner sends have one effect each', () async {
    final a = message(text: 'SYNTHETIC A');
    final b = message(text: 'SYNTHETIC B');
    final responses = await Future.wait([
      for (var i = 0; i < 5; i++) send(sendRoute, a),
      for (var i = 0; i < 5; i++) send(sendRoute, b, label: 'qa-b'),
    ]);
    expect(responses.every((r) => r.$1 == 200 || r.$1 == 429), true);
    final acceptedA = await send(sendRoute, a);
    final acceptedB = await send(sendRoute, b, label: 'qa-b');
    expect(acceptedA.$1, 200);
    expect(acceptedB.$1, 200);
    expect(
      responses
          .where((r) => r.$1 == 200)
          .map((r) => r.$2['message_id'])
          .toSet(),
      {acceptedA.$2['message_id'], acceptedB.$2['message_id']},
    );
    final request = sharePage(group);
    final received = ChatPage.fromJson(
      (await send(listRoute, request.toJson())).$2,
      request: request,
    );
    expect(received.revision, 2);
    expect(received.messages.map((m) => m.sequence), [2, 1]);
    expect(received.messages.map((m) => m.text).toSet(), {
      a['text'],
      b['text'],
    });
    expect(
      (await send(sendRoute, {...a, 'text': 'changed'})).$2['error'],
      'operation_conflict',
    );
  });

  test(
    'both members leaving during a send cannot retain chat or uploaded photos',
    () async {
      final photo = await upload();
      final command = message(photo: photo);
      final a = PairingCommand.leave(sharingId(), group);
      final b = PairingCommand.leave(sharingId(), group);
      final route = pairingCommandRoutes.entries
          .singleWhere((e) => e.value == PairingCommandKind.leave)
          .key;
      final result = await Future.wait([
        send(sendRoute, command),
        send(route, a.toJson()),
        send(route, b.toJson(), label: 'qa-b'),
      ]);
      expect(result.first.$1, anyOf(200, 403));
      expect(result[1].$1, 200);
      expect(result[2].$1, 200);
      for (final label in ['qa-a', 'qa-b']) {
        expect(
          (await send(listRoute, sharePage(group).toJson(), label: label)).$1,
          403,
        );
        expect((await send(sendRoute, command, label: label)).$1, 403);
        expect(
          (await send(
            companionPhotoReadRoute,
            mediaRequest(group, photo).toJson(),
            label: label,
          )).$1,
          403,
        );
      }
      expect(await objects.keys(), isEmpty);
      expect(store.state('qa-a').group, isNull);
      expect(store.state('qa-b').group, isNull);
    },
  );

  Future<String> delayed(
    String route,
    Map<String, Object?> body,
    Future<void> Function() interrupt,
  ) async {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      server.port,
    );
    try {
      final authenticated = Completer<void>();
      devices.authenticated = authenticated;
      final response = utf8.decoder.bind(socket).join();
      final bytes = utf8.encode(jsonEncode(body));
      socket.write(
        'POST $route HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n'
        'Authorization: Bearer ${tokens['qa-a']}\r\nContent-Type: application/json\r\nContent-Length: ${bytes.length}\r\n\r\n',
      );
      await socket.flush();
      await authenticated.future.timeout(const Duration(seconds: 5));
      await interrupt();
      socket.add(bytes);
      await socket.flush();
      return await response.timeout(const Duration(seconds: 10));
    } finally {
      socket.destroy();
    }
  }

  for (final route in [sendRoute, removeRoute, listRoute]) {
    for (final revoke in [true, false]) {
      test(
        '$route rechecks ${revoke ? 'credentials' : 'membership'} after a delayed body',
        () async {
          final accepted = await send(sendRoute, message());
          final body = switch (route) {
            sendRoute => message(),
            removeRoute => remove(accepted.$2['message_id'] as String),
            _ => sharePage(group).toJson(),
          };
          final response = await delayed(route, body, () async {
            if (revoke) {
              await devices.revoke('qa-a');
            } else {
              store.execute('qa-b', PairingCommand.leave(sharingId(), group));
            }
          });
          expect(response, startsWith('HTTP/1.1 ${revoke ? 401 : 403}'));
          expect(response, isNot(contains('SYNTHETIC')));
          if (revoke) {
            expect(
              store.chatMessages('qa-b', sharePage(group)).messages,
              hasLength(1),
            );
          } else {
            expect(
              (await send(
                listRoute,
                sharePage(group).toJson(),
                label: 'qa-b',
              )).$1,
              403,
            );
          }
        },
      );
    }
  }

  test(
    'chat photo rejects foreign owner, wrong purpose, reuse and another pair',
    () async {
      final grant = store
          .executeSharing(
            'qa-a',
            shareCommand(SharingCommandKind.enable, group, {
              'goal_id': sharingId(),
            }),
          )
          .resourceId;
      final own = await upload();
      final partner = await upload(label: 'qa-b');
      final record = await upload(grant: grant);
      for (final photo in [partner, record, sharingId()]) {
        expect(
          (await send(sendRoute, message(photo: photo))).$2['error'],
          'photo_unavailable',
        );
      }
      expect((await send(sendRoute, message(photo: own))).$1, 200);
      expect(
        (await send(sendRoute, message(photo: own))).$2['error'],
        'photo_unavailable',
      );
      expect(
        (await send(sendRoute, {
          ...message(photo: own),
          'group_id': otherGroup,
        }, label: 'qa-c')).$2['error'],
        'photo_unavailable',
      );
      expect(
        (await send(
          companionPhotoReadRoute,
          mediaRequest(otherGroup, own).toJson(),
          label: 'qa-c',
        )).$1,
        403,
      );
      expect(
        (await send(
          companionPhotoReadRoute,
          mediaRequest(group, own).toJson(),
          label: 'qa-c',
        )).$1,
        403,
      );
      expect(
        (await send(
          companionPhotoReadRoute,
          mediaRequest(group, own).toJson(),
          label: 'qa-b',
        )).$1,
        200,
      );
    },
  );

  test('deletion denies access immediately and waits for retryable physical cleanup', () async {
    final photo = await upload();
    final command = message(photo: photo);
    final accepted = await send(sendRoute, command);
    final deletion = remove(accepted.$2['message_id'] as String);
    objects.failDelete = true;
    expect((await send(removeRoute, deletion)).$1, 503);
    expect(store.chatMessages('qa-b', sharePage(group)).messages, isEmpty);
    expect(
      (await send(
        companionPhotoReadRoute,
        mediaRequest(group, photo).toJson(),
        label: 'qa-b',
      )).$1,
      403,
    );
    expect((await send(sendRoute, command)).$1, 403);
    expect(await objects.keys(), [photo]);
    objects.failDelete = false;
    expect((await send(removeRoute, deletion)).$1, 200);
    expect((await send(removeRoute, deletion)).$1, 200);
    expect(await objects.keys(), isEmpty);
  });

  for (final interrupt in ['remove', 'unpair', 'revoke']) {
    test('photo read discards bytes after concurrent $interrupt', () async {
      final photo = await upload();
      final accepted = await send(sendRoute, message(photo: photo));
      objects.afterRead = (_) async {
        objects.afterRead = null;
        if (interrupt == 'revoke') {
          await devices.revoke('qa-b');
        } else if (interrupt == 'unpair') {
          store.execute('qa-a', PairingCommand.leave(sharingId(), group));
        } else {
          expect(
            (await send(
              removeRoute,
              remove(accepted.$2['message_id'] as String),
            )).$1,
            200,
          );
        }
      };
      final received = await send(
        companionPhotoReadRoute,
        mediaRequest(group, photo).toJson(),
        label: 'qa-b',
      );
      expect(received.$1, interrupt == 'revoke' ? 401 : 403);
      expect(received.$2.keys, ['error']);
      expect(received.$2, isNot(contains('jpeg_base64')));
    });
  }

  test('deletion reauthenticates after slow physical cleanup', () async {
    final photo = await upload();
    final accepted = await send(sendRoute, message(photo: photo));
    objects.afterDelete = (_) async {
      objects.afterDelete = null;
      await devices.revoke('qa-a');
    };
    expect(
      (await send(removeRoute, remove(accepted.$2['message_id'] as String))).$1,
      401,
    );
    expect(store.chatMessages('qa-b', sharePage(group)).messages, isEmpty);
    expect(await objects.keys(), isEmpty);
  });

  test(
    'invalid envelopes and private fields never enter storage or logs',
    () async {
      final bodies = {
        sendRoute: message(),
        removeRoute: remove(sharingId()),
        listRoute: sharePage(group).toJson(),
      };
      for (final entry in bodies.entries) {
        for (final field in [
          'author_id',
          'member_id',
          'owner_id',
          'created_at',
          'notes',
        ]) {
          expect(
            (await send(entry.key, {
              ...entry.value,
              field: 'PRIVATE INVALID',
            })).$1,
            400,
          );
        }
        expect(
          (await send(entry.key, entry.value, raw: '{PRIVATE INVALID')).$1,
          400,
        );
        expect(
          (await send(entry.key, entry.value, type: 'text/plain')).$1,
          400,
        );
        expect(
          (await send(
            entry.key,
            entry.value,
            raw: 'x' * (assistantBodyLimit + 1),
          )).$1,
          413,
        );
        expect(
          (await send('${entry.key}?text=PRIVATE-INVALID', entry.value)).$1,
          400,
        );
        expect((await send(entry.key, entry.value, method: 'GET')).$1, 404);
      }
      expect(
        (await send(sendRoute, {
          ...message(),
          'operation_id': 'PRIVATE INVALID',
        })).$1,
        400,
      );
      expect(store.chatMessages('qa-b', sharePage(group)).messages, isEmpty);
      final content = message(text: 'SYNTHETIC secret chat\nline');
      final accepted = await send(sendRoute, content);
      expect(accepted.$1, 200);
      expect(
        (await send(listRoute, sharePage(group).toJson(), label: 'qa-b')).$1,
        200,
      );
      final photoRequest = mediaUpload(group, null);
      expect(
        (await send(companionPhotoUploadRoute, photoRequest.toJson())).$1,
        200,
      );
      final logged = jsonEncode(logs);
      for (final private in [
        'PRIVATE INVALID',
        'PRIVATE-INVALID',
        ...tokens.values,
        content['text'] as String,
        group,
        base64Encode(photoRequest.bytes),
      ]) {
        expect(logged, isNot(contains(private)));
      }
      expect(logs, isNotEmpty);
      expect(
        logs.every(
          (r) => r.keys.toSet().difference({
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
    },
  );
}
