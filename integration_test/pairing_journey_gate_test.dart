import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/app/app.dart';
import 'package:habit_checkin/app/providers.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/local/open_database.dart';
import 'package:habit_checkin/data/sync/identity_store.dart';
import 'package:habit_checkin/features/assistant/assistant_providers.dart';
import 'package:habit_checkin/features/companion/companion_providers.dart';
import 'package:habit_checkin/features/companion/data/chat_photo_files.dart';
import 'package:habit_checkin/features/companion/data/companion_service.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:habit_checkin/features/records/record_providers.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:xingyuan_core/xingyuan_core.dart';

import '../test/support/pairing_fixtures.dart';
import '../test/support/isolated_goal_probe.dart';
import '../test/support/layout_capture.dart';
import '../test/support/test_clock.dart';
import '../test/support/test_reminder_notifications.dart';
import '../test/support/ui_harness.dart' show TestNotificationPermissions;

// Simulator-only entry point. Isolated synthetic database, loopback transport,
// no real credentials, model, owner data or system notifications.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  const run = String.fromEnvironment('PAIRING_JOURNEY_RUN');
  const phase = String.fromEnvironment('PAIRING_JOURNEY_PHASE');
  testWidgets(
    'pairing native HTTP, frozen retry and independent process recovery',
    (tester) async {
      expect(Platform.isIOS, true);
      expect(RegExp(r'^[A-Za-z0-9-]{8,60}$').hasMatch(run), true);
      expect(['write', 'arm', 'reopen'], contains(phase));
      final capture = LayoutCapture();
      await capture.prepare();
      if (LayoutCapture.enabled) {
        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1;
        tester.view.padding = const FakeViewPadding(top: 20);
        tester.view.viewPadding = const FakeViewPadding(top: 20);
        tester.view.viewInsets = const FakeViewPadding();
        tester.platformDispatcher.textScaleFactorTestValue = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPadding);
        addTearDown(tester.view.resetViewPadding);
        addTearDown(tester.view.resetViewInsets);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      }
      final db = openAppDatabase(name: 'habit_checkin_pairing_$run');
      final workspace = await Directory(
        '${(await getApplicationDocumentsDirectory()).path}/pairing_probe_$run',
      ).create(recursive: true);
      final clock = TestClock()
        ..location = tz.getLocation(
          phase == 'reopen' ? 'Asia/Shanghai' : 'America/Los_Angeles',
        );
      clock.setDay(2026, 10, 21, hour: 23, minute: 58);
      final lease = await IdentityStore(db).active();
      final goals = LocalGoalRepository(db, clock, identityLease: lease);
      final credential = 'a' * 43;
      final requests = <PairingCommand>[];
      var server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      var delay = Duration.zero;
      var state = testPairingState();
      String? rejection;
      Future<void> handle(HttpRequest incoming) async {
        expectSync(
          incoming.headers.value('authorization'),
          'Bearer $credential',
        );
        Object? body;
        var status = 200;
        if (incoming.uri.path == pairingStateRoute) {
          body = state.toJson();
        } else if (pairingCommandRoutes.containsKey(incoming.uri.path)) {
          final kind = pairingCommandRoutes[incoming.uri.path];
          expectSync(kind, isNotNull);
          final command = PairingCommand.fromJson(
            kind!,
            jsonDecode(await utf8.decoder.bind(incoming).join()),
          );
          requests.add(command);
          if (rejection != null) {
            status = 404;
            body = {'error': rejection};
          } else {
            state = switch (command.kind) {
              PairingCommandKind.createInvite => testPairingState(
                invited: true,
              ),
              PairingCommandKind.join => testPairingState(paired: true),
              _ => testPairingState(),
            };
            body = {
              'protocol': companionProtocol,
              'operation_id': command.operationId,
              'state': state.toJson(),
            };
          }
          await Future<void>.delayed(delay);
        } else {
          status = 404;
          body = {'error': 'not_found'};
        }
        try {
          incoming.response.statusCode = status;
          incoming.response.headers.contentType = ContentType.json;
          incoming.response.write(jsonEncode(body));
          await incoming.response.close();
        } on HttpException {
          // Timeout and cancellation intentionally close the client socket.
        } on SocketException {
          // Timeout and cancellation intentionally close the client socket.
        }
      }

      server.listen(handle);
      final service = HttpCompanionService(
        endpoint: Uri.parse('http://127.0.0.1:$port'),
        readCredential: () async => credential,
        allowInsecureLoopback: true,
        timeout: phase == 'arm'
            ? const Duration(minutes: 5)
            : const Duration(seconds: 4),
      );
      Future<void> waitFor(Future<bool> Function() ready) async {
        final watch = Stopwatch()..start();
        while (!await ready()) {
          if (watch.elapsed > const Duration(seconds: 20)) {
            fail('Native pairing wait exceeded');
          }
          await tester.pump(const Duration(milliseconds: 50));
        }
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }

      Future<void> tap(Finder finder) async {
        await tester.ensureVisible(finder);
        await tester.pumpAndSettle();
        expect(finder.hitTestable(), findsOneWidget);
        await tester.tap(finder);
        await tester.pumpAndSettle();
      }

      Future<void> open() async {
        await tap(find.byTooltip('陪伴'));
        expect(
          tester
              .widget<NavigationBar>(find.byType(NavigationBar))
              .selectedIndex,
          3,
        );
      }

      Future<void> confirm() =>
          tap(find.byKey(const ValueKey('confirm-pairing')));
      final input = find.byKey(const ValueKey('pairing-code-input'));
      ChatPhotoFiles? chatFiles;
      try {
        if (phase == 'write') {
          expect(await goals.loadGoals(), isEmpty);
          final id = await goals.create(
            const GoalDraft(
              title: 'TEST personal preserved',
              kind: GoalKind.habit,
            ),
          );
          await goals.setCompleted(id, true, expectedDay: clock.day);
        }
        final overrides = [
          databaseFactoryProvider.overrideWithValue(
            () => throw StateError(
              'Pairing probe tried to open the ordinary database',
            ),
          ),
          clockProvider.overrideWithValue(clock),
          refreshClockProvider.overrideWithValue(() async {}),
          ...isolatedGoalProbeOverrides(
            goals: goals,
            workspace: workspace,
            credential: credential,
          ),
          companionServiceProvider.overrideWithValue(service),
          notificationPermissionsProvider.overrideWithValue(
            TestNotificationPermissions(),
          ),
          reminderNotificationsProvider.overrideWithValue(
            TestReminderNotifications(),
          ),
        ];
        const bootstrap = ValueKey('pairing-probe-bootstrap');
        await tester.pumpWidget(
          ProviderScope(
            overrides: overrides,
            child: const SizedBox(key: bootstrap),
          ),
        );
        final container = ProviderScope.containerOf(
          tester.element(find.byKey(bootstrap)),
        );
        // Check bindings before App startup can launch background file cleanup.
        expect(await container.read(databaseProvider.future), same(db));
        final recordRoot = await container.read(recordPhotoRootProvider.future);
        final files = await container.read(chatPhotoFilesProvider.future);
        chatFiles = files;
        expect(recordRoot.path, '${workspace.path}/record_photos');
        expect(files.root.path, '${workspace.path}/chat_photos');
        expect(files.db, same(db));
        expect(
          await container.read(assistantCredentialProvider).read(),
          credential,
        );
        await container.read(chatPhotoCleanupProvider.future);
        debugPrint('PAIRING_PROBE_ISOLATION verified=true');
        await tester.pumpWidget(
          ProviderScope(
            overrides: overrides,
            child: capture.wrap(const HabitCheckinApp()),
          ),
        );
        await waitFor(() async => find.byTooltip('陪伴').evaluate().isNotEmpty);
        expect(
          ProviderScope.containerOf(
            tester.element(find.byType(HabitCheckinApp)),
          ),
          same(container),
        );
        await open();
        final controller = await container.read(
          pairingControllerProvider.future,
        );
        await waitFor(
          () async => !controller.refreshing && controller.confirmed,
        );
        if (phase == 'write') {
          await tester.enterText(input, 'TEST 😀\n草稿');
          await tester.pumpAndSettle();
          await tap(find.byType(BackButton));
          await tap(find.byTooltip('回顾'));
          await tap(find.byTooltip('今天'));
          await open();
          await waitFor(() async => !controller.refreshing);
          expect(
            tester.widget<TextField>(input).controller!.text,
            'TEST 😀\n草稿',
          );
          delay = const Duration(seconds: 3);
          final create = find.byKey(const ValueKey('create-pairing-invite'));
          for (var i = 0; i < 5; i++) {
            await tester.tap(create);
          }
          await waitFor(() async => !controller.busy && requests.length == 1);
          expect(find.text('ABCDEFGH'), findsOneWidget);
          delay = Duration.zero;
          await tap(find.byKey(const ValueKey('cancel-pairing-invite')));
          await confirm();
          await waitFor(() async => !controller.busy);
          rejection = 'invite_invalid';
          await tester.enterText(input, 'WRONG');
          await tap(find.byKey(const ValueKey('join-pairing')));
          await confirm();
          await waitFor(() async => !controller.busy);
          expect(controller.snapshot!.command!.row.errorCode, 'invite_invalid');
          rejection = null;
          delay = const Duration(seconds: 10);
          await tester.enterText(input, 'ABCDEFGH');
          await tap(find.byKey(const ValueKey('join-pairing')));
          await confirm();
          await waitFor(() async => !controller.busy);
          expect(controller.hasUncertainOperation, true);
          final timedOut = requests.last;
          await tester.enterText(input, 'NEXT-DRAFT');
          delay = Duration.zero;
          await tap(find.byKey(const ValueKey('retry-pairing')));
          await waitFor(() async => !controller.busy);
          expect(requests.last.toJson(), timedOut.toJson());
          expect(controller.draft, 'NEXT-DRAFT');
          expect(find.text('已配对'), findsOneWidget);
          await capture.shot(tester, 1, 'paired-after-retry');
          await tap(find.byKey(const ValueKey('leave-pairing')));
          await tap(find.text('取消').last);
          expect(find.text('已配对'), findsOneWidget);
          await tap(find.byKey(const ValueKey('leave-pairing')));
          await confirm();
          await waitFor(() async => !controller.busy);
          expect(controller.snapshot!.state!.group, isNull);
          await server.close(force: true);
          await tap(find.byKey(const ValueKey('create-pairing-invite')));
          await waitFor(() async => !controller.busy);
          expect(controller.snapshot!.command!.row.errorCode, 'network');
          await capture.shot(tester, 1, 'offline-create');
          server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
          server.listen(handle);
          await tap(find.byKey(const ValueKey('retry-pairing')));
          await waitFor(() async => !controller.busy);
          expect(controller.snapshot!.state!.invitation, isNotNull);
          await tap(find.byKey(const ValueKey('cancel-pairing-invite')));
          await confirm();
          await waitFor(() async => !controller.busy);
          await tester.enterText(input, 'TEST durable draft');
          await controller.flushDraft();
          await capture.shot(tester, 1, 'durable-draft');
        } else if (phase == 'arm') {
          expect(controller.draft, 'TEST durable draft');
          delay = const Duration(minutes: 5);
          await tap(find.byKey(const ValueKey('create-pairing-invite')));
          await waitFor(() async => controller.busy && requests.length == 1);
          final pending = (await controller.store.snapshot()).command!;
          expect(pending.row.status, 'sending');
          expect(requests.single.toJson(), pending.command.toJson());
          expect(state.invitation, isNotNull);
          await capture.shot(tester, 1, 'sending-before-interruption');
          await File('${workspace.path}/arm.json').writeAsString(
            jsonEncode({
              'request': requests.single.toJson(),
              'localStatus': pending.row.status,
              'syntheticHandlerAccepted': state.invitation != null,
            }),
            flush: true,
          );
          debugPrint('PAIRING_PROBE_READY_TO_KILL $run');
          await Future<void>.delayed(const Duration(minutes: 2));
          fail('Host did not terminate armed simulator App');
        } else {
          expect(controller.draft, 'TEST durable draft');
          expect(controller.hasUncertainOperation, true);
          final saved = controller.snapshot!.command!.command.toJson();
          expect(requests, isEmpty);
          await capture.shot(tester, 1, 'recovered-uncertain');
          await tap(find.byKey(const ValueKey('retry-pairing')));
          await waitFor(() async => !controller.busy);
          expect(requests.single.toJson(), saved);
          expect(controller.snapshot!.state!.invitation, isNotNull);
          expect(controller.draft, 'TEST durable draft');
          await capture.shot(tester, 1, 'retried-original-operation');
        }
        expect(
          (await goals.loadGoals()).single.titleOn(clock.day),
          'TEST personal preserved',
        );
        expect((await db.select(db.checkIns).get()).single.completed, true);
        expect(await db.select(db.assistantSessions).get(), isEmpty);
        expect(await db.select(db.dayAnalyses).get(), isEmpty);
        expect(tester.takeException(), isNull);
        await capture.passed(tester, 1);
        debugPrint('PAIRING_PROBE phase=$phase passed=true model_calls=0');
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(Duration.zero);
        await chatFiles?.dispose();
        await server.close(force: true);
        await db.close();
      }
    },
  );
}
