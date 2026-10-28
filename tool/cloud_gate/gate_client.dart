import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:habit_checkin/data/sync/sync_identity.dart';

import '../check_cloud_config.dart';

enum GateFailureKind {
  input,
  network,
  timeout,
  response,
  authentication,
  rateLimited,
  rejected,
  accountMismatch,
  assertion,
  unexpected,
}

class GateFailure implements Exception {
  const GateFailure(this.kind);
  final GateFailureKind kind;

  @override
  String toString() => 'GateFailure(${kind.name})';
}

class GateResponse {
  const GateResponse(this.status, this.body);
  final int status;
  final Object? body;

  @override
  String toString() => 'GateResponse(status=$status, body=withheld)';
}

typedef GateTransport = Future<GateResponse> Function(
  String method,
  Uri uri,
  Map<String, String> headers,
  Object? body,
);

/// One bounded request with no redirects/retries or response-content logging.
/// Cold connections are intentional; this is a diagnostic, not an SDK benchmark.
Future<GateResponse> gateHttpRequest(
  String method,
  Uri uri,
  Map<String, String> headers,
  Object? body, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    return await (() async {
      final request = await client.openUrl(method, uri);
      request.followRedirects = false;
      headers.forEach(request.headers.set);
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close();
      final bytes = <int>[];
      await for (final chunk in response) {
        if (bytes.length + chunk.length > 65536) {
          throw const GateFailure(GateFailureKind.response);
        }
        bytes.addAll(chunk);
      }
      final text = utf8.decode(bytes);
      return GateResponse(
        response.statusCode,
        text.isEmpty ? null : jsonDecode(text),
      );
    })().timeout(timeout);
  } on GateFailure {
    rethrow;
  } on TimeoutException {
    throw const GateFailure(GateFailureKind.timeout);
  } on SocketException {
    throw const GateFailure(GateFailureKind.network);
  } on HttpException {
    throw const GateFailure(GateFailureKind.network);
  } on HandshakeException {
    throw const GateFailure(GateFailureKind.network);
  } on FormatException {
    throw const GateFailure(GateFailureKind.response);
  } catch (_) {
    throw const GateFailure(GateFailureKind.unexpected);
  } finally {
    client.close(force: true);
  }
}

class GateSession {
  const GateSession._(this.userId, this._accessToken, this._refreshToken);
  final String userId;
  final String _accessToken;
  final String _refreshToken;

  @override
  String toString() => 'GateSession(withheld)';
}

class GateClient {
  factory GateClient(
    String publicConfiguration, {
    GateTransport transport = gateHttpRequest,
  }) {
    validateCloudClientConfig(publicConfiguration);
    final json = jsonDecode(publicConfiguration) as Map<String, dynamic>;
    return GateClient._(
      Uri.parse(json['SUPABASE_URL'] as String),
      json['SUPABASE_PUBLISHABLE_KEY'] as String,
      transport,
    );
  }

  GateClient._(this._origin, this._key, this._transport);
  final Uri _origin;
  final String _key;
  final GateTransport _transport;
  String get projectRef => _origin.host.split('.').first;
  final _observations = <Map<String, Object?>>[];
  List<Map<String, Object?>> get observations =>
      List.unmodifiable(_observations);

  Future<GateResponse> _send(
    String method,
    String path, {
    GateSession? session,
    Map<String, String>? query,
    Object? body,
  }) async {
    final watch = Stopwatch()..start();
    final startedAt = DateTime.now().toUtc();
    GateResponse? response;
    GateFailureKind? failure;
    try {
      response = await _transport(
        method,
        _origin.replace(path: path, queryParameters: query),
        {
          'apikey': _key,
          'Accept': 'application/json',
          if (session != null)
            'Authorization': 'Bearer ${session._accessToken}',
        },
        body,
      );
      return response;
    } on GateFailure catch (error) {
      failure = error.kind;
      rethrow;
    } catch (_) {
      failure = GateFailureKind.unexpected;
      throw const GateFailure(GateFailureKind.unexpected);
    } finally {
      final result = response?.body;
      final code = result is Map
          ? result['code'] ?? result['error_code']
          : null;
      const safeCodes = {
        '42501',
        'PGRST202',
        'PGRST205',
        'PGRST301',
        'otp_expired',
        'over_email_send_rate_limit',
        'over_request_rate_limit',
      };
      _observations.add(
        Map.unmodifiable({
          'method': method,
          'path': path,
          'authorization': session == null ? 'anonymous' : 'authenticated',
          'started_at': startedAt.toIso8601String(),
          'elapsed_us': watch.elapsedMicroseconds,
          if (response != null) 'http_status': response.status,
          if (code != null)
            'code': safeCodes.contains(code) ? code : 'withheld',
          if (path == '/rest/v1/g3_probe_records' && result is List)
            'row_count': result.length,
          if (failure != null) 'failure': failure.name,
        }),
      );
    }
  }

