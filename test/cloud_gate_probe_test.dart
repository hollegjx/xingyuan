import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/cloud_gate/authorization_probe.dart';
import '../tool/cloud_gate/gate_client.dart';
import '../tool/run_cloud_gate.dart';
import 'support/sync_fixtures.dart';

class _Request {
  _Request(this.method, this.uri, this.headers, this.body);
  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final Object? body;
  String? get user => switch (headers['Authorization']) {
    'Bearer test-access-a' => accountA.userId,
    'Bearer test-access-b' => accountB.userId,
    _ => null,
  };
}

/// Test-only contract substitute. No real token or hosted request is used.
class _GateServer {
  final rows = <String, Map<String, dynamic>>{};
  final requests = <_Request>[];
  GateResponse? Function(_Request)? intercept;
  static const denied = GateResponse(403, {'code': '42501'});

  Future<GateResponse> call(
    String method,
    Uri uri,
    Map<String, String> headers,
    Object? body,
  ) async {
    final request = _Request(method, uri, headers, body);
    requests.add(request);
    final intercepted = intercept?.call(request);
    if (intercepted != null) return intercepted;
    final path = uri.path;
    if (path == '/auth/v1/otp') return const GateResponse(200, {});
    if (path == '/auth/v1/logout') return const GateResponse(204, null);
    if (path == '/auth/v1/verify' || path == '/auth/v1/token') {
      final json = body as Map;
      final isB =
          json['email'] == 'b@example.invalid' ||
          json['refresh_token'] == 'test-refresh-b';
      return GateResponse(200, {
        'access_token': isB ? 'test-access-b' : 'test-access-a',
        'refresh_token': isB ? 'test-refresh-b' : 'test-refresh-a',
        'token_type': 'bearer',
        'user': {
          'id': isB ? accountB.userId : accountA.userId,
          'role': 'authenticated',
        },
      });
    }
    if (path == '/auth/v1/user') {
      return GateResponse(200, {'id': request.user, 'role': 'authenticated'});
    }
    if (request.user == null) return const GateResponse(401, {'code': '42501'});
    if (path == '/rest/v1/g3_probe_records') {
      if (method != 'GET') return denied;
      final id = uri.queryParameters['id']!.substring(3);
      final row = rows[id];
      return GateResponse(200, [
        if (row != null && row['owner_id'] == request.user) row,
      ]);
    }
    final json = body as Map;
    final id = json['p_id'] as String;
    if (path == '/rest/v1/rpc/g3_probe_delete') {
      if (rows[id]?['owner_id'] != request.user) {
        return const GateResponse(200, false);
      }
      rows.remove(id);
      return const GateResponse(200, true);
    }
    if (path == '/rest/v1/rpc/g3_probe_write') {
      if (json.containsKey('owner_id')) {
        return const GateResponse(404, {'code': 'PGRST202'});
      }
      if (rows.containsKey(id) && rows[id]!['owner_id'] != request.user) {
        return denied;
      }
      final row = {
        'id': id,
        'owner_id': request.user,
        'value': json['p_value'],
      };
      rows[id] = row;
      return GateResponse(200, row);
    }
    throw StateError('Unexpected test route');
  }
}

