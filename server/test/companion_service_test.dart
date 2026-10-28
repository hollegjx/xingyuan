import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'package:xingyuan_core/xingyuan_core.dart';
import 'package:xingyuan_server/src/companion_service.dart';
import 'package:xingyuan_server/src/companion_store.dart';
import 'package:xingyuan_server/src/device_registry.dart';

void main() {
  late Directory directory;
  late DeviceRegistry devices;
  late CompanionStore store;
  late HttpServer server;
  late HttpClient client;
  late List<Map<String, Object?>> logs;
  late Map<String, String> tokens;
  late DateTime now;
  String id() => const Uuid().v4();
  String route(PairingCommandKind kind) => CompanionService
      .commandRoutes
      .entries
      .singleWhere((entry) => entry.value == kind)
      .key;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('companion-service-');
    devices = DeviceRegistry('${directory.path}/devices.json');
    tokens = {};
    for (final label in ['qa-a', 'qa-b', 'qa-c', 'qa-d']) {
      tokens[label] = await devices.issue(label);
    }
    now = DateTime.utc(2026, 10, 21, 10);
    store = CompanionStore.open('${directory.path}/data.db', now: () => now);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    logs = [];
    final service = CompanionService(
      devices: devices,
      store: store,
      log: logs.add,
      readTimeout: const Duration(milliseconds: 200),
    );
    server.listen(service.handle);
    client = HttpClient();
  });
  tearDown(() async {
    client.close(force: true);
    await server.close(force: true);
    store.close();
    await directory.delete(recursive: true);
  });

  Future<(int, Map<String, dynamic>)> send({
    String label = 'qa-a',
    PairingCommand? command,
    String? path,
    String? method,
    bool noAuth = false,
    String? credential,
    String? origin,
    Object? body,
    String? raw,
    String contentType = 'application/json',
  }) async {
    final request = await client.openUrl(
      method ?? (command == null ? 'GET' : 'POST'),
      Uri.parse(
        'http://127.0.0.1:${server.port}${path ?? (command == null ? CompanionService.stateRoute : route(command.kind))}',
      ),
    );
    if (!noAuth) {
      request.headers.set(
        'authorization',
        'Bearer ${credential ?? tokens[label]}',
      );
    }
    if (origin != null) request.headers.set('origin', origin);
    request.headers.set('content-type', contentType);
    if (raw != null || body != null || command != null) {
      final bytes = utf8.encode(raw ?? jsonEncode(body ?? command!.toJson()));
      request.contentLength = bytes.length;
      request.add(bytes);
    }
    final response = await request.close();
    expect(response.headers.value('cache-control'), 'no-store');
    return (
      response.statusCode,
      jsonDecode(await utf8.decoder.bind(response).join())
          as Map<String, dynamic>,
    );
  }

  Future<PairingReceipt> ok(String label, PairingCommand command) async {
    final result = await send(label: label, command: command);
    expect(result.$1, 200);
    return PairingReceipt.fromJson(result.$2, operationId: command.operationId);
  }

  test('ordinary empty GET is readable but a GET body is rejected', () async {
    final empty = await send();
    expect(empty.$1, 200);
    expect(PairingState.fromJson(empty.$2).group, isNull);
    expect((await send(raw: 'unexpected-private-body')).$1, 400);
    expect(jsonEncode(logs), isNot(contains('unexpected-private-body')));
  });

  test(
    'every pairing endpoint denies absent, wrong and revoked credentials',
    () async {
      final commands = [
        PairingCommand.createInvite(id()),
        PairingCommand.cancelInvite(id(), id()),
        PairingCommand.join(id(), 'ABCDEFGH'),
        PairingCommand.leave(id(), id()),
      ];
      for (final command in <PairingCommand?>[null, ...commands]) {
        expect((await send(command: command, noAuth: true)).$1, 401);
        expect((await send(command: command, credential: 'wrong')).$1, 401);
        expect(
          (await send(
            command: command,
            origin: 'https://untrusted.invalid',
          )).$1,
          403,
        );
      }
      await devices.revoke('qa-a');
      for (final command in <PairingCommand?>[null, ...commands]) {
        expect((await send(command: command)).$1, 401);
      }
      expect((await send(label: 'qa-b')).$1, 200);
    },
  );

  test(
    'complete pairing, forbidden resources, scoped leave and private logs',
    () async {
      final create = PairingCommand.createInvite(id());
      final a = await ok('qa-a', create);
      final invite = a.state.invitation!;
      final b = await ok('qa-b', PairingCommand.join(id(), invite.code));
      final group = b.state.group!;
      expect(
        (await send(
          command: PairingCommand.cancelInvite(id(), invite.id),
          label: 'qa-c',
        )).$1,
        403,
      );
      expect(
        (await send(
          command: PairingCommand.leave(id(), group.id),
          label: 'qa-c',
        )).$1,
        403,
      );
      expect(
        PairingState.fromJson((await send(label: 'qa-c')).$2).group,
        isNull,
      );
      final otherInvite = (await ok(
        'qa-c',
        PairingCommand.createInvite(id()),
      )).state.invitation!;
      final other = (await ok(
        'qa-d',
        PairingCommand.join(id(), otherInvite.code),
      )).state.group!;
      expect(
        (await send(command: PairingCommand.leave(id(), other.id))).$1,
        403,
      );
      final left = await ok('qa-a', PairingCommand.leave(id(), group.id));
      expect(left.state.group, isNull);
      expect(
        PairingState.fromJson((await send(label: 'qa-b')).$2).group,
        isNull,
      );
      expect(
        PairingState.fromJson((await send(label: 'qa-d')).$2).group!.id,
        other.id,
      );
      final encoded = jsonEncode(logs);
      for (final secret in [
        ...tokens.values,
        invite.code,
        otherInvite.code,
        group.id,
        other.id,
      ]) {
        expect(encoded, isNot(contains(secret)));
      }
      expect(
        logs.every(
          (row) => row.keys.toSet().difference({
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

  test(
    'wrong expired used already paired and throttled statuses stay explicit',
    () async {
      final invite = (await ok(
        'qa-a',
        PairingCommand.createInvite(id()),
      )).state.invitation!;
      expect(
        (await send(
          label: 'qa-c',
          command: PairingCommand.join(id(), '22222222'),
        )).$2['error'],
        'invite_invalid',
      );
      now = invite.expiresAt;
      expect(
        (await send(
          label: 'qa-b',
          command: PairingCommand.join(id(), invite.code),
        )).$2['error'],
        'invite_expired',
      );
      final next = (await ok(
        'qa-a',
        PairingCommand.createInvite(id()),
      )).state.invitation!;
      await ok('qa-b', PairingCommand.join(id(), next.code));
      expect(
        (await send(
          label: 'qa-c',
          command: PairingCommand.join(id(), next.code),
        )).$2['error'],
        'invite_used',
      );
      expect(
        (await send(command: PairingCommand.createInvite(id()))).$2['error'],
        'already_paired',
      );
      for (var i = 0; i < 4; i++) {
        await send(label: 'qa-d', command: PairingCommand.join(id(), 'WRONG'));
      }
      final limited = await send(
        label: 'qa-d',
        command: PairingCommand.join(id(), 'WRONG'),
      );
      expect(limited.$1, 429);
      expect(limited.$2['error'], 'invite_rate_limited');
      expect(limited.$2['retry_after'], 600);
    },
  );

  test(
    'duplicates preserve effect and altered operation payload conflicts',
    () async {
      final command = PairingCommand.createInvite(id());
      final results = await Future.wait(
        List.generate(5, (_) => send(command: command)),
      );
      expect(
        results.every((result) => result.$1 == 200 || result.$1 == 429),
        true,
      );
      final successes = results.where((result) => result.$1 == 200).toList();
      expect(successes, isNotEmpty);
      expect(
        successes
            .map(
              (result) => PairingReceipt.fromJson(
                result.$2,
                operationId: command.operationId,
              ).state.invitation!.id,
            )
            .toSet()
            .length,
        1,
      );
      expect(
        (await send(
          command: PairingCommand.join(command.operationId, 'ABCDEFGH'),
        )).$2['error'],
        'operation_conflict',
      );
    },
  );

  test(
    'rejects client identity, extra fields, body type, size and URL data',
    () async {
      final command = PairingCommand.createInvite(id());
      expect(
        (await send(
          command: command,
          body: {...command.toJson(), 'member_id': 'private-value'},
        )).$1,
        400,
      );
      expect(
        (await send(
          command: command,
          body: {...command.toJson(), 'operation_id': 'private-value'},
        )).$1,
        400,
      );
      expect(
        (await send(command: command, raw: '{private-invalid-json')).$1,
        400,
      );
      expect((await send(command: command, contentType: 'text/plain')).$1, 400);
      expect(
        (await send(command: command, raw: 'x' * (assistantBodyLimit + 1))).$1,
        413,
      );
      expect(
        (await send(
          path: '${CompanionService.stateRoute}?private=private-value',
        )).$1,
        400,
      );
      expect((await send(path: '/v1/companion/private-value')).$1, 404);
      expect(jsonEncode(logs), isNot(contains('private-value')));
      expect(jsonEncode(logs), isNot(contains('private-invalid-json')));
    },
  );

  test('revocation during a delayed body prevents database mutation', () async {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      server.port,
    );
    final reply = utf8.decoder.bind(socket).join();
    final body = jsonEncode(PairingCommand.createInvite(id()).toJson());
    socket.write(
      'POST ${route(PairingCommandKind.createInvite)} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nAuthorization: Bearer ${tokens['qa-a']}\r\nContent-Type: application/json\r\nContent-Length: ${utf8.encode(body).length}\r\n\r\n',
    );
    await socket.flush();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await devices.revoke('qa-a');
    socket.write(body);
    await socket.flush();
    final response = await reply.timeout(const Duration(seconds: 3));
    expect(response, startsWith('HTTP/1.1 401'));
    expect(store.state('qa-a').invitation, isNull);
    socket.destroy();
  });

  test('unfinished body times out without leaking or applying operation', () async {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      server.port,
    );
    final reply = utf8.decoder.bind(socket).join();
    socket.write(
      'POST ${route(PairingCommandKind.createInvite)} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nAuthorization: Bearer ${tokens['qa-a']}\r\nContent-Type: application/json\r\nContent-Length: 100\r\n\r\n{',
    );
    await socket.flush();
    expect(
      await reply.timeout(const Duration(seconds: 3)),
      contains('request_read_timeout'),
    );
    expect(store.state('qa-a').invitation, isNull);
    socket.destroy();
  });
}
