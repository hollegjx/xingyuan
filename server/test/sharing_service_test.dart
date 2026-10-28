import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:xingyuan_core/xingyuan_core.dart';
import 'package:xingyuan_server/src/companion_service.dart';
import 'package:xingyuan_server/src/companion_store.dart';
import 'package:xingyuan_server/src/device_registry.dart';

import 'support/sharing_fixtures.dart';

class _ObservedRegistry extends DeviceRegistry {
  _ObservedRegistry(super.path);
  Completer<void>? authenticated;

  @override
  Future<String?> authenticate(String? authorization) async {
    final member = await super.authenticate(authorization);
    final signal = authenticated;
    authenticated = null;
    signal?.complete();
    return member;
  }
}

void main() {
  late Directory directory;
  late CompanionStore store;
  late _ObservedRegistry devices;
  late HttpServer server;
  late HttpClient client;
  late Map<String, String> tokens;
  late List<Map<String, Object?>> logs;
  late String group;
  late String grant;
  late DateTime now;
  String route(SharingCommand command) => sharingCommandRoutes.entries
      .singleWhere((e) => e.value == command.kind)
      .key;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('sharing-http-');
    now = DateTime.utc(2026, 10, 21, 10);
    store = CompanionStore.open('${directory.path}/data.db', now: () => now);
    devices = _ObservedRegistry('${directory.path}/devices.json');
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

  Future<(int, Map<String, dynamic>)> send(
    String path,
    Object? body, {
    String label = 'qa-a',
    bool noAuth = false,
    String? credential,
    String? origin,
    String? raw,
    String type = 'application/json',
    String method = 'POST',
  }) async {
    final request = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:${server.port}$path'),
    );
    if (!noAuth) {
      request.headers.set(
        'authorization',
        'Bearer ${credential ?? tokens[label]}',
      );
    }
    if (origin != null) {
      request.headers.set('origin', origin);
    }
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

  Future<SharingReceipt> ok(String label, SharingCommand command) async {
    final response = await send(route(command), command.toJson(), label: label);
    expect(response.$1, 200, reason: response.$2.toString());
    return SharingReceipt.fromJson(response.$2, command: command);
  }

  Map<String, Object?> getRecord(String record, {String? targetGroup}) => {
    'protocol': companionProtocol,
    'group_id': targetGroup ?? group,
    'record_id': record,
  };

  Map<String, Object?> resolution(SharingCommand command) => {
    'protocol': companionProtocol,
    'group_id': command.groupId,
    'operation_id': command.operationId,
    'fingerprint': sha256
        .convert(
          utf8.encode(
            jsonEncode({'kind': command.kind.name, ...command.toJson()}),
          ),
        )
        .toString(),
  };

  test('publication resolution seals a missing request without sending its content', () async {
    final command = publishRecord(
      group,
      grant,
      now,
      text: 'SYNTHETIC withdrawn',
    );
    final resolved = await send(
      '/v1/companion/records/resolve',
      resolution(command),
    );
    expect(resolved.$1, 200);
    expect(resolved.$2['error_code'], 'publication_cancelled');
    expect(resolved.$2['receipt'], isNull);
    expect(
      (await send(route(command), command.toJson())).$2['error'],
      'publication_cancelled',
    );
    expect(store.sharedFeed('qa-b', sharePage(group)).records, isEmpty);
    expect(jsonEncode(logs), isNot(contains('SYNTHETIC withdrawn')));
  });

  test(
    'publication resolution returns a lost receipt without replaying a write',
    () async {
      final command = publishRecord(group, grant, now);
      final receipt = await ok('qa-a', command);
      final before = store.sharedFeed('qa-b', sharePage(group)).toJson();
      final resolved = await send(
        '/v1/companion/records/resolve',
        resolution(command),
      );
      expect(resolved.$1, 200);
      expect(resolved.$2['receipt'], receipt.toJson());
      expect(resolved.$2['error_code'], isNull);
      expect(store.sharedFeed('qa-b', sharePage(group)).toJson(), before);
    },
  );

  test(
    'every sharing route rejects absent, bad, revoked and browser credentials',
    () async {
      for (final path in {
        ...sharingCommandRoutes.keys,
        ...sharingReadRoutes,
        publicationResolveRoute,
      }) {
        expect((await send(path, {}, noAuth: true)).$1, 401);
        expect((await send(path, {}, credential: 'invalid')).$1, 401);
        expect(
          (await send(path, {}, origin: 'https://untrusted.invalid')).$1,
          403,
        );
      }
      await devices.revoke('qa-a');
      for (final path in {
        ...sharingCommandRoutes.keys,
        ...sharingReadRoutes,
        publicationResolveRoute,
      }) {
        expect((await send(path, {})).$1, 401);
      }
      expect(
        (await send(
          sharedFeedRoute,
          sharePage(group).toJson(),
          label: 'qa-b',
        )).$1,
        200,
      );
    },
  );

  test(
    'HTTP sharing and reply flow keeps private fields out and deletes on stop',
    () async {
      final command = publishRecord(
        group,
        grant,
        now,
        text: 'Synthetic private-to-pair text',
      );
      final record = await ok('qa-a', command);
      final feed = await send(
        sharedFeedRoute,
        sharePage(group).toJson(),
        label: 'qa-b',
      );
      expect(feed.$1, 200);
      expect(
        SharedFeedPage.fromJson(
          feed.$2,
          request: sharePage(group),
        ).records.single.text,
        command.text,
      );
      expect(
        (await send(
          sharedRecordRoute,
          getRecord(record.resourceId),
          label: 'qa-b',
        )).$1,
        200,
      );
      final reply = shareCommand(SharingCommandKind.reply, group, {
        'record_id': record.resourceId,
        'text': 'Synthetic encouragement',
      });
      await ok('qa-b', reply);
      final replies = await send(
        sharedRepliesRoute,
        sharePage(group, record: record.resourceId).toJson(),
      );
      expect(
        SharedRepliesPage.fromJson(
          replies.$2,
          request: sharePage(group, record: record.resourceId),
        ).replies.single.text,
        reply.text,
      );
      await ok(
        'qa-a',
        shareCommand(SharingCommandKind.stop, group, {'grant_id': grant}),
      );
      expect(
        (await send(
          sharedRecordRoute,
          getRecord(record.resourceId),
          label: 'qa-b',
        )).$1,
        403,
      );
      expect(
        (await send(
          sharedRepliesRoute,
          sharePage(group, record: record.resourceId).toJson(),
          label: 'qa-b',
        )).$1,
        403,
      );
      expect((await send(route(reply), reply.toJson(), label: 'qa-b')).$1, 403);
      expect((await send(route(command), command.toJson())).$1, 403);
      expect(
        SharedFeedPage.fromJson(
          (await send(
            sharedFeedRoute,
            sharePage(group).toJson(),
            label: 'qa-b',
          )).$2,
          request: sharePage(group),
        ).records,
        isEmpty,
      );
      final logged = jsonEncode(logs);
      for (final private in [
        ...tokens.values,
        command.text!,
        reply.text!,
        command.title!,
        grant,
        group,
      ]) {
        expect(logged, isNot(contains(private)));
      }
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

  test('third party and other pair cannot use any content route with forged ownership', () async {
    final record = await ok('qa-a', publishRecord(group, grant, now));
    final reply = await ok(
      'qa-b',
      shareCommand(SharingCommandKind.reply, group, {
        'record_id': record.resourceId,
        'text': 'Synthetic',
      }),
    );
    final commands = [
      shareCommand(SharingCommandKind.enable, group, {'goal_id': sharingId()}),
      shareCommand(SharingCommandKind.stop, group, {'grant_id': grant}),
      publishRecord(group, grant, now),
      shareCommand(SharingCommandKind.remove, group, {
        'record_id': record.resourceId,
      }),
      shareCommand(SharingCommandKind.reply, group, {
        'record_id': record.resourceId,
        'text': 'Synthetic',
      }),
      shareCommand(SharingCommandKind.deleteReply, group, {
        'reply_id': reply.resourceId,
      }),
    ];
    final reads = {
      sharedFeedRoute: sharePage(group).toJson(),
      sharingGrantsRoute: sharePage(group).toJson(),
      sharedRepliesRoute: sharePage(group, record: record.resourceId).toJson(),
      sharedRecordRoute: getRecord(record.resourceId),
    };
    for (final command in commands) {
      expect(
        (await send(route(command), command.toJson(), label: 'qa-c')).$1,
        403,
      );
    }
    for (final read in reads.entries) {
      expect((await send(read.key, read.value, label: 'qa-c')).$1, 403);
    }
    final other = pairForSharing(store, 'qa-c', 'qa-d');
    for (final command in commands.where(
      (c) => c.kind != SharingCommandKind.enable,
    )) {
      expect(
        (await send(route(command), {
          ...command.toJson(),
          'group_id': other,
        }, label: 'qa-c')).$1,
        403,
      );
    }
    expect(
      (await send(
        sharedRecordRoute,
        getRecord(record.resourceId, targetGroup: other),
        label: 'qa-c',
      )).$1,
      403,
    );
    expect(
      (await send(
        sharedRepliesRoute,
        sharePage(other, record: record.resourceId).toJson(),
        label: 'qa-c',
      )).$1,
      403,
    );
    expect(
      (await send(
        sharingGrantsRoute,
        sharePage(group).toJson(),
        label: 'qa-b',
      )).$2['grants'],
      isEmpty,
    );
    for (final command in commands.where(
      (c) => [
        SharingCommandKind.stop,
        SharingCommandKind.publish,
        SharingCommandKind.remove,
      ].contains(c.kind),
    )) {
      expect(
        (await send(route(command), command.toJson(), label: 'qa-b')).$1,
        403,
      );
    }
    expect((await send(route(commands.last), commands.last.toJson())).$1, 403);
  });

  test('five concurrent retries create one record and one reply', () async {
    final command = publishRecord(group, grant, now);
    final results = await Future.wait(
      List.generate(5, (_) => send(route(command), command.toJson())),
    );
    expect(results.every((r) => r.$1 == 200 || r.$1 == 429), true);
    final successes = results.where((r) => r.$1 == 200).toList();
    expect(successes, isNotEmpty);
    expect(successes.map((r) => r.$2['resource_id']).toSet(), hasLength(1));
    final record = await ok('qa-a', command);
    final reply = shareCommand(SharingCommandKind.reply, group, {
      'record_id': record.resourceId,
      'text': 'Synthetic',
    });
    await Future.wait(
      List.generate(
        5,
        (_) => send(route(reply), reply.toJson(), label: 'qa-b'),
      ),
    );
    await ok('qa-b', reply);
    expect(store.sharedFeed('qa-b', sharePage(group)).records, hasLength(1));
    expect(
      store
          .sharedReplies('qa-a', sharePage(group, record: record.resourceId))
          .replies,
      hasLength(1),
    );
    expect(
      (await send(route(command), {
        ...command.toJson(),
        'text': 'changed',
      })).$2['error'],
      'operation_conflict',
    );
  });

  test('malformed, excessive and private-field requests fail without logged contents', () async {
    final command = publishRecord(group, grant, now);
    for (final field in [
      'member_id',
      'owner_id',
      'reminder',
      'planned_time',
      'private_note',
    ]) {
      expect(
        (await send(route(command), {
          ...command.toJson(),
          field: 'private-test-value',
        })).$1,
        400,
      );
    }
    expect(
      (await send(route(command), {
        ...command.toJson(),
        'operation_id': 'private-test-value',
      })).$1,
      400,
    );
    expect(
      (await send(
        route(command),
        command.toJson(),
        raw: '{private-test-value',
      )).$1,
      400,
    );
    expect(
      (await send(route(command), command.toJson(), type: 'text/plain')).$1,
      400,
    );
    expect(
      (await send(
        route(command),
        command.toJson(),
        raw: 'x' * (assistantBodyLimit + 1),
      )).$1,
      413,
    );
    expect(
      (await send(
        '${route(command)}?private=private-test-value',
        command.toJson(),
      )).$1,
      400,
    );
    expect(
      (await send(route(command), command.toJson(), method: 'GET')).$1,
      404,
    );
    expect(jsonEncode(logs), isNot(contains('private-test-value')));
    expect(store.sharedFeed('qa-b', sharePage(group)).records, isEmpty);
  });

  Future<String> delayed(
    SharingCommand command,
    Future<void> Function() interrupt, {
    bool resolve = false,
  }) async {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      server.port,
    );
    try {
      final authenticated = Completer<void>();
      devices.authenticated = authenticated;
      final response = utf8.decoder.bind(socket).join();
      final bytes = utf8.encode(
        jsonEncode(resolve ? resolution(command) : command.toJson()),
      );
      socket.write(
        'POST ${resolve ? publicationResolveRoute : route(command)} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n'
        'Authorization: Bearer ${tokens['qa-a']}\r\nContent-Type: application/json\r\nContent-Length: ${bytes.length}\r\n\r\n',
      );
      await socket.flush();
      // Interleave after real authentication, not after an assumed scheduler delay.
      await authenticated.future.timeout(const Duration(seconds: 5));
      await interrupt();
      socket.add(bytes);
      await socket.flush();
      return await response.timeout(const Duration(seconds: 10));
    } finally {
      socket.destroy();
    }
  }

  test(
    'revocation while body is delayed rejects write after authentication',
    () async {
      final response = await delayed(
        publishRecord(group, grant, now),
        () => devices.revoke('qa-a'),
      );
      expect(response, startsWith('HTTP/1.1 401'));
      expect(store.sharedFeed('qa-b', sharePage(group)).records, isEmpty);
    },
  );

  test(
    'partner leaving while body is delayed rejects every subsequent access',
    () async {
      final response = await delayed(
        publishRecord(group, grant, now),
        () async {
          store.execute('qa-b', PairingCommand.leave(sharingId(), group));
        },
      );
      expect(response, startsWith('HTTP/1.1 403'));
      expect((await send(sharedFeedRoute, sharePage(group).toJson())).$1, 403);
      expect(
        (await send(sharingGrantsRoute, sharePage(group).toJson())).$1,
        403,
      );
    },
  );

  test('stop sharing during body read rejects late publication', () async {
    final response = await delayed(publishRecord(group, grant, now), () async {
      store.executeSharing(
        'qa-a',
        shareCommand(SharingCommandKind.stop, group, {'grant_id': grant}),
      );
    });
    expect(response, startsWith('HTTP/1.1 403'));
    expect(store.sharedFeed('qa-b', sharePage(group)).records, isEmpty);
  });

  test('publication resolution wins against a delayed old body', () async {
    final command = publishRecord(group, grant, now);
    final response = await delayed(command, () async {
      expect(
        (await send('/v1/companion/records/resolve', resolution(command))).$1,
        200,
      );
    });
    expect(response, startsWith('HTTP/1.1 409'));
    expect(response, contains('publication_cancelled'));
    expect(store.sharedFeed('qa-b', sharePage(group)).records, isEmpty);
  });

  test('publication resolution recovers a publication committed during its body read', () async {
    final command = publishRecord(group, grant, now);
    late SharingReceipt receipt;
    final response = await delayed(command, () async {
      receipt = await ok('qa-a', command);
    }, resolve: true);
    expect(response, startsWith('HTTP/1.1 200'));
    expect(response, contains(receipt.resourceId));
    expect(response, isNot(contains('publication_cancelled')));
    expect(store.sharedFeed('qa-b', sharePage(group)).records, hasLength(1));
  });

  test('publication resolution reauthenticates delayed bodies', () async {
    final command = publishRecord(group, grant, now);
    final revoked = await delayed(
      command,
      () => devices.revoke('qa-a'),
      resolve: true,
    );
    expect(revoked, startsWith('HTTP/1.1 401'));
  });

  test(
    'publication resolution checks membership after delayed bodies',
    () async {
      final command = publishRecord(group, grant, now);
      final left = await delayed(command, () async {
        store.execute('qa-b', PairingCommand.leave(sharingId(), group));
      }, resolve: true);
      expect(left, startsWith('HTTP/1.1 403'));
    },
  );

  test(
    'publication resolution cannot recover or cancel another member operation',
    () async {
      final command = publishRecord(group, grant, now);
      final receipt = await ok('qa-a', command);
      final body = resolution(command);
      final partner = await send(publicationResolveRoute, body, label: 'qa-b');
      expect(partner.$1, 200);
      expect(partner.$2['receipt'], isNull);
      expect(partner.$2['error_code'], 'publication_cancelled');
      expect(
        (await send(publicationResolveRoute, body)).$2['receipt'],
        receipt.toJson(),
      );
      pairForSharing(store, 'qa-c', 'qa-d');
      expect(
        (await send(publicationResolveRoute, body, label: 'qa-c')).$1,
        403,
      );
      expect(
        (await send(publicationResolveRoute, {
          ...body,
          'fingerprint': 'f' * 64,
        })).$1,
        409,
      );
      final logsJson = jsonEncode(logs);
      expect(logsJson, isNot(contains(body['fingerprint'])));
      expect(logsJson, isNot(contains(command.text)));
      for (final token in tokens.values) {
        expect(logsJson, isNot(contains(token)));
      }
    },
  );

  test('publication resolution rejects content oversized bodies and non-POST requests', () async {
    final body = resolution(publishRecord(group, grant, now));
    for (final field in ['text', 'photo_ids', 'member_id', 'notes']) {
      expect(
        (await send(publicationResolveRoute, {
          ...body,
          field: 'private-test-value',
        })).$1,
        400,
      );
    }
    expect(
      (await send(
        publicationResolveRoute,
        body,
        raw: '{private-test-value',
      )).$1,
      400,
    );
    expect(
      (await send(publicationResolveRoute, body, type: 'text/plain')).$1,
      400,
    );
    expect(
      (await send(
        publicationResolveRoute,
        body,
        raw: 'x' * (assistantBodyLimit + 1),
      )).$1,
      413,
    );
    expect(
      (await send(
        '$publicationResolveRoute?private=private-test-value',
        body,
      )).$1,
      400,
    );
    expect((await send(publicationResolveRoute, body, method: 'GET')).$1, 404);
    expect(jsonEncode(logs), isNot(contains('private-test-value')));
    expect(store.sharedFeed('qa-b', sharePage(group)).records, isEmpty);
  });
}
