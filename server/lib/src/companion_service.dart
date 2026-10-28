import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:xingyuan_core/xingyuan_core.dart';

import 'companion_media.dart';
import 'companion_store.dart';
import 'device_registry.dart';
import 'object_store.dart';

class CompanionService {
  CompanionService({
    required this.devices,
    required this.store,
    required this.log,
    ObjectStore? objects,
    this.readTimeout = const Duration(seconds: 10),
  }) : media = objects == null ? null : CompanionMedia(store, objects);

  static const stateRoute = pairingStateRoute;
  static const commandRoutes = pairingCommandRoutes;
  final DeviceRegistry devices;
  final CompanionStore store;
  final void Function(Map<String, Object?>) log;
  final Duration readTimeout;
  final CompanionMedia? media;
  final Map<String, int> _active = {};

  Future<void> handle(HttpRequest incoming) async {
    final watch = Stopwatch()..start();
    final route =
        incoming.uri.path == stateRoute ||
            commandRoutes.containsKey(incoming.uri.path) ||
            sharingCommandRoutes.containsKey(incoming.uri.path) ||
            sharingReadRoutes.contains(incoming.uri.path) ||
            chatCommandRoutes.containsKey(incoming.uri.path) ||
            incoming.uri.path == chatMessagesRoute ||
            incoming.uri.path == publicationResolveRoute ||
            companionMediaRoutes.contains(incoming.uri.path)
        ? incoming.uri.path
        : 'unknown';
    var status = 500;
    String? device;
    String? operation;
    var reserved = false;
    StreamSubscription<List<int>>? subscription;

    Future<void> respond(int code, Map<String, Object?> body) async {
      status = code;
      try {
        final response = incoming.response;
        response.statusCode = code;
        response.headers.contentType = ContentType.json;
        response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
        if (body['retry_after'] case final int retry) {
          response.headers.set(HttpHeaders.retryAfterHeader, retry.toString());
        }
        if (code != 200) response.persistentConnection = false;
        response.write(jsonEncode(body));
        await response.close();
      } on HttpException {
        // State is already committed; the same operation ID can recover it.
      } on SocketException {
        // Never log transport exceptions containing request or connection data.
      }
    }

    try {
      if (incoming.headers['origin'] != null) {
        await respond(403, {'error': 'browser_origin_rejected'});
        return;
      }
      if (route == 'unknown' ||
          incoming.method != (route == stateRoute ? 'GET' : 'POST')) {
        await respond(404, {'error': 'not_found'});
        return;
      }
      final authorization =
          incoming.headers[HttpHeaders.authorizationHeader]?.singleOrNull;
      device = await devices.authenticate(authorization);
      if (device == null) {
        await respond(401, {'error': 'unauthorized'});
        return;
      }
      Future<void> authenticate() async {
        if (await devices.authenticate(authorization) != device) {
          throw const CompanionFailure(401, 'unauthorized');
        }
      }

      if (incoming.uri.hasQuery) {
        await respond(400, {'error': 'invalid_request'});
        return;
      }
      if ((_active[device] ?? 0) >= 2) {
        await respond(429, {'error': 'device_busy'});
        return;
      }
      _active.update(device, (count) => count + 1, ifAbsent: () => 1);
      reserved = true;
      final bodyLimit = route == companionPhotoUploadRoute
          ? companionMediaBodyLimit
          : assistantBodyLimit;
      if (incoming.contentLength > bodyLimit) {
        await respond(413, {'error': 'request_too_large'});
        return;
      }
      if (route != stateRoute &&
          incoming.headers.contentType?.mimeType != 'application/json') {
        await respond(400, {'error': 'invalid_content_type'});
        return;
      }
      final bytes = <int>[];
      final bodyRead = Completer<void>();
      subscription = incoming.listen(
        (chunk) {
          if (bodyRead.isCompleted) return;
          if (bytes.length + chunk.length > bodyLimit) {
            bodyRead.completeError(const _OversizedBody());
          } else {
            bytes.addAll(chunk);
          }
        },
        onError: (Object error, StackTrace stack) {
          if (!bodyRead.isCompleted) {
            bodyRead.completeError(const _InterruptedBody(), stack);
          }
        },
        onDone: () {
          if (!bodyRead.isCompleted) bodyRead.complete();
        },
      );
      await bodyRead.future.timeout(readTimeout);
      // Revocation can happen while the client is still uploading its body.
      if (await devices.authenticate(authorization) != device) {
        await respond(401, {'error': 'unauthorized'});
        return;
      }
      if (route == stateRoute) {
        if (bytes.isNotEmpty) {
          await respond(400, {'error': 'invalid_request'});
        } else {
          await respond(200, store.state(device).toJson());
        }
        return;
      }
      final payload = route == companionPhotoUploadRoute
          ? decodeCompanionMediaJson(utf8.decode(bytes))
          : decodeAssistantJson(utf8.decode(bytes));
      if (commandRoutes[route] case final kind?) {
        final command = PairingCommand.fromJson(kind, payload);
        operation = command.operationId;
        if (kind == PairingCommandKind.leave && media != null) {
          store.execute(device, command);
          await store.drainPhotoDeletions(media!.objects);
          await authenticate();
        }
        await respond(200, store.execute(device, command).toJson());
      } else if (sharingCommandRoutes[route] case final kind?) {
        final command = SharingCommand.fromJson(kind, payload);
        operation = command.operationId;
        if (media != null) {
          store.executeSharing(device, command);
          await store.drainPhotoDeletions(media!.objects);
          await authenticate();
        }
        await respond(200, store.executeSharing(device, command).toJson());
      } else if (chatCommandRoutes[route] case final kind?) {
        final command = ChatCommand.fromJson(kind, payload);
        operation = command.operationId;
        if (media != null) {
          store.executeChat(device, command);
          await store.drainPhotoDeletions(media!.objects);
          await authenticate();
        }
        await respond(200, store.executeChat(device, command).toJson());
      } else if (route == chatMessagesRoute) {
        await respond(
          200,
          store
              .chatMessages(device, SharedPageRequest.fromJson(payload))
              .toJson(),
        );
      } else if (route == publicationResolveRoute) {
        final request = PublicationResolveRequest.fromJson(payload);
        operation = request.operationId;
        await respond(200, store.resolvePublication(device, request).toJson());
      } else if (companionMediaRoutes.contains(route)) {
        final handler = media;
        if (handler == null) {
          throw const CompanionFailure(503, 'photo_storage_unavailable');
        }
        if (route == companionPhotoUploadRoute) {
          final request = CompanionPhotoUpload.fromJson(payload);
          operation = request.operationId;
          final receipt = await handler.upload(device, request, authenticate);
          await respond(200, receipt.toJson());
        } else if (route == companionPhotoReadRoute) {
          final request = CompanionPhotoRequest.fromJson(payload);
          final download = await handler.download(
            device,
            request,
            authenticate,
          );
          await respond(200, download.toJson());
        } else {
          final request = CompanionPhotoRequest.fromJson(payload, remove: true);
          operation = request.operationId;
          store.removePhoto(device, request);
          await store.drainPhotoDeletions(handler.objects);
          await authenticate();
          await respond(200, store.removePhoto(device, request));
        }
      } else if (route == sharingGrantsRoute) {
        await respond(
          200,
          store
              .sharingGrants(device, SharedPageRequest.fromJson(payload))
              .toJson(),
        );
      } else if (route == sharedFeedRoute) {
        await respond(
          200,
          store
              .sharedFeed(device, SharedPageRequest.fromJson(payload))
              .toJson(),
        );
      } else if (route == sharedRepliesRoute) {
        await respond(
          200,
          store
              .sharedReplies(
                device,
                SharedPageRequest.fromJson(payload, replies: true),
              )
              .toJson(),
        );
      } else if (route == sharedRecordRoute) {
        final request = SharedResourceRequest.fromJson(payload, record: true);
        await respond(
          200,
          store
              .sharedRecord(device, request.groupId, request.recordId!)
              .toJson(),
        );
      }
    } on CompanionFailure catch (error) {
      await respond(error.status, {
        'error': error.code,
        if (error.retryAfter != null) 'retry_after': error.retryAfter,
      });
    } on _OversizedBody {
      await respond(413, {'error': 'request_too_large'});
    } on _InterruptedBody {
      await respond(400, {'error': 'request_interrupted'});
    } on TimeoutException {
      await respond(400, {'error': 'request_read_timeout'});
    } on FormatException {
      await respond(400, {'error': 'invalid_request'});
    } on ObjectStoreFailure {
      await respond(503, {'error': 'photo_storage_unavailable'});
    } catch (_) {
      await respond(500, {'error': 'service_error'});
    } finally {
      await subscription?.cancel();
      if (reserved) {
        final count = (_active[device] ?? 1) - 1;
        if (count == 0) {
          _active.remove(device);
        } else {
          _active[device!] = count;
        }
      }
      log({
        'time': DateTime.now().toUtc().toIso8601String(),
        'request_id': operation,
        'device': device,
        'route': route,
        'status': status,
        'elapsed_ms': watch.elapsedMilliseconds,
      });
    }
  }
}

class _OversizedBody implements Exception {
  const _OversizedBody();
}

class _InterruptedBody implements Exception {
  const _InterruptedBody();
}
