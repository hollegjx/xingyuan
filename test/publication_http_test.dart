import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/companion/data/companion_service.dart';
import 'package:habit_checkin/features/companion/data/publication_runner.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:xingyuan_core/xingyuan_core.dart';

import 'support/publication_fixtures.dart';
import 'support/sharing_fixtures.dart';

// This is a protocol fixture, not a replacement for the compiled-server probe.
void main() {
  setUpAll(tzdata.initializeTimeZones);
  late PublicationFixture f;
  late HttpServer server;
  late PublicationRunner runner;
  late HttpCompanionService service;
  final requests = <({String path, Map<String, dynamic> body})>[];
  final receipts = <String, SharingReceipt>{};
  final fingerprints = <String, String>{};
  final photos = <String, CompanionPhotoReceipt>{};
  final cancelled = <String>{};
  late bool losePublishReply;
  late bool rejectPublish;
  late bool loseUploadReply;
  late bool malformedResolution;
  String? remote;
  final token = 'a' * 43;

  Future<void> bind() async {
    runner = PublicationRunner(
      outbox: f.outbox,
      sharing: service,
      media: service,
      resolution: service,
      files: f.files,
    );
    await runner.initialize();
  }

  setUp(() async {
    requests.clear();
    receipts.clear();
    fingerprints.clear();
    photos.clear();
    cancelled.clear();
    remote = null;
    losePublishReply = false;
    rejectPublish = false;
    loseUploadReply = false;
    malformedResolution = false;
    f = PublicationFixture(credentialScope: companionCredentialScope(token));
    await f.open();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((incoming) async {
      try {
        expect(
          incoming.headers.value(HttpHeaders.authorizationHeader),
          'Bearer $token',
        );
        final body = jsonDecode(
          await utf8.decoder.bind(incoming).join(),
        ) as Map<String, dynamic>;
        final path = incoming.uri.path;
        requests.add((path: path, body: body));
        Object result;
        var status = 200;
        if (path == companionPhotoUploadRoute) {
          final upload = CompanionPhotoUpload.fromJson(body);
          result = photos
              .putIfAbsent(upload.operationId, () => f.photoReceipt(upload))
              .toJson();
          if (loseUploadReply) {
            status = 503;
            result = {'error': 'unavailable'};
          }
        } else if (path == publicationResolveRoute) {
          final request = PublicationResolveRequest.fromJson(body);
          expect(request.fingerprint, fingerprints[request.operationId]);
          final receipt = receipts[request.operationId];
          if (receipt == null) cancelled.add(request.operationId);
          result = {
            ...request.toJson(),
            'fingerprint': malformedResolution ? '0' * 64 : request.fingerprint,
            'receipt': receipt?.toJson(),
            'error_code': receipt == null ? 'publication_cancelled' : null,
          };
        } else {
          final command = SharingCommand.fromJson(
            sharingCommandRoutes[path]!,
            body,
          );
          if (command.kind == SharingCommandKind.publish) {
            fingerprints[command.operationId] = sha256
                .convert(utf8.encode(command.fingerprintInput))
                .toString();
          }
          if (cancelled.contains(command.operationId)) {
            status = 409;
            result = {'error': 'publication_cancelled'};
          } else if (rejectPublish &&
              command.kind == SharingCommandKind.publish) {
            status = 503;
            result = {'error': 'unavailable'};
          } else {
            final receipt = receipts.putIfAbsent(
              command.operationId,
              () => SharingReceipt.fromJson({
                'protocol': companionProtocol,
                'operation_id': command.operationId,
                'group_id': command.groupId,
                'resource_id': command.recordId ?? sharingId(50),
                'revision': command.kind == SharingCommandKind.remove
                    ? 0
                    : command.baseRevision! + 1,
              }, command: command),
            );
            remote = command.kind == SharingCommandKind.remove
                ? null
                : receipt.resourceId;
            result = receipt.toJson();
            if (losePublishReply &&
                command.kind == SharingCommandKind.publish) {
              status = 503;
              result = {'error': 'unavailable'};
            }
          }
        }
        incoming.response.statusCode = status;
        incoming.response.headers.contentType = ContentType.json;
        incoming.response.write(jsonEncode(result));
        await incoming.response.close();
      } catch (failure, stack) {
        incoming.response.statusCode = 500;
        await incoming.response.close();
        Error.throwWithStackTrace(failure, stack);
      }
    });
    service = HttpCompanionService(
      endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
      readCredential: () async => token,
      allowInsecureLoopback: true,
    );
    await bind();
  });

  tearDown(() async {
    runner.dispose();
    await server.close(force: true);
    await f.close();
  });

  List<Map<String, dynamic>> bodies(String route) =>
      requests.where((r) => r.path == route).map((r) => r.body).toList();
  String route(SharingCommandKind kind) =>
      sharingCommandRoutes.entries.singleWhere((e) => e.value == kind).key;

  test('real HTTP photo publication recovers lost success and withdraws without body replay', () async {
    await f.save(
      await f.addPhoto(
        await f.draft('SYNTHETIC never replay after withdrawal'),
      ),
    );
    losePublishReply = true;
    await runner.run();
    expect(remote, isNotNull);
    expect(runner.pending.single.row.status, 'uncertain');
    runner.dispose();
    await f.reopen();
    await bind();
    await f.deleteRecord();
    losePublishReply = false;
    await runner.run();
    expect(remote, isNull);
    expect(runner.pending, isEmpty);
    expect(bodies(companionPhotoUploadRoute), hasLength(1));
    expect(bodies(route(SharingCommandKind.publish)), hasLength(1));
    expect(bodies(route(SharingCommandKind.remove)), hasLength(1));
    expect(bodies(publicationResolveRoute).single.keys.toSet(), {
      'protocol',
      'operation_id',
      'group_id',
      'fingerprint',
    });
    expect(
      jsonEncode(bodies(publicationResolveRoute)),
      isNot(contains('SYNTHETIC')),
    );
  });

  test(
    'malformed resolution cannot release a withdrawn body or unblock successor',
    () async {
      await f.save(await f.draft('SYNTHETIC withdrawn'));
      rejectPublish = true;
      await runner.run();
      await f.deleteRecord();
      malformedResolution = true;
      await runner.run();
      expect(runner.pending, hasLength(2));
      expect(runner.pending.first.row.status, 'uncertain');
      expect(bodies(route(SharingCommandKind.publish)), hasLength(1));
      expect(bodies(route(SharingCommandKind.remove)), isEmpty);
      malformedResolution = false;
      await runner.run();
      expect(runner.pending, isEmpty);
      expect(bodies(route(SharingCommandKind.publish)), hasLength(1));
      expect(bodies(route(SharingCommandKind.remove)), isEmpty);
      expect(remote, isNull);
    },
  );

  test('lost upload response retries same image operation after reopening, then publishes once', () async {
    await f.save(await f.addPhoto(await f.draft('SYNTHETIC image retry')));
    loseUploadReply = true;
    await runner.run();
    final operation = runner.pending.single.row.operationId;
    expect(bodies(route(SharingCommandKind.publish)), isEmpty);
    runner.dispose();
    await f.reopen();
    await bind();
    loseUploadReply = false;
    await runner.run();
    expect(bodies(companionPhotoUploadRoute), hasLength(1));
    await runner.run(retryOperation: operation);
    expect(bodies(companionPhotoUploadRoute), hasLength(2));
    expect(
      bodies(companionPhotoUploadRoute).first,
      bodies(companionPhotoUploadRoute).last,
    );
    expect(bodies(route(SharingCommandKind.publish)), hasLength(1));
    expect(runner.pending, isEmpty);
    expect(
      (await f.records.at(f.goalId, f.clock.day))!.record.syncState,
      'confirmed',
    );
  });
}
