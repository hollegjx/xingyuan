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
import 'package:habit_checkin/features/analysis/analysis_providers.dart';
import 'package:habit_checkin/features/assistant/data/assistant_service.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:habit_checkin/features/records/data/local_day_record_store.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:uuid/uuid.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

import '../test/support/test_clock.dart';
import '../test/support/isolated_goal_probe.dart';
import '../test/support/test_reminder_notifications.dart';
import '../test/support/ui_harness.dart' show TestNotificationPermissions;

// Isolated simulator database and real loopback HTTP; no real model, Keychain,
// ordinary personal database or system notifications are accessed.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  const run = String.fromEnvironment('ANALYSIS_JOURNEY_RUN');
  const phase = String.fromEnvironment('ANALYSIS_JOURNEY_PHASE');
  testWidgets(
    'analysis consent, HTTP retry/cancel and independent process recovery',
    (tester) async {
      expect(Platform.isIOS, true);
      expect(RegExp(r'^[A-Za-z0-9-]{8,60}$').hasMatch(run), true);
      expect(['write', 'arm', 'reopen'], contains(phase));
      final db = openAppDatabase(name: 'habit_checkin_analysis_$run');
      final workspace = await Directory(
        '${(await getApplicationDocumentsDirectory()).path}/analysis_probe_$run',
      ).create(recursive: true);
      final clock = TestClock()
        ..location = tz.getLocation('America/Los_Angeles');
      clock.setDay(2026, 10, 21, hour: 23, minute: 58);
      final lease = await IdentityStore(db).active();
      final goals = LocalGoalRepository(
        db,
        clock,
        owner: lease.identity.owner,
        identityLease: lease,
      );
      final requests = <Map<String, dynamic>>[];
      var server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      var status = 200;
      var delay = Duration.zero;
      final token = base64Url.encode(List.filled(32, 4)).replaceAll('=', '');
      Future<void> handle(HttpRequest incoming) async {
        final payload = jsonDecode(
          await utf8.decoder.bind(incoming).join(),
        ) as Map<String, dynamic>;
        requests.add(payload);
        final currentStatus = status;
        expectSync(incoming.uri.path, '/v1/analyze-day');
        expectSync(incoming.headers.value('authorization'), 'Bearer $token');
        await Future<void>.delayed(delay);
        try {
          incoming.response.statusCode = currentStatus;
          incoming.response.headers.contentType = ContentType.json;
          incoming.response.write(
            jsonEncode(
              currentStatus == 200
                  ? {
                      'protocol': assistantProtocol,
                      'request_id': payload['request_id'],
                      'summary': 'TEST 今天完成了阅读。',
                      'suggestions': ['TEST 可以记下一点读后的感受。'],
                    }
                  : {'error': 'synthetic-unavailable'},
            ),
          );
          await incoming.response.close();
        } on HttpException {
          /* Client cancellation is part of this probe. */
        } on SocketException {
          /* Client cancellation is part of this probe. */
        }
      }

      server.listen(handle);
      final service = HttpAssistantService(
        endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
        allowInsecureLoopback: true,
        readCredential: () async => token,
        timeout: phase == 'arm'
            ? const Duration(minutes: 5)
            : const Duration(seconds: 4),
      );
      Future<void> waitFor(Future<bool> Function() ready) async {
        final watch = Stopwatch()..start();
        while (!await ready()) {
          if (watch.elapsed > const Duration(seconds: 20)) {
            fail('Native analysis wait exceeded');
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

      try {
        if (phase == 'write') {
          expect(await goals.loadGoals(), isEmpty);
          final id = await goals.create(
            const GoalDraft(
              title: 'TEST 阅读',
              kind: GoalKind.habit,
              startMinute: 1200,
              durationMinutes: 20,
            ),
          );
          await goals.setCompleted(id, true, expectedDay: clock.day);
          final records = LocalDayRecordStore(goals);
          var record = await records.beginDraft(id, clock.day);
          record = await records.writeDraft(
            record.record.id,
            content: 'TEST 读完一章\n想整理要点',
            expectedDraftRevision: record.record.draftRevision,
          );
          await records.save(
            record.record.id,
            operationId: const Uuid().v4(),
            expectedRevision: record.record.revision,
            expectedDraftRevision: record.record.draftRevision,
          );
          record = await records.beginDraft(id, clock.day);
          await records.writeDraft(
            record.record.id,
            content: 'OMITTED unsaved draft',
            expectedDraftRevision: record.record.draftRevision,
          );
        } else if (phase == 'reopen') {
          clock.location = tz.getLocation('Asia/Shanghai');
        }
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              clockProvider.overrideWithValue(clock),
              refreshClockProvider.overrideWithValue(() async {}),
              ...isolatedGoalProbeOverrides(goals: goals, workspace: workspace),
              dayAnalysisServiceProvider.overrideWithValue(service),
              notificationPermissionsProvider.overrideWithValue(
                TestNotificationPermissions(),
              ),
              reminderNotificationsProvider.overrideWithValue(
                TestReminderNotifications(),
              ),
            ],
            child: const HabitCheckinApp(),
          ),
        );
        await waitFor(
          () async => find
              .byKey(const ValueKey('open-day-analysis'))
              .evaluate()
              .isNotEmpty,
        );
        final container = ProviderScope.containerOf(
          tester.element(find.byType(HabitCheckinApp)),
        );
        await tap(find.byKey(const ValueKey('open-day-analysis')));
        final controller = await container.read(
          dayAnalysisControllerProvider.future,
        );
        final store = controller.store;
        if (phase == 'write') {
          await tap(find.byKey(const ValueKey('analyze-today')));
          expect(requests, isEmpty);
          await tap(find.text('取消'));
          await tap(find.byKey(const ValueKey('analyze-today')));
          delay = const Duration(seconds: 3);
          await tap(find.byKey(const ValueKey('consent-day-analysis')));
          for (var i = 0; i < 5; i++) {
            await tester.tap(find.byKey(const ValueKey('analyze-today')));
          }
          await waitFor(() async => requests.length == 1);
          expect(jsonEncode(requests.single), isNot(contains('OMITTED')));
          expect(requests.single.keys.toSet(), {
            'protocol',
            'request_id',
            'now',
            'entries',
          });
          await tap(find.byType(BackButton));
          await tap(find.byTooltip('回顾'));
          await tap(find.byTooltip('今天'));
          await tap(find.byKey(const ValueKey('open-day-analysis')));
          await waitFor(() async => !controller.busy);
          expect(controller.results.single.status, 'succeeded');
          expect(requests, hasLength(1));
          final succeeded = controller.results.single;
          await tap(find.byKey(ValueKey('analysis-payload-${succeeded.id}')));
          expect(find.textContaining('TEST 读完一章'), findsOneWidget);
          await tap(find.byType(BackButton));

          status = 503;
          delay = Duration.zero;
          await tap(find.byKey(const ValueKey('analyze-today')));
          await waitFor(() async => !controller.busy);
          final failed = controller.results.singleWhere(
            (row) => row.status == 'failed',
          );
          expect(failed.failureCode, 'unavailable');
          status = 200;
          delay = const Duration(seconds: 3);
          final retry = find.byKey(ValueKey('retry-analysis-${failed.id}'));
          await tester.ensureVisible(retry);
          for (var i = 0; i < 5; i++) {
            await tester.tap(retry);
          }
          await waitFor(() async => !controller.busy && requests.length == 3);
          expect(
            controller.results.where((row) => row.status == 'succeeded'),
            hasLength(2),
          );

          delay = const Duration(seconds: 10);
          await tap(find.byKey(const ValueKey('analyze-today')));
          await waitFor(() async => !controller.busy);
          expect(
            controller.results.where((row) => row.failureCode == 'timeout'),
            hasLength(1),
          );
          delay = const Duration(seconds: 3);
          await tap(find.byKey(const ValueKey('analyze-today')));
          await waitFor(() async => requests.length == 5);
          await tap(find.byKey(const ValueKey('cancel-analysis')));
          await waitFor(() async => !controller.busy);
          expect(
            controller.results.where((row) => row.status == 'cancelled'),
            hasLength(1),
          );
          expect((await goals.loadGoals()).single.singleCompletion, isNull);
          expect((await db.select(db.checkIns).get()).single.completed, true);

          await server.close(force: true);
          await tap(find.byKey(const ValueKey('analyze-today')));
          await waitFor(() async => !controller.busy);
          final offline = controller.results.singleWhere(
            (row) => row.failureCode == 'network',
          );
          expect(requests, hasLength(5));
          server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
          server.listen(handle);
          delay = Duration.zero;
          await tap(find.byKey(ValueKey('retry-analysis-${offline.id}')));
          await waitFor(() async => !controller.busy && requests.length == 6);
          expect(
            controller.results.where((row) => row.status == 'succeeded'),
            hasLength(3),
          );

          await tap(find.byKey(ValueKey('delete-analysis-${succeeded.id}')));
          await tap(find.byKey(const ValueKey('confirm-delete-analysis')));
          expect(
            (await store.list()).any((row) => row.id == succeeded.id),
            false,
          );
        } else if (phase == 'arm') {
          delay = const Duration(minutes: 5);
          await tap(find.byKey(const ValueKey('analyze-today')));
          await waitFor(() async => requests.length == 1 && controller.busy);
          expect(
            (await store.list()).where((row) => row.status == 'pending'),
            hasLength(1),
          );
          debugPrint('ANALYSIS_PROBE_READY_TO_KILL $run');
          // The host must terminate this simulator App after the marker. Reopen
          // verifies the disk state; normal test completion here is a failure.
          await Future<void>.delayed(const Duration(minutes: 2));
          fail('Host did not terminate the armed test App');
        } else {
          expect(requests, isEmpty);
          expect(
            controller.results.where((row) => row.failureCode == 'interrupted'),
            hasLength(1),
          );
          expect(
            controller.results.where((row) => row.status == 'succeeded'),
            hasLength(2),
          );
          expect(
            controller.results.every(
              (row) =>
                  row.day == '2026-10-21' && row.zone == 'America/Los_Angeles',
            ),
            true,
          );
          final row = controller.results.firstWhere(
            (row) => row.status == 'succeeded',
          );
          await tap(find.byKey(ValueKey('analysis-payload-${row.id}')));
          expect(find.textContaining('TEST 读完一章'), findsOneWidget);
          expect((await db.select(db.checkIns).get()).single.completed, true);
          expect(
            (await db.select(db.dayRecords).get()).single.draftText,
            'OMITTED unsaved draft',
          );
        }
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(Duration.zero);
        await server.close(force: true);
        await db.close();
      }
    },
  );
}
