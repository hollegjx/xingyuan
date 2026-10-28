import 'package:habit_checkin/data/sync/sync_identity.dart';
import 'package:uuid/uuid.dart';

import 'gate_client.dart';

class GateFixtures {
  GateFixtures(this.a, this.b, this.forged) {
    if (![a, b, forged].every(SyncIdentity.isUuid) ||
        {a, b, forged}.length != 3) {
      throw const GateFailure(GateFailureKind.input);
    }
  }
  factory GateFixtures.fresh() =>
      GateFixtures(const Uuid().v4(), const Uuid().v4(), const Uuid().v4());
  final String a;
  final String b;
  final String forged;
  List<String> get ids => [a, b, forged];
}

enum GateCheck {
  identities,
  createA,
  updateA,
  readA,
  createB,
  readB,
  bCannotReadA,
  aCannotReadB,
  bCannotWriteA,
  bCannotDeleteA,
  directInsert,
  directUpdate,
  directDelete,
  forgedOwnerRpc,
  anonymousRead,
  anonymousWrite,
  anonymousDelete,
  aUnchanged,
  deleteA,
  deletedAAbsent,
}

class GateCheckResult {
  const GateCheckResult(
    this.check,
    this.elapsedMicroseconds,
    this.failure,
    this.requestStart,
    this.requestCount,
  );
  final GateCheck check;
  final int elapsedMicroseconds;
  final GateFailureKind? failure;
  final int requestStart;
  final int requestCount;

  Map<String, Object?> toJson() => {
    'check': check.name,
    'elapsed_us': elapsedMicroseconds,
    'status': failure == null ? 'passed' : 'failed',
    'request_start': requestStart,
    'request_count': requestCount,
    if (failure != null) 'failure': failure!.name,
  };
}

class GateReport {
  GateReport(this.results, {required this.cleanupPassed});
  final List<GateCheckResult> results;
  final bool cleanupPassed;
  bool get passed =>
      cleanupPassed &&
      results.length == GateCheck.values.length &&
      results.every((r) => r.failure == null);

  Map<String, Object?> toJson() => {
    'scope': 'G3 synthetic Data API authorization, not production sync RLS',
    'passed': passed,
    'cleanup_passed': cleanupPassed,
    'checks': [
      for (final check in GateCheck.values)
        results.where((r) => r.check == check).firstOrNull?.toJson() ??
            {'check': check.name, 'status': 'not_run'},
    ],
  };
}

class AuthorizationProbe {
  AuthorizationProbe({
    required this.client,
    required this.a,
    required this.b,
    required this.fixtures,
  });
  final GateClient client;
  final GateSession a;
  final GateSession b;
  final GateFixtures fixtures;

