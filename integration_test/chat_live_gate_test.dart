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
import 'package:habit_checkin/features/companion/presentation/chat_controller.dart';
import 'package:habit_checkin/features/records/record_providers.dart';
import 'package:habit_checkin/shared/local_date.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:xingyuan_core/xingyuan_core.dart';

import '../test/support/record_fixtures.dart';
import '../test/support/isolated_goal_probe.dart';
import '../test/support/test_reminder_notifications.dart';
import '../test/support/ui_harness.dart' show TestNotificationPermissions;

// Real native UI and compiled backend; only credentials, isolated storage,
// synthetic photo picking and notification delivery are replaced.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  const run = String.fromEnvironment('COMPANION_JOURNEY_RUN');
  const role = String.fromEnvironment('COMPANION_JOURNEY_ROLE');
  const phase = String.fromEnvironment('COMPANION_JOURNEY_PHASE');
  const token = String.fromEnvironment('COMPANION_JOURNEY_TOKEN');
  const address = String.fromEnvironment('COMPANION_JOURNEY_URL');
  const invitation = String.fromEnvironment('COMPANION_JOURNEY_INVITE');
  const concurrent = bool.fromEnvironment('COMPANION_JOURNEY_CONCURRENT');
  const uploadFaults = bool.fromEnvironment('COMPANION_JOURNEY_UPLOAD_FAULTS');
  const deleteFaults = bool.fromEnvironment('COMPANION_JOURNEY_DELETE_FAULTS');
  const uploadedPhoto = String.fromEnvironment('COMPANION_JOURNEY_PHOTO');
  const races = {'race-send', 'race-leave', 'race-send-leave', 'race-observe'};
  const phases = {
    'invite': 'a',
    'join': 'b',
    'send': 'a',
    'reply': 'b',
    'offline': 'a',
    'recover': 'a',
    'delay': 'a',
    'timeout': 'a',
    'confirm': 'a',
    'arm': 'a',
    'resume': 'a',
    'remove-b': 'b',
    'remove-a': 'a',
    'leave': 'b',
    'cleanup': 'a',
    'upload-arm': 'a',
    'upload-private': 'b',
    'upload-resume': 'a',
    'upload-observe': 'b',
    'upload-leave': 'b',
    'delete-arm': 'a',
    'delete-observe': 'b',
    'delete-resume': 'a',
    'delete-leave': 'b',
  };
  const first = 'SYNTHETIC A photo';
  const reply = 'SYNTHETIC B photo';
  const offline = 'SYNTHETIC A offline';
  const queued = 'SYNTHETIC A queued';
  const delayed = 'SYNTHETIC A delayed';
  const timeout = 'SYNTHETIC A timeout';
  const interrupted = 'SYNTHETIC A interrupted';
  const interruptedUpload = 'SYNTHETIC A interrupted upload';
  const draft = 'SYNTHETIC unsent\n\u{1f44d}';

  testWidgets('real backend chat journey $role/$phase', (tester) async {
    expect(Platform.isIOS, true);
    expect(RegExp(r'^[a-z0-9-]{8,40}$').hasMatch(run), true);
    expect(
      phases[phase] == role ||
          (concurrent && races.contains(phase) && {'a', 'b'}.contains(role)),
      true,
    );
    expect(RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(token), true);
    expect(!phase.startsWith('upload-') || uploadFaults, true);
    expect(!phase.startsWith('delete-') || deleteFaults, true);
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
    final db = openAppDatabase(name: 'habit_checkin_chat_${run}_$role');
    final lease = await IdentityStore(db).active();
    final goals = LocalGoalRepository(db, clock, identityLease: lease);
    final root = Directory(
      '${(await getApplicationDocumentsDirectory()).path}/chat_journey_${run}_$role',
    );
    await root.create(recursive: true);
    final output = Directory('${root.path}/$phase');
    expect(
      await output.exists(),
      false,
      reason: 'Use a fresh phase/run; retain failed evidence',
    );
    await output.create();
    final service = HttpCompanionService(
      endpoint: endpoint,
      allowInsecureLoopback: true,
      readCredential: () async => token,
      timeout:
          phase == 'arm' ||
              phase == 'upload-arm' ||
              phase == 'delete-arm' ||
              races.contains(phase)
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
    Finder key(String name) => find.byKey(ValueKey(name));

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
      final watch = Stopwatch()..start();
      while (!await predicate()) {
        if (watch.elapsed >
            (races.contains(phase)
                ? const Duration(minutes: 5)
                : const Duration(seconds: 40))) {
          fail('Native chat state did not settle: $phase');
        }
        await tester.pump(const Duration(milliseconds: 50));
      }
      await render(settle: settle);
      expect(tester.takeException(), isNull);
    }

    Future<void> reveal(Finder finder, {bool settle = true}) async {
      if (finder.evaluate().isEmpty &&
          key('chat-messages').evaluate().isNotEmpty) {
        final scroll = tester.state<ScrollableState>(
          find
              .descendant(
                of: key('chat-messages'),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        scroll.position.jumpTo(scroll.position.minScrollExtent);
        await render(settle: settle);
        for (var i = 0; i < 80 && finder.evaluate().isEmpty; i++) {
          scroll.position.jumpTo(
            (scroll.position.pixels + 120).clamp(
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
      }
      expect(finder.hitTestable(), findsOneWidget);
    }

    Future<void> tap(Finder finder, {int times = 1, bool settle = true}) async {
      await reveal(finder, settle: settle);
      for (var i = 0; i < times; i++) {
        await tester.tap(finder);
      }
      await render(settle: settle);
      expect(tester.takeException(), isNull);
    }

    Future<void> back() async {
      final button = find.byType(BackButton);
      if (button.evaluate().isNotEmpty) return tap(button);
      final bar = find.byType(NavigationBar);
      expect(bar, findsOneWidget);
      expect(Navigator.of(tester.element(bar)).canPop(), isFalse);
      expect(tester.widget<NavigationBar>(bar).selectedIndex, isNot(0));
      await tap(find.byTooltip('今天'));
    }

    Future<void> menu() async {
      await tap(find.byTooltip('陪伴'));
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        3,
      );
    }

    Future<void> shot(String name, {bool settle = true}) async {
      await render(settle: settle);
      final boundary =
          capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
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

    Future<ChatController> chat() =>
        container!.read(chatControllerProvider.future);
    Future<ChatController> openChat() async {
      await menu();
      await waitFor(() async => key('open-chat').evaluate().isNotEmpty);
      await tap(key('open-chat'));
      final state = await chat();
      await waitFor(
        () async => !state.busy && state.snapshot!.state.serverRevision != null,
      );
      return state;
    }

    Future<void> enter(String text, {bool settle = true}) async {
      await reveal(key('chat-input'), settle: settle);
      await tester.enterText(key('chat-input'), text);
      await waitFor(() async => (await chat()).draftSaved, settle: settle);
    }

    Future<void> send(
      String text, {
      bool photo = false,
      bool settle = true,
    }) async {
      await enter(text);
      if (photo) {
        await tap(key('chat-library'));
        await waitFor(
          () async =>
              (await chat()).draftPhotoId != null && (await chat()).draftSaved,
        );
      }
      await tap(key('send-chat'), times: 5, settle: settle);
    }

    Future<void> settled(int count) async {
      final state = await chat();
      await waitFor(
        () async =>
            !state.busy &&
            state.pending.isEmpty &&
            state.snapshot!.messages.length == count,
      );
      expect(state.error, isNull);
      final messages = state.snapshot!.messages;
      expect(messages.map((m) => m.id).toSet().length, count);
      expect(
        messages.map((m) => m.sequence).toList(),
        orderedEquals(messages.map((m) => m.sequence).toList()..sort()),
      );
    }

    Future<Map<String, dynamic>> previous(String name) async =>
        jsonDecode(await File('${root.path}/$name/report.json').readAsString())
            as Map<String, dynamic>;
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
        for (final row in await db.select(db.recordPhotos).get()) row.toJson(),
      ],
      'completions': [
        for (final row in await db.select(db.checkIns).get()) row.toJson(),
      ],
    };
    Future<void> viewPhoto(ChatMessage message, String name) async {
      final state = await chat();
      final photo = message.photoId!;
      await tap(key('chat-photo-$photo'));
      await waitFor(
        () async =>
            find.byType(InteractiveViewer).evaluate().isNotEmpty &&
            find.byType(Image).evaluate().isNotEmpty,
      );
      await shot(name);
      final downloaded = await state.downloadPhoto(
        message.id,
        photo,
        CompanionCancellation(),
      );
      final decoded = img.decodeJpg(downloaded.bytes)!;
      expect(decoded.exif.isEmpty, true);
      expect(decoded.width, 120);
      expect(decoded.height, 80);
      await back();
    }

    Future<void> refusedPhoto(ChatController state, String id) async {
      await expectLater(
        service.downloadPhoto(
          CompanionPhotoRequest.fromJson({
            'protocol': companionProtocol,
            'group_id': state.store.groupId,
            'photo_id': id,
          }),
          access: state.access,
        ),
        throwsA(
          isA<CompanionServiceFailure>().having(
            (e) => e.code,
            'revoked photo',
            'photo_unavailable',
          ),
        ),
      );
    }

    Future<void> remove(ChatMessage message) async {
      await tap(key('delete-chat-${message.id}'));
      await tap(find.text('取消'));
      expect(
        (await chat()).snapshot!.messages.any((m) => m.id == message.id),
        true,
      );
      await tap(key('delete-chat-${message.id}'));
      await tap(key('confirm-chat'));
      await waitFor(
        () async =>
            !(await chat()).busy &&
            !(await chat()).snapshot!.messages.any((m) => m.id == message.id),
      );
    }

    Future<void> uncertain(String code) async {
      final state = await chat();
      await waitFor(
        () async =>
            !state.busy &&
            state.pending.length == 1 &&
            state.pending.single.row.status == 'uncertain',
      );
      final attempt = state.pending.single;
      expect(attempt.row.attempts, 1);
      expect(attempt.row.errorCode, code);
      expect(key('discard-chat-${attempt.row.operationId}'), findsNothing);
      report.addAll({
        'operation_id': attempt.row.operationId,
        'message_id': attempt.row.messageId,
        'body_hash': sha256
            .convert(utf8.encode(attempt.row.requestJson!))
            .toString(),
        'photo_id': attempt.command.photoId,
      });
      await shot('uncertain-$code');
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
      if (fresh) {
        await tap(key('entry-new-goal'));
        await tester.enterText(
          key('goal-title'),
          'SYNTHETIC $role private goal',
        );
        await tap(key('save-goal'));
        await waitFor(() async => key('save-goal').evaluate().isEmpty);
        final id = (await goals.loadGoals()).single.id;
        await tap(key('record-$id-${day.key}'));
        await tester.enterText(
          key('record-text'),
          'SYNTHETIC $role private record',
        );
        await tap(key('record-library'));
        await waitFor(() async => find.byType(Image).evaluate().isNotEmpty);
        await tap(key('save-record'));
        await waitFor(() async => key('record-text').evaluate().isEmpty);
        await tap(key('complete-$id'));
        await menu();
        final pairing = await container.read(pairingControllerProvider.future);
        await waitFor(() async => pairing.canStart && pairing.confirmed);
        if (phase == 'invite') {
          await tap(key('create-pairing-invite'), times: 5);
          await waitFor(
            () async => pairing.snapshot?.state?.invitation != null,
          );
          report['invitation'] = pairing.snapshot!.state!.invitation!.code;
        } else {
          expect(RegExp(r'^[A-HJ-NP-Z2-9]{8}$').hasMatch(invitation), true);
          await reveal(key('pairing-code-input'));
          await tester.enterText(key('pairing-code-input'), invitation);
          await tap(key('join-pairing'));
          await tap(key('confirm-pairing'), times: 5);
          await waitFor(() async => pairing.snapshot?.state?.group != null);
          await shot('paired');
          await tap(key('open-chat'));
          await settled(0);
          await shot('empty-chat');
        }
      } else if (phase == 'cleanup' || phase == 'race-observe') {
        await menu();
        final pairing = await container.read(pairingControllerProvider.future);
        await waitFor(
          () async =>
              pairing.confirmed && pairing.snapshot?.state?.group == null,
        );
        await shot('remote-unpair-observed');
      } else {
        final state = await openChat();
        report['group_id'] = state.store.groupId;
        if (phase == 'delete-arm') {
          await settled(1);
          final message = state.snapshot!.messages.single;
          expect(message.text, first);
          await enter(draft);
          await tap(key('delete-chat-${message.id}'));
          await tap(find.text('取消'));
          expect(state.snapshot!.messages.single.id, message.id);
          expect(state.pending, isEmpty);
          await tap(key('delete-chat-${message.id}'));
          await tap(key('confirm-chat'), times: 5, settle: false);
          await waitFor(
            () async =>
                state.busy &&
                state.pending.length == 1 &&
                state.pending.single.row.status == 'sending',
            settle: false,
          );
          final attempt = (await state.store.snapshot()).commands.singleWhere(
            (job) => job.row.kind == 'remove',
          );
          expect(attempt.row.attempts, 1);
          expect(attempt.row.receiptJson, isNull);
          report.addAll({
            'operation_id': attempt.row.operationId,
            'message_id': message.id,
            'photo_id': message.photoId,
            'body_hash': sha256
                .convert(utf8.encode(attempt.row.requestJson!))
                .toString(),
            'next_draft': draft,
            'ready_to_kill': true,
          });
          expect((await state.store.snapshot()).state.draftText, draft);
          await shot('deletion-waiting', settle: false);
          await File('${output.path}/report.json')
              .writeAsString(jsonEncode(report), flush: true);
          debugPrint('CHAT_DELETE_READY_TO_KILL');
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(minutes: 4)),
          );
          fail('Host must verify matching durable deletion before termination');
        } else if (phase == 'delete-resume') {
          final old = await previous('delete-arm');
          final pending = state.pending.single;
          expect(pending.row.operationId, old['operation_id']);
          expect(pending.row.kind, 'remove');
          expect(pending.row.messageId, old['message_id']);
          expect(pending.row.status, 'uncertain');
          expect(pending.row.attempts, 1);
          expect(
            sha256.convert(utf8.encode(pending.row.requestJson!)).toString(),
            old['body_hash'],
          );
          expect(state.snapshot!.messages, isEmpty);
          expect(state.draftText, draft);
          await tester.pump(const Duration(seconds: 2));
          expect(state.pending.single.row.attempts, 1);
          expect(state.busy, false);
          await shot('cold-delete-unknown');
          await tap(key('retry-chat-${pending.row.operationId}'), times: 5);
          await settled(0);
          expect(state.draftText, draft);
          await refusedPhoto(state, old['photo_id'] as String);
          await shot('deletion-confirmed-draft-retained');
          report.addAll({
            'operation_id': old['operation_id'],
            'body_hash': old['body_hash'],
          });
        } else if (phase == 'delete-observe' || phase == 'delete-leave') {
          await settled(0);
          await refusedPhoto(state, uploadedPhoto);
          expect(find.text(first), findsNothing);
          await shot('partner-deletion-observed');
          if (phase == 'delete-leave') {
            await back();
            await tap(key('leave-pairing'));
            await tap(key('confirm-pairing'));
            final pairing = await container.read(
              pairingControllerProvider.future,
            );
            await waitFor(
              () async =>
                  pairing.confirmed && pairing.snapshot?.state?.group == null,
            );
            await shot('deletion-journey-unpaired');
          }
        } else if (phase == 'upload-arm') {
          await settled(0);
          await send(interruptedUpload, photo: true, settle: false);
          await enter(draft, settle: false);
          await waitFor(
            () async =>
                state.busy &&
                state.pending.length == 1 &&
                state.pending.single.row.status == 'sending',
            settle: false,
          );
          final attempt = (await state.store.snapshot()).commands.single;
          expect(attempt.row.attempts, 1);
          expect(attempt.row.photoReceiptJson, isNull);
          expect(attempt.row.requestJson, isNull);
          expect(attempt.row.receiptJson, isNull);
          final bytes = await chatFiles.read(
            state.store,
            attempt.row.localPhotoId!,
          );
          final upload = CompanionPhotoUpload.fromJson({
            'protocol': companionProtocol,
            'operation_id': attempt.row.uploadOperationId,
            'group_id': state.store.groupId,
            'purpose': 'chat',
            'grant_id': null,
            'jpeg_base64': base64Encode(bytes),
          });
          expect(img.decodeJpg(bytes)!.exif.isEmpty, true);
          report.addAll({
            'operation_id': attempt.row.operationId,
            'upload_operation_id': upload.operationId,
            'upload_body_hash': sha256
                .convert(utf8.encode(jsonEncode(upload.toJson())))
                .toString(),
            'local_photo_id': attempt.row.localPhotoId,
            'local_photo_sha256': sha256.convert(bytes).toString(),
            'next_draft': draft,
            'ready_to_kill': true,
          });
          expect((await state.store.snapshot()).state.draftText, draft);
          await shot('upload-accepted-waiting', settle: false);
          await File('${output.path}/report.json')
              .writeAsString(jsonEncode(report), flush: true);
          debugPrint('CHAT_UPLOAD_READY_TO_KILL');
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(minutes: 4)),
          );
          fail('Host must verify private upload acceptance before termination');
        } else if (phase == 'upload-private') {
          await settled(0);
          await refusedPhoto(state, uploadedPhoto);
          expect(find.text(interruptedUpload), findsNothing);
          report['unattached_photo_denied'] = true;
          await shot('partner-still-empty');
        } else if (phase == 'upload-resume') {
          final old = await previous('upload-arm');
          final pending = state.pending.single;
          expect(pending.row.operationId, old['operation_id']);
          expect(pending.row.uploadOperationId, old['upload_operation_id']);
          expect(pending.row.localPhotoId, old['local_photo_id']);
          expect(pending.row.status, 'uncertain');
          expect(pending.row.attempts, 1);
          expect(pending.row.photoReceiptJson, isNull);
          expect(pending.row.requestJson, isNull);
          expect(state.snapshot!.messages, isEmpty);
          expect(state.draftText, draft);
          expect(
            sha256
                .convert(
                  await chatFiles.read(state.store, pending.row.localPhotoId!),
                )
                .toString(),
            old['local_photo_sha256'],
          );
          await tester.pump(const Duration(seconds: 2));
          expect(state.pending.single.row.attempts, 1);
          expect(state.busy, false);
          await shot('cold-upload-unknown');
          await tap(key('retry-chat-${pending.row.operationId}'), times: 5);
          await settled(1);
          expect(state.snapshot!.messages.single.text, interruptedUpload);
          expect(state.snapshot!.messages.single.photoId, uploadedPhoto);
          expect(state.draftText, draft);
          report.addAll({
            'operation_id': pending.row.operationId,
            'upload_operation_id': pending.row.uploadOperationId,
            'photo_id': uploadedPhoto,
          });
          await viewPhoto(state.snapshot!.messages.single, 'recovered-photo');
          await shot('recovered-once-with-draft');
        } else if (phase == 'upload-observe') {
          await settled(1);
          final message = state.snapshot!.messages.single;
          expect(message.text, interruptedUpload);
          expect(message.photoId, uploadedPhoto);
          expect(key('delete-chat-${message.id}'), findsNothing);
          await viewPhoto(message, 'partner-received-photo');
          await shot('partner-received-once');
        } else if (phase == 'upload-leave') {
          await settled(1);
          await back();
          await tap(key('leave-pairing'));
          await tap(key('confirm-pairing'));
          final pairing = await container.read(
            pairingControllerProvider.future,
          );
          await waitFor(
            () async =>
                pairing.confirmed && pairing.snapshot?.state?.group == null,
          );
          await shot('upload-journey-unpaired');
        } else if (phase == 'race-send') {
          await settled(0);
          await send('SYNTHETIC simultaneous $role', photo: true);
          await enter(draft);
          debugPrint('CHAT_RACE_WAITING $role/$phase');
          await settled(2);
          expect(state.draftText, draft);
          expect(state.snapshot!.messages.map((m) => m.text).toSet(), {
            'SYNTHETIC simultaneous a',
            'SYNTHETIC simultaneous b',
          });
          final incoming = state.snapshot!.messages.singleWhere(
            (m) => m.authorId != state.store.memberId,
          );
          expect(key('delete-chat-${incoming.id}'), findsNothing);
          await viewPhoto(incoming, 'concurrent-partner-photo');
          await shot('concurrent-two-messages');
        } else if (phase == 'race-leave' ||
            (phase == 'race-send-leave' && role == 'b')) {
          await back();
          await tap(key('leave-pairing'));
          await tap(key('confirm-pairing'), times: 5);
          debugPrint('CHAT_RACE_WAITING $role/$phase');
          final pairing = await container.read(
            pairingControllerProvider.future,
          );
          await waitFor(
            () async =>
                pairing.confirmed && pairing.snapshot?.state?.group == null,
          );
          await shot('concurrent-unpaired');
        } else if (phase == 'race-send-leave') {
          await settled(2);
          await send('SYNTHETIC overlaps unpair', photo: true);
          debugPrint('CHAT_RACE_WAITING $role/$phase');
          await waitFor(() async => !state.available);
          expect(key('send-chat'), findsNothing);
          expect(find.text('SYNTHETIC simultaneous b'), findsNothing);
          await shot('concurrent-unpair-blocked-send');
        } else if (phase == 'send') {
          await enter(draft);
          await back();
          await tap(key('open-sharing'));
          await back();
          await tap(key('open-chat'));
          expect(
            tester.widget<TextField>(key('chat-input')).controller!.text,
            draft,
          );
          await send(first, photo: true);
          await settled(1);
          await viewPhoto(state.snapshot!.messages.single, 'sent-photo');
        } else if (phase == 'reply') {
          await settled(1);
          final incoming = state.snapshot!.messages.single;
          expect(incoming.text, first);
          expect(key('delete-chat-${incoming.id}'), findsNothing);
          await viewPhoto(incoming, 'received-a-photo');
          await send(reply, photo: true);
          await settled(2);
          await enter(draft);
          await shot('b-replied');
        } else if (phase == 'offline') {
          await settled(2);
          await viewPhoto(state.snapshot!.messages.last, 'received-b-photo');
          await send(offline, photo: true);
          await uncertain('network');
          await send(queued);
          await waitFor(() async => state.pending.length == 2);
          expect(state.pending.map((a) => a.row.content), [offline, queued]);
          expect(state.pending.last.row.attempts, 0);
          await enter(draft);
          await shot('ordered-pending');
        } else if ({'recover', 'confirm', 'resume'}.contains(phase)) {
          final source = phase == 'recover'
              ? 'offline'
              : phase == 'confirm'
              ? 'timeout'
              : 'arm';
          final old = await previous(source);
          final count = phase == 'recover'
              ? 4
              : phase == 'confirm'
              ? 6
              : 7;
          final pending = state.pending.first;
          expect(pending.row.operationId, old['operation_id']);
          expect(pending.row.status, 'uncertain');
          expect(pending.row.attempts, 1);
          expect(
            sha256.convert(utf8.encode(pending.row.requestJson!)).toString(),
            old['body_hash'],
          );
          expect(state.draftText, draft);
          await tester.pump(const Duration(seconds: 2));
          expect(state.pending.first.row.attempts, 1);
          expect(state.error ?? '', isNot(contains('尚未发送')));
          await shot('cold-unknown');
          await tap(key('retry-chat-${pending.row.operationId}'), times: 5);
          await settled(count);
          expect(state.draftText, draft);
          report.addAll({
            'operation_id': pending.row.operationId,
            'body_hash': old['body_hash'],
          });
          await shot('recovered-once');
        } else if (phase == 'delay') {
          await settled(4);
          await send(delayed);
          await waitFor(
            () async =>
                state.busy && state.pending.single.row.status == 'sending',
          );
          await enter(draft);
          await shot('slow-send-with-next-draft');
          await settled(5);
          expect(state.draftText, draft);
          await shot('delayed-confirmed');
        } else if (phase == 'timeout') {
          await settled(5);
          await send(timeout, photo: true);
          await enter(draft);
          await uncertain('timeout');
          await tester.pump(const Duration(seconds: 7));
          expect(state.pending.single.row.status, 'uncertain');
          expect(state.pending.single.row.attempts, 1);
        } else if (phase == 'arm') {
          await settled(6);
          await send(interrupted, photo: true);
          await enter(draft);
          await waitFor(
            () async =>
                state.busy &&
                (await state.store.snapshot())
                        .commands
                        .single
                        .row
                        .requestJson !=
                    null,
          );
          final attempt = (await state.store.snapshot()).commands.single;
          report.addAll({
            'operation_id': attempt.row.operationId,
            'message_id': attempt.row.messageId,
            'body_hash': sha256
                .convert(utf8.encode(attempt.row.requestJson!))
                .toString(),
            'photo_id': attempt.command.photoId,
            'personal': await personal(),
            'ready_to_kill': true,
          });
          await shot('sending-before-kill');
          await File('${output.path}/report.json')
              .writeAsString(jsonEncode(report), flush: true);
          debugPrint('CHAT_READY_TO_KILL');
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(minutes: 4)),
          );
          fail(
            'Host must terminate after verifying client and backend evidence',
          );
        } else if (phase == 'remove-b') {
          await settled(7);
          expect(state.draftText, draft);
          expect(state.snapshot!.messages.map((m) => m.text), [
            first,
            reply,
            offline,
            queued,
            delayed,
            timeout,
            interrupted,
          ]);
          final own = state.snapshot!.messages.singleWhere(
            (m) => m.text == reply,
          );
          report['removed_photo'] = own.photoId;
          await remove(own);
          await settled(6);
          await refusedPhoto(state, own.photoId!);
          await shot('b-removed-own-message');
        } else if (phase == 'remove-a') {
          await settled(6);
          expect(state.snapshot!.messages.any((m) => m.text == reply), false);
          final old = await previous('offline');
          final oldMessages = old['messages'] as List;
          final removed =
              (oldMessages.cast<Map>().singleWhere(
                    (m) => m['text'] == reply,
                  ))['photo_id']
                  as String;
          await refusedPhoto(state, removed);
          final own = state.snapshot!.messages.singleWhere(
            (m) => m.text == first,
          );
          report['removed_photo'] = own.photoId;
          await remove(own);
          await settled(5);
          await refusedPhoto(state, own.photoId!);
          await shot('a-removed-own-message');
        } else if (phase == 'leave') {
          await settled(5);
          expect(state.snapshot!.messages.map((m) => m.text), [
            offline,
            queued,
            delayed,
            timeout,
            interrupted,
          ]);
          final old = await previous('reply');
          final messages = old['messages'] as List;
          final removed =
              messages.cast<Map>().singleWhere(
                    (m) => m['text'] == first,
                  )['photo_id']
                  as String;
          await refusedPhoto(state, removed);
          await shot('partner-deletion-observed');
          await back();
          await tap(key('leave-pairing'));
          await tap(key('confirm-pairing'));
          final pairing = await container.read(
            pairingControllerProvider.future,
          );
          await waitFor(
            () async =>
                pairing.confirmed && pairing.snapshot?.state?.group == null,
          );
          await shot('unpaired');
        }
        if (state.available) {
          report['messages'] = state.snapshot!.messages
              .map((m) => m.toJson())
              .toList();
          report['revision'] = state.snapshot!.state.serverRevision;
        }
      }
      if (phase == 'leave' ||
          phase == 'delete-leave' ||
          phase == 'upload-leave' ||
          phase == 'cleanup' ||
          {'race-leave', 'race-send-leave', 'race-observe'}.contains(phase)) {
        await waitFor(
          () async =>
              (await db.select(db.chatStates).get()).isEmpty &&
              (await db.select(db.chatMessagesCache).get()).isEmpty &&
              (await db.select(db.chatCommands).get()).isEmpty &&
              (await db.select(db.chatPhotos).get()).isEmpty,
        );
        final files = await container.read(chatPhotoFilesProvider.future);
        final retained = await files.root.exists()
            ? await files.root
                  .list(recursive: true, followLinks: false)
                  .where((f) => f is File)
                  .toList()
            : <FileSystemEntity>[];
        expect(retained, isEmpty);
        report['chat_files_remaining'] = retained.length;
      }
      if (!fresh) {
        expect(
          await personal(),
          (await previous(role == 'a' ? 'invite' : 'join'))['personal'],
        );
      }
      final records = await container.read(dayRecordStoreProvider.future);
      final record = (await db.select(db.dayRecords).get()).single;
      final saved = (await records.at(
        record.goalId,
        LocalDate.parse(record.day),
      ))!;
      final personalFiles = await container.read(
        recordPhotoFilesProvider.future,
      );
      expect(await personalFiles.read(saved.savedPhotos.single), isNotEmpty);
      report['personal'] = await personal();
      report['success'] = true;
      await File('${output.path}/report.json')
          .writeAsString(jsonEncode(report), flush: true);
      debugPrint('CHAT_JOURNEY $role/$phase passed');
    } catch (_) {
      if (capture.currentContext != null) await shot('failure');
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
