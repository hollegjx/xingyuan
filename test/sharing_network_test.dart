import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/companion/data/companion_service.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

void main() {
  String id(int n) =>
      '00000000-0000-4000-8000-${n.toString().padLeft(12, '0')}';
  late HttpServer server;
  late HttpCompanionService service;
  late String token;
  late bool current;
  late List<Map<String, Object?>> requests;
  late Object? response;
  late int status;
  late Completer<void>? gate;
  CompanionAccess access() => CompanionAccess(
    credentialScope: companionCredentialScope('a' * 43),
    isCurrent: () async => current,
  );
  SharedPageRequest page({bool replies = false}) => SharedPageRequest.fromJson({
    'protocol': companionProtocol,
    'group_id': id(1),
    'before_sequence': null,
    'revision': null,
    if (replies) 'record_id': id(3),
  }, replies: replies);
  SharingCommand command(SharingCommandKind kind) =>
      SharingCommand.fromJson(kind, {
        'protocol': companionProtocol,
        'operation_id': id(2),
        'group_id': id(1),
        ...switch (kind) {
          SharingCommandKind.enable => {'goal_id': id(9)},
          SharingCommandKind.stop => {'grant_id': id(4)},
          SharingCommandKind.publish => {
            'grant_id': id(4),
            'source_id': id(5),
            'base_revision': 0,
            'title': 'Synthetic reading',
            'occurred_at': '2026-10-21T10:00:00.000Z',
            'completed_at': null,
            'share_details': true,
            'text': 'Synthetic shared text',
            'photo_ids': <String>[],
          },
          SharingCommandKind.remove => {'record_id': id(3)},
          SharingCommandKind.reply => {
            'record_id': id(3),
            'text': 'Synthetic reply',
          },
          SharingCommandKind.deleteReply => {'reply_id': id(6)},
        },
      });
  Map<String, Object?> feed() => {
    'protocol': companionProtocol,
    'group_id': id(1),
    'revision': 1,
    'records': <Object>[],
    'next_before': null,
  };
  Map<String, Object?> record() => {
    'id': id(3),
    'author_id': id(7),
    'grant_id': id(4),
    'sequence': 1,
    'revision': 1,
    'title': 'Synthetic reading',
    'occurred_at': '2026-10-21T10:00:00.000Z',
    'completed_at': null,
    'text': 'Synthetic text',
    'photo_ids': <String>[],
  };
  TypeMatcher<CompanionServiceFailure> failed(String code, {bool? unknown}) =>
      isA<CompanionServiceFailure>()
          .having((e) => e.code, 'code', code)
          .having(
            (e) => unknown == null || e.outcomeUnknown == unknown,
            'unknown',
            true,
          );
  setUp(() async {
    token = 'a' * 43;
    current = true;
    requests = [];
    status = 200;
    gate = null;
    response = null;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final body = jsonDecode(
        await utf8.decoder.bind(request).join(),
      ) as Map<String, dynamic>;
      requests.add({
        'path': request.uri.path,
        'method': request.method,
        'authorization': request.headers.value('authorization'),
        'body': body,
      });
      if (gate != null) await gate!.future;
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode(
          response ??
              {
                'protocol': companionProtocol,
                'operation_id': body['operation_id'],
                'group_id': body['group_id'],
                'resource_id': id(3),
                'revision': 1,
              },
        ),
      );
      try {
        await request.response.close();
      } on SocketException {
        // The bounded client has already stopped waiting.
      } on HttpException {
        // A cancelled request must not keep this synthetic server alive.
      }
    });
    service = HttpCompanionService(
      endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
      readCredential: () async => token,
      allowInsecureLoopback: true,
    );
  });
  tearDown(() async {
    if (gate != null && !gate!.isCompleted) gate!.complete();
    await server.close(force: true);
  });
  Future<void> received({int count = 1}) async {
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (requests.length < count && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(requests.length, greaterThanOrEqualTo(count));
  }

  Map<String, Object?> resolutionRequest(SharingCommand value) => {
    'protocol': companionProtocol,
    'group_id': value.groupId,
    'operation_id': value.operationId,
    'fingerprint': sha256
        .convert(utf8.encode(value.fingerprintInput))
        .toString(),
  };
  Map<String, Object?> resolved(
    SharingCommand value, {
    bool rejected = false,
  }) => {
    ...resolutionRequest(value),
    'receipt': rejected
        ? null
        : {
            'protocol': companionProtocol,
            'group_id': value.groupId,
            'operation_id': value.operationId,
            'resource_id': id(3),
            'revision': value.baseRevision! + 1,
          },
    'error_code': rejected ? 'publication_cancelled' : null,
  };

  test('publication resolution sends only fingerprint and identity without old content', () async {
    final value = command(SharingCommandKind.publish);
    for (final rejected in [false, true]) {
      response = resolved(value, rejected: rejected);
      final result = await service.resolvePublication(value, access: access());
      expect(result.toJson(), response);
      expect(requests.last['path'], publicationResolveRoute);
      expect(requests.last['body'], resolutionRequest(value));
      expect(requests.last['authorization'], 'Bearer $token');
      expect(requests.last['method'], 'POST');
      expect(jsonEncode(requests.last['body']), isNot(contains(value.text)));
      expect(jsonEncode(requests.last['body']), isNot(contains(value.title)));
    }
    expect(requests, hasLength(2));
  });

  test('publication resolution cannot resolve a different command kind', () {
    expect(
      () => service.resolvePublication(
        command(SharingCommandKind.reply),
        access: access(),
      ),
      throwsA(failed('invalid_request', unknown: false)),
    );
    expect(requests, isEmpty);
  });

  test(
    'publication resolution validates identity receipt revision and envelope',
    () async {
      final value = command(SharingCommandKind.publish);
      final body = resolved(value);
      final receipt = body['receipt']! as Map<String, Object?>;
      for (final bad in <Object?>[
        {...body, 'operation_id': id(8)},
        {...body, 'group_id': id(8)},
        {...body, 'fingerprint': 'b' * 64},
        {
          ...body,
          'receipt': {...receipt, 'revision': 2},
        },
        {
          ...body,
          'receipt': {...receipt, 'operation_id': id(8)},
        },
        {
          ...body,
          'receipt': {...receipt, 'group_id': id(8)},
        },
        {...body, 'error_code': 'publication_cancelled'},
        {...body, 'receipt': null},
        {...body, 'receipt': null, 'error_code': 'unknown_rejection'},
        {...body, 'text': 'secret'},
        {'unexpected': true},
        {'padding': 'x' * assistantBodyLimit},
      ]) {
        response = bad;
        await expectLater(
          service.resolvePublication(value, access: access()),
          throwsA(failed('invalid_response', unknown: true)),
        );
      }
    },
  );

  test('publication resolution retains unknown outcome after timeout without retry', () async {
    final value = command(SharingCommandKind.publish);
    response = resolved(value, rejected: true);
    gate = Completer<void>();
    service = HttpCompanionService(
      endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
      readCredential: () async => token,
      allowInsecureLoopback: true,
      timeout: const Duration(seconds: 1),
    );
    final checked = expectLater(
      service.resolvePublication(value, access: access()),
      throwsA(failed('timeout', unknown: true)),
    );
    await received();
    await checked;
    expect(requests, hasLength(1));
    gate!.complete();
    final result = await service.resolvePublication(value, access: access());
    expect(result.errorCode, 'publication_cancelled');
    expect(requests, hasLength(2));
    expect(requests.first['body'], requests.last['body']);
  });

  test(
    'publication resolution cancellation distinguishes unsent from uncertain',
    () async {
      final value = command(SharingCommandKind.publish);
      await expectLater(
        service.resolvePublication(
          value,
          access: access(),
          cancellation: CompanionCancellation()..cancel(),
        ),
        throwsA(failed('cancelled', unknown: false)),
      );
      expect(requests, isEmpty);
      gate = Completer<void>();
      response = resolved(value);
      final cancellation = CompanionCancellation();
      final checked = expectLater(
        service.resolvePublication(
          value,
          access: access(),
          cancellation: cancellation,
        ),
        throwsA(failed('cancelled', unknown: true)),
      );
      await received();
      cancellation.cancel();
      await checked;
      expect(requests, hasLength(1));
    },
  );

  test(
    'publication resolution rejects stale credentials and late session results',
    () async {
      final value = command(SharingCommandKind.publish);
      token = 'b' * 43;
      await expectLater(
        service.resolvePublication(value, access: access()),
        throwsA(failed('discarded', unknown: false)),
      );
      expect(requests, isEmpty);
      for (final changeToken in [false, true]) {
        token = 'a' * 43;
        current = true;
        gate = Completer<void>();
        response = resolved(value);
        final checked = expectLater(
          service.resolvePublication(value, access: access()),
          throwsA(failed('discarded', unknown: true)),
        );
        await received(count: changeToken ? 2 : 1);
        if (changeToken) {
          token = 'b' * 43;
        } else {
          current = false;
        }
        gate!.complete();
        await checked;
      }
      expect(requests, hasLength(2));
    },
  );

  test(
    'resolution transport failures never fabricate a definitive cancellation',
    () async {
      final value = command(SharingCommandKind.publish);
      for (final entry in <String, int>{
        'unauthorized': 401,
        'pair_unavailable': 403,
        'operation_conflict': 409,
      }.entries) {
        status = entry.value;
        response = {'error': entry.key};
        await expectLater(
          service.resolvePublication(value, access: access()),
          throwsA(failed(entry.key, unknown: false)),
        );
      }
      for (final code in [302, 503]) {
        status = code;
        await expectLater(
          service.resolvePublication(value, access: access()),
          throwsA(
            failed(
              code == 503 ? 'unavailable' : 'invalid_response',
              unknown: true,
            ),
          ),
        );
      }
    },
  );

  test('all commands send exactly their whitelist payload through credential transport', () async {
    for (final kind in SharingCommandKind.values) {
      final value = command(kind);
      response = {
        'protocol': companionProtocol,
        'operation_id': value.operationId,
        'group_id': value.groupId,
        'resource_id': switch (kind) {
          SharingCommandKind.stop => value.grantId,
          SharingCommandKind.remove => value.recordId,
          SharingCommandKind.deleteReply => value.replyId,
          _ => id(3),
        },
        'revision': switch (kind) {
          SharingCommandKind.publish => value.baseRevision! + 1,
          SharingCommandKind.reply => 1,
          _ => 0,
        },
      };
      final result = await service.executeSharing(value, access: access());
      expect(result.operationId, value.operationId);
      expect(requests.last['body'], value.toJson());
      expect(
        requests.last['path'],
        sharingCommandRoutes.entries.singleWhere((e) => e.value == kind).key,
      );
      expect(requests.last['authorization'], 'Bearer $token');
      expect(requests.last['method'], 'POST');
    }
    expect(requests, hasLength(6));
  });

  test('own grants feed record and replies use scoped POST reads', () async {
    response = {
      'protocol': companionProtocol,
      'group_id': id(1),
      'revision': 1,
      'grants': <Object>[],
      'next_before': null,
    };
    expect((await service.grants(page(), access: access())).grants, isEmpty);
    response = feed();
    expect((await service.feed(page(), access: access())).records, isEmpty);
    response = record();
    expect(
      (await service.record(
        SharedResourceRequest.fromJson({
          'protocol': companionProtocol,
          'group_id': id(1),
          'record_id': id(3),
        }, record: true),
        access: access(),
      )).id,
      id(3),
    );
    response = {
      'protocol': companionProtocol,
      'group_id': id(1),
      'record_id': id(3),
      'revision': 1,
      'replies': <Object>[],
      'next_before': null,
    };
    expect(
      (await service.replies(page(replies: true), access: access())).replies,
      isEmpty,
    );
    expect(requests.map((r) => r['path']), [
      sharingGrantsRoute,
      sharedFeedRoute,
      sharedRecordRoute,
      sharedRepliesRoute,
    ]);
    expect(
      requests.every(
        (r) => r['method'] == 'POST' && r['authorization'] == 'Bearer $token',
      ),
      true,
    );
  });

  test(
    'pair permission and conflict errors stay safe known failures',
    () async {
      for (final entry in <String, int>{
        'pair_unavailable': 403,
        'sharing_unavailable': 403,
        'record_unavailable': 403,
        'reply_unavailable': 403,
        'photo_unavailable': 403,
        'history_not_shareable': 409,
        'revision_conflict': 409,
        'snapshot_changed': 409,
      }.entries) {
        status = entry.value;
        response = {'error': entry.key};
        await expectLater(
          service.executeSharing(
            command(SharingCommandKind.publish),
            access: access(),
          ),
          throwsA(failed(entry.key, unknown: false)),
        );
      }
      status = 403;
      response = {'error': 'private-server-error'};
      await expectLater(
        service.executeSharing(
          command(SharingCommandKind.publish),
          access: access(),
        ),
        throwsA(failed('invalid_response', unknown: true)),
      );
    },
  );

  test(
    'incorrect group resource or operation responses are rejected',
    () async {
      response = {...feed(), 'group_id': id(8)};
      await expectLater(
        service.feed(page(), access: access()),
        throwsA(failed('invalid_response', unknown: false)),
      );
      response = {...record(), 'id': id(8)};
      await expectLater(
        service.record(
          SharedResourceRequest.fromJson({
            'protocol': companionProtocol,
            'group_id': id(1),
            'record_id': id(3),
          }, record: true),
          access: access(),
        ),
        throwsA(failed('invalid_response', unknown: false)),
      );
      response = {
        'protocol': companionProtocol,
        'group_id': id(1),
        'operation_id': id(8),
        'resource_id': id(3),
        'revision': 1,
      };
      await expectLater(
        service.executeSharing(
          command(SharingCommandKind.publish),
          access: access(),
        ),
        throwsA(failed('invalid_response', unknown: true)),
      );
    },
  );

  test(
    'read failure is not an unknown write; sent command timeout is unknown',
    () async {
      service = HttpCompanionService(
        endpoint: service.endpoint,
        readCredential: () async => token,
        allowInsecureLoopback: true,
        timeout: const Duration(seconds: 1),
      );
      gate = Completer<void>();
      response = feed();
      final read = expectLater(
        service.feed(page(), access: access()),
        throwsA(failed('timeout', unknown: false)),
      );
      await received();
      await read;
      gate!.complete();
      gate = Completer<void>();
      final write = expectLater(
        service.executeSharing(
          command(SharingCommandKind.publish),
          access: access(),
        ),
        throwsA(failed('timeout', unknown: true)),
      );
      await received(count: 2);
      await write;
      expect(requests, hasLength(2));
    },
  );

  test('changed credentials before sending and identity after response never cross scopes', () async {
    token = 'b' * 43;
    await expectLater(
      service.feed(page(), access: access()),
      throwsA(failed('discarded', unknown: false)),
    );
    expect(requests, isEmpty);
    token = 'a' * 43;
    response = feed();
    gate = Completer<void>();
    final checked = expectLater(
      service.feed(page(), access: access()),
      throwsA(failed('discarded')),
    );
    await received();
    current = false;
    gate!.complete();
    await checked;
  });

  test(
    'cancelled sharing never silently retries or invents acknowledgement',
    () async {
      final cancelled = CompanionCancellation()..cancel();
      await expectLater(
        service.executeSharing(
          command(SharingCommandKind.reply),
          access: access(),
          cancellation: cancelled,
        ),
        throwsA(failed('cancelled', unknown: false)),
      );
      expect(requests, isEmpty);
      final cancellation = CompanionCancellation();
      gate = Completer<void>();
      final checked = expectLater(
        service.executeSharing(
          command(SharingCommandKind.reply),
          access: access(),
          cancellation: cancellation,
        ),
        throwsA(failed('cancelled', unknown: true)),
      );
      await received();
      cancellation.cancel();
      await checked;
      expect(requests, hasLength(1));
    },
  );
}