  Future<GateReport> run() async {
    final results = <GateCheckResult>[];
    var checkedIdentities = false;
    var cleanupPassed = false;
    Future<void> check(GateCheck id, Future<void> Function() body) async {
      final watch = Stopwatch()..start();
      final requestStart = client.observations.length;
      GateFailureKind? failure;
      try {
        await body();
      } on GateFailure catch (error) {
        failure = error.kind;
      } catch (_) {
        failure = GateFailureKind.unexpected;
      }
      results.add(
        GateCheckResult(
          id,
          watch.elapsedMicroseconds,
          failure,
          requestStart,
          client.observations.length - requestStart,
        ),
      );
      if (failure != null) throw GateFailure(failure);
    }

    try {
      await check(GateCheck.identities, () async {
        if (a.userId == b.userId) {
          throw const GateFailure(GateFailureKind.accountMismatch);
        }
        await client.verifyIdentity(a);
        await client.verifyIdentity(b);
        checkedIdentities = true;
      });
      await check(
        GateCheck.createA,
        () async => expectRecord(
          await client.write(fixtures.a, 1, session: a),
          fixtures.a,
          a.userId,
          1,
        ),
      );
      await check(
        GateCheck.updateA,
        () async => expectRecord(
          await client.write(fixtures.a, 2, session: a),
          fixtures.a,
          a.userId,
          2,
        ),
      );
      await check(
        GateCheck.readA,
        () async => expectRows(
          await client.read(fixtures.a, session: a),
          fixtures.a,
          a.userId,
          2,
        ),
      );
      await check(
        GateCheck.createB,
        () async => expectRecord(
          await client.write(fixtures.b, 3, session: b),
          fixtures.b,
          b.userId,
          3,
        ),
      );
      await check(
        GateCheck.readB,
        () async => expectRows(
          await client.read(fixtures.b, session: b),
          fixtures.b,
          b.userId,
          3,
        ),
      );
      await check(
        GateCheck.bCannotReadA,
        () async => expectEmpty(await client.read(fixtures.a, session: b)),
      );
      await check(
        GateCheck.aCannotReadB,
        () async => expectEmpty(await client.read(fixtures.b, session: a)),
      );
      await check(
        GateCheck.bCannotWriteA,
        () async => expectDenied(await client.write(fixtures.a, 4, session: b)),
      );
      await check(
        GateCheck.bCannotDeleteA,
        () async =>
            expectBoolean(await client.delete(fixtures.a, session: b), false),
      );
      await check(
        GateCheck.directInsert,
        () async => expectDenied(
          await client.directMutation(
            'POST',
            fixtures.forged,
            b,
            owner: a.userId,
          ),
        ),
      );
      await check(
        GateCheck.directUpdate,
        () async => expectDenied(
          await client.directMutation('PATCH', fixtures.a, b, owner: b.userId),
        ),
      );
      await check(
        GateCheck.directDelete,
        () async => expectDenied(
          await client.directMutation('DELETE', fixtures.a, a, owner: a.userId),
        ),
      );
      await check(GateCheck.forgedOwnerRpc, () async {
        final response = await client.write(
          fixtures.forged,
          5,
          session: b,
          forgedOwner: a.userId,
        );
        _assert(
          response.status == 404 &&
              response.body is Map &&
              (response.body as Map)['code'] == 'PGRST202',
        );
      });
      await check(
        GateCheck.anonymousRead,
        () async =>
            expectDenied(await client.read(fixtures.a), anonymous: true),
      );
      await check(
        GateCheck.anonymousWrite,
        () async =>
            expectDenied(await client.write(fixtures.a, 6), anonymous: true),
      );
      await check(
        GateCheck.anonymousDelete,
        () async =>
            expectDenied(await client.delete(fixtures.a), anonymous: true),
      );
      await check(
        GateCheck.aUnchanged,
        () async => expectRows(
          await client.read(fixtures.a, session: a),
          fixtures.a,
          a.userId,
          2,
        ),
      );
      await check(
        GateCheck.deleteA,
        () async =>
            expectBoolean(await client.delete(fixtures.a, session: a), true),
      );
      await check(
        GateCheck.deletedAAbsent,
        () async => expectEmpty(await client.read(fixtures.a, session: a)),
      );
    } on GateFailure {
      // Remaining checks stay NOT RUN; a failed prerequisite is not a denial.
    } finally {
      if (checkedIdentities) cleanupPassed = await cleanup();
    }
    return GateReport(List.unmodifiable(results), cleanupPassed: cleanupPassed);
  }

  /// Only touches this run's three UUIDs in the synthetic gate table.
  Future<bool> cleanup() async {
    var passed = true;
    for (final session in [a, b]) {
      for (final id in fixtures.ids) {
        try {
          final response = await client.delete(id, session: session);
          _assert(response.status == 200 && response.body is bool);
          expectEmpty(await client.read(id, session: session));
        } catch (_) {
          passed = false;
        }
      }
    }
    return passed;
  }
}

void expectRecord(GateResponse response, String id, String owner, int value) {
  _assert(response.status == 200);
  final body = response.body;
  _assert(
    body is Map &&
        body.length == 3 &&
        body['id'] == id &&
        body['owner_id'] == owner &&
        body['value'] == value,
  );
}

void expectRows(GateResponse response, String id, String owner, int value) {
  _assert(
    response.status == 200 &&
        response.body is List &&
        (response.body as List).length == 1,
  );
  expectRecord(
    GateResponse(200, (response.body as List).single),
    id,
    owner,
    value,
  );
}

void expectEmpty(GateResponse response) => _assert(
  response.status == 200 &&
      response.body is List &&
      (response.body as List).isEmpty,
);

void expectBoolean(GateResponse response, bool value) =>
    _assert(response.status == 200 && response.body == value);

void expectDenied(GateResponse response, {bool anonymous = false}) => _assert(
  (response.status == 403 || anonymous && response.status == 401) &&
      response.body is Map &&
      (response.body as Map)['code'] == '42501',
);

void _assert(bool condition) {
  if (!condition) throw const GateFailure(GateFailureKind.assertion);
}
