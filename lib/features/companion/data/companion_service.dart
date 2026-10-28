import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

import '../../../shared/service_endpoint.dart';

class CompanionServiceFailure implements Exception {
  const CompanionServiceFailure(
    this.code, {
    this.outcomeUnknown = false,
    this.retryAfter,
  });
  final String code;
  final bool outcomeUnknown;
  final int? retryAfter;

  String get message => switch (code) {
    'unconfigured' || 'not_found' => '陪伴服务尚未连接。',
    'credential' || 'unauthorized' => '请在设置中检查设备凭证。',
    'forbidden' || 'pair_gone' => '这段配对已不可访问，请刷新确认。',
    'pair_unavailable' => '这段配对已结束或不可访问，请刷新确认。',
    'sharing_unavailable' => '这个目标已停止分享，请刷新确认。',
    'record_unavailable' || 'reply_unavailable' => '这条分享或回复已不可访问。',
    'message_unavailable' => '这条消息已删除或不可访问。',
    'photo_unavailable' => '图片尚未上传或已不可访问。',
    'photo_attached' => '图片仍在分享或消息中，请先删除对应内容。',
    'photo_format' ||
    'photo_dimensions' ||
    'photo_size' => '图片格式或大小不符合要求，请重新选择。',
    'upload_in_progress' => '图片仍在上传，请稍后重试确认。',
    'history_not_shareable' => '只能分享开启分享后发生的内容，请检查设备时间。',
    'revision_conflict' => '内容已变化，请刷新后重新操作。',
    'snapshot_changed' => '分享内容已更新，请重新刷新。',
    'invite_invalid' => '邀请码不正确，请检查后重试。',
    'invite_expired' => '邀请码已过期，请对方重新生成。',
    'invite_used' => '邀请码已被使用。',
    'invite_cancelled' => '邀请码已取消。',
    'already_paired' => '你已经有一个配对，请刷新查看。',
    'invite_owner_paired' => '对方已经有一个配对。',
    'invite_self' => '不能使用自己的邀请码。',
    'invite_rate_limited' => '输错次数过多，请稍后再试。',
    'device_busy' => '服务繁忙，请稍后重试。',
    'operation_conflict' => '这次操作的内容已变化，请刷新后重新操作。',
    'operation_pending' => '上次操作尚未确认，请先重试确认结果。',
    'publication_cancelled' => '旧发布已取消，不会重新发送。',
    'draft_conflict' => '草稿已在另一处更新，请重新打开。',
    'interrupted' => '上次操作被中断，结果尚未确认，请重试。',
    'discarded' => '身份或凭证已变化，旧请求的结果不会显示。',
    'cancelled' => outcomeUnknown ? '已取消等待，操作可能已生效，请重新确认。' : '已取消等待。',
    'timeout' => outcomeUnknown ? '等待超时，结果尚未确认；重试不会重复操作。' : '连接超时，请重试。',
    'network' => outcomeUnknown ? '网络中断，结果尚未确认；重试不会重复操作。' : '网络连接失败，请重试。',
    'invalid_request' ||
    'invalid_content_type' ||
    'request_too_large' ||
    'request_read_timeout' ||
    'request_interrupted' => '请求未完成，请重试或更新 App。',
    _ => '服务结果尚未确认，请重试。',
  };
  @override
  String toString() => message;
}

String companionCredentialScope(String credential) {
  if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(credential)) {
    throw const CompanionServiceFailure('credential');
  }
  return sha256.convert(utf8.encode(credential)).toString();
}

class CompanionAccess {
  const CompanionAccess({
    required this.credentialScope,
    required this.isCurrent,
  });
  final String credentialScope;
  final Future<bool> Function() isCurrent;
}

class CompanionCancellation {
  final _ended = Completer<void>();
  bool get isCancelled => _ended.isCompleted;
  void cancel() {
    if (!isCancelled) _ended.complete();
  }
}

abstract interface class CompanionService {
  bool get configured;
  Future<PairingState> state({
    required CompanionAccess access,
    CompanionCancellation? cancellation,
  });
  Future<PairingReceipt> execute(
    PairingCommand command, {
    required CompanionAccess access,
    CompanionCancellation? cancellation,
  });
}

abstract interface class CompanionSharingService {
  bool get configured;
  Future<SharingGrants> grants(
    SharedPageRequest request, {
    required CompanionAccess access,
    CompanionCancellation? cancellation,
  });
  Future<SharedFeedPage> feed(
    SharedPageRequest request, {
    required CompanionAccess access,
    CompanionCancellation? cancellation,
  });
  Future<SharedRecord> record(
    SharedResourceRequest request, {
    required CompanionAccess access,
    CompanionCancellation? cancellation,
  });
  Future<SharedRepliesPage> replies(
    SharedPageRequest request, {
    required CompanionAccess access,
    CompanionCancellation? cancellation,
  });
  Future<SharingReceipt> executeSharing(
    SharingCommand command, {
    required CompanionAccess access,
    CompanionCancellation? cancellation,
  });
}

