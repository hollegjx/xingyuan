import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/app/app.dart';
import 'package:habit_checkin/app/providers.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/local/open_database.dart';
import 'package:habit_checkin/data/sync/identity_store.dart';
import 'package:habit_checkin/features/companion/companion_providers.dart';
import 'package:habit_checkin/features/companion/data/companion_service.dart';
import 'package:habit_checkin/features/companion/presentation/sharing_controller.dart';
import 'package:habit_checkin/features/records/record_providers.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:xingyuan_core/xingyuan_core.dart';

import '../test/support/record_fixtures.dart';
import '../test/support/isolated_goal_probe.dart';
import '../test/support/test_reminder_notifications.dart';
import '../test/support/ui_harness.dart' show TestNotificationPermissions;

// Two separate iOS installations talk to the compiled backend over loopback.
// Credentials, isolated storage, picker and no-op notifications are injected.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  const run = String.fromEnvironment('COMPANION_JOURNEY_RUN');
  const role = String.fromEnvironment('COMPANION_JOURNEY_ROLE');
  const phase = String.fromEnvironment('COMPANION_JOURNEY_PHASE');
  const token = String.fromEnvironment('COMPANION_JOURNEY_TOKEN');
  const address = String.fromEnvironment('COMPANION_JOURNEY_URL');
  const invitation = String.fromEnvironment('COMPANION_JOURNEY_INVITE');
  const recovery = bool.fromEnvironment('COMPANION_JOURNEY_RECOVERY');
  const network = bool.fromEnvironment('COMPANION_JOURNEY_NETWORK');
  const replyFaults = bool.fromEnvironment('COMPANION_JOURNEY_REPLY_FAULTS');
  const uploadFaults = bool.fromEnvironment('COMPANION_JOURNEY_UPLOAD_FAULTS');
  const uploadedPhoto = String.fromEnvironment('COMPANION_JOURNEY_PHOTO');
  const publicationPhase = uploadFaults
      ? 'upload-recover'
      : network
      ? 'network-confirm'
      : recovery
      ? 'recover'
      : 'publish';
  const phases = {
    'invite': 'a',
    'join': 'b',
    'publish': 'a',
    'arm': 'a',
    'recover': 'a',
    'upload-arm': 'a',
    'upload-private': 'b',
    'upload-recover': 'a',
    'network-offline': 'a',
    'network-recover': 'a',
    'network-delay': 'a',
    'network-timeout': 'a',
    'network-confirm': 'a',
    'reply': 'b',
    'reply-offline': 'b',
    'reply-recover': 'b',
    'reply-delay': 'b',
    'reply-timeout': 'b',
    'reply-confirm': 'b',
    'reply-arm': 'b',
    'reply-resume': 'b',
    'withdraw': 'a',
    'leave': 'b',
    'cleanup': 'a',
  };
  testWidgets('actual backend sharing journey $role/$phase', (tester) async {
    expect(Platform.isIOS, true);
    expect(RegExp(r'^[a-z0-9-]{8,40}$').hasMatch(run), true);
    expect(phases[phase] == role, true);
    expect(!phase.startsWith('upload-') || uploadFaults, true);
    expect(RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(token), true);
    final endpoint = Uri.parse(address);
    expect(endpoint.scheme == 'http' && endpoint.host == '127.0.0.1', true);
    expect(endpoint.hasPort && endpoint.port > 1023, true);
    expect(
      endpoint.path.isEmpty && !endpoint.hasQuery && !endpoint.hasFragment,
      true,
    );
    final clock = DeviceClock();
    await clock.refreshZone();
    final day = clock.read().day;
    final db = openAppDatabase(name: 'habit_checkin_sharing_${run}_$role');
    final lease = await IdentityStore(db).active();
    final goals = LocalGoalRepository(db, clock, identityLease: lease);
    final root = Directory(
      '${(await getApplicationDocumentsDirectory()).path}/companion_journey_${run}_$role',
    );
    await root.create(recursive: true);
    final output = Directory('${root.path}/$phase');
    expect(
      await output.exists(),
      false,
      reason: 'Never overwrite a prior phase; use a fresh run',
    );
    await output.create();
    final service = HttpCompanionService(
      endpoint: endpoint,
      allowInsecureLoopback: true,
      readCredential: () async => token,
      timeout: phase == 'arm' || phase == 'reply-arm' || phase == 'upload-arm'
          ? const Duration(minutes: 5)
          : const Duration(seconds: 20),
    );
    final picture = img.Image(width: 120, height: 80)
      ..clear(img.ColorRgb8(24, 140, 120));
    img.fillRect(
      picture,
      x1: 20,
      y1: 20,
      x2: 90,
      y2: 60,
      color: img.ColorRgb8(215, 80, 95),
    );
    picture.exif.gpsIfd
      ..gpsLatitude = 12.34
      ..gpsLatitudeRef = 'N'
      ..gpsLongitude = 56.78
      ..gpsLongitudeRef = 'E';
    final capture = GlobalKey();
    ProviderContainer? container;
    final report = <String, Object?>{
      'run': run,
      'role': role,
      'phase': phase,
      'day': day.key,
    };

    Future<void> render({bool settle = true}) async {
      if (settle) {
        await tester.pumpAndSettle();
      } else {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    Future<void> waitFor(
      Future<bool> Function() predicate, {
      bool settle = true,
    }) async {
      final elapsed = Stopwatch()..start();
      while (!await predicate()) {
        if (elapsed.elapsed > const Duration(seconds: 30)) {
          fail('Real backend journey did not reach the required state');
        }
        await tester.pump(const Duration(milliseconds: 50));
      }
      await render(settle: settle);
      expect(tester.takeException(), isNull);
    }

    Future<void> reveal(Finder finder, {bool settle = true}) async {
      if (finder.evaluate().isEmpty &&
          find.byType(ListView).evaluate().isNotEmpty) {
        final scroll = tester.state<ScrollableState>(
          find
              .descendant(
                of: find.byType(ListView).last,
                matching: find.byType(Scrollable),
              )
              .first,
        );
        scroll.position.jumpTo(scroll.position.minScrollExtent);
        await render(settle: settle);
        for (var i = 0; i < 80 && finder.evaluate().isEmpty; i++) {
          scroll.position.jumpTo(
            (scroll.position.pixels + 160).clamp(
              scroll.position.minScrollExtent,
              scroll.position.maxScrollExtent,
            ),
          );
          await render(settle: settle);
        }
      }
      expect(finder, findsOneWidget);
      for (var i = 0; i < 5; i++) {
        await tester.ensureVisible(finder);
        await render(settle: settle);
        if (finder.hitTestable().evaluate().isNotEmpty) break;
        await tester.pump(const Duration(milliseconds: 100));
      }
      if (finder.hitTestable().evaluate().isEmpty) {
        debugPrint(
          'Unreachable $finder rect=${tester.getRect(finder)} '
          'view=${tester.view.physicalSize} '
          'insets=${tester.view.viewInsets}',
        );
      }
      expect(finder.hitTestable(), findsOneWidget);
    }

    Future<void> tap(Finder finder) async {
      await reveal(finder);
      await tester.tap(finder);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }

    Finder key(String name) => find.byKey(ValueKey(name));
    Future<void> back() async {
      final button = find.byType(BackButton);
      if (button.evaluate().isNotEmpty) return tap(button);
      final bar = find.byType(NavigationBar);
      expect(bar, findsOneWidget);
      expect(Navigator.of(tester.element(bar)).canPop(), isFalse);
      expect(tester.widget<NavigationBar>(bar).selectedIndex, isNot(0));
      await tap(find.byTooltip('今天'));
    }

    Future<void> menu(String label) async {
      if (label == '陪伴') {
        await tap(find.byTooltip(label));
        expect(
          tester
              .widget<NavigationBar>(find.byType(NavigationBar))
              .selectedIndex,
          3,
        );
        return;
      }
      await tap(find.byTooltip('今天'));
      await tap(find.byTooltip(label));
    }

    Future<void> shot(String name, {bool settle = true}) async {
      await render(settle: settle);
      final boundary =
          capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      expect(boundary.size.width, greaterThanOrEqualTo(320));
      expect(boundary.size.height, greaterThanOrEqualTo(568));
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        try {
          final data = (await image.toByteData(
            format: ui.ImageByteFormat.png,
          ))!;
          await File('${output.path}/$name.png')
              .writeAsBytes(data.buffer.asUint8List(), flush: true);
        } finally {
          image.dispose();
        }
      });
    }

    Future<int> goal(String suffix) async => (await goals.loadGoals())
        .singleWhere((g) => g.titleOn(day) == 'SYNTHETIC $role $suffix')
        .id;
    Future<void> create(String suffix) async {
      await tap(key('entry-new-goal'));
      await tester.enterText(key('goal-title'), 'SYNTHETIC $role $suffix');
      await tap(key('save-goal'));
      await waitFor(() async => key('save-goal').evaluate().isEmpty);
    }

    Future<void> edit(int id, String text) async {
      await tap(key('record-$id-${day.key}'));
      await waitFor(() async => key('record-text').evaluate().isNotEmpty);
      await tester.enterText(key('record-text'), text);
      await tester.pumpAndSettle();
    }

    Future<void> save() async {
      await tap(key('save-record'));
      await waitFor(() async => key('record-text').evaluate().isEmpty);
    }

    Future<SharingController> sharing() =>
        container!.read(sharingControllerProvider.future);
    Future<void> openFeed() async {
      await menu('陪伴');
      await waitFor(() async => key('open-sharing').evaluate().isNotEmpty);
      await tap(key('open-sharing'));
      await waitFor(() async => (await sharing()).confirmed);
    }

    Future<void> enable(int id) async {
      await tap(find.text('我的分享'));
      await tap(key('share-goal-$id'));
      await tap(key('confirm-sharing'));
      await waitFor(
        () async => !(await sharing()).busy && (await sharing()).confirmed,
      );
    }

    Future<void> settled() async {
      await waitFor(() async {
        final runner = await container!.read(publicationRunnerProvider.future);
        return !runner.busy && (await runner.outbox.pending()).isEmpty;
      });
      final runner = await container!.read(publicationRunnerProvider.future);
      expect(runner.error, isNull);
    }

    Future<Map<String, Object?>> personal() async => {
      'goals': [
        for (final row in await db.select(db.goals).get()) row.toJson(),
      ],
      'records': [
        for (final row in await db.select(db.dayRecords).get())
          {
            'id': row.id,
            'goal': row.goalId,
            'day': row.day,
            'content': row.content,
            'revision': row.revision,
            'draft_text': row.draftText,
          },
      ],
      'photos': [
        for (final row in await db.select(db.recordPhotos).get())
          {'id': row.id, 'sha256': row.sha256, 'filename': row.filename},
      ],
      'completions': [
        for (final row in await db.select(db.checkIns).get()) row.toJson(),
      ],
    };
    Future<Map<String, dynamic>> previous(String name) async =>
        jsonDecode(await File('${root.path}/$name/report.json').readAsString())
            as Map<String, dynamic>;

    Future<void> finishPublication({bool complete = true}) async {
      if (complete) {
        await tap(key('complete-${await goal('shared')}'));
        await waitFor(
          () async =>
              (await db.select(db.checkIns).get()).any((row) => row.completed),
        );
      }
      await settled();
      await openFeed();
      final state = await sharing();
      expect(state.snapshot!.records, hasLength(1));
      final record = state.snapshot!.records.single;
      expect(record.text, 'SYNTHETIC shared text and photo');
      expect(record.photoIds, hasLength(1));
      expect(record.completedAt, complete ? isNotNull : isNull);
      expect(record.authorId, state.store.memberId);
      report['record_id'] = record.id;
      report['photo_id'] = record.photoIds.single;
      report['group_id'] = state.store.groupId;
      await shot('published');
    }

    Future<void> networkFailure(String code) async {
      expect(network, true);
      final runner = await container!.read(publicationRunnerProvider.future);
      await waitFor(() async {
        final pending = await runner.outbox.pending();
        return !runner.busy &&
            pending.length == 1 &&
            pending.single.row.status == 'uncertain' &&
            pending.single.row.errorCode == code;
      });
      final attempt = (await runner.outbox.pending()).single;
      expect(attempt.row.attempts, 1);
      expect(attempt.command, isNotNull);
      report.addAll({
        'operation_id': attempt.row.operationId,
        'body_hash': sha256
            .convert(utf8.encode(jsonEncode(attempt.command!.toJson())))
            .toString(),
        'attempts': attempt.row.attempts,
        'error_code': code,
      });
      await openFeed();
      final state = await sharing();
      expect(state.snapshot!.records, hasLength(code == 'network' ? 0 : 1));
      await reveal(key('retry-publication-${attempt.row.operationId}'));
      await shot('$code-before-retry');
      await tester.pump(const Duration(seconds: 2));
      expect((await runner.outbox.pending()).single.row.attempts, 1);
      expect(runner.busy, false);
    }

    try {
      final fresh = phase == 'invite' || phase == 'join';
      expect((await goals.loadGoals()).isEmpty, fresh);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseFactoryProvider.overrideWithValue(
              () => throw StateError('Ordinary database must not open'),
            ),
            clockProvider.overrideWithValue(clock),
            refreshClockProvider.overrideWithValue(clock.refreshZone),
            ...isolatedGoalProbeOverrides(
              goals: goals,
              workspace: root,
              credential: token,
            ),
            companionServiceProvider.overrideWithValue(service),
            recordPhotoPickerProvider.overrideWithValue(
              StubRecordPhotoPicker()
                ..onPick = () async => img.encodeJpg(picture),
            ),
            notificationPermissionsProvider.overrideWithValue(
              TestNotificationPermissions(),
            ),
            reminderNotificationsProvider.overrideWithValue(
              TestReminderNotifications(),
            ),
          ],
          child: RepaintBoundary(key: capture, child: const HabitCheckinApp()),
        ),
      );
      await waitFor(() async => key('entry-new-goal').evaluate().isNotEmpty);
      container = ProviderScope.containerOf(
        tester.element(find.byType(HabitCheckinApp)),
      );
      expect(await container.read(databaseProvider.future), same(db));
      final chatFiles = await container.read(chatPhotoFilesProvider.future);
      expect(chatFiles.db, same(db));
      expect(chatFiles.root.path, '${root.path}/chat_photos');
      final records = await container.read(dayRecordStoreProvider.future);
      if (fresh) {
        await create('private');
        await edit(await goal('private'), 'SYNTHETIC $role private text');
        expect(key('record-share-details'), findsNothing);
        await save();
        if (role == 'a') {
          await create('history');
          await edit(await goal('history'), 'SYNTHETIC pre-grant history');
          await save();
          await create('shared');
        }
        if (uploadFaults) {
          final privateId = await goal('private');
          await tap(key('complete-$privateId'));
          await waitFor(
            () async => (await db.select(db.checkIns).get()).any(
              (row) => row.goalId == privateId && row.completed,
            ),
          );
        }
        await menu('陪伴');
        final pairing = await container.read(pairingControllerProvider.future);
        await waitFor(() async => pairing.canStart && pairing.confirmed);
        if (phase == 'invite') {
          await tap(key('create-pairing-invite'));
          await waitFor(
            () async => pairing.snapshot?.state?.invitation != null,
          );
          report['invitation'] = pairing.snapshot!.state!.invitation!.code;
          expect(key('pairing-invite-code'), findsOneWidget);
        } else {
          expect(RegExp(r'^[A-HJ-NP-Z2-9]{8}$').hasMatch(invitation), true);
          await reveal(key('pairing-code-input'));
          await tester.enterText(key('pairing-code-input'), invitation);
          await tester.pumpAndSettle();
          await tap(key('join-pairing'));
          await tap(key('confirm-pairing'));
          await waitFor(() async => pairing.snapshot?.state?.group != null);
          await shot('paired');
          await tap(key('open-sharing'));
          await waitFor(() async => (await sharing()).confirmed);
          expect((await sharing()).snapshot!.records, isEmpty);
        }
      } else if (phase == 'publish' ||
          phase == 'arm' ||
          phase == 'upload-arm' ||
          phase == 'network-offline') {
        expect((await previous('invite'))['day'] == day.key, true);
        await openFeed();
        await enable(await goal('history'));
        await enable(await goal('shared'));
        expect((await sharing()).snapshot!.records, isEmpty);
        await back();
        await back();
        await tap(key('record-${await goal('history')}-${day.key}'));
        expect(key('record-share-details'), findsNothing);
        await back();
        await edit(await goal('shared'), 'SYNTHETIC shared text and photo');
        expect(
          tester.widget<CheckboxListTile>(key('record-share-details')).value,
          false,
        );
        await tap(key('record-share-details'));
        await tap(key('record-library'));
        await waitFor(
          () async => find.byTooltip('移除照片').evaluate().length == 1,
        );
        await save();
        if (phase == 'upload-arm') {
          final runner = await container.read(publicationRunnerProvider.future);
          await waitFor(() async {
            final pending = await runner.outbox.pending();
            return runner.busy &&
                pending.length == 1 &&
                pending.single.command == null &&
                pending.single.row.status == 'sending';
          }, settle: false);
          const draft = 'SYNTHETIC later record draft\ncontinue later';
          await edit(await goal('shared'), draft);
          await back();
          final attempt = (await runner.outbox.pending()).single;
          final photo = (await runner.outbox.photos(attempt)).single;
          final files = await container.read(recordPhotoFilesProvider.future);
          final request = CompanionPhotoUpload.fromJson({
            'protocol': companionProtocol,
            'operation_id': photo.row.uploadOperationId,
            'group_id': runner.outbox.sharing.groupId,
            'purpose': 'record',
            'grant_id': attempt.source.grantId,
            'jpeg_base64': base64Encode(await files.read(photo.photo)),
          });
          expect(attempt.row.attempts, 1);
          expect(attempt.row.receiptJson, isNull);
          expect(photo.remote, isNull);
          expect(photo.row.receiptJson, isNull);
          expect(
            (await records.at(await goal('shared'), day))!.record.draftText,
            draft,
          );
          report.addAll({
            'ready_to_kill': true,
            'success': false,
            'operation_id': attempt.row.operationId,
            'upload_operation_id': request.operationId,
            'upload_body_hash': sha256
                .convert(utf8.encode(jsonEncode(request.toJson())))
                .toString(),
            'local_photo_id': photo.photo.id,
            'local_photo_sha256': photo.photo.sha256,
            'group_id': runner.outbox.sharing.groupId,
            'grant_id': attempt.source.grantId,
            'next_draft': draft,
            'personal': await personal(),
          });
          await shot('upload-waiting-draft-retained', settle: false);
          await File('${output.path}/report.json')
              .writeAsString(jsonEncode(report), flush: true);
          debugPrint('PUBLICATION_UPLOAD_READY_TO_KILL');
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(minutes: 4)),
          );
          fail('Host must verify durable upload before terminating the App');
        }
        if (phase == 'arm') {
          expect(recovery, true);
          final runner = await container.read(publicationRunnerProvider.future);
          await waitFor(() async {
            final pending = await runner.outbox.pending();
            return runner.busy &&
                pending.length == 1 &&
                pending.single.command != null &&
                pending.single.row.status == 'sending';
          });
          final attempt = (await runner.outbox.pending()).single;
          report.addAll({
            'ready_to_kill': true,
            'success': false,
            'operation_id': attempt.row.operationId,
            'body_hash': sha256
                .convert(utf8.encode(jsonEncode(attempt.command!.toJson())))
                .toString(),
            'attempts': attempt.row.attempts,
            'personal': await personal(),
          });
          await shot('sending-before-kill');
          await File('${output.path}/report.json')
              .writeAsString(jsonEncode(report), flush: true);
          debugPrint(
            'PUBLICATION_READY_TO_KILL; private artifacts=${output.path}',
          );
          final waiting = Stopwatch()..start();
          while (waiting.elapsed < const Duration(minutes: 3)) {
            await tester.pump(const Duration(milliseconds: 250));
          }
          fail('Host did not terminate the armed simulator process');
        }
        if (phase == 'network-offline') {
          await networkFailure('network');
        } else {
          await settled();
          await finishPublication();
        }
      } else if (phase == 'upload-private') {
        await openFeed();
        final state = await sharing();
        expect(state.snapshot!.records, isEmpty);
        await expectLater(
          service.downloadPhoto(
            CompanionPhotoRequest.fromJson({
              'protocol': companionProtocol,
              'group_id': state.store.groupId,
              'photo_id': uploadedPhoto,
            }),
            access: state.access,
          ),
          throwsA(
            isA<CompanionServiceFailure>().having(
              (failure) => failure.code,
              'unattached record photo is private',
              'photo_unavailable',
            ),
          ),
        );
        expect(await personal(), (await previous('join'))['personal']);
        await shot('unpublished-photo-unavailable');
      } else if (phase == 'upload-recover') {
        final armed = await previous('upload-arm');
        expect(armed['ready_to_kill'], true);
        expect(armed['day'], day.key);
        final runner = await container.read(publicationRunnerProvider.future);
        await waitFor(() async {
          final pending = await runner.outbox.pending();
          return !runner.busy &&
              pending.length == 1 &&
              pending.single.row.status == 'uncertain' &&
              pending.single.row.errorCode == 'interrupted';
        });
        await tester.pump(const Duration(seconds: 2));
        final attempt = (await runner.outbox.pending()).single;
        expect(attempt.row.operationId, armed['operation_id']);
        expect(attempt.row.attempts, 1);
        expect(attempt.command, isNull);
        expect(attempt.row.receiptJson, isNull);
        final mapping = (await db.select(db.sharingPublicationPhotos).get())
            .singleWhere((row) => row.operationId == attempt.row.operationId);
        final photo = (await db.select(db.recordPhotos).get()).singleWhere(
          (row) => row.id == mapping.photoId,
        );
        expect(mapping.uploadOperationId, armed['upload_operation_id']);
        expect(mapping.receiptJson, isNull);
        expect(photo.id, armed['local_photo_id']);
        expect(photo.sha256, armed['local_photo_sha256']);
        expect(await personal(), armed['personal']);
        await tap(key('record-${await goal('shared')}-${day.key}'));
        await waitFor(() async => key('record-text').evaluate().isNotEmpty);
        expect(
          tester.widget<TextField>(key('record-text')).controller!.text,
          armed['next_draft'],
        );
        await shot('cold-draft-retained');
        await back();
        await openFeed();
        final state = await sharing();
        expect(state.snapshot!.records, isEmpty);
        final retry = key('retry-publication-${attempt.row.operationId}');
        await reveal(retry);
        await shot('cold-upload-unknown');
        for (var i = 0; i < 5; i++) {
          await tester.tap(retry);
        }
        await settled();
        await waitFor(() async => !state.busy && state.confirmed);
        expect(state.snapshot!.records, hasLength(1));
        expect(state.snapshot!.records.single.photoIds, [uploadedPhoto]);
        expect(await personal(), armed['personal']);
        report['recovered_operation_id'] = attempt.row.operationId;
        report['recovered_upload_operation_id'] = mapping.uploadOperationId;
        await shot('upload-retry-confirmed');
        await back();
        await back();
        await finishPublication(complete: false);
      } else if (phase == 'recover') {
        expect(recovery, true);
        final armed = await previous('arm');
        expect(armed['ready_to_kill'], true);
        expect(armed['success'], false);
        expect(armed['day'], day.key);
        final runner = await container.read(publicationRunnerProvider.future);
        await waitFor(() async {
          final pending = await runner.outbox.pending();
          return !runner.busy &&
              pending.length == 1 &&
              pending.single.row.status == 'uncertain' &&
              pending.single.row.errorCode == 'interrupted';
        });
        await tester.pump(const Duration(seconds: 2));
        final attempt = (await runner.outbox.pending()).single;
        expect(attempt.row.operationId, armed['operation_id']);
        expect(attempt.row.attempts, armed['attempts']);
        expect(
          sha256
              .convert(utf8.encode(jsonEncode(attempt.command!.toJson())))
              .toString(),
          armed['body_hash'],
        );
        expect(await personal(), armed['personal']);
        await openFeed();
        final state = await sharing();
        expect(state.snapshot!.records, hasLength(1));
        final before = state.snapshot!.records.single;
        expect(before.completedAt, isNull);
        final retry = key('retry-publication-${attempt.row.operationId}');
        await reveal(retry);
        await shot('interrupted-before-retry');
        for (var i = 0; i < 5; i++) {
          await tester.tap(retry);
        }
        await settled();
        await waitFor(() async => !state.busy && state.confirmed);
        expect(state.snapshot!.records, hasLength(1));
        expect(state.snapshot!.records.single.id, before.id);
        expect(state.snapshot!.records.single.revision, before.revision);
        expect(await personal(), armed['personal']);
        report['recovered_operation_id'] = attempt.row.operationId;
        report['recovered_body_hash'] = armed['body_hash'];
        await shot('retry-confirmed');
        await back();
        await back();
        await finishPublication();
      } else if (phase == 'network-recover' || phase == 'network-confirm') {
        expect(network, true);
        final offline = phase == 'network-recover';
        final prior = await previous(
          offline ? 'network-offline' : 'network-timeout',
        );
        expect(prior['success'], true);
        expect(prior['day'], day.key);
        final runner = await container.read(publicationRunnerProvider.future);
        await waitFor(() async => !runner.busy);
        await openFeed();
        final state = await sharing();
        final attempt = (await runner.outbox.pending()).single;
        expect(attempt.row.status, 'uncertain');
        expect(attempt.row.errorCode, offline ? 'network' : 'timeout');
        expect(attempt.row.operationId, prior['operation_id']);
        expect(attempt.row.attempts, 1);
        expect(
          sha256
              .convert(utf8.encode(jsonEncode(attempt.command!.toJson())))
              .toString(),
          prior['body_hash'],
        );
        expect(await personal(), prior['personal']);
        expect(state.snapshot!.records, hasLength(offline ? 0 : 1));
        final before = offline ? null : state.snapshot!.records.single;
        final retry = key('retry-publication-${attempt.row.operationId}');
        await reveal(retry);
        await shot('cold-start-before-retry');
        for (var i = 0; i < 5; i++) {
          await tester.tap(retry);
        }
        await settled();
        await waitFor(() async => !state.busy && state.confirmed);
        final after = state.snapshot!.records.single;
        expect(after.text, 'SYNTHETIC shared text and photo');
        if (before != null) {
          expect(after.id, before.id);
          expect(after.revision, before.revision);
          expect(after.photoIds, before.photoIds);
        }
        expect(await personal(), prior['personal']);
        report.addAll({
          'recovered_operation_id': attempt.row.operationId,
          'recovered_body_hash': prior['body_hash'],
          'record_id': after.id,
          'photo_id': after.photoIds.single,
          'group_id': state.store.groupId,
          'revision_before': before?.revision,
          'revision_after': after.revision,
        });
        await shot('retry-confirmed');
        if (offline) {
          await back();
          await back();
          await finishPublication();
        }
      } else if (phase == 'network-delay' || phase == 'network-timeout') {
        expect(network, true);
        expect((await previous('network-recover'))['day'], day.key);
        final delay = phase == 'network-delay';
        await openFeed();
        final before = (await sharing()).snapshot!.records.single;
        await back();
        await back();
        await edit(
          await goal('shared'),
          delay
              ? 'SYNTHETIC delayed shared text and photo'
              : 'SYNTHETIC shared text and photo',
        );
        expect(
          tester.widget<CheckboxListTile>(key('record-share-details')).value,
          true,
        );
        final watch = Stopwatch()..start();
        final saveButton = key('save-record');
        await reveal(saveButton);
        for (var i = 0; i < 5; i++) {
          await tester.tap(saveButton);
        }
        await waitFor(() async => key('record-text').evaluate().isEmpty);
        if (!delay) {
          await networkFailure('timeout');
          expect(
            watch.elapsed,
            greaterThanOrEqualTo(const Duration(seconds: 20)),
          );
          // A late success must not settle an already timed-out client attempt.
          while (watch.elapsed < const Duration(seconds: 28)) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          final runner = await container.read(publicationRunnerProvider.future);
          final pending = (await runner.outbox.pending()).single;
          expect(pending.row.status, 'uncertain');
          expect(pending.row.attempts, 1);
          expect(runner.busy, false);
          await shot('late-response-still-uncertain');
        } else {
          final runner = await container.read(publicationRunnerProvider.future);
          await waitFor(() async {
            final pending = await runner.outbox.pending();
            return runner.busy &&
                pending.length == 1 &&
                pending.single.command != null;
          });
          final attempt = (await runner.outbox.pending()).single;
          expect(attempt.row.attempts, 1);
          report['operation_id'] = attempt.row.operationId;
          await shot('delayed-pending');
          await settled();
          expect(
            watch.elapsed,
            greaterThanOrEqualTo(const Duration(seconds: 6)),
          );
          await openFeed();
          final after = (await sharing()).snapshot!.records.single;
          expect(after.id, before.id);
          expect(after.revision, before.revision + 1);
          expect(after.text, 'SYNTHETIC delayed shared text and photo');
          report['revision_before'] = before.revision;
          report['revision_after'] = after.revision;
          await shot('delayed-confirmed');
        }
      } else if (phase.startsWith('reply-')) {
        expect(replyFaults, true);
        expect(await personal(), (await previous('join'))['personal']);
        await openFeed();
        final state = await sharing();
        final record = state.snapshot!.records.single;
        await tap(key('open-replies-${record.id}'));
        await waitFor(
          () async => state.replyReady(record.id) && !state.refreshing,
        );
        final input = key('sharing-reply-input');
        final send = key('send-sharing-reply');
        final prior = switch (phase) {
          'reply-recover' => 'reply-offline',
          'reply-confirm' => 'reply-timeout',
          'reply-resume' => 'reply-arm',
          _ => null,
        };
        final count = switch (phase) {
          'reply-offline' => 1,
          'reply-recover' => 2,
          'reply-delay' => 3,
          'reply-timeout' || 'reply-confirm' => 4,
          'reply-arm' || 'reply-resume' => 5,
          _ => throw StateError('Unknown reply phase'),
        };
        Future<String> draft() async {
          await reveal(input);
          return tester.widget<TextField>(input).controller!.text;
        }

        Future<void> fiveTaps(Finder button) async {
          await reveal(button);
          for (var i = 0; i < 5; i++) {
            await tester.tap(button);
          }
        }

        if (prior != null) {
          final old = await previous(prior);
          final pending = state.pending.single;
          expect(pending.command.operationId, old['operation_id']);
          expect(pending.row.status, 'uncertain');
          expect(pending.row.attempts, 1);
          expect(pending.row.receiptJson, isNull);
          expect(
            sha256.convert(utf8.encode(pending.row.requestJson)).toString(),
            old['body_hash'],
          );
          expect(await draft(), old['next_draft']);
          await shot('cold-reopen-draft');
          await reveal(send);
          expect(tester.widget<IconButton>(send).onPressed, isNull);
          await shot('cold-reopen-pending');
          await tester.pump(const Duration(seconds: 2));
          expect(state.pending.single.row.attempts, 1);
          await fiveTaps(key('retry-sharing-${pending.command.operationId}'));
          await waitFor(
            () async =>
                !state.busy &&
                state.pending.isEmpty &&
                state.replies[record.id]?.length == count,
          );
          final saved = (await db.select(db.sharingCommands).get()).singleWhere(
            (row) => row.operationId == old['operation_id'],
          );
          expect(saved.status, 'succeeded');
          expect(saved.attempts, 2);
          expect(saved.requestJson, pending.row.requestJson);
          expect(await draft(), old['next_draft']);
          expect((await state.store.draft(record.id))!.content, await draft());
          report.addAll({
            'operation_id': saved.operationId,
            'body_hash': old['body_hash'],
            'attempts': saved.attempts,
            'next_draft': await draft(),
          });
          await shot('retry-confirmed-draft-kept');
        } else {
          final nextDraft = 'SYNTHETIC later draft $phase';
          await reveal(input);
          await tester.enterText(input, 'SYNTHETIC send $phase');
          await tester.pumpAndSettle();
          final watch = Stopwatch()..start();
          await fiveTaps(send);
          await waitFor(() async => state.pending.length == 1, settle: false);
          final attempt = state.pending.single;
          expect(attempt.command.kind, SharingCommandKind.reply);
          expect(attempt.row.attempts, 1);
          await reveal(input, settle: false);
          await tester.enterText(input, nextDraft);
          await waitFor(
            () async => state.replyDraftSaved(record.id),
            settle: false,
          );
          expect((await state.store.draft(record.id))!.content, nextDraft);
          report.addAll({
            'operation_id': attempt.command.operationId,
            'body_hash': sha256
                .convert(utf8.encode(attempt.row.requestJson))
                .toString(),
            'attempts': 1,
            'next_draft': nextDraft,
          });
          if (phase == 'reply-arm') {
            expect(state.busy, true);
            expect(state.pending.single.row.status, 'sending');
            expect(state.pending.single.row.receiptJson, isNull);
            await shot('sending-before-kill', settle: false);
            report.addAll({
              'ready_to_kill': true,
              'personal': await personal(),
            });
            await File('${output.path}/report.json')
                .writeAsString(jsonEncode(report), flush: true);
            debugPrint('REPLY_READY_TO_KILL');
            final deadline = DateTime.now().add(const Duration(minutes: 4));
            while (DateTime.now().isBefore(deadline)) {
              await tester.pump(const Duration(milliseconds: 100));
            }
            fail('Host did not terminate at the verified reply gate');
          } else if (phase == 'reply-delay') {
            expect(state.busy, true);
            expect(state.pending.single.row.status, 'sending');
            await shot('delayed-sending', settle: false);
            await waitFor(
              () async =>
                  !state.busy &&
                  state.pending.isEmpty &&
                  state.replies[record.id]?.length == count,
            );
            expect(
              watch.elapsed,
              greaterThanOrEqualTo(const Duration(seconds: 6)),
            );
            expect(await draft(), nextDraft);
            expect((await state.store.draft(record.id))!.content, nextDraft);
            await shot('delayed-confirmed-draft-kept');
          } else {
            final code = phase == 'reply-offline' ? 'network' : 'timeout';
            await waitFor(
              () async =>
                  !state.busy &&
                  state.pending.single.row.status == 'uncertain' &&
                  state.pending.single.row.errorCode == code,
            );
            if (code == 'timeout') {
              expect(
                watch.elapsed,
                greaterThanOrEqualTo(const Duration(seconds: 20)),
              );
              while (watch.elapsed < const Duration(seconds: 28)) {
                await tester.pump(const Duration(milliseconds: 100));
              }
            }
            expect(state.pending.single.row.status, 'uncertain');
            expect(state.pending.single.row.attempts, 1);
            expect(state.pending.single.row.receiptJson, isNull);
            expect(await draft(), nextDraft);
            await shot('$code-later-draft');
            await reveal(send);
            expect(tester.widget<IconButton>(send).onPressed, isNull);
            await reveal(key('retry-sharing-${attempt.command.operationId}'));
            report['error_code'] = code;
            await shot('$code-pending-draft-kept');
          }
        }
        expect(await personal(), (await previous('join'))['personal']);
      } else if (phase == 'reply') {
        await openFeed();
        final state = await sharing();
        expect(state.snapshot!.records, hasLength(1));
        final record = state.snapshot!.records.single;
        expect(record.authorId == state.store.memberId, false);
        expect(record.text, 'SYNTHETIC shared text and photo');
        expect(record.completedAt, uploadFaults ? isNull : isNotNull);
        expect(find.text('SYNTHETIC a private'), findsNothing);
        expect(find.text('SYNTHETIC pre-grant history'), findsNothing);
        await tap(key('shared-photo-${record.photoIds.single}'));
        await waitFor(() async => find.byType(Image).evaluate().isNotEmpty);
        await shot('partner-photo');
        await back();
        final downloaded = await state.downloadPhoto(
          record.id,
          record.photoIds.single,
          service,
          cancellation: CompanionCancellation(),
        );
        expect(img.decodeJpg(downloaded.bytes)!.exif.isEmpty, true);
        await tap(key('open-replies-${record.id}'));
        await tester.enterText(
          key('sharing-reply-input'),
          'SYNTHETIC encouragement from b',
        );
        await tester.pumpAndSettle();
        final send = key('send-sharing-reply');
        await reveal(send);
        for (var i = 0; i < 5; i++) {
          await tester.tap(send);
        }
        await waitFor(
          () async =>
              !state.busy && (state.replies[record.id]?.length ?? 0) == 1,
        );
        expect(find.text('SYNTHETIC encouragement from b'), findsOneWidget);
        report['record_id'] = record.id;
        report['photo_id'] = record.photoIds.single;
        report['group_id'] = state.store.groupId;
        await shot('replied');
      } else if (phase == 'withdraw') {
        await openFeed();
        final state = await sharing();
        final record = state.snapshot!.records.single;
        await tap(key('open-replies-${record.id}'));
        await waitFor(
          () async =>
              find.text('SYNTHETIC encouragement from b').evaluate().isNotEmpty,
        );
        expect(state.replies[record.id], hasLength(replyFaults ? 5 : 1));
        if (replyFaults) {
          expect(state.replies[record.id]!.map((reply) => reply.text).toSet(), {
            'SYNTHETIC encouragement from b',
            for (final name in ['offline', 'delay', 'timeout', 'arm'])
              'SYNTHETIC send reply-$name',
          });
        }
        await shot('received-reply');
        await back();
        await tap(find.text('我的分享'));
        await tap(key('share-goal-${await goal('shared')}'));
        await tap(key('confirm-sharing'));
        await waitFor(
          () async => !state.busy && state.snapshot!.records.isEmpty,
        );
        expect(
          await personal(),
          (await previous(publicationPhase))['personal'],
        );
        final saved = (await records.at(await goal('shared'), day))!;
        final files = await container.read(recordPhotoFilesProvider.future);
        expect(await files.read(saved.savedPhotos.single), isNotEmpty);
        await shot('stopped-sharing');
      } else if (phase == 'leave') {
        final old = await previous('reply');
        await openFeed();
        final state = await sharing();
        expect(state.snapshot!.records, isEmpty);
        expect(await db.select(db.sharedRecordsCache).get(), isEmpty);
        await expectLater(
          service.downloadPhoto(
            CompanionPhotoRequest.fromJson({
              'protocol': companionProtocol,
              'group_id': old['group_id'],
              'photo_id': old['photo_id'],
            }),
            access: state.access,
          ),
          throwsA(
            isA<CompanionServiceFailure>().having(
              (e) => e.code,
              'server refusal',
              'photo_unavailable',
            ),
          ),
        );
        await shot('withdrawal-visible');
        await back();
        await tap(key('leave-pairing'));
        await tap(key('confirm-pairing'));
        final pairing = await container.read(pairingControllerProvider.future);
        await waitFor(
          () async =>
              pairing.confirmed && pairing.snapshot!.state!.group == null,
        );
        expect(await personal(), (await previous('join'))['personal']);
        expect(await db.select(db.sharedRepliesCache).get(), isEmpty);
        await shot('unpaired');
      } else if (phase == 'cleanup') {
        await menu('陪伴');
        final pairing = await container.read(pairingControllerProvider.future);
        await waitFor(
          () async =>
              pairing.confirmed && pairing.snapshot?.state?.group == null,
        );
        expect(await db.select(db.sharedRecordsCache).get(), isEmpty);
        expect(await db.select(db.sharedRepliesCache).get(), isEmpty);
        expect(await db.select(db.sharingPublications).get(), isEmpty);
        expect(
          await personal(),
          (await previous(publicationPhase))['personal'],
        );
        final saved = (await records.at(await goal('shared'), day))!;
        final files = await container.read(recordPhotoFilesProvider.future);
        expect(await files.read(saved.savedPhotos.single), isNotEmpty);
        await shot('remote-unpair-observed');
      }
      report['personal'] = await personal();
      report['success'] = true;
      await File('${output.path}/report.json')
          .writeAsString(jsonEncode(report), flush: true);
      debugPrint(
        'COMPANION_JOURNEY $role/$phase passed; private artifacts=${output.path}',
      );
    } catch (_) {
      if (capture.currentContext != null) await shot('failure', settle: false);
      rethrow;
    } finally {
      final foreground = container?.read(companionForegroundProvider);
      foreground?.setForeground(false);
      await foreground?.idle;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(Duration.zero);
      await db.close();
    }
  });
}
