import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/companion/data/companion_service.dart';
import 'package:uuid/uuid.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

void main() {
  const member = '00000000-0000-4000-8000-000000000001';
  late HttpServer server;
  late HttpCompanionService service;
  late String token;
  late bool current;
  late int reads;
  late List<Map<String, Object?>> requests;
  late int status;
  late Object? responseBody;
  late String? redirect;
  late Completer<void>? gate;
  CompanionAccess access() => CompanionAccess(
    credentialScope: companionCredentialScope('a' * 43),
    isCurrent: () async => current,
  );
  Map<String, Object?> state() => {
    'protocol': companionProtocol,
    'member_id': member,
    'group': null,
    'invitation': null,
  };
  setUp(() async {
    token = 'a' * 43;
    current = true;
    reads = 0;
    requests = [];
    status = 200;
    responseBody = null;
    redirect = null;
    gate = null;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final raw = await utf8.decoder.bind(request).join();
      final body = raw.isEmpty ? null : jsonDecode(raw) as Map<String, dynamic>;
      requests.add({
        'method': request.method,
        'path': request.uri.path,
        'authorization': request.headers.value('authorization'),
        'body': body,
      });
      if (gate != null) await gate!.future;
      request.response.headers.contentType = ContentType.json;
      request.response.statusCode = status;
      if (redirect != null) request.response.headers.set('location', redirect!);
      request.response.write(
        jsonEncode(
          responseBody ??
              (body == null
                  ? state()
                  : {
                      'protocol': companionProtocol,
                      'operation_id': body['operation_id'],
                      'state': state(),
                    }),
        ),
      );
      try {
        await request.response.close();
      } on SocketException {
        /* Timed out client. */
      }
    });
    service = HttpCompanionService(
      endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
      readCredential: () async {
        reads++;
        return token;
      },
      allowInsecureLoopback: true,
    );
  });
  tearDown(() async {
    if (gate != null && !gate!.isCompleted) gate!.complete();
    await server.close(force: true);
  });
  Future<void> received() async {
    final until = DateTime.now().add(const Duration(seconds: 2));
    while (requests.isEmpty && DateTime.now().isBefore(until)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(requests, isNotEmpty);
  }

  TypeMatcher<CompanionServiceFailure> failed(String code, {bool? unknown}) =>
      isA<CompanionServiceFailure>()
          .having((error) => error.code, 'code', code)
          .having(
            (error) => unknown == null || error.outcomeUnknown == unknown,
            'outcomeUnknown',
            true,
          );

  test(
    'state and all commands authenticate without AI consent or private context',
    () async {
      expect((await service.state(access: access())).memberId, member);
      final commands = [
        PairingCommand.createInvite(const Uuid().v4()),
        PairingCommand.cancelInvite(const Uuid().v4(), const Uuid().v4()),
        PairingCommand.join(const Uuid().v4(), 'ABCDEFGH'),
        PairingCommand.leave(const Uuid().v4(), const Uuid().v4()),
      ];
      for (final command in commands) {
        expect(
          (await service.execute(command, access: access())).operationId,
          command.operationId,
        );
      }
      expect(reads, 15);
      expect(
        requests.every((row) => row['authorization'] == 'Bearer $token'),
        true,
      );
      expect(requests.first['method'], 'GET');
      expect(requests.skip(1).map((row) => row['path']), [
        '/v1/companion/invites/create',
        '/v1/companion/invites/cancel',
        '/v1/companion/join',
        '/v1/companion/leave',
      ]);
      expect(
        requests.skip(1).map((row) => row['body']),
        commands.map((command) => command.toJson()),
      );
    },
  );

  test('invalid changed or inaccessible credentials never send', () async {
    token = 'invalid';
    await expectLater(
      service.state(access: access()),
      throwsA(failed('credential', unknown: false)),
    );
    token = 'b' * 43;
    await expectLater(
      service.state(access: access()),
      throwsA(failed('discarded', unknown: false)),
    );
    current = false;
    token = 'a' * 43;
    await expectLater(
      service.state(access: access()),
      throwsA(failed('discarded', unknown: false)),
    );
    expect(requests, isEmpty);
    final inaccessible = HttpCompanionService(
      endpoint: service.endpoint,
      readCredential: () async => throw StateError('private-credential-error'),
      allowInsecureLoopback: true,
    );
    current = true;
    await expectLater(
      inaccessible.state(access: access()),
      throwsA(failed('credential', unknown: false)),
    );
    expect(requests, isEmpty);
  });

  test(
    'late response after identity or credential change is discarded',
    () async {
      gate = Completer<void>();
      final call = service.state(access: access());
      final checked = expectLater(call, throwsA(failed('discarded')));
      await received();
      current = false;
      gate!.complete();
      await checked;
      current = true;
      requests.clear();
      gate = Completer<void>();
      final changed = expectLater(
        service.state(access: access()),
        throwsA(failed('discarded')),
      );
      await received();
      token = 'b' * 43;
      gate!.complete();
      await changed;
    },
  );

  test(
    'slow credential read cannot send after timeout or cancellation',
    () async {
      final pending = Completer<String?>();
      service = HttpCompanionService(
        endpoint: service.endpoint,
        readCredential: () => pending.future,
        allowInsecureLoopback: true,
        timeout: const Duration(milliseconds: 30),
      );
      await expectLater(
        service.state(access: access()),
        throwsA(failed('timeout', unknown: false)),
      );
      pending.complete(token);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(requests, isEmpty);
      final cancellation = CompanionCancellation()..cancel();
      await expectLater(
        service.execute(
          PairingCommand.createInvite(const Uuid().v4()),
          access: access(),
          cancellation: cancellation,
        ),
        throwsA(failed('cancelled', unknown: false)),
      );
      expect(requests, isEmpty);
    },
  );

  test(
    'credential swap before headers are sent prevents any request',
    () async {
      var count = 0;
      service = HttpCompanionService(
        endpoint: service.endpoint,
        readCredential: () async => ++count == 1 ? token : 'b' * 43,
        allowInsecureLoopback: true,
      );
      await expectLater(
        service.execute(
          PairingCommand.createInvite(const Uuid().v4()),
          access: access(),
        ),
        throwsA(failed('discarded', unknown: false)),
      );
      expect(requests, isEmpty);
    },
  );

  test('known domain errors retain safe codes and retry timing', () async {
    final command = PairingCommand.join(const Uuid().v4(), 'ABCDEFGH');
    for (final entry in <String, int>{
      'unauthorized': 401,
      'forbidden': 403,
      'invite_invalid': 404,
      'invite_expired': 410,
      'invite_used': 409,
      'invite_cancelled': 410,
      'already_paired': 409,
      'invite_self': 409,
      'pair_gone': 410,
      'operation_conflict': 409,
      'device_busy': 429,
    }.entries) {
      status = entry.value;
      responseBody = {'error': entry.key};
      await expectLater(
        service.execute(command, access: access()),
        throwsA(failed(entry.key, unknown: false)),
      );
    }
    status = 429;
    responseBody = {'error': 'invite_rate_limited', 'retry_after': 600};
    await expectLater(
      service.execute(command, access: access()),
      throwsA(
        failed(
          'invite_rate_limited',
          unknown: false,
        ).having((dynamic value) => value.retryAfter, 'retry', 600),
      ),
    );
  });

  test('timeout and cancellation never retry automatically or claim no server effect', () async {
    gate = Completer<void>();
    service = HttpCompanionService(
      endpoint: service.endpoint,
      readCredential: () async => token,
      allowInsecureLoopback: true,
      timeout: const Duration(seconds: 1),
    );
    final command = PairingCommand.createInvite(const Uuid().v4());
    await expectLater(
      service.execute(command, access: access()),
      throwsA(failed('timeout', unknown: true)),
    );
    expect(requests, hasLength(1));
    gate!.complete();
    gate = null;
    service = HttpCompanionService(
      endpoint: service.endpoint,
      readCredential: () async => token,
      allowInsecureLoopback: true,
    );
    final retry = await service.execute(command, access: access());
    expect(retry.operationId, command.operationId);
    expect((requests.last['body'] as Map)['operation_id'], command.operationId);
    requests.clear();
    gate = Completer<void>();
    final cancellation = CompanionCancellation();
    final cancelled = expectLater(
      service.execute(command, access: access(), cancellation: cancellation),
      throwsA(failed('cancelled', unknown: true)),
    );
    await received();
    cancellation.cancel();
    await cancelled;
    expect(requests, hasLength(1));
  });

  test(
    'bad success or failure payload never exposes arbitrary server text',
    () async {
      final command = PairingCommand.createInvite(const Uuid().v4());
      for (final body in <Object?>[
        {
          'protocol': companionProtocol,
          'operation_id': const Uuid().v4(),
          'state': state(),
        },
        {...state(), 'private': 'unexpected'},
        'x' * (assistantBodyLimit + 1),
      ]) {
        responseBody = body;
        await expectLater(
          service.execute(command, access: access()),
          throwsA(failed('invalid_response', unknown: true)),
        );
      }
      status = 500;
      responseBody = {'error': 'private-secret-response'};
      await expectLater(
        service.execute(command, access: access()),
        throwsA(failed('unavailable', unknown: true)),
      );
      status = 409;
      responseBody = {'error': 'private-secret-response'};
      try {
        await service.execute(command, access: access());
        fail('expected failure');
      } on CompanionServiceFailure catch (error) {
        expect(error.code, 'invalid_response');
        expect(error.toString(), isNot(contains('private-secret-response')));
      }
    },
  );

  test('redirect is not followed and unsafe endpoint is rejected', () async {
    final other = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var forwarded = 0;
    other.listen((request) async {
      forwarded++;
      await request.response.close();
    });
    try {
      status = 307;
      redirect = 'http://127.0.0.1:${other.port}/v1/companion/state';
      await expectLater(
        service.state(access: access()),
        throwsA(failed('invalid_response')),
      );
      expect(forwarded, 0);
      for (final endpoint in [
        'http://external.invalid',
        'https://user:pass@example.invalid',
        'https://example.invalid/v1',
        'https://example.invalid?secret=1',
        'https://example.invalid#x',
      ]) {
        expect(
          () => HttpCompanionService(
            endpoint: Uri.parse(endpoint),
            readCredential: () async => token,
          ),
          throwsA(failed('unconfigured', unknown: false)),
        );
      }
    } finally {
      await other.close(force: true);
    }
  });
}
