import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
import 'package:habit_checkin/features/records/data/record_photo.dart';
import 'package:habit_checkin/features/records/data/record_photo_files.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:uuid/uuid.dart';

import '../test/support/test_clock.dart';
import '../test/support/isolated_goal_probe.dart';
import '../test/support/test_reminder_notifications.dart';
import '../test/support/ui_harness.dart' show TestNotificationPermissions;

// Simulator only: synthetic database, one HTTPS call, no ordinary Keychain.
// The host injects and later revokes a qa- credential outside the build.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  const run = String.fromEnvironment('ANALYSIS_HTTPS_RUN');
  const phase = String.fromEnvironment(
    'ANALYSIS_HTTPS_PHASE',
    defaultValue: 'submit',
  );
  testWidgets('native UI and real HTTPS own-day analysis', (tester) async {
    expect(Platform.isIOS, true);
    expect(RegExp(r'^[A-Za-z0-9-]{8,60}$').hasMatch(run), true);
    expect({'submit', 'reopen'}, contains(phase));
    const address = String.fromEnvironment('ASSISTANT_BASE_URL');
    expect(address, 'https://assistant.example.invalid');
    final documents = await getApplicationDocumentsDirectory();
    final bootstrap = File('${documents.path}/analysis-https-$run.credential');
    String? token;
    if (phase == 'submit') {
      token = (await bootstrap.readAsString()).trim();
      expect(RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(token), true);
      await bootstrap.delete();
    } else {
      expect(await bootstrap.exists(), false);
    }
    final workspace = await Directory('${documents.path}/analysis_https_$run')
        .create(recursive: true);
    final output = await Directory('${workspace.path}/$phase').create();
    final capture = GlobalKey();
    var credentialReads = 0;
    final db = openAppDatabase(name: 'habit_checkin_analysis_https_$run');
    final clock = TestClock()..location = tz.getLocation('America/Los_Angeles');
    clock.setDay(2026, 10, 21, hour: 20, minute: 30);
    final lease = await IdentityStore(db).active();
    final goals = LocalGoalRepository(
      db,
      clock,
      owner: lease.identity.owner,
      identityLease: lease,
    );
    try {
      if (phase == 'submit') {
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
        final walk = await goals.create(
          const GoalDraft(title: 'TEST 散步', kind: GoalKind.habit),
        );
        await goals.setCompleted(walk, true, expectedDay: clock.day);
        await goals.create(
          const GoalDraft(title: 'TEST 拉伸', kind: GoalKind.habit),
        );
        final records = LocalDayRecordStore(goals);
        var record = await records.beginDraft(id, clock.day);
        record = await records.writeDraft(
          record.record.id,
          content: 'TEST 读完了一章，想整理一点感受。',
          expectedDraftRevision: record.record.draftRevision,
        );
        final sample = img.Image(width: 40, height: 30);
        img.fill(sample, color: img.ColorRgb8(25, 140, 120));
        final files = RecordPhotoFiles(
          Directory('${workspace.path}/record_photos'),
          goals.owner,
        );
        final photo = await files.write(
          await sanitizeRecordPhoto(img.encodeJpg(sample)),
        );
        record = await records.addPhoto(
          record.record.id,
          photo: photo,
          expectedDraftRevision: record.record.draftRevision,
        );
        await records.save(
          record.record.id,
          operationId: const Uuid().v4(),
          expectedRevision: record.record.revision,
          expectedDraftRevision: record.record.draftRevision,
        );
      }
      expect(await goals.loadGoals(), hasLength(3));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            clockProvider.overrideWithValue(clock),
            refreshClockProvider.overrideWithValue(() async {}),
            ...isolatedGoalProbeOverrides(goals: goals, workspace: workspace),
            dayAnalysisServiceProvider.overrideWithValue(
              HttpAssistantService(
                endpoint: Uri.parse(address),
                readCredential: () async {
                  credentialReads++;
                  return token;
                },
              ),
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
      Future<void> waitFor(bool Function() ready) async {
        final watch = Stopwatch()..start();
        while (!ready()) {
          if (watch.elapsed > const Duration(seconds: 95)) {
            fail('HTTPS UI deadline');
          }
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }

      Future<void> tap(Finder finder) async {
        await tester.ensureVisible(finder);
        await tester.tap(finder);
        await tester.pumpAndSettle();
      }

      Future<void> shot(String name) async {
        await tester.pumpAndSettle();
        final boundary =
            capture.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        try {
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('${output.path}/$name.png')
              .writeAsBytes(bytes!.buffer.asUint8List(), flush: true);
        } finally {
          image.dispose();
        }
      }

      await waitFor(
        () => find
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
      if (phase == 'submit') {
        await tap(find.byKey(const ValueKey('analyze-today')));
        expect(find.text('分析发送范围'), findsOneWidget);
        await shot('consent');
        await tap(find.byKey(const ValueKey('consent-day-analysis')));
      }
      await waitFor(() => !controller.busy && controller.results.isNotEmpty);
      final result = controller.results.single;
      expect(result.status, 'succeeded');
      expect(result.responseJson, isNotNull);
      await shot('result');
      await tap(find.byKey(ValueKey('analysis-payload-${result.id}')));
      expect(find.textContaining('TEST 读完了一章'), findsOneWidget);
      expect(find.textContaining('"photos"'), findsNothing);
      await shot('payload');
      final payload = jsonDecode(result.requestJson) as Map;
      final entries = (payload['entries'] as List).cast<Map>();
      expect(entries, hasLength(3));
      expect(entries.where((e) => e['completed'] == true), hasLength(2));
      expect(entries.where((e) => e['text'] != ''), hasLength(1));
      final photo = (await db.select(db.recordPhotos).get()).single;
      for (final value in [photo.id, photo.sha256, photo.filename]) {
        expect(result.requestJson, isNot(contains(value)));
      }
      final bytes = await RecordPhotoFiles(
        Directory('${workspace.path}/record_photos'),
        goals.owner,
      ).read(photo);
      expect(result.requestJson, isNot(contains(base64Encode(bytes))));
      expect(await db.select(db.checkIns).get(), hasLength(2));
      expect(credentialReads, phase == 'submit' ? 1 : 0);
      final report = File('${output.path}/report.json');
      await report.writeAsString(
        jsonEncode({
          'run': run,
          'phase': phase,
          'credential_reads': credentialReads,
          'local_photo_retained_and_excluded': true,
          'request_id': result.id,
          'status': result.status,
          'request': jsonDecode(result.requestJson),
          'response': jsonDecode(result.responseJson!),
          'ordinary_database_used': false,
          'ordinary_keychain_used': false,
        }),
        flush: true,
      );
      debugPrint('ANALYSIS_HTTPS_PASSED request_id=${result.id}');
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(Duration.zero);
      await db.close();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
