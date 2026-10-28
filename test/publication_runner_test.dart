import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/companion/data/companion_service.dart';
import 'package:habit_checkin/features/companion/data/local_pairing_store.dart';
import 'package:habit_checkin/features/companion/data/publication_runner.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:xingyuan_core/xingyuan_core.dart';

import 'support/publication_fixtures.dart';
import 'support/sharing_fixtures.dart';

class _Service extends TestSharingService
    implements CompanionPublicationService {
  _Service(this.fixture);
  final PublicationFixture fixture;
  final resolutions = <SharingCommand>[];
  final uploads = <CompanionPhotoUpload>[];
  final uploaded = <String, CompanionPhotoReceipt>{};
  final cancelled = <String>{};
  CompanionServiceFailure? resolutionFailure;
  Completer<void>? resolutionGate;
  Future<void> Function()? afterWrite;

  Future<void> check(
    CompanionAccess access,
    CompanionCancellation? cancel,
  ) async {
    if (cancel?.isCancelled == true) {
      throw const CompanionServiceFailure('cancelled', outcomeUnknown: true);
    }
    if (!await access.isCurrent()) {
      throw const CompanionServiceFailure('discarded', outcomeUnknown: true);
    }
  }

  @override
  Future<SharingReceipt> executeSharing(
    SharingCommand command, {
    required CompanionAccess access,
    CompanionCancellation? cancellation,
  }) async {
    sharedCommands.add(command);
    await sharedGate?.future;
    await check(access, cancellation);
    if (sharedFailure case final failure?) throw failure;
    if (cancelled.contains(command.operationId)) {
      throw const CompanionServiceFailure('publication_cancelled');
    }
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
    await afterWrite?.call();
    if (afterCommitFailure case final failure?) throw failure;
    await check(access, cancellation);
    return receipt;
  }

  @override
  Future<CompanionPhotoReceipt> uploadPhoto(
    CompanionPhotoUpload request, {
    required CompanionAccess access,
    CompanionCancellation? cancellation,
  }) async {
    uploads.add(request);
    await photoGate?.future;
    await check(access, cancellation);
    if (photoFailure case final failure?) throw failure;
    return uploaded.putIfAbsent(
      request.operationId,
      () => fixture.photoReceipt(
        request,
        remote: sharingId(70 + uploaded.length),
      ),
    );
  }

  @override
  Future<PublicationResolution> resolvePublication(
    SharingCommand command, {
    required CompanionAccess access,
    CompanionCancellation? cancellation,
  }) async {
    resolutions.add(command);
    await resolutionGate?.future;
    await check(access, cancellation);
    if (resolutionFailure case final failure?) throw failure;
    final receipt = receipts[command.operationId];
    if (receipt == null) cancelled.add(command.operationId);
    final request = PublicationResolveRequest.fromJson({
      'protocol': companionProtocol,
      'group_id': command.groupId,
      'operation_id': command.operationId,
      'fingerprint': sha256
          .convert(utf8.encode(command.fingerprintInput))
          .toString(),
    });
    return PublicationResolution.fromJson({
      ...request.toJson(),
      'receipt': receipt?.toJson(),
      'error_code': receipt == null ? 'publication_cancelled' : null,
    }, request: request);
  }
}

