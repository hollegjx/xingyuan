import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/companion/data/companion_service.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

void main() {
  String id(int n) =>
      '00000000-0000-4000-8000-${n.toString().padLeft(12, '0')}';
  final bytes = Uint8List.fromList(List.generate(100000, (i) => i % 256));
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
  CompanionPhotoUpload upload() => CompanionPhotoUpload.fromJson({
    'protocol': companionProtocol,
    'operation_id': id(1),
    'group_id': id(2),
    'purpose': 'record',
    'grant_id': id(3),
    'jpeg_base64': base64Encode(bytes),
  });
  CompanionPhotoRequest request({bool remove = false}) =>
      CompanionPhotoRequest.fromJson({
        'protocol': companionProtocol,
        'group_id': id(2),
        'photo_id': id(4),
        if (remove) 'operation_id': id(6),
      }, remove: remove);
  Map<String, Object?> photo() => {
    'id': id(4),
    'group_id': id(2),
    'author_id': id(5),
    'purpose': 'record',
    'grant_id': id(3),
    'width': 100,
    'height': 100,
    'byte_count': bytes.length,
    'sha256': sha256.convert(bytes).toString(),
  };
  Map<String, Object?> uploadResponse() => {
    'protocol': companionProtocol,
    'operation_id': id(1),
    'photo': photo(),
  };
  Map<String, Object?> downloadResponse() => {
    'protocol': companionProtocol,
    'photo': photo(),
    'jpeg_base64': base64Encode(bytes),
  };
  Matcher failure(String code, bool unknown) => isA<CompanionServiceFailure>()
      .having((e) => e.code, 'code', code)
      .having((e) => e.outcomeUnknown, 'unknown', unknown);
  setUp(() async {
    token = 'a' * 43;
    current = true;
    requests = [];
    response = null;
    status = 200;
    gate = null;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((incoming) async {
      final body = jsonDecode(
        await utf8.decoder.bind(incoming).join(),
      ) as Map<String, dynamic>;
      requests.add({
        'path': incoming.uri.path,
        'authorization': incoming.headers.value('authorization'),
        'body': body,
      });
      final pending = gate;
      if (pending != null) await pending.future;
      final result =
          response ??
          switch (incoming.uri.path) {
            companionPhotoUploadRoute => uploadResponse(),
            companionPhotoReadRoute => downloadResponse(),
            _ => body,
          };
      try {
        incoming.response.statusCode = status;
        incoming.response.headers.contentType = ContentType.json;
        incoming.response.write(jsonEncode(result));
        await incoming.response.close();
      } on SocketException {
        // Cancellation closes this synthetic connection.
      } on HttpException {
        // A late reply must not restart a cancelled request.
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
    expect(requests, hasLength(count));
  }

  test('authenticated media can exceed 64 KiB while upload get and remove remain distinct', () async {
    final sent = upload();
    final receipt = await service.uploadPhoto(sent, access: access());
    expect(receipt.photo.toJson(), photo());
    final got = await service.downloadPhoto(request(), access: access());
    expect(got.bytes, bytes);
    expect(() => got.bytes[0] = 0, throwsUnsupportedError);
    await service.removePhoto(request(remove: true), access: access());
    expect(requests.map((r) => r['path']), [
      companionPhotoUploadRoute,
      companionPhotoReadRoute,
      companionPhotoRemoveRoute,
    ]);
    expect(requests.first['body'], sent.toJson());
    expect(requests.every((r) => r['authorization'] == 'Bearer $token'), true);
  });

  test(
    'wrong digest photo identity and length never become usable downloads',
    () async {
      for (final change in <Map<String, Object?>>[
        {'sha256': 'a' * 64},
        {'id': id(9)},
        {'group_id': id(9)},
        {'byte_count': bytes.length - 1},
      ]) {
        response = {
          ...downloadResponse(),
          'photo': {...photo(), ...change},
        };
        await expectLater(
          service.downloadPhoto(request(), access: access()),
          throwsA(failure('invalid_response', false)),
        );
      }
    },
  );

  test(
    'upload and removal cannot acknowledge a different operation or grant',
    () async {
      for (final change in <Map<String, Object?>>[
        {'operation_id': id(9)},
        {
          'photo': {...photo(), 'grant_id': id(9)},
        },
      ]) {
        response = {...uploadResponse(), ...change};
        await expectLater(
          service.uploadPhoto(upload(), access: access()),
          throwsA(failure('invalid_response', true)),
        );
      }
      for (final field in ['operation_id', 'group_id', 'photo_id']) {
        response = {...request(remove: true).toJson(), field: id(9)};
        await expectLater(
          service.removePhoto(request(remove: true), access: access()),
          throwsA(failure('invalid_response', true)),
        );
      }
    },
  );

  test('remove without an operation fails before network', () async {
    await expectLater(
      service.removePhoto(request(), access: access()),
      throwsA(failure('invalid_request', false)),
    );
    expect(requests, isEmpty);
  });

  test(
    'media failures are allowlisted and busy upload retains unknown outcome',
    () async {
      for (final entry in {
        'photo_format': 400,
        'photo_size': 400,
        'photo_dimensions': 400,
        'photo_attached': 409,
        'photo_unavailable': 403,
        'upload_in_progress': 409,
      }.entries) {
        status = entry.value;
        response = {'error': entry.key};
        await expectLater(
          service.uploadPhoto(upload(), access: access()),
          throwsA(failure(entry.key, entry.key == 'upload_in_progress')),
        );
      }
      status = 503;
      response = {'error': 'photo_cleanup_pending'};
      await expectLater(
        service.removePhoto(request(remove: true), access: access()),
        throwsA(failure('unavailable', true)),
      );
      await expectLater(
        service.downloadPhoto(request(), access: access()),
        throwsA(failure('unavailable', false)),
      );
      status = 400;
      response = {'error': 'SYNTHETIC PRIVATE ERROR'};
      await expectLater(
        service.uploadPhoto(upload(), access: access()),
        throwsA(failure('invalid_response', true)),
      );
    },
  );

  test('large envelopes remain bounded and ordinary success receipts stay at 64 KiB', () async {
    response = {
      'protocol': companionProtocol,
      'padding': 'x' * (assistantBodyLimit + 1),
    };
    await expectLater(
      service.uploadPhoto(upload(), access: access()),
      throwsA(failure('invalid_response', true)),
    );
    response = {
      'protocol': companionProtocol,
      'padding': 'x' * (companionMediaBodyLimit + 1),
    };
    await expectLater(
      service.downloadPhoto(request(), access: access()),
      throwsA(failure('invalid_response', false)),
    );
  });

  test(
    'changed credential before send and identity after response discard media',
    () async {
      token = 'b' * 43;
      await expectLater(
        service.uploadPhoto(upload(), access: access()),
        throwsA(failure('discarded', false)),
      );
      expect(requests, isEmpty);
      token = 'a' * 43;
      gate = Completer<void>();
      final checked = expectLater(
        service.downloadPhoto(request(), access: access()),
        throwsA(failure('discarded', false)),
      );
      await received();
      current = false;
      gate!.complete();
      await checked;
    },
  );

  test(
    'upload cancellation does not retry or report a confirmed deletion',
    () async {
      final preflight = CompanionCancellation()..cancel();
      await expectLater(
        service.uploadPhoto(
          upload(),
          access: access(),
          cancellation: preflight,
        ),
        throwsA(failure('cancelled', false)),
      );
      expect(requests, isEmpty);
      final cancellation = CompanionCancellation();
      gate = Completer<void>();
      final checked = expectLater(
        service.uploadPhoto(
          upload(),
          access: access(),
          cancellation: cancellation,
        ),
        throwsA(failure('cancelled', true)),
      );
      await received();
      cancellation.cancel();
      await checked;
      expect(requests, hasLength(1));
    },
  );

  test('read timeout is not an unknown mutation and write timeout keeps same-operation retry semantics', () async {
    service = HttpCompanionService(
      endpoint: service.endpoint,
      readCredential: () async => token,
      allowInsecureLoopback: true,
      timeout: const Duration(seconds: 1),
    );
    gate = Completer<void>();
    final read = expectLater(
      service.downloadPhoto(request(), access: access()),
      throwsA(failure('timeout', false)),
    );
    await received();
    await read;
    gate!.complete();
    gate = Completer<void>();
    final write = expectLater(
      service.uploadPhoto(upload(), access: access()),
      throwsA(failure('timeout', true)),
    );
    await received(count: 2);
    await write;
    expect(requests, hasLength(2));
  });
}