abstract interface class CompanionMediaService {
  bool get configured;
  Future<CompanionPhotoReceipt> uploadPhoto(
    CompanionPhotoUpload request, {
    required CompanionAccess access,
    CompanionCancellation? cancellation,
  });
  Future<CompanionPhotoDownload> downloadPhoto(
    CompanionPhotoRequest request, {
    required CompanionAccess access,
    CompanionCancellation? cancellation,
  });
  Future<void> removePhoto(
    CompanionPhotoRequest request, {
    required CompanionAccess access,
    CompanionCancellation? cancellation,
  });
}

abstract interface class CompanionPublicationService {
  Future<PublicationResolution> resolvePublication(
    SharingCommand command, {
    required CompanionAccess access,
    CompanionCancellation? cancellation,
  });
}

abstract interface class CompanionChatService {
  bool get configured;
  Future<ChatPage> messages(
    SharedPageRequest request, {
    required CompanionAccess access,
    CompanionCancellation? cancellation,
  });
  Future<ChatReceipt> executeChat(
    ChatCommand command, {
    required CompanionAccess access,
    CompanionCancellation? cancellation,
  });
}

class HttpCompanionService
    implements
        CompanionService,
        CompanionSharingService,
        CompanionMediaService,
        CompanionPublicationService,
        CompanionChatService {
  HttpCompanionService({
    required Uri? endpoint,
    required this.readCredential,
    bool allowInsecureLoopback = false,
    this.timeout = const Duration(seconds: 20),
  }) : endpoint = _endpoint(endpoint, allowInsecureLoopback);

  final Uri? endpoint;
  final Future<String?> Function() readCredential;
  final Duration timeout;
  @override
  bool get configured => endpoint != null;

  static Uri? _endpoint(Uri? endpoint, bool local) {
    try {
      return validateServiceEndpoint(endpoint, allowInsecureLoopback: local);
    } on FormatException {
      throw const CompanionServiceFailure('unconfigured');
    }
  }

  @override
  Future<PairingState> state({
    required CompanionAccess access,
    CompanionCancellation? cancellation,
  }) async {
    final result = await _send(pairingStateRoute, null, access, cancellation);
    try {
      return PairingState.fromJson(result);
    } on FormatException {
      throw const CompanionServiceFailure('invalid_response');
    }
  }

  @override
  Future<PairingReceipt> execute(
    PairingCommand command, {
    required CompanionAccess access,
    CompanionCancellation? cancellation,
  }) async {
    final route = pairingCommandRoutes.entries
        .singleWhere((entry) => entry.value == command.kind)
        .key;
    final result = await _send(
      route,
      command.toJson(),
      access,
      cancellation,
      mutation: true,
    );
    try {
      return PairingReceipt.fromJson(result, operationId: command.operationId);
    } on FormatException {
      throw const CompanionServiceFailure(
        'invalid_response',
        outcomeUnknown: true,
      );
    }
  }

  @override
  Future<SharingGrants> grants(
    SharedPageRequest request, {
    required CompanionAccess access,
    CompanionCancellation? cancellation,
  }) => _sharingRequest(
    sharingGrantsRoute,
    request.toJson(),
    access,
    cancellation,
    (body) => SharingGrants.fromJson(body, request: request),
  );

  @override
  Future<SharedFeedPage> feed(
    SharedPageRequest request, {
    required CompanionAccess access,
    CompanionCancellation? cancellation,
  }) => _sharingRequest(
    sharedFeedRoute,
    request.toJson(),
    access,
    cancellation,
    (body) => SharedFeedPage.fromJson(body, request: request),
  );

  @override
  Future<SharedRecord> record(
    SharedResourceRequest request, {
    required CompanionAccess access,
    CompanionCancellation? cancellation,
  }) => _sharingRequest(
    sharedRecordRoute,
    request.toJson(),
    access,
    cancellation,
    (body) {
      final result = SharedRecord.fromJson(body);
      if (result.id != request.recordId) {
        throw const FormatException('Record identity');
      }
      return result;
    },
  );

  @override
  Future<SharedRepliesPage> replies(
    SharedPageRequest request, {
    required CompanionAccess access,
    CompanionCancellation? cancellation,
  }) => _sharingRequest(
    sharedRepliesRoute,
    request.toJson(),
    access,
    cancellation,
    (body) => SharedRepliesPage.fromJson(body, request: request),
  );

  @override
  Future<SharingReceipt> executeSharing(
    SharingCommand command, {
    required CompanionAccess access,
    CompanionCancellation? cancellation,
  }) => _sharingRequest(
    sharingCommandRoutes.entries
        .singleWhere((e) => e.value == command.kind)
        .key,
    command.toJson(),
    access,
    cancellation,
    (body) => SharingReceipt.fromJson(body, command: command),
    mutation: true,
  );

  @override
  Future<ChatPage> messages(
    SharedPageRequest request, {
    required CompanionAccess access,
    CompanionCancellation? cancellation,
  }) => _sharingRequest(
    chatMessagesRoute,
    request.toJson(),
    access,
    cancellation,
    (body) => ChatPage.fromJson(body, request: request),
  );

  @override
  Future<ChatReceipt> executeChat(
    ChatCommand command, {
    required CompanionAccess access,
    CompanionCancellation? cancellation,
  }) => _sharingRequest(
    chatCommandRoutes.entries.singleWhere((e) => e.value == command.kind).key,
    command.toJson(),
    access,
    cancellation,
    (body) => ChatReceipt.fromJson(body, command: command),
    mutation: true,
  );

  Future<T> _sharingRequest<T>(
    String route,
    Map<String, Object?> body,
    CompanionAccess access,
    CompanionCancellation? cancellation,
    T Function(Object?) parse, {
    bool mutation = false,
  }) async {
    final result = await _send(
      route,
      body,
      access,
      cancellation,
      mutation: mutation,
    );
    try {
      return parse(result);
    } on FormatException {
      throw CompanionServiceFailure(
        'invalid_response',
        outcomeUnknown: mutation,
      );
    }
  }

  @override
  Future<PublicationResolution> resolvePublication(
    SharingCommand command, {
    required CompanionAccess access,
    CompanionCancellation? cancellation,
  }) {
    if (command.kind != SharingCommandKind.publish) {
      throw const CompanionServiceFailure('invalid_request');
    }
    final request = PublicationResolveRequest.fromJson({
      'protocol': companionProtocol,
      'group_id': command.groupId,
      'operation_id': command.operationId,
      'fingerprint': sha256
          .convert(utf8.encode(command.fingerprintInput))
          .toString(),
    });
    return _sharingRequest(
      publicationResolveRoute,
      request.toJson(),
      access,
      cancellation,
      (body) {
        final resolution = PublicationResolution.fromJson(
          body,
          request: request,
        );
        resolution.validateCommand(command);
        return resolution;
      },
      mutation: true,
    );
  }

  @override
  Future<CompanionPhotoReceipt> uploadPhoto(
    CompanionPhotoUpload request, {
    required CompanionAccess access,
    CompanionCancellation? cancellation,
  }) => _sharingRequest(
    companionPhotoUploadRoute,
    request.toJson(),
    access,
    cancellation,
    (body) => CompanionPhotoReceipt.fromJson(body, request: request),
    mutation: true,
  );

  @override
  Future<CompanionPhotoDownload> downloadPhoto(
    CompanionPhotoRequest request, {
    required CompanionAccess access,
    CompanionCancellation? cancellation,
  }) => _sharingRequest(
    companionPhotoReadRoute,
    request.toJson(),
    access,
    cancellation,
    (body) {
      final result = CompanionPhotoDownload.fromJson(body, request: request);
      if (sha256.convert(result.bytes).toString() != result.photo.sha256) {
        throw const FormatException('Photo integrity');
      }
      return result;
    },
  );

  @override
  Future<void> removePhoto(
    CompanionPhotoRequest request, {
    required CompanionAccess access,
    CompanionCancellation? cancellation,
  }) async {
    if (request.operationId == null) {
      throw const CompanionServiceFailure('invalid_request');
    }
    await _sharingRequest<void>(
      companionPhotoRemoveRoute,
      request.toJson(),
      access,
      cancellation,
      (body) {
        final result = CompanionPhotoRequest.fromJson(body, remove: true);
        if (result.operationId != request.operationId ||
            result.groupId != request.groupId ||
            result.photoId != request.photoId) {
          throw const FormatException('Photo removal identity');
        }
      },
      mutation: true,
    );
  }

  Future<Object?> _send(
    String route,
    Map<String, Object?>? body,
    CompanionAccess access,
    CompanionCancellation? cancellation, {
    bool mutation = false,
  }) async {
    HttpClient? client;
    var ended = false;
    var sent = false;
    bool unknown() => sent && mutation;
    CompanionServiceFailure failure(String code) =>
        CompanionServiceFailure(code, outcomeUnknown: unknown());
    Future<void> requireAccess() async {
      if (ended) throw failure('discarded');
      if (cancellation?.isCancelled ?? false) throw failure('cancelled');
      bool valid;
      try {
        valid = await access.isCurrent();
      } catch (_) {
        valid = false;
      }
      if (ended || !valid) throw failure('discarded');
      if (cancellation?.isCancelled ?? false) throw failure('cancelled');
    }

    Future<String> credential() async {
      String? token;
      try {
        token = await readCredential();
      } catch (_) {
        throw failure('credential');
      }
      await requireAccess();
      if (token == null || !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(token)) {
        throw failure('credential');
      }
      if (companionCredentialScope(token) != access.credentialScope) {
        throw failure('discarded');
      }
      return token;
    }

    Future<Object?> perform() async {
      await requireAccess();
      final base = endpoint;
      if (base == null) throw failure('unconfigured');
      await credential();
      final bytes = body == null ? null : utf8.encode(jsonEncode(body));
      final requestLimit = route == companionPhotoUploadRoute
          ? companionMediaBodyLimit
          : assistantBodyLimit;
      if (bytes != null && bytes.length > requestLimit) {
        throw failure('request_too_large');
      }
      final transport = HttpClient()..connectionTimeout = timeout;
      client = transport;
      final outgoing = await transport.openUrl(
        body == null ? 'GET' : 'POST',
        base.replace(path: route),
      );
      final token = await credential();
      outgoing.followRedirects = false;
      outgoing.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      outgoing.headers.contentType = ContentType.json;
      if (bytes != null) {
        outgoing.contentLength = bytes.length;
        outgoing.add(bytes);
      }
      sent = true;
      final response = await outgoing.close();
      if (response.statusCode >= 500) throw failure('unavailable');
      if (response.statusCode >= 300 && response.statusCode < 400) {
        throw failure('invalid_response');
      }
      if (response.statusCode == 413) {
        throw const CompanionServiceFailure('request_too_large');
      }
      if (response.headers.contentType?.mimeType != 'application/json') {
        throw failure('invalid_response');
      }
      final received = <int>[];
      final responseLimit =
          route == companionPhotoReadRoute && response.statusCode == 200
          ? companionMediaBodyLimit
          : assistantBodyLimit;
      if (response.contentLength > responseLimit) {
        throw failure('invalid_response');
      }
      await for (final chunk in response) {
        if (received.length + chunk.length > responseLimit) {
          throw failure('invalid_response');
        }
        received.addAll(chunk);
      }
      await credential();
      final decoded = responseLimit == companionMediaBodyLimit
          ? decodeCompanionMediaJson(utf8.decode(received))
          : decodeAssistantJson(utf8.decode(received));
      if (response.statusCode == 200) return decoded;
      if (decoded is! Map<String, dynamic> ||
          !decoded.containsKey('error') ||
          decoded.keys.any((key) => !['error', 'retry_after'].contains(key)) ||
          _errorStatuses[decoded['error']] != response.statusCode) {
        throw failure('invalid_response');
      }
      final retry = decoded['retry_after'];
      if (retry != null && (retry is! int || retry < 0 || retry > 86400)) {
        throw failure('invalid_response');
      }
      throw CompanionServiceFailure(
        decoded['error'] as String,
        retryAfter: retry as int?,
        outcomeUnknown: mutation && decoded['error'] == 'upload_in_progress',
      );
    }

    try {
      return await Future.any([
        perform(),
        if (cancellation != null)
          cancellation._ended.future.then<Object?>(
            (_) => throw failure('cancelled'),
          ),
      ]).timeout(timeout);
    } on CompanionServiceFailure {
      rethrow;
    } on TimeoutException {
      throw failure('timeout');
    } on FormatException {
      throw failure('invalid_response');
    } catch (_) {
      throw failure('network');
    } finally {
      ended = true;
      client?.close(force: true);
    }
  }
}

const _errorStatuses = <String, int>{
  'message_unavailable': 403,
  'unauthorized': 401,
  'forbidden': 403,
  'browser_origin_rejected': 403,
  'not_found': 404,
  'invite_invalid': 404,
  'invite_expired': 410,
  'invite_used': 409,
  'invite_cancelled': 410,
  'already_paired': 409,
  'invite_owner_paired': 409,
  'invite_self': 409,
  'pair_gone': 410,
  'pair_unavailable': 403,
  'sharing_unavailable': 403,
  'record_unavailable': 403,
  'reply_unavailable': 403,
  'photo_unavailable': 403,
  'photo_attached': 409,
  'photo_format': 400,
  'photo_dimensions': 400,
  'photo_size': 400,
  'upload_in_progress': 409,
  'history_not_shareable': 409,
  'revision_conflict': 409,
  'snapshot_changed': 409,
  'operation_conflict': 409,
  'publication_cancelled': 409,
  'device_busy': 429,
  'invite_rate_limited': 429,
  'invalid_request': 400,
  'invalid_content_type': 400,
  'request_read_timeout': 400,
  'request_interrupted': 400,
};
