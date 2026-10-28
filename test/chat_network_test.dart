import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/companion/data/companion_service.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

import 'support/chat_fixtures.dart';
import 'support/pairing_fixtures.dart';
import 'support/sharing_fixtures.dart' show sharingId;

void main() {
  late HttpServer server;
  late HttpCompanionService service;
  late String credential;
  late bool current;
  late List<Map<String, Object?>> requests;
  Completer<void>? gate;
  Object? response;
  int status = 200;
  CompanionAccess access() => CompanionAccess(
    credentialScope: companionCredentialScope('a' * 43),
    isCurrent: () async => current,
  );
  ChatCommand command({bool remove = false}) => ChatCommand.fromJson(
    remove ? ChatCommandKind.remove : ChatCommandKind.send,
    {
      'protocol': companionProtocol,
      'operation_id': sharingId(50),
      'group_id': testGroupId,
      if (remove)
        'message_id': sharingId(10)
      else ...{
        'text': 'SYNTHETIC 👨‍👩‍👧‍👦\nmessage',
        'photo_id': sharingId(40),
      },
    },
  );
  Matcher failure(String code, bool unknown) => isA<CompanionServiceFailure>()
      .having((e) => e.code, 'code', code)
      .having((e) => e.outcomeUnknown, 'unknown', unknown);
  setUp(() async {
    credential = 'a' * 43;
    current = true;
    requests = [];
    gate = null;
    response = null;
    status = 200;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((incoming) async {
      final body = jsonDecode(
        await utf8.decoder.bind(incoming).join(),
      ) as Map<String, dynamic>;
      requests.add({
        'path': incoming.uri.path,
        'authorization': incoming.headers.value('authorization'),
        'body': body,
        'method': incoming.method,
      });
      await gate?.future;
      incoming.response.statusCode = status;
      incoming.response.headers.contentType = ContentType.json;
      incoming.response.write(
        jsonEncode(
          response ??
              {
                'protocol': companionProtocol,
                'group_id': testGroupId,
                'operation_id': body['operation_id'],
                'message_id': sharingId(10),
                'sequence': body.containsKey('message_id') ? 0 : 1,
              },
        ),
      );
      try {
        await incoming.response.close();
      } on SocketException {
        /* Client cancelled. */
      } on HttpException {
        /* Client cancelled. */
      }
    });
    service = HttpCompanionService(
      endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
      readCredential: () async => credential,
      allowInsecureLoopback: true,
    );
  });
  tearDown(() async {
    if (gate != null && !gate!.isCompleted) gate!.complete();
    await server.close(force: true);
  });
  Future<void> received() async {
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (requests.isEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(requests, isNotEmpty);
  }

  test(
    'authenticated send remove and list use bounded dedicated routes',
    () async {
      for (final remove in [false, true]) {
        final request = command(remove: remove);
        final result = await service.executeChat(request, access: access());
        expect(result.operationId, request.operationId);
        expect(
          requests.last['path'],
          remove ? '/v1/companion/chat/remove' : '/v1/companion/chat/send',
        );
        expect(requests.last['body'], request.toJson());
        expect(requests.last['authorization'], 'Bearer $credential');
        expect(requests.last['method'], 'POST');
      }
      response = chatPage([chatMessageJson()]).toJson();
      final result = await service.messages(
        chatPageRequest(),
        access: access(),
      );
      expect(result.messages, hasLength(1));
      expect(requests.last['path'], chatMessagesRoute);
      expect(requests.last['body'], chatPageRequest().toJson());
    },
  );

  test(
    'invalid mutation receipt remains unknown and does not auto retry',
    () async {
      response = {
        'protocol': companionProtocol,
        'operation_id': sharingId(51),
        'group_id': testGroupId,
        'message_id': sharingId(10),
        'sequence': 1,
      };
      await expectLater(
        service.executeChat(command(), access: access()),
        throwsA(failure('invalid_response', true)),
      );
      expect(requests, hasLength(1));
    },
  );

  test(
    'read protocol errors do not masquerade as uncertain mutations',
    () async {
      response = {...chatPage([]).toJson(), 'group_id': sharingId(99)};
      await expectLater(
        service.messages(chatPageRequest(), access: access()),
        throwsA(failure('invalid_response', false)),
      );
      expect(requests, hasLength(1));
    },
  );

  test('invalid credential and pre-cancellation send no request', () async {
    credential = 'b' * 43;
    await expectLater(
      service.executeChat(command(), access: access()),
      throwsA(failure('discarded', false)),
    );
    credential = 'a' * 43;
    final cancellation = CompanionCancellation()..cancel();
    await expectLater(
      service.executeChat(
        command(),
        access: access(),
        cancellation: cancellation,
      ),
      throwsA(failure('cancelled', false)),
    );
    expect(requests, isEmpty);
  });

  for (final read in [false, true]) {
    test(
      'cancelling an in-flight ${read ? 'read' : 'write'} has correct uncertainty',
      () async {
        gate = Completer<void>();
        final cancellation = CompanionCancellation();
        final future = read
            ? service.messages(
                chatPageRequest(),
                access: access(),
                cancellation: cancellation,
              )
            : service.executeChat(
                command(),
                access: access(),
                cancellation: cancellation,
              );
        final assertion = expectLater(
          future,
          throwsA(failure('cancelled', !read)),
        );
        await received();
        cancellation.cancel();
        await assertion;
        expect(requests, hasLength(1));
      },
    );
  }

  test('changed credential rejects late response instead of exposing old conversation', () async {
    gate = Completer<void>();
    response = chatPage([chatMessageJson()]).toJson();
    final future = service.messages(chatPageRequest(), access: access());
    final assertion = expectLater(future, throwsA(failure('discarded', false)));
    await received();
    credential = 'b' * 43;
    gate!.complete();
    await assertion;
  });

  test(
    'authorization and unavailable message errors retain server meaning',
    () async {
      for (final code in [
        'unauthorized',
        'pair_unavailable',
        'message_unavailable',
      ]) {
        status = code == 'unauthorized' ? 401 : 403;
        response = {'error': code};
        await expectLater(
          service.executeChat(command(remove: true), access: access()),
          throwsA(failure(code, false)),
        );
      }
    },
  );
}