  Future<void> sendCode(String email, {bool createUser = false}) async {
    _email(email);
    _success(
      await _send(
        'POST',
        '/auth/v1/otp',
        body: {'email': email, 'create_user': createUser},
      ),
    );
  }

  Future<GateSession> verifyCode(String email, String code) async {
    _email(email);
    if (!RegExp(r'^[0-9]{6,10}$').hasMatch(code)) {
      throw const GateFailure(GateFailureKind.input);
    }
    return _session(
      await _send(
        'POST',
        '/auth/v1/verify',
        body: {'email': email, 'token': code, 'type': 'email'},
      ),
    );
  }

  Future<GateSession> refresh(GateSession session) async {
    final refreshed = _session(
      await _send(
        'POST',
        '/auth/v1/token',
        query: {'grant_type': 'refresh_token'},
        body: {'refresh_token': session._refreshToken},
      ),
    );
    if (refreshed.userId != session.userId) {
      throw const GateFailure(GateFailureKind.accountMismatch);
    }
    return refreshed;
  }

  Future<void> verifyIdentity(GateSession session) async {
    final response = await _send('GET', '/auth/v1/user', session: session);
    _success(response);
    final user = _object(response.body);
    if (user['id'] != session.userId || user['role'] != 'authenticated') {
      throw const GateFailure(GateFailureKind.accountMismatch);
    }
  }

  Future<void> logout(GateSession session) async => _success(
    await _send(
      'POST',
      '/auth/v1/logout',
      session: session,
      query: {'scope': 'local'},
    ),
  );

  Future<GateResponse> read(String id, {GateSession? session}) {
    _id(id);
    return _send(
      'GET',
      '/rest/v1/g3_probe_records',
      session: session,
      query: {'id': 'eq.$id', 'select': 'id,owner_id,value'},
    );
  }

  Future<GateResponse> write(
    String id,
    int value, {
    GateSession? session,
    String? forgedOwner,
  }) {
    _id(id);
    if (forgedOwner != null) _id(forgedOwner);
    return _send(
      'POST',
      '/rest/v1/rpc/g3_probe_write',
      session: session,
      body: {'p_id': id, 'p_value': value, 'owner_id': ?forgedOwner},
    );
  }

  Future<GateResponse> delete(String id, {GateSession? session}) {
    _id(id);
    return _send(
      'POST',
      '/rest/v1/rpc/g3_probe_delete',
      session: session,
      body: {'p_id': id},
    );
  }

  Future<GateResponse> directMutation(
    String method,
    String id,
    GateSession session, {
    required String owner,
  }) {
    _id(id);
    _id(owner);
    if (!{'POST', 'PATCH', 'DELETE'}.contains(method)) {
      throw const GateFailure(GateFailureKind.input);
    }
    return _send(
      method,
      '/rest/v1/g3_probe_records',
      session: session,
      query: method == 'POST' ? null : {'id': 'eq.$id'},
      body: switch (method) {
        'POST' => {'id': id, 'owner_id': owner, 'value': 91},
        'PATCH' => {'owner_id': owner, 'value': 92},
        _ => null,
      },
    );
  }

  GateSession _session(GateResponse response) {
    _success(response);
    final json = _object(response.body);
    final user = _object(json['user']);
    final id = user['id'];
    final access = json['access_token'];
    final refresh = json['refresh_token'];
    if (id is! String ||
        !SyncIdentity.isUuid(id) ||
        user['role'] != 'authenticated' ||
        access is! String ||
        refresh is! String ||
        !RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(access) ||
        !RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(refresh) ||
        json['token_type'] != 'bearer') {
      throw const GateFailure(GateFailureKind.response);
    }
    return GateSession._(id, access, refresh);
  }

  static void _id(String id) {
    if (!SyncIdentity.isUuid(id)) {
      throw const GateFailure(GateFailureKind.input);
    }
  }

  static void _email(String email) {
    if (email.length > 254 ||
        !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      throw const GateFailure(GateFailureKind.input);
    }
  }
}

Map<String, dynamic> _object(Object? value) {
  if (value is! Map<String, dynamic>) {
    throw const GateFailure(GateFailureKind.response);
  }
  return value;
}

void _success(GateResponse response) {
  if (response.status >= 200 && response.status < 300) return;
  throw GateFailure(switch (response.status) {
    401 => GateFailureKind.authentication,
    429 => GateFailureKind.rateLimited,
    _ => GateFailureKind.rejected,
  });
}