void main() {
  final ref = 'a' * 20;
  final configuration = jsonEncode({
    'SUPABASE_URL': 'https://$ref.supabase.co',
    'SUPABASE_PUBLISHABLE_KEY': 'sb_publishable_${'x' * 32}',
  });
  late _GateServer server;
  late GateClient client;
  late GateSession a;
  late GateSession b;
  late GateFixtures fixtures;

  setUp(() async {
    server = _GateServer();
    client = GateClient(configuration, transport: server.call);
    a = await client.verifyCode('a@example.invalid', '123456');
    b = await client.verifyCode('b@example.invalid', '654321');
    fixtures = GateFixtures.fresh();
    server.requests.clear();
  });

  AuthorizationProbe probe() =>
      AuthorizationProbe(client: client, a: a, b: b, fixtures: fixtures);

  test(
    'complete authorization matrix checks each role then cleans only run IDs',
    () async {
      const unrelated = syntheticGoalUuid;
      server.rows[unrelated] = {
        'id': unrelated,
        'owner_id': a.userId,
        'value': 88,
      };
      final report = await probe().run();
      expect(report.passed, isTrue);
      expect(report.results.map((r) => r.check), GateCheck.values);
      expect(server.rows.keys, [unrelated]);
      expect(
        server.requests.every((r) => r.uri.host == '$ref.supabase.co'),
        isTrue,
      );
      final anonymous = server.requests.where(
        (r) =>
            r.uri.path.startsWith('/rest/') &&
            !r.headers.containsKey('Authorization'),
      );
      expect(anonymous.length, 3);
      expect(anonymous.every((r) => r.headers.containsKey('apikey')), isTrue);
      final serialized = jsonEncode({
        'report': report.toJson(),
        'requests': client.observations,
      });
      for (final secret in [
        'test-access',
        'test-refresh',
        'example.invalid',
        '123456',
      ]) {
        expect(serialized, isNot(contains(secret)));
      }
      final check = report.results.first;
      expect(check.requestCount, 2);
      expect(client.observations[check.requestStart]['path'], '/auth/v1/user');
      expect(client.observations.any((r) => r['row_count'] == 0), isTrue);
    },
  );

  test(
    'same account is rejected before any mutation or cleanup request',
    () async {
      final report = await AuthorizationProbe(
        client: client,
        a: a,
        b: a,
        fixtures: fixtures,
      ).run();
      expect(report.passed, isFalse);
      expect(report.results.single.failure, GateFailureKind.accountMismatch);
      expect(server.requests, isEmpty);
    },
  );

  test(
    'a signed user endpoint must agree with the authenticated session',
    () async {
      server.intercept = (r) => r.uri.path == '/auth/v1/user'
          ? const GateResponse(200, {
              'id': syntheticGoalUuid,
              'role': 'authenticated',
            })
          : null;
      final report = await probe().run();
      expect(report.results.single.failure, GateFailureKind.accountMismatch);
      expect(server.rows, isEmpty);
    },
  );

  test(
    'unauthorized visibility returning HTTP 200 is still a failure',
    () async {
      server.intercept = (r) =>
          r.method == 'GET' &&
              r.uri.path == '/rest/v1/g3_probe_records' &&
              r.user == b.userId &&
              r.uri.queryParameters['id'] == 'eq.${fixtures.a}'
          ? GateResponse(200, [server.rows[fixtures.a]])
          : null;
      final report = await probe().run();
      expect(report.passed, isFalse);
      expect(report.results.last.check, GateCheck.bCannotReadA);
      expect(report.results.last.failure, GateFailureKind.assertion);
      expect(server.rows, isEmpty);
    },
  );

  for (final (index, response) in [
    const GateResponse(404, {'code': 'PGRST205'}),
    const GateResponse(401, {'code': 'PGRST301'}),
    const GateResponse(503, {'code': '42501'}),
    const GateResponse(403, {'code': 'something_else'}),
    const GateResponse(200, {'code': '42501'}),
  ].indexed) {
    test(
      'non-authorization failure $index is never counted as an RLS pass',
      () async {
        server.intercept = (r) =>
            r.uri.path == '/rest/v1/rpc/g3_probe_write' &&
                r.user == b.userId &&
                (r.body as Map)['p_id'] == fixtures.a
            ? response
            : null;
        final report = await probe().run();
        expect(report.passed, isFalse);
        expect(report.results.last.check, GateCheck.bCannotWriteA);
        final rest = (report.toJson()['checks'] as List).cast<Map>();
        expect(rest.where((r) => r['status'] == 'not_run'), isNotEmpty);
        expect(report.cleanupPassed, isTrue);
      },
    );
  }

  test(
    'unexpected RPC signature error code does not prove forged owner rejected',
    () async {
      server.intercept = (r) =>
          r.uri.path == '/rest/v1/rpc/g3_probe_write' &&
              (r.body as Map).containsKey('owner_id')
          ? const GateResponse(404, {'code': 'PGRST205'})
          : null;
      final report = await probe().run();
      expect(report.results.last.check, GateCheck.forgedOwnerRpc);
      expect(report.passed, isFalse);
    },
  );

  test(
    'failed cleanup is reported even when every authorization check passed',
    () async {
      server.intercept = (r) =>
          r.uri.path == '/rest/v1/rpc/g3_probe_delete' &&
              (r.body as Map)['p_id'] == fixtures.b &&
              r.user == b.userId
          ? const GateResponse(503, {})
          : null;
      final report = await probe().run();
      expect(report.results.length, GateCheck.values.length);
      expect(report.results.every((r) => r.failure == null), isTrue);
      expect(report.cleanupPassed, isFalse);
      expect(report.passed, isFalse);
      expect(server.rows.keys, [fixtures.b]);
      server.intercept = null;
      expect(await probe().cleanup(), isTrue);
      expect(server.rows, isEmpty);
    },
  );

  test('lost write reply still triggers targeted cleanup', () async {
    var lost = false;
    server.intercept = (r) {
      if (!lost && r.uri.path == '/rest/v1/rpc/g3_probe_write') {
        lost = true;
        server.rows[fixtures.a] = {
          'id': fixtures.a,
          'owner_id': a.userId,
          'value': 1,
        };
        throw const GateFailure(GateFailureKind.timeout);
      }
      return null;
    };
    final report = await probe().run();
    expect(report.results.last.failure, GateFailureKind.timeout);
    expect(report.cleanupPassed, isTrue);
    expect(server.rows, isEmpty);
  });

  test(
    'OTP refresh and local logout use the intended REST routes without retries',
    () async {
      await client.sendCode('a@example.invalid');
      expect((server.requests.last.body as Map)['create_user'], isFalse);
      await client.sendCode('a@example.invalid', createUser: true);
      expect((server.requests.last.body as Map)['create_user'], isTrue);
      final refreshed = await client.refresh(a);
      expect(refreshed.userId, a.userId);
      expect(
        server.requests.last.uri.queryParameters['grant_type'],
        'refresh_token',
      );
      expect(
        server.requests.last.headers.containsKey('Authorization'),
        isFalse,
      );
      await client.logout(refreshed);
      expect(server.requests.last.uri.queryParameters, {'scope': 'local'});
      expect(server.requests.length, 4);
    },
  );

  test(
    'authentication errors and transport exceptions never echo private values',
    () async {
      final broken = GateClient(
        configuration,
        transport: (_, _, _, _) async {
          throw const FormatException(
            'private@example.invalid secret-code private-token',
          );
        },
      );
      try {
        await broken.sendCode('a@example.invalid');
        fail('Expected sanitized error');
      } on GateFailure catch (error) {
        expect(error.toString(), 'GateFailure(unexpected)');
      }
      server.intercept = (_) => const GateResponse(429, {
        'message': 'private@example.invalid secret-code',
      });
      await expectLater(
        client.sendCode('a@example.invalid'),
        throwsA(
          isA<GateFailure>().having(
            (e) => e.kind,
            'kind',
            GateFailureKind.rateLimited,
          ),
        ),
      );
      expect(server.requests.length, 1);
      expect(a.toString(), 'GateSession(withheld)');
      expect(
        const GateResponse(200, 'private-token').toString(),
        'GateResponse(status=200, body=withheld)',
      );
    },
  );

  test(
    'refresh cannot change the account associated with the session',
    () async {
      server.intercept = (r) => r.uri.path == '/auth/v1/token'
          ? GateResponse(200, {
              'access_token': 'test-access-b',
              'refresh_token': 'test-refresh-b',
              'token_type': 'bearer',
              'user': {'id': b.userId, 'role': 'authenticated'},
            })
          : null;
      await expectLater(
        client.refresh(a),
        throwsA(
          isA<GateFailure>().having(
            (e) => e.kind,
            'kind',
            GateFailureKind.accountMismatch,
          ),
        ),
      );
    },
  );

  test(
    'malformed session, admin role and header injection are rejected',
    () async {
      for (final change in [
        {
          'user': {'id': a.userId, 'role': 'service_role'},
        },
        {'access_token': 'bad\r\nheader'},
        {'refresh_token': ''},
        {'token_type': 'other'},
        {
          'user': {'id': 'invalid', 'role': 'authenticated'},
        },
      ]) {
        server.intercept = (_) => GateResponse(200, {
          'access_token': 'test-access-a',
          'refresh_token': 'test-refresh-a',
          'token_type': 'bearer',
          'user': {'id': a.userId, 'role': 'authenticated'},
          ...change,
        });
        await expectLater(
          client.verifyCode('a@example.invalid', '123456'),
          throwsA(isA<GateFailure>()),
        );
      }
    },
  );

  test('invalid inputs fail before network activity', () async {
    await expectLater(
      client.sendCode('bad input'),
      throwsA(isA<GateFailure>()),
    );
    await expectLater(
      client.verifyCode('a@example.invalid', 'private-token'),
      throwsA(isA<GateFailure>()),
    );
    expect(() => client.read('not-a-uuid'), throwsA(isA<GateFailure>()));
    expect(
      () => client.directMutation('PUT', fixtures.a, a, owner: a.userId),
      throwsA(isA<GateFailure>()),
    );
    expect(server.requests, isEmpty);
  });

  test('CLI live mode requires an explicit single project and permits no secret args', () {
    for (final args in <List<String>>[
      [],
      ['--project-ref=$ref'],
      ['--live'],
      ['--live', '--project-ref=$ref', '--token=private'],
      ['--live', '--project-ref=$ref', '--live'],
      ['--live', '--project-ref=$ref', '--project-ref=${'b' * 20}'],
      ['--live', '--project-ref=$ref', '--cleanup=../../unknown'],
      [
        '--live',
        '--project-ref=$ref',
        '--cleanup=${fixtures.a}',
        '--create-test-users',
      ],
    ]) {
      expect(() => GateOptions.parse(args), throwsA(isA<GateFailure>()));
    }
    final options = GateOptions.parse(['--live', '--project-ref=$ref']);
    expect(options.createUsers, isFalse);
    expect(options.cleanupRun, isNull);
  });

  test(
    'recovery manifest is credential-free and bound to project run and users',
    () {
      final manifest = GateManifest(
        projectRef: ref,
        runId: fixtures.a,
        ownerA: a.userId,
        ownerB: b.userId,
        fixtures: fixtures,
      );
      final options = GateOptions(projectRef: ref, cleanupRun: fixtures.a);
      final source = jsonEncode(manifest.toJson());
      final restored = GateManifest.decode(source, options);
      expect(restored.fixtures.ids, fixtures.ids);
      expect(source, isNot(contains('token')));
      expect(source, isNot(contains('email')));
      for (final change in [
        {'project_ref': 'b' * 20},
        {'run_id': fixtures.b},
        {'owner_b': a.userId},
        {'owner_a': 'bad'},
        {'access_token': 'test-only-sensitive-value'},
        {
          'fixture_ids': [fixtures.a, fixtures.a, fixtures.a],
        },
        {
          'fixture_ids': [null, 1, {}],
        },
      ]) {
        expect(
          () => GateManifest.decode(
            jsonEncode({...manifest.toJson(), ...change}),
            options,
          ),
          throwsA(isA<GateFailure>()),
        );
      }
      expect(
        () => GateManifest.decode('private-token', options),
        throwsA(isA<GateFailure>()),
      );
    },
  );

  test(
    'report replacement preserves cleanup IDs and owner-only permissions',
    () async {
      final directory = await Directory.systemTemp.createTemp('gate-report-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/run.json');
      final manifest = GateManifest(
        projectRef: ref,
        runId: fixtures.a,
        ownerA: a.userId,
        ownerB: b.userId,
        fixtures: fixtures,
      );
      await file.writeAsString(jsonEncode(manifest.toJson()));
      await persistGateReport(file, {...manifest.toJson(), 'passed': false});
      final restored = GateManifest.decode(
        await file.readAsString(),
        GateOptions(projectRef: ref, cleanupRun: fixtures.a),
      );
      expect(restored.fixtures.ids, fixtures.ids);
      expect((await file.stat()).mode & 0x1ff, 0x180);
      expect(await directory.list().length, 1);
    },
  );

  test(
    'report encoding failure leaves the original manifest unchanged',
    () async {
      final directory = await Directory.systemTemp.createTemp('gate-report-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/run.json');
      const original = '{"version":1}';
      await file.writeAsString(original);
      await expectLater(
        persistGateReport(file, {'invalid': Object()}),
        throwsA(isA<JsonUnsupportedObjectError>()),
      );
      expect(await file.readAsString(), original);
      expect(await directory.list().length, 1);
    },
  );

  test(
    'report replacement refuses symbolic links without modifying their target',
    () async {
      final directory = await Directory.systemTemp.createTemp('gate-report-');
      addTearDown(() => directory.delete(recursive: true));
      final target = File('${directory.path}/original.json');
      await target.writeAsString('original evidence');
      final link = Link('${directory.path}/run.json');
      await link.create(target.path);
      await expectLater(
        persistGateReport(File(link.path), {'passed': true}),
        throwsA(isA<GateFailure>()),
      );
      expect(await target.readAsString(), 'original evidence');
      expect(await link.exists(), isTrue);
    },
  );

  test(
    'HTTP transport refuses redirects instead of forwarding credentials',
    () async {
      final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var count = 0;
      final handling = http.listen((request) async {
        count++;
        request.response.statusCode = 302;
        request.response.headers.set(
          'location',
          'http://127.0.0.1:${http.port}/forbidden',
        );
        request.response.write('{}');
        await request.response.close();
      });
      try {
        final response = await gateHttpRequest(
          'GET',
          Uri.parse('http://127.0.0.1:${http.port}/redirect'),
          {'Authorization': 'Bearer test-only'},
          null,
        );
        expect(response.status, 302);
        expect(count, 1);
      } finally {
        await http.close(force: true);
        await handling.cancel();
      }
    },
  );

  test(
    'HTTP transport rejects oversized or non-JSON bodies with sanitized errors',
    () async {
      final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final handling = http.listen((request) async {
        request.response.write(
          request.uri.path == '/large' ? 'x' * 65537 : 'private-token not-json',
        );
        await request.response.close();
      });
      try {
        for (final route in ['large', 'invalid']) {
          await expectLater(
            gateHttpRequest(
              'GET',
              Uri.parse('http://127.0.0.1:${http.port}/$route'),
              {},
              null,
            ),
            throwsA(
              isA<GateFailure>().having(
                (e) => e.toString(),
                'message',
                'GateFailure(response)',
              ),
            ),
          );
        }
      } finally {
        await http.close(force: true);
        await handling.cancel();
      }
    },
  );

  test(
    'HTTP timeout aborts a stalled request and emits no response content',
    () async {
      final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final handling = http.listen((_) {});
      try {
        await expectLater(
          gateHttpRequest(
            'GET',
            Uri.parse('http://127.0.0.1:${http.port}/stall'),
            {'Authorization': 'Bearer test-only'},
            null,
            timeout: const Duration(milliseconds: 75),
          ),
          throwsA(
            isA<GateFailure>().having(
              (e) => e.kind,
              'kind',
              GateFailureKind.timeout,
            ),
          ),
        );
      } finally {
        await http.close(force: true);
        await handling.cancel();
      }
    },
  );
}
