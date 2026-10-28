import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:uuid/uuid.dart';
import 'package:xingyuan_core/xingyuan_core.dart';
import 'package:xingyuan_server/src/companion_service.dart';
import 'package:xingyuan_server/src/device_registry.dart';
import 'package:xingyuan_server/src/object_store.dart';

// Exercises the packaged server against an ephemeral local-only configuration.
Future<void> main(List<String> args) async {
  if (args.length != 1 || !File(args.single).isAbsolute) {
    stderr.writeln(
      'Usage: dart run tool/pairing_process_probe.dart /absolute/bundle/bin/server',
    );
    exitCode = 64;
    return;
  }
  final directory = await Directory.systemTemp.createTemp(
    'xingyuan-process-probe-',
  );
  final client = HttpClient();
  Process? process;
  Future<void>? outputDone;
  Future<void>? errorDone;
  final output = StringBuffer();
  final errors = StringBuffer();
  Future<void> stop() async {
    final running = process;
    if (running == null) return;
    process = null;
    running.kill(ProcessSignal.sigterm);
    try {
      await running.exitCode.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      running.kill(ProcessSignal.sigkill);
      await running.exitCode;
    }
    await outputDone;
    await errorDone;
  }

  void require(bool value, String rule) {
    if (!value) throw StateError(rule);
  }

  try {
    final registry = DeviceRegistry('${directory.path}/devices.json');
    final a = await registry.issue('qa-process-a');
    final b = await registry.issue('qa-process-b');
    final outsider = await registry.issue('qa-process-outsider');
    final spare = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = spare.port;
    await spare.close();
    final config = File('${directory.path}/server.json');
    await config.writeAsString(
      jsonEncode({
        'base_url': 'https://example.invalid/v1',
        'model': 'gpt-6-luna',
        'model_api_key': 'synthetic-unused-no-model-requests',
        'port': port,
        'devices_file': registry.path,
        'companion_database': '${directory.path}/data.db',
        'companion_objects': '${directory.path}/objects',
      }),
    );
    require(
      (await Process.run('chmod', ['600', config.path])).exitCode == 0,
      'private-config',
    );
    Future<(int, Map<String, dynamic>)> send(
      String path, {
      String? token,
      PairingCommand? command,
      Map<String, Object?>? body,
    }) async {
      final request = await client.openUrl(
        command == null && body == null ? 'GET' : 'POST',
        Uri.parse('http://127.0.0.1:$port$path'),
      );
      if (token != null) request.headers.set('authorization', 'Bearer $token');
      if (command != null || body != null) {
        request.headers.contentType = ContentType.json;
        request.add(utf8.encode(jsonEncode(body ?? command!.toJson())));
      }
      final response = await request.close();
      return (
        response.statusCode,
        jsonDecode(await utf8.decoder.bind(response).join())
            as Map<String, dynamic>,
      );
    }

    Future<void> start() async {
      process = await Process.start(args.single, ['--config', config.path]);
      outputDone = process!.stdout
          .transform(utf8.decoder)
          .forEach(output.write);
      errorDone = process!.stderr.transform(utf8.decoder).forEach(errors.write);
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (true) {
        try {
          if ((await send('/v1/health')).$1 == 200) break;
        } on SocketException {
          // The compiled process has not bound its local socket yet.
        }
        require(DateTime.now().isBefore(deadline), 'startup-deadline');
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }

    await start();
    require(
      (await send(CompanionService.stateRoute)).$1 == 401,
      'unauthorized',
    );
    final create = PairingCommand.createInvite(const Uuid().v4());
    final inviteResponse = await send(
      '/v1/companion/invites/create',
      token: a,
      command: create,
    );
    require(inviteResponse.$1 == 200, 'create-invitation');
    final first = PairingReceipt.fromJson(
      inviteResponse.$2,
      operationId: create.operationId,
    );
    final invite = first.state.invitation!;
    final join = PairingCommand.join(const Uuid().v4(), invite.code);
    final joined = await send('/v1/companion/join', token: b, command: join);
    require(joined.$1 == 200, 'join-invitation');
    final group = PairingReceipt.fromJson(
      joined.$2,
      operationId: join.operationId,
    ).state.group!;
    SharingCommand sharing(
      SharingCommandKind kind,
      Map<String, Object?> fields,
    ) => SharingCommand.fromJson(kind, {
      'protocol': companionProtocol,
      'group_id': group.id,
      'operation_id': const Uuid().v4(),
      ...fields,
    });
    Future<SharingReceipt> apply(String token, SharingCommand command) async {
      final route = sharingCommandRoutes.entries
          .singleWhere((e) => e.value == command.kind)
          .key;
      final response = await send(route, token: token, body: command.toJson());
      require(response.$1 == 200, 'sharing-command');
      return SharingReceipt.fromJson(response.$2, command: command);
    }

    final enabled = await apply(
      a,
      sharing(SharingCommandKind.enable, {'goal_id': const Uuid().v4()}),
    );
    final source = img.Image(width: 24, height: 12);
    source.exif.gpsIfd
      ..gpsLatitude = 12.34
      ..gpsLongitude = 56.78;
    final upload = CompanionPhotoUpload.fromJson({
      'protocol': companionProtocol,
      'operation_id': const Uuid().v4(),
      'group_id': group.id,
      'purpose': 'record',
      'grant_id': enabled.resourceId,
      'jpeg_base64': base64Encode(img.encodeJpg(source)),
    });
    final uploaded = await send(
      companionPhotoUploadRoute,
      token: a,
      body: upload.toJson(),
    );
    require(uploaded.$1 == 200, 'photo-upload');
    final photo = CompanionPhotoReceipt.fromJson(
      uploaded.$2,
      request: upload,
    ).photo;
    final photoRequest = CompanionPhotoRequest.fromJson({
      'protocol': companionProtocol,
      'group_id': group.id,
      'photo_id': photo.id,
    });
    require(
      (await send(
            companionPhotoReadRoute,
            token: b,
            body: photoRequest.toJson(),
          )).$1 ==
          403,
      'staged-photo-private',
    );
    final publish = sharing(SharingCommandKind.publish, {
      'grant_id': enabled.resourceId,
      'source_id': const Uuid().v4(),
      'base_revision': 0,
      'title': 'Synthetic process reading',
      'occurred_at': DateTime.now().toUtc().toIso8601String(),
      'completed_at': null,
      'text': 'Synthetic process record',
      'share_details': true,
      'photo_ids': [photo.id],
    });
    final published = await apply(a, publish);
    PublicationResolveRequest resolution(SharingCommand command) =>
        PublicationResolveRequest.fromJson({
          'protocol': companionProtocol,
          'operation_id': command.operationId,
          'group_id': command.groupId,
          'fingerprint': sha256
              .convert(utf8.encode(command.fingerprintInput))
              .toString(),
        });
    Future<PublicationResolution> resolve(SharingCommand command) async {
      final request = resolution(command);
      final response = await send(
        publicationResolveRoute,
        token: a,
        body: request.toJson(),
      );
      require(response.$1 == 200, 'publication-resolution');
      final result = PublicationResolution.fromJson(
        response.$2,
        request: request,
      );
      result.validateCommand(command);
      return result;
    }

    final withdrawn = sharing(SharingCommandKind.publish, {
      ...publish.toJson()..remove('operation_id'),
      'source_id': const Uuid().v4(),
      'text': 'Synthetic withdrawn process record',
      'photo_ids': <String>[],
    });
    require(
      (await resolve(withdrawn)).errorCode == 'publication_cancelled',
      'publication-sealed',
    );
    require(
      (await resolve(publish)).receipt!.resourceId == published.resourceId,
      'publication-recovered',
    );
    final reply = sharing(SharingCommandKind.reply, {
      'record_id': published.resourceId,
      'text': 'Synthetic process reply',
    });
    final replied = await apply(b, reply);
    SharedPageRequest page({String? record}) => SharedPageRequest.fromJson({
      'protocol': companionProtocol,
      'group_id': group.id,
      'before_sequence': null,
      'revision': null,
      'record_id': ?record,
    }, replies: record != null);
    ChatCommand chat(ChatCommandKind kind, Map<String, Object?> fields) =>
        ChatCommand.fromJson(kind, {
          'protocol': companionProtocol,
          'group_id': group.id,
          'operation_id': const Uuid().v4(),
          ...fields,
        });
    Future<ChatReceipt> applyChat(String token, ChatCommand command) async {
      final route = chatCommandRoutes.entries
          .singleWhere((e) => e.value == command.kind)
          .key;
      final response = await send(route, token: token, body: command.toJson());
      require(response.$1 == 200, 'chat-command');
      return ChatReceipt.fromJson(response.$2, command: command);
    }

    final chatUpload = CompanionPhotoUpload.fromJson({
      ...upload.toJson(),
      'operation_id': const Uuid().v4(),
      'purpose': 'chat',
      'grant_id': null,
    });
    final chatUploaded = await send(
      companionPhotoUploadRoute,
      token: a,
      body: chatUpload.toJson(),
    );
    require(chatUploaded.$1 == 200, 'chat-photo-upload');
    final chatPhoto = CompanionPhotoReceipt.fromJson(
      chatUploaded.$2,
      request: chatUpload,
    ).photo;
    final chatPhotoRequest = CompanionPhotoRequest.fromJson({
      'protocol': companionProtocol,
      'group_id': group.id,
      'photo_id': chatPhoto.id,
    });
    require(
      (await send(
            companionPhotoReadRoute,
            token: b,
            body: chatPhotoRequest.toJson(),
          )).$1 ==
          403,
      'chat-staged-photo-private',
    );
    final chatA = chat(ChatCommandKind.send, {
      'text': 'SYNTHETIC process chat A',
      'photo_id': chatPhoto.id,
    });
    final chatB = chat(ChatCommandKind.send, {
      'text': 'SYNTHETIC process chat B',
      'photo_id': null,
    });
    final sentA = await applyChat(a, chatA);
    final sentB = await applyChat(b, chatB);
    final removeChat = chat(ChatCommandKind.remove, {
      'message_id': sentA.messageId,
    });
    for (final (route, body) in [
      ('/v1/companion/chat/send', chatA.toJson()),
      ('/v1/companion/chat/remove', removeChat.toJson()),
      (chatMessagesRoute, page().toJson()),
      (companionPhotoReadRoute, chatPhotoRequest.toJson()),
    ]) {
      require((await send(route, body: body)).$1 == 401, 'chat-no-credential');
      require(
        (await send(route, token: outsider, body: body)).$1 == 403,
        'chat-outside-pair',
      );
    }
    require(
      (await send(
            '/v1/companion/chat/remove',
            token: b,
            body: removeChat.toJson(),
          )).$1 ==
          403,
      'chat-author-only-removal',
    );
    await stop();
    // Simulate a crash after file creation but before metadata finalization.
    final disk = await DiskObjectStore.open('${directory.path}/objects');
    await disk.put(
      const Uuid().v4(),
      img.encodeJpg(img.Image(width: 2, height: 2)),
    );
    final partial = File(
      '${disk.directory}/.pending-${const Uuid().v4()}-${const Uuid().v4()}',
    );
    await partial.writeAsString('SYNTHETIC unfinished');
    await start();
    require(
      (await resolve(withdrawn)).errorCode == 'publication_cancelled',
      'publication-sealed-restart',
    );
    final delayedPublication = await send(
      '/v1/companion/records/publish',
      token: a,
      body: withdrawn.toJson(),
    );
    require(
      delayedPublication.$1 == 409 &&
          delayedPublication.$2['error'] == 'publication_cancelled',
      'publication-late-body-rejected',
    );
    require(
      (await resolve(publish)).receipt!.resourceId == published.resourceId,
      'publication-recovered-restart',
    );
    require(
      (await disk.keys(includePending: true))
              .toSet()
              .containsAll({photo.id, chatPhoto.id}) &&
          (await disk.keys(includePending: true)).length == 2,
      'orphan-cleanup',
    );
    require(!await partial.exists(), 'partial-cleanup');
    final download = await send(
      companionPhotoReadRoute,
      token: b,
      body: photoRequest.toJson(),
    );
    require(download.$1 == 200, 'photo-after-restart');
    final image = CompanionPhotoDownload.fromJson(
      download.$2,
      request: photoRequest,
    );
    require(img.decodeJpg(image.bytes)!.exif.isEmpty, 'photo-exif-cleared');
    require(
      sha256.convert(image.bytes).toString() == photo.sha256,
      'photo-integrity',
    );
    final retriedUpload = await send(
      companionPhotoUploadRoute,
      token: a,
      body: upload.toJson(),
    );
    require(retriedUpload.$1 == 200, 'photo-retry');
    require(
      CompanionPhotoReceipt.fromJson(
            retriedUpload.$2,
            request: upload,
          ).photo.id ==
          photo.id,
      'photo-idempotency',
    );
    final aState = PairingState.fromJson(
      (await send(CompanionService.stateRoute, token: a)).$2,
    );
    require(
      aState.group!.id == group.id && aState.memberId == first.state.memberId,
      'durable-membership',
    );
    final retried = await send('/v1/companion/join', token: b, command: join);
    require(retried.$1 == 200, 'durable-idempotency');
    require(
      PairingReceipt.fromJson(
            retried.$2,
            operationId: join.operationId,
          ).state.group!.id ==
          group.id,
      'same-pair',
    );
    require(
      (await apply(a, publish)).resourceId == published.resourceId,
      'sharing-replay',
    );
    require(
      (await apply(b, reply)).resourceId == replied.resourceId,
      'reply-replay',
    );
    final feed = await send(sharedFeedRoute, token: b, body: page().toJson());
    require(feed.$1 == 200, 'feed-after-restart');
    require(
      SharedFeedPage.fromJson(feed.$2, request: page()).records.single.text ==
          publish.text,
      'durable-record',
    );
    final replies = await send(
      sharedRepliesRoute,
      token: a,
      body: page(record: published.resourceId).toJson(),
    );
    require(replies.$1 == 200, 'replies-after-restart');
    require(
      SharedRepliesPage.fromJson(
            replies.$2,
            request: page(record: published.resourceId),
          ).replies.single.text ==
          reply.text,
      'durable-reply',
    );
    for (var i = 0; i < 5; i++) {
      require(
        (await applyChat(a, chatA)).messageId == sentA.messageId,
        'chat-replay',
      );
      require(
        (await applyChat(b, chatB)).messageId == sentB.messageId,
        'chat-partner-replay',
      );
    }
    final chatList = await send(
      chatMessagesRoute,
      token: b,
      body: page().toJson(),
    );
    require(chatList.$1 == 200, 'chat-after-restart');
    final chatPage = ChatPage.fromJson(chatList.$2, request: page());
    require(
      chatPage.messages.length == 2 && chatPage.revision == 2,
      'chat-idempotency',
    );
    require(
      chatPage.messages[0].id == sentB.messageId &&
          chatPage.messages[1].id == sentA.messageId,
      'chat-order',
    );
    require(
      chatPage.messages[0].text == chatB.text &&
          chatPage.messages[1].photoId == chatPhoto.id,
      'chat-payload-persisted',
    );
    final chatImageResponse = await send(
      companionPhotoReadRoute,
      token: b,
      body: chatPhotoRequest.toJson(),
    );
    require(chatImageResponse.$1 == 200, 'chat-photo-after-restart');
    final chatImage = CompanionPhotoDownload.fromJson(
      chatImageResponse.$2,
      request: chatPhotoRequest,
    );
    require(
      img.decodeJpg(chatImage.bytes)!.exif.isEmpty &&
          sha256.convert(chatImage.bytes).toString() == chatPhoto.sha256,
      'chat-photo-privacy-integrity',
    );
    require(
      (await send(
            '/v1/companion/chat/send',
            token: a,
            body: {...chatA.toJson(), 'text': 'changed'},
          )).$1 ==
          409,
      'chat-payload-binding',
    );
    await applyChat(a, removeChat);
    require(
      !(await disk.keys()).contains(chatPhoto.id),
      'chat-deletion-cleans-file',
    );
    await stop();
    await start();
    require(
      (await applyChat(a, removeChat)).messageId == sentA.messageId,
      'chat-remove-retry-after-restart',
    );
    require(
      (await send(
            '/v1/companion/chat/send',
            token: a,
            body: chatA.toJson(),
          )).$1 ==
          403,
      'deleted-chat-never-resurrects',
    );
    require(
      (await send(
            companionPhotoReadRoute,
            token: b,
            body: chatPhotoRequest.toJson(),
          )).$1 ==
          403,
      'deleted-chat-photo-denied',
    );
    require(
      ChatPage.fromJson(
            (await send(chatMessagesRoute, token: b, body: page().toJson())).$2,
            request: page(),
          ).messages.single.id ==
          sentB.messageId,
      'only-surviving-chat-remains',
    );
    final unpairUpload = CompanionPhotoUpload.fromJson({
      ...chatUpload.toJson(),
      'operation_id': const Uuid().v4(),
    });
    final unpairResponse = await send(
      companionPhotoUploadRoute,
      token: a,
      body: unpairUpload.toJson(),
    );
    require(unpairResponse.$1 == 200, 'chat-unpair-photo-upload');
    final unpairPhoto = CompanionPhotoReceipt.fromJson(
      unpairResponse.$2,
      request: unpairUpload,
    ).photo;
    await applyChat(
      a,
      chat(ChatCommandKind.send, {'text': '', 'photo_id': unpairPhoto.id}),
    );
    await registry.revoke('qa-process-b');
    for (final (route, body) in [
      ('/v1/companion/chat/send', chatB.toJson()),
      ('/v1/companion/chat/remove', removeChat.toJson()),
      (chatMessagesRoute, page().toJson()),
    ]) {
      require(
        (await send(route, token: b, body: body)).$1 == 401,
        'chat-credential-revoked',
      );
    }
    require(
      (await send(
            publicationResolveRoute,
            token: b,
            body: resolution(publish).toJson(),
          )).$1 ==
          401,
      'publication-resolution-revocation',
    );
    require(
      (await send(
            companionPhotoReadRoute,
            token: b,
            body: photoRequest.toJson(),
          )).$1 ==
          401,
      'photo-revocation',
    );
    require(
      (await send(CompanionService.stateRoute, token: b)).$1 == 401,
      'revocation',
    );
    require(
      (await send(sharedFeedRoute, token: b, body: page().toJson())).$1 == 401,
      'content-revocation',
    );
    require(
      (await send(CompanionService.stateRoute, token: a)).$1 == 200,
      'other-credential-independent',
    );
    final leave = PairingCommand.leave(const Uuid().v4(), group.id);
    require(
      (await send('/v1/companion/leave', token: a, command: leave)).$1 == 200,
      'leave',
    );
    require(
      (await disk.keys(includePending: true)).isEmpty,
      'photo-physical-purge',
    );
    require(
      PairingState.fromJson(
            (await send(CompanionService.stateRoute, token: a)).$2,
          ).group ==
          null,
      'unpaired',
    );
    require(
      (await send(sharedFeedRoute, token: a, body: page().toJson())).$1 == 403,
      'content-after-unpair',
    );
    await stop();
    await start();
    for (final (route, body) in [
      ('/v1/companion/chat/send', chatA.toJson()),
      ('/v1/companion/chat/remove', removeChat.toJson()),
      (chatMessagesRoute, page().toJson()),
    ]) {
      require(
        (await send(route, token: a, body: body)).$1 == 403,
        'chat-after-unpair',
      );
    }
    require(
      (await send(
            publicationResolveRoute,
            token: a,
            body: resolution(publish).toJson(),
          )).$1 ==
          403,
      'publication-resolution-after-unpair',
    );
    require(
      (await send(
            companionPhotoReadRoute,
            token: a,
            body: photoRequest.toJson(),
          )).$1 ==
          403,
      'photo-purge-after-restart',
    );
    require(
      (await send(
            sharedRepliesRoute,
            token: a,
            body: page(record: published.resourceId).toJson(),
          )).$1 ==
          403,
      'purge-after-restart',
    );
    await stop();
    final logs = output.toString();
    for (final value in [
      a,
      b,
      outsider,
      invite.code,
      group.id,
      publish.title!,
      publish.text!,
      withdrawn.text!,
      resolution(withdrawn).fingerprint,
      reply.text!,
      chatA.text!,
      chatB.text!,
      base64Encode(upload.bytes),
      'synthetic-unused-no-model-requests',
    ]) {
      require(
        !logs.contains(value) && !errors.toString().contains(value),
        'log-privacy',
      );
    }
    require(errors.isEmpty, 'stderr-empty');
    for (final line in const LineSplitter().convert(logs)) {
      final row = jsonDecode(line) as Map;
      require(
        ![
          '/v1/turn',
          '/v1/summarize',
          '/v1/analyze-day',
        ].contains(row['route']),
        'no-model-call',
      );
    }
    stdout.writeln(
      jsonEncode({
        'passed': true,
        'compiled_process': true,
        'restart': true,
        'idempotency': true,
        'sharing_and_replies': true,
        'publication_resolution': true,
        'authenticated_photos': true,
        'chat_persistence': true,
        'chat_idempotency': true,
        'chat_authorization': true,
        'chat_photo_cleanup': true,
        'orphan_recovery': true,
        'content_revocation': true,
        'revocation': true,
        'log_privacy': true,
        'model_calls': 0,
      }),
    );
  } catch (_) {
    stderr.writeln(
      'Pairing process probe failed; no request, credential or server output is printed.',
    );
    exitCode = 1;
  } finally {
    await stop();
    client.close(force: true);
    await directory.delete(recursive: true);
  }
}