void main() {
  setUpAll(tzdata.initializeTimeZones);
  late PublicationFixture f;
  late _Service service;
  late PublicationRunner runner;

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
    f = PublicationFixture();
    await f.open();
    service = _Service(f);
    await bind();
  });
  tearDown(() async {
    runner.dispose();
    await f.close();
  });

  Future<void> entered(bool Function() ready) async {
    for (var i = 0; i < 200 && !ready(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(ready(), true, reason: 'transport should have started');
  }

  test(
    'initialization is local; five drains make one acknowledged publication',
    () async {
      await f.save(await f.draft('SYNTHETIC shared'));
      expect(service.sharedCommands, isEmpty);
      await Future.wait(List.generate(5, (_) => runner.run()));
      expect(service.sharedCommands, hasLength(1));
      expect(runner.pending, isEmpty);
      expect(
        (await f.records.at(f.goalId, f.clock.day))!.record.syncState,
        'confirmed',
      );
    },
  );

  test(
    'failed send never loops; explicit retry uses identical persisted request',
    () async {
      await f.save(await f.draft('SYNTHETIC offline'));
      service.sharedFailure = const CompanionServiceFailure(
        'network',
        outcomeUnknown: true,
      );
      await runner.run();
      final operation = runner.pending.single.row.operationId;
      expect(runner.pending.single.row.status, 'uncertain');
      service.sharedFailure = null;
      await runner.run();
      expect(service.sharedCommands, hasLength(1));
      runner.dispose();
      await f.reopen();
      await bind();
      await runner.run();
      expect(service.sharedCommands, hasLength(1));
      await runner.run(retryOperation: operation);
      expect(service.sharedCommands, hasLength(2));
      expect(
        service.sharedCommands.first.toJson(),
        service.sharedCommands.last.toJson(),
      );
      expect(runner.pending, isEmpty);
    },
  );

  test('durable photo receipts skip completed uploads after restart', () async {
    var draft = await f.addPhoto(await f.draft('SYNTHETIC photo'));
    draft = await f.addPhoto(draft);
    await f.save(draft);
    service.sharedFailure = const CompanionServiceFailure(
      'timeout',
      outcomeUnknown: true,
    );
    await runner.run();
    expect(service.uploads, hasLength(2));
    final first = service.sharedCommands.single;
    expect(first.photoIds, hasLength(2));
    runner.dispose();
    await f.reopen();
    await bind();
    service.sharedFailure = null;
    await runner.run(retryOperation: first.operationId);
    expect(service.uploads, hasLength(2));
    expect(service.sharedCommands.last.toJson(), first.toJson());
    expect(await f.db.select(f.db.sharingPublicationPhotos).get(), isEmpty);
    expect(
      (await f.records.at(f.goalId, f.clock.day))!.savedPhotos,
      hasLength(2),
    );
  });

  test(
    'withdrawal during upload never publishes a private record or reuploads it',
    () async {
      await f.save(await f.addPhoto(await f.draft('SYNTHETIC withdrawn')));
      service.photoGate = Completer<void>();
      final running = runner.run();
      await entered(() => service.uploads.isNotEmpty);
      await f.deleteRecord();
      service.photoGate!.complete();
      await running;
      expect(service.sharedCommands, isEmpty);
      expect(service.resolutions, isEmpty);
      expect(runner.pending, isEmpty);
    },
  );

  test(
    'withdrawal before server commit resolves by hash and never replays text',
    () async {
      await f.save(await f.draft('SYNTHETIC withdrawn'));
      service.sharedGate = Completer<void>();
      final running = runner.run();
      await entered(() => service.sharedCommands.isNotEmpty);
      await f.deleteRecord();
      service.sharedGate!.complete();
      await running;
      expect(service.sharedCommands, hasLength(1));
      expect(service.resolutions, hasLength(1));
      expect(
        service.cancelled,
        contains(service.sharedCommands.single.operationId),
      );
      expect(runner.pending, isEmpty);
    },
  );

  test('lost success then withdrawal resolves receipt and removes original remote ID', () async {
    await f.save(await f.draft('SYNTHETIC old'));
    service.afterCommitFailure = const CompanionServiceFailure(
      'network',
      outcomeUnknown: true,
    );
    await runner.run();
    await f.deleteRecord();
    service.afterCommitFailure = null;
    await runner.run();
    expect(service.sharedCommands.map((c) => c.kind), [
      SharingCommandKind.publish,
      SharingCommandKind.remove,
    ]);
    expect(service.resolutions, hasLength(1));
    expect(service.sharedCommands.last.recordId, sharingId(50));
    expect(runner.pending, isEmpty);
  });

  test('new save during successful send resolves old revision before publishing latest', () async {
    await f.save(await f.draft('SYNTHETIC old'));
    service.afterWrite = () async {
      service.afterWrite = null;
      await f.save(await f.draft('SYNTHETIC latest'));
      await f.draft('SYNTHETIC still typing');
    };
    await runner.run();
    expect(service.resolutions, hasLength(1));
    expect(service.sharedCommands.map((c) => c.baseRevision), [0, 1]);
    expect(service.sharedCommands.last.text, 'SYNTHETIC latest');
    final own = (await f.records.at(f.goalId, f.clock.day))!.record;
    expect(own.syncState, 'confirmed');
    expect(own.draftText, 'SYNTHETIC still typing');
  });

  test('resolution timeout keeps original body frozen and blocks successor once per run', () async {
    await f.save(await f.draft('SYNTHETIC old'));
    service.sharedFailure = const CompanionServiceFailure(
      'timeout',
      outcomeUnknown: true,
    );
    await runner.run();
    await f.deleteRecord();
    service.resolutionFailure = const CompanionServiceFailure(
      'timeout',
      outcomeUnknown: true,
    );
    await runner.run();
    expect(service.resolutions, hasLength(1));
    expect(service.sharedCommands, hasLength(1));
    expect(runner.pending, hasLength(2));
    expect(runner.pending.first.row.status, 'uncertain');
    service.resolutionFailure = null;
    await runner.run();
    expect(runner.pending, isEmpty);
    expect(service.sharedCommands, hasLength(1));
  });

  test('confirmed cancellation is never retried and cannot strand later withdrawal', () async {
    await f.save(await f.draft('SYNTHETIC old'));
    service.sharedFailure = const CompanionServiceFailure(
      'publication_cancelled',
    );
    await runner.run();
    final cancelled = runner.pending.single;
    expect(runner.canRetry(cancelled), false);
    await runner.run(retryOperation: cancelled.row.operationId);
    expect(service.sharedCommands, hasLength(1));
    await f.deleteRecord();
    await runner.run();
    expect(service.sharedCommands, hasLength(1));
    expect(service.resolutions, isEmpty);
    expect(runner.pending, isEmpty);
  });

  test('credential replacement during transport discards reply and protects own record', () async {
    await f.save(await f.draft('SYNTHETIC retained'));
    service.sharedGate = Completer<void>();
    final running = runner.run();
    await entered(() => service.sharedCommands.isNotEmpty);
    await LocalPairingStore.open(f.goals, credentialScope: 'c' * 64);
    service.sharedGate!.complete();
    await running;
    expect(runner.invalidated, true);
    expect(service.receipts, isEmpty);
    expect(
      (await f.records.at(f.goalId, f.clock.day))!.record.content,
      'SYNTHETIC retained',
    );
    expect(await f.db.select(f.db.sharingPublications).get(), isEmpty);
  });

  test(
    'revocation clears companion scope without deleting personal content',
    () async {
      await f.save(await f.draft('SYNTHETIC retained'));
      service.sharedFailure = const CompanionServiceFailure('unauthorized');
      await runner.run();
      expect(runner.invalidated, true);
      expect(runner.pending, isEmpty);
      expect(await f.db.select(f.db.sharingPublications).get(), isEmpty);
      expect(
        (await f.records.at(f.goalId, f.clock.day))!.record.content,
        'SYNTHETIC retained',
      );
    },
  );
}
