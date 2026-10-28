import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/assistant/assistant_providers.dart';
import 'package:habit_checkin/features/assistant/data/device_credential_store.dart';
import 'package:habit_checkin/features/companion/companion_providers.dart';
import 'package:habit_checkin/features/companion/data/companion_service.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:image/image.dart' as img;
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:xingyuan_core/xingyuan_core.dart';

import 'support/record_fixtures.dart';
import 'support/layout_capture.dart';
import 'support/sharing_fixtures.dart';
import 'support/publication_service.dart';
import 'support/ui_harness.dart';

class _Credentials extends DeviceCredentialStore {
  String? value = 'a' * 43;
  Completer<void>? clearGate;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> clear() async {
    await clearGate?.future;
    value = null;
  }
}

void main() {
  final capture = LayoutCapture();
  setUpAll(() async {
    tzdata.initializeTimeZones();
    await capture.prepare();
  });

  Future<(UiHarness, int)> foregroundApp(
    WidgetTester tester,
    TestPublicationService service, {
    _Credentials? credentials,
  }) async {
    final app = UiHarness();
    app.clock.instant = DateTime.utc(2026, 10, 21, 10, 1);
    final goal = await app.repository.create(
      const GoalDraft(
        title: 'SYNTHETIC foreground reading',
        kind: GoalKind.habit,
      ),
    );
    await app.mount(
      tester,
      assistantCredentials: credentials ?? _Credentials(),
      companionService: service,
      recordPhotoFiles: MemoryRecordPhotoFiles(),
      companionForeground: true,
      wrapApp: capture.wrap,
      recordPhotoPicker: StubRecordPhotoPicker()
        ..onPick = () async => img.encodePng(
          img.Image(width: 12, height: 8)..clear(img.ColorRgb8(32, 160, 90)),
        ),
    );
    await openMenu(tester, '陪伴');
    await tapVisible(tester, find.byKey(const ValueKey('open-sharing')));
    await tapVisible(tester, find.text('我的分享'));
    await tapVisible(tester, find.byKey(ValueKey('share-goal-$goal')));
    await tapVisible(tester, find.byKey(const ValueKey('confirm-sharing')));
    await goBack(tester);
    await goBack(tester);
    return (app, goal);
  }

  Future<void> edit(
    WidgetTester tester,
    UiHarness app,
    int goal,
    String text,
  ) async {
    await tapVisible(
      tester,
      find.byKey(ValueKey('record-$goal-${app.clock.day.key}')),
    );
    await tester.enterText(find.byKey(const ValueKey('record-text')), text);
    await tester.pumpAndSettle();
  }

  Future<void> importPhoto(WidgetTester tester) async {
    final picker = find.byKey(const ValueKey('record-library'));
    await tester.ensureVisible(picker);
    await tester.tap(picker);
    await tester.pump();
    for (var i = 0; i < 200; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
      if (find.byTooltip('移除照片').evaluate().length == 1) break;
    }
    await tester.pumpAndSettle();
    expect(find.byTooltip('移除照片'), findsOneWidget);
  }

  testUiWidgets(
    'normal foreground publishes explicit text and photo, displays feed, and sends one reply',
    (tester) async {
      final service = TestPublicationService();
      final (app, goal) = await foregroundApp(tester, service);
      await edit(tester, app, goal, 'SYNTHETIC published through editor');
      await tapVisible(
        tester,
        find.byKey(const ValueKey('record-share-details')),
      );
      await importPhoto(tester);
      await tapVisible(tester, find.byKey(const ValueKey('save-record')));
      expect(
        service.sharedCommands.where(
          (c) => c.kind == SharingCommandKind.publish,
        ),
        hasLength(1),
      );
      expect(service.uploads, hasLength(1));
      expect(find.text('记录已分享'), findsOneWidget);
      await openMenu(tester, '陪伴');
      await tapVisible(tester, find.byKey(const ValueKey('open-sharing')));
      expect(find.text('SYNTHETIC published through editor'), findsOneWidget);
      final remote = service.sharedRecords.single['id'];
      await tapVisible(tester, find.byKey(ValueKey('open-replies-$remote')));
      await tester.enterText(
        find.byKey(const ValueKey('sharing-reply-input')),
        'SYNTHETIC encouragement',
      );
      await tester.pumpAndSettle();
      final send = find.byKey(const ValueKey('send-sharing-reply'));
      await tester.ensureVisible(send);
      for (var i = 0; i < 5; i++) {
        await tester.tap(send);
      }
      await tester.pumpAndSettle();
      expect(service.sharedReplies, hasLength(1));
      expect(find.text('SYNTHETIC encouragement'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testUiWidgets(
    'offline share is visible and five retry taps reuse one operation',
    (tester) async {
      final service = TestPublicationService();
      final (app, goal) = await foregroundApp(tester, service);
      service.sharedFailure = const CompanionServiceFailure(
        'network',
        outcomeUnknown: true,
      );
      await edit(tester, app, goal, 'SYNTHETIC offline note');
      await tapVisible(
        tester,
        find.byKey(const ValueKey('record-share-details')),
      );
      await tapVisible(tester, find.byKey(const ValueKey('save-record')));
      expect(find.textContaining('分享结果尚未确认'), findsOneWidget);
      expect(find.text('记录已分享'), findsNothing);
      final first = service.sharedCommands.last;
      service.sharedFailure = null;
      final retry = find.byKey(
        ValueKey('retry-publication-${first.operationId}'),
      );
      await tester.ensureVisible(retry);
      for (var i = 0; i < 5; i++) {
        await tester.tap(retry);
      }
      await tester.pumpAndSettle();
      final published = service.sharedCommands
          .where((c) => c.kind == SharingCommandKind.publish)
          .toList();
      expect(published, hasLength(2));
      expect(published.first.toJson(), published.last.toJson());
      expect(find.text('记录已分享'), findsOneWidget);
      expect(find.byTooltip('重试分享'), findsNothing);
    },
  );

  testUiWidgets(
    'unchecking sharing removes remote details but keeps personal record and photo',
    (tester) async {
      final service = TestPublicationService();
      final (app, goal) = await foregroundApp(tester, service);
      await edit(tester, app, goal, 'SYNTHETIC formerly shared');
      await tapVisible(
        tester,
        find.byKey(const ValueKey('record-share-details')),
      );
      await importPhoto(tester);
      await tapVisible(tester, find.byKey(const ValueKey('save-record')));
      expect(service.sharedRecords, hasLength(1));
      await edit(tester, app, goal, 'SYNTHETIC now private');
      await tapVisible(
        tester,
        find.byKey(const ValueKey('record-share-details')),
      );
      await tapVisible(tester, find.byKey(const ValueKey('save-record')));
      expect(service.sharedRecords, isEmpty);
      final own =
          (await app.database.select(app.database.dayRecords).get()).single;
      expect(own.content, 'SYNTHETIC now private');
      expect(own.shareWithPartner, false);
      expect(own.syncState, 'local');
      expect(
        await app.database.select(app.database.recordPhotos).get(),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testUiWidgets(
    'App background cancels waiting and resume requires same-ID retry',
    (tester) async {
      final service = TestPublicationService();
      final (app, goal) = await foregroundApp(tester, service);
      service.publicationGate = Completer<void>();
      await edit(tester, app, goal, 'SYNTHETIC paused publication');
      await tapVisible(
        tester,
        find.byKey(const ValueKey('record-share-details')),
      );
      await tapVisible(tester, find.byKey(const ValueKey('save-record')));
      final sent = service.sharedCommands
          .where((c) => c.kind == SharingCommandKind.publish)
          .single;
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      service.publicationGate!.complete();
      // The native binding stops drawing while paused. Wait for the transport
      // without requesting a frame, then resume before pumping the UI.
      await tester.runAsync(
        () => app.container.read(companionForegroundProvider)!.idle,
      );
      expect(service.receipts.containsKey(sent.operationId), false);
      for (final state in [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pumpAndSettle();
      expect(
        service.sharedCommands.where(
          (c) => c.kind == SharingCommandKind.publish,
        ),
        hasLength(1),
      );
      expect(find.textContaining('分享结果尚未确认'), findsOneWidget);
      await tapVisible(
        tester,
        find.byKey(ValueKey('retry-publication-${sent.operationId}')),
      );
      expect(service.receipts.containsKey(sent.operationId), true);
      expect(service.sharedCommands.last.toJson(), sent.toJson());
      expect(find.text('记录已分享'), findsOneWidget);
    },
  );

  testUiWidgets(
    'sharing provider recreation keeps normal editor publication reactive',
    (tester) async {
      final service = TestPublicationService();
      final (app, goal) = await foregroundApp(tester, service);
      app.container.invalidate(sharingControllerProvider);
      await tester.pumpAndSettle();
      await edit(tester, app, goal, 'SYNTHETIC after provider retry');
      await tapVisible(
        tester,
        find.byKey(const ValueKey('record-share-details')),
      );
      await tapVisible(tester, find.byKey(const ValueKey('save-record')));
      expect(service.sharedRecords, hasLength(1));
      expect(
        service.sharedRecords.single['text'],
        'SYNTHETIC after provider retry',
      );
      expect(find.text('记录已分享'), findsOneWidget);
    },
  );

  testUiWidgets(
    'losing the grant while editing clears share choice without losing typed text',
    (tester) async {
      final service = TestPublicationService();
      final (app, goal) = await foregroundApp(tester, service);
      await edit(tester, app, goal, 'SYNTHETIC keep draft');
      await tapVisible(
        tester,
        find.byKey(const ValueKey('record-share-details')),
      );
      final sharing = await app.container.read(
        sharingControllerProvider.future,
      );
      await sharing.stop(sharing.snapshot!.grants.single.id);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('record-share-details')), findsNothing);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('record-text')))
            .controller!
            .text,
        'SYNTHETIC keep draft',
      );
      await tapVisible(tester, find.byKey(const ValueKey('save-record')));
      expect(
        service.sharedCommands.where(
          (c) => c.kind == SharingCommandKind.publish,
        ),
        isEmpty,
      );
      expect(
        (await app.database.select(app.database.dayRecords).get())
            .single
            .content,
        'SYNTHETIC keep draft',
      );
    },
  );

  testUiWidgets(
    'clearing credentials removes editor sharing eligibility and keeps personal text',
    (tester) async {
      final service = TestPublicationService();
      final credentials = _Credentials();
      final (app, goal) = await foregroundApp(
        tester,
        service,
        credentials: credentials,
      );
      await edit(
        tester,
        app,
        goal,
        'SYNTHETIC retain after credential removal',
      );
      await tapVisible(
        tester,
        find.byKey(const ValueKey('record-share-details')),
      );
      credentials.value = null;
      app.container
          .read(assistantCredentialRevisionProvider.notifier)
          .changed();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('record-share-details')), findsNothing);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('record-text')))
            .controller!
            .text,
        'SYNTHETIC retain after credential removal',
      );
      await tapVisible(tester, find.byKey(const ValueKey('save-record')));
      expect(service.sharedRecords, isEmpty);
      expect(
        (await app.database.select(app.database.dayRecords).get())
            .single
            .shareWithPartner,
        false,
      );
    },
  );

  testUiWidgets(
    'slow credential clearing pauses foreground and clears old sharing scope',
    (tester) async {
      final service = TestPublicationService();
      final credentials = _Credentials();
      final (app, _) = await foregroundApp(
        tester,
        service,
        credentials: credentials,
      );
      final oldSharing = await app.container.read(
        sharingControllerProvider.future,
      );
      await openMenu(tester, '设置');
      await tapVisible(tester, find.text('AI 设置'));
      credentials.clearGate = Completer<void>();
      final clear = find.byKey(const ValueKey('assistant-clear-credential'));
      await tester.ensureVisible(clear);
      await tester.tap(clear);
      await tester.pumpAndSettle();
      try {
        expect(app.container.read(companionForegroundProvider), isNull);
        expect(await oldSharing.store.isCurrent(), false);
      } finally {
        credentials.clearGate!.complete();
        await tester.pumpAndSettle();
      }
      expect(credentials.value, isNull);
      expect(app.container.read(companionForegroundProvider), isNull);
      expect(
        await app.database.select(app.database.sharingGrantsCache).get(),
        isEmpty,
      );
      expect(await app.repository.loadGoals(), hasLength(1));
    },
  );
  testUiWidgets(
    'record share choice defaults off, persists draft and only saves explicit details',
    (tester) async {
      final app = UiHarness();
      app.clock.instant = DateTime.utc(2026, 10, 21, 10, 1);
      final goal = await app.repository.create(
        const GoalDraft(title: 'SYNTHETIC share reading', kind: GoalKind.habit),
      );
      final service = TestSharingService()
        ..seed(
          (await app.database.select(app.database.goals).get()).single.globalId,
        );
      await app.mount(
        tester,
        assistantCredentials: _Credentials(),
        companionService: service,
        recordPhotoFiles: MemoryRecordPhotoFiles(),
      );
      await (await app.container.read(pairingControllerProvider.future))
          .refresh();
      await (await app.container.read(sharingControllerProvider.future))
          .refresh();
      await tapVisible(
        tester,
        find.byKey(ValueKey('record-$goal-${app.clock.day.key}')),
      );
      final choice = find.byKey(const ValueKey('record-share-details'));
      expect(choice, findsOneWidget);
      expect(tester.widget<CheckboxListTile>(choice).value, false);
      await tester.enterText(
        find.byKey(const ValueKey('record-text')),
        'SYNTHETIC explicit note',
      );
      await tapVisible(tester, choice);
      await goBack(tester);
      expect(
        await app.database.select(app.database.sharingPublications).get(),
        isEmpty,
      );
      await tapVisible(
        tester,
        find.byKey(ValueKey('record-$goal-${app.clock.day.key}')),
      );
      expect(tester.widget<CheckboxListTile>(choice).value, true);
      await tapVisible(tester, find.byKey(const ValueKey('save-record')));
      final intent =
          (await app.database.select(app.database.sharingPublications).get())
              .single;
      expect(intent.shareDetails, true);
      expect(intent.content, 'SYNTHETIC explicit note');
      expect(tester.takeException(), isNull);
    },
  );

  for (final scale in [1.0, 2.0, 3.0]) {
    for (final brightness in Brightness.values) {
      testUiWidgets(
        'publication editor and retry at 320px ${scale}x ${brightness.name}',
        (tester) async {
          tester.view.physicalSize = const Size(320, 568);
          tester.view.devicePixelRatio = 1;
          tester.view.padding = FakeViewPadding.zero;
          tester.view.viewPadding = FakeViewPadding.zero;
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          tester.platformDispatcher.platformBrightnessTestValue = brightness;
          addTearDown(() {
            tester.view.resetPhysicalSize();
            tester.view.resetDevicePixelRatio();
            tester.view.resetPadding();
            tester.view.resetViewPadding();
            tester.view.resetViewInsets();
            tester.platformDispatcher.clearTextScaleFactorTestValue();
            tester.platformDispatcher.clearPlatformBrightnessTestValue();
          });
          final service = TestPublicationService();
          final (app, goal) = await foregroundApp(tester, service);
          service.sharedFailure = const CompanionServiceFailure(
            'network',
            outcomeUnknown: true,
          );
          await edit(tester, app, goal, 'SYNTHETIC\n\u{1f44d}');
          final choice = find.byKey(const ValueKey('record-share-details'));
          await tapVisible(tester, choice);
          expect(tester.widget<CheckboxListTile>(choice).value, true);
          expect(choice.hitTestable(), findsOneWidget);
          await capture.shot(
            tester,
            scale,
            'publication-${brightness.name}-consent',
          );
          tester.view.viewInsets = const FakeViewPadding(bottom: 200);
          await tester.pumpAndSettle();
          final save = find.byKey(const ValueKey('save-record'));
          await tester.ensureVisible(save);
          await tester.pumpAndSettle();
          expect(save.hitTestable(), findsOneWidget);
          expect(tester.getBottomRight(save).dy, lessThanOrEqualTo(368));
          await capture.shot(
            tester,
            scale,
            'publication-${brightness.name}-keyboard',
          );
          tester.view.resetViewInsets();
          await tapVisible(tester, save);
          expect(find.textContaining('分享结果尚未确认'), findsOneWidget);
          final retry = find.byTooltip('重试分享');
          await tester.ensureVisible(retry);
          await tester.pumpAndSettle();
          expect(retry.hitTestable(), findsOneWidget);
          await capture.shot(
            tester,
            scale,
            'publication-${brightness.name}-retry',
          );
          for (final paragraph in tester.renderObjectList<RenderParagraph>(
            find.byType(RichText),
          )) {
            expect(paragraph.didExceedMaxLines, false);
          }
          service.sharedFailure = null;
          await tapVisible(tester, retry);
          expect(find.text('记录已分享'), findsOneWidget);
          expect(service.sharedRecords, hasLength(1));
          expect(tester.takeException(), isNull);
          await capture.passed(tester, scale);
        },
      );
    }
  }
}
