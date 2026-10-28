import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/companion/data/companion_service.dart';
import 'package:habit_checkin/features/companion/data/publication_runner.dart';
import 'package:habit_checkin/features/companion/presentation/companion_foreground.dart';
import 'package:habit_checkin/features/companion/presentation/pairing_controller.dart';
import 'package:habit_checkin/features/companion/presentation/sharing_controller.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:xingyuan_core/xingyuan_core.dart';

import 'support/publication_fixtures.dart';
import 'support/publication_service.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);
  late PublicationFixture f;
  late TestPublicationService service;
  late PairingController pairing;
  late SharingController sharing;
  late PublicationRunner runner;
  late CompanionForeground foreground;
  var changes = 0;
  setUp(() async {
    f = PublicationFixture();
    await f.open();
    service = TestPublicationService()
      ..seed((await f.db.select(f.db.goals).get()).single.globalId);
    service.sharedRecords.clear();
    pairing = PairingController(store: f.pairing, service: service);
    sharing = SharingController(store: f.sharing, service: service);
    runner = PublicationRunner(
      outbox: f.outbox,
      sharing: service,
      media: service,
      resolution: service,
      files: f.files,
    );
    await pairing.initialize();
    await sharing.initialize();
    await runner.initialize();
    changes = 0;
    foreground = CompanionForeground(
      pairing: pairing,
      loadSharing: () async => sharing,
      loadRunner: () async => runner,
      groupChanged: () {
        changes++;
      },
    );
  });
  tearDown(() async {
    foreground.dispose();
    await foreground.idle;
    runner.dispose();
    sharing.dispose();
    pairing.dispose();
    await f.close();
  });
  Future<void> entered(bool Function() done) async {
    for (var i = 0; i < 200 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(done(), true);
  }

  test('background never sends; foreground automatically drains a newly saved intent', () async {
    await f.save(await f.draft('SYNTHETIC background'));
    await foreground.idle;
    expect(service.sharedCommands, isEmpty);
    foreground.setForeground(true);
    await foreground.idle;
    expect(service.sharedCommands, hasLength(1));
    expect(runner.pending, isEmpty);
    await f.save(await f.draft('SYNTHETIC next'));
    await entered(() => service.sharedCommands.length == 2);
    await foreground.idle;
    expect(service.sharedCommands.last.text, 'SYNTHETIC next');
    expect(sharing.snapshot!.records.single.text, 'SYNTHETIC next');
  });

  test(
    'failure status updates and resume never loop an unknown publication',
    () async {
      foreground.setForeground(true);
      await foreground.idle;
      service.sharedFailure = const CompanionServiceFailure(
        'network',
        outcomeUnknown: true,
      );
      await f.save(await f.draft('SYNTHETIC offline'));
      await entered(() => service.sharedCommands.isNotEmpty);
      await foreground.idle;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(service.sharedCommands, hasLength(1));
      expect(runner.pending.single.row.status, 'uncertain');
      service.sharedFailure = null;
      foreground.setForeground(false);
      foreground.setForeground(true);
      await foreground.idle;
      expect(service.sharedCommands, hasLength(1));
      await runner.run(retryOperation: runner.pending.single.row.operationId);
      expect(service.sharedCommands, hasLength(2));
      expect(
        service.sharedCommands.first.toJson(),
        service.sharedCommands.last.toJson(),
      );
    },
  );

  test('new intent during active upload is eventually drained without replaying old text', () async {
    foreground.setForeground(true);
    await foreground.idle;
    service.photoGate = Completer<void>();
    await f.save(await f.addPhoto(await f.draft('SYNTHETIC old')));
    await entered(() => service.uploads.isNotEmpty);
    await f.save(await f.draft('SYNTHETIC latest'));
    service.photoGate!.complete();
    await foreground.idle;
    await entered(() => service.sharedCommands.isNotEmpty);
    await foreground.idle;
    expect(service.sharedCommands, hasLength(1));
    expect(service.sharedCommands.single.text, 'SYNTHETIC latest');
    expect(runner.pending, isEmpty);
  });

  test('background interrupts sending and waits for explicit same-ID retry after resume', () async {
    foreground.setForeground(true);
    await foreground.idle;
    service.publicationGate = Completer<void>();
    await f.save(await f.draft('SYNTHETIC paused'));
    await entered(() => service.sharedCommands.isNotEmpty);
    foreground.setForeground(false);
    service.publicationGate!.complete();
    await foreground.idle;
    expect(service.receipts, isEmpty);
    expect(runner.pending.single.row.status, 'uncertain');
    foreground.setForeground(true);
    await foreground.idle;
    expect(service.sharedCommands, hasLength(1));
    await runner.run(retryOperation: runner.pending.single.row.operationId);
    expect(service.receipts, hasLength(1));
  });

  test(
    'unpair invalidates scheduling without touching personal data',
    () async {
      foreground.setForeground(true);
      await foreground.idle;
      service.publicationGate = Completer<void>();
      await f.save(await f.draft('SYNTHETIC retained'));
      await entered(() => service.sharedCommands.isNotEmpty);
      await pairing.leave(pairing.snapshot!.state!.group!.id);
      service.publicationGate!.complete();
      await foreground.idle;
      expect(changes, 1);
      expect(service.receipts, isEmpty);
      expect(
        service.sharedCommands.where(
          (c) => c.kind == SharingCommandKind.publish,
        ),
        hasLength(1),
      );
      expect(
        (await f.records.at(f.goalId, f.clock.day))!.record.content,
        'SYNTHETIC retained',
      );
      expect(await f.db.select(f.db.sharingPublications).get(), isEmpty);
    },
  );

  test('reopening sharing providers does not leave foreground attached to disposed controllers', () async {
    foreground.setForeground(true);
    await foreground.idle;
    sharing.dispose();
    runner.dispose();
    sharing = SharingController(store: f.sharing, service: service);
    runner = PublicationRunner(
      outbox: f.outbox,
      sharing: service,
      media: service,
      resolution: service,
      files: f.files,
    );
    await sharing.initialize();
    await runner.initialize();
    await f.save(await f.draft('SYNTHETIC after page retry'));
    await entered(() => service.sharedCommands.isNotEmpty);
    await foreground.idle;
    expect(service.sharedCommands.single.text, 'SYNTHETIC after page retry');
    expect(runner.pending, isEmpty);
  });
}
