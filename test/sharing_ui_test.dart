import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/assistant/assistant_providers.dart';
import 'package:habit_checkin/features/assistant/data/device_credential_store.dart';
import 'package:habit_checkin/features/companion/companion_providers.dart';
import 'package:habit_checkin/features/companion/data/companion_service.dart';
import 'package:habit_checkin/features/companion/presentation/sharing_controller.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'support/layout_capture.dart';
import 'support/pairing_fixtures.dart';
import 'support/sharing_fixtures.dart';
import 'support/ui_harness.dart' hide tapVisible;

class _Credentials extends DeviceCredentialStore {
  @override
  Future<String?> read() async => 'a' * 43;
}

Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await reveal(tester, finder);
  await tester.pumpAndSettle();
  expect(finder.hitTestable(), findsOneWidget);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> reveal(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    final scrollable = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byType(ListView).last,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    scrollable.position.jumpTo(scrollable.position.minScrollExtent);
    await tester.pumpAndSettle();
    for (var i = 0; i < 100 && finder.evaluate().isEmpty; i++) {
      scrollable.position.jumpTo(
        (scrollable.position.pixels + 120).clamp(
          scrollable.position.minScrollExtent,
          scrollable.position.maxScrollExtent,
        ),
      );
      await tester.pumpAndSettle();
    }
  }
  expect(finder, findsOneWidget);
  await tester.ensureVisible(finder);
}

void main() {
  final capture = LayoutCapture();
  setUpAll(() async {
    tzdata.initializeTimeZones();
    await capture.prepare();
  });
  final input = find.byKey(const ValueKey('sharing-reply-input'));
  final send = find.byKey(const ValueKey('send-sharing-reply'));
  Future<UiHarness> mount(
    WidgetTester tester,
    TestSharingService service, {
    bool seed = true,
    List<String> photos = const [],
  }) async {
    final harness = UiHarness();
    await harness.repository.create(
      const GoalDraft(title: 'SYNTHETIC personal', kind: GoalKind.habit),
    );
    if (seed) {
      service.seed(
        (await harness.database.select(harness.database.goals).get())
            .single
            .globalId,
        photos: photos,
      );
    }
    await harness.mount(
      tester,
      assistantCredentials: _Credentials(),
      companionService: service,
      wrapApp: capture.wrap,
    );
    return harness;
  }

  Future<void> open(WidgetTester tester) async {
    await openMenu(tester, '陪伴');
    await tapVisible(tester, find.byKey(const ValueKey('open-sharing')));
  }

  Future<void> replies(WidgetTester tester) =>
      tapVisible(tester, find.byKey(ValueKey('open-replies-$testRecordId')));
  Future<SharingController> controller(UiHarness harness) =>
      harness.container.read(sharingControllerProvider.future);

  testUiWidgets(
    'reply input boundaries reject empty and 301, send exactly 300 unchanged',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(top: 20);
      tester.view.viewPadding = const FakeViewPadding(top: 20);
      tester.view.viewInsets = const FakeViewPadding();
      tester.platformDispatcher.textScaleFactorTestValue = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.view.resetPadding();
        tester.view.resetViewPadding();
        tester.view.resetViewInsets();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      });
      final service = TestSharingService();
      final harness = await mount(tester, service);
      await open(tester);
      await replies(tester);
      final state = await controller(harness);
      final maximum = '${'\u{1f44d}\u{1f3fd}' * 298}\nA';
      expect(maximum.characters.length, 300);
      expect(maximum.length, greaterThan(300));
      for (final invalid in ['', ' \n\t ', '${maximum}B']) {
        await reveal(tester, input);
        await tester.enterText(input, invalid);
        await tester.pumpAndSettle();
        await tapVisible(tester, send);
        final message = invalid.trim().isEmpty ? '请先写下回复。' : '回复最多 300 字。';
        expect(state.error, message);
        await reveal(tester, find.text(message));
        expect(find.text(message), findsOneWidget);
        expect(service.sharedCommands, isEmpty);
        expect(service.sharedReplies, isEmpty);
        expect(state.pending, isEmpty);
        await reveal(tester, input);
        expect(tester.widget<TextField>(input).controller!.text, invalid);
        expect((await state.store.draft(testRecordId))?.content ?? '', invalid);
      }
      await reveal(tester, input);
      await capture.shot(tester, 1, 'reply-boundary-301');
      await goBack(tester);
      await replies(tester);
      expect(tester.widget<TextField>(input).controller!.text, '${maximum}B');
      await reveal(tester, input);
      await tester.enterText(input, maximum);
      await tester.pumpAndSettle();
      await capture.shot(tester, 1, 'reply-boundary-300');
      await tapVisible(tester, send);
      expect(service.sharedCommands, hasLength(1));
      expect(service.sharedCommands.single.text, maximum);
      expect(service.sharedReplies, hasLength(1));
      expect(service.sharedReplies.single['text'], maximum);
      expect(state.pending, isEmpty);
      await reveal(tester, input);
      expect(tester.widget<TextField>(input).controller!.text, isEmpty);
      expect((await state.store.draft(testRecordId))?.content ?? '', isEmpty);
      await reveal(tester, find.text(maximum));
      await capture.shot(tester, 1, 'reply-boundary-sent');
      await goBack(tester);
      await replies(tester);
      expect(find.text(maximum), findsOneWidget);
      expect(service.sharedCommands, hasLength(1));
      expect(
        (await harness.repository.loadGoals()).single.titleOn(
          harness.clock.day,
        ),
        'SYNTHETIC personal',
      );
      expect(tester.takeException(), isNull);
      await capture.passed(tester, 1);
    },
  );

  testUiWidgets(
    'goal sharing is private by default and needs explicit confirmation',
    (tester) async {
      final service = TestSharingService();
      final harness = await mount(tester, service, seed: false);
      await open(tester);
      await tapVisible(tester, find.text('我的分享'));
      final toggle = find.byKey(const ValueKey('share-goal-1'));
      expect(tester.widget<SwitchListTile>(toggle).value, false);
      await tapVisible(tester, toggle);
      await tapVisible(tester, find.text('取消'));
      expect(service.sharedCommands, isEmpty);
      await tapVisible(tester, toggle);
      await tapVisible(tester, find.byKey(const ValueKey('confirm-sharing')));
      expect(tester.widget<SwitchListTile>(toggle).value, true);
      expect(service.sharedCommands, hasLength(1));
      expect((await controller(harness)).snapshot!.records, isEmpty);
      expect(service.sharedRecords, isEmpty);
    },
  );

  testUiWidgets(
    'reply draft survives back, tab changes, background and reopening',
    (tester) async {
      final service = TestSharingService();
      final harness = await mount(tester, service);
      await open(tester);
      await replies(tester);
      await tester.enterText(input, 'SYNTHETIC\n\u{1f44d}');
      await tester.pumpAndSettle();
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pumpAndSettle();
      await goBack(tester);
      await tapVisible(tester, find.text('我的分享'));
      await tapVisible(tester, find.text('动态'));
      await replies(tester);
      expect(
        tester.widget<TextField>(input).controller!.text,
        'SYNTHETIC\n\u{1f44d}',
      );
      final state = await controller(harness);
      expect(
        (await state.store.draft(testRecordId))!.content,
        'SYNTHETIC\n\u{1f44d}',
      );
      expect(service.sharedCommands, isEmpty);
      await tapVisible(tester, send);
      expect(tester.widget<TextField>(input).controller!.text, isEmpty);
      expect(find.text('SYNTHETIC\n\u{1f44d}'), findsOneWidget);
    },
  );

  testUiWidgets(
    'five reply taps with delayed response retain subsequent typing',
    (tester) async {
      final service = TestSharingService()..sharedGate = Completer<void>();
      await mount(tester, service);
      await open(tester);
      await replies(tester);
      await tester.enterText(input, 'SYNTHETIC first');
      await tester.pumpAndSettle();
      await tester.ensureVisible(send);
      for (var i = 0; i < 5; i++) {
        await tester.tap(send);
      }
      for (var i = 0; i < 100 && service.sharedCommands.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(service.sharedCommands, hasLength(1));
      await tester.enterText(input, 'SYNTHETIC next');
      service.sharedGate!.complete();
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(input).controller!.text,
        'SYNTHETIC next',
      );
      expect(service.sharedReplies, hasLength(1));
    },
  );

  testUiWidgets(
    'offline outcome is visible and retry keeps the original operation',
    (tester) async {
      final service = TestSharingService()
        ..afterCommitFailure = const CompanionServiceFailure(
          'timeout',
          outcomeUnknown: true,
        );
      final harness = await mount(tester, service);
      await open(tester);
      await replies(tester);
      await tester.enterText(input, 'SYNTHETIC retry');
      await tester.pumpAndSettle();
      await tapVisible(tester, send);
      final state = await controller(harness);
      final pending = state.pending.single;
      expect(tester.widget<IconButton>(send).onPressed, isNull);
      service.afterCommitFailure = null;
      await tapVisible(
        tester,
        find.byKey(ValueKey('retry-sharing-${pending.command.operationId}')),
      );
      expect(
        service.sharedCommands.last.toJson(),
        service.sharedCommands.first.toJson(),
      );
      expect(service.sharedReplies, hasLength(1));
      expect(state.pending, isEmpty);
    },
  );

  testUiWidgets(
    'own reply and record deletion require confirmation and preserve personal goal',
    (tester) async {
      final service = TestSharingService();
      final harness = await mount(tester, service);
      await open(tester);
      await replies(tester);
      await tester.enterText(input, 'SYNTHETIC delete');
      await tester.pumpAndSettle();
      await tapVisible(tester, send);
      await tapVisible(tester, find.byTooltip('删除回复'));
      await tapVisible(tester, find.text('取消'));
      expect(service.sharedReplies, hasLength(1));
      await tapVisible(tester, find.byTooltip('删除回复'));
      await tapVisible(tester, find.byKey(const ValueKey('confirm-sharing')));
      expect(service.sharedReplies, isEmpty);
      await tapVisible(tester, find.byTooltip('移除分享'));
      await tapVisible(tester, find.byKey(const ValueKey('confirm-sharing')));
      expect(find.text('这条分享已不可访问。'), findsOneWidget);
      expect(await harness.repository.loadGoals(), hasLength(1));
    },
  );

  testUiWidgets(
    'photo replacement fetches new ID instead of reusing old thumbnail',
    (tester) async {
      final service = TestSharingService();
      final harness = await mount(tester, service, photos: [sharingId(20)]);
      await open(tester);
      expect(service.photoReads, [sharingId(20)]);
      service.sharedRecords[0] = {
        ...service.sharedRecords.single,
        'revision': 2,
        'photo_ids': [sharingId(21)],
      };
      service.revision++;
      await (await controller(harness)).refresh();
      await tester.pumpAndSettle();
      expect(service.photoReads, [sharingId(20), sharingId(21)]);
      expect(
        find.byKey(ValueKey('shared-photo-${sharingId(20)}')),
        findsNothing,
      );
      expect(
        find.byKey(ValueKey('shared-photo-${sharingId(21)}')),
        findsOneWidget,
      );
    },
  );

  testUiWidgets('withdrawn record hides an already-open full photo', (
    tester,
  ) async {
    final service = TestSharingService();
    final harness = await mount(tester, service, photos: [sharingId(20)]);
    await open(tester);
    await tapVisible(
      tester,
      find.byKey(ValueKey('shared-photo-${sharingId(20)}')),
    );
    expect(find.byType(Image), findsOneWidget);
    service.sharedRecords.clear();
    service.revision++;
    await (await controller(harness)).refresh();
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsNothing);
  });

  testUiWidgets(
    'credential replacement closes full photo and confirmation overlays',
    (tester) async {
      final service = TestSharingService();
      final harness = await mount(tester, service, photos: [sharingId(20)]);
      await open(tester);
      await tapVisible(
        tester,
        find.byKey(ValueKey('shared-photo-${sharingId(20)}')),
      );
      harness.container
          .read(assistantCredentialRevisionProvider.notifier)
          .state++;
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsNothing);
      expect(find.text('分享照片'), findsNothing);
      expect(
        find.byWidgetPredicate((widget) => widget is AlertDialog),
        findsNothing,
      );
      expect(service.sharedCommands, isEmpty);
    },
  );

  testUiWidgets(
    'credential replacement closes a pending sharing confirmation',
    (tester) async {
      final service = TestSharingService();
      final harness = await mount(tester, service);
      await open(tester);
      await tapVisible(tester, find.text('我的分享'));
      await tapVisible(tester, find.byKey(const ValueKey('share-goal-1')));
      expect(
        find.byWidgetPredicate((widget) => widget is AlertDialog),
        findsOneWidget,
      );
      harness.container
          .read(assistantCredentialRevisionProvider.notifier)
          .state++;
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate((widget) => widget is AlertDialog),
        findsNothing,
      );
      expect(service.sharedCommands, isEmpty);
    },
  );

  testUiWidgets('photo download revocation clears the sharing session', (
    tester,
  ) async {
    final service = TestSharingService()
      ..photoFailure = const CompanionServiceFailure('unauthorized');
    final harness = await mount(tester, service, photos: [sharingId(20)]);
    await open(tester);
    expect((await controller(harness)).invalidated, true);
    expect(find.text('SYNTHETIC shared note'), findsNothing);
    expect(find.byType(Image), findsNothing);
  });

  testUiWidgets('foregrounding the reply page fetches newly received replies', (
    tester,
  ) async {
    final service = TestSharingService();
    await mount(tester, service);
    await open(tester);
    await replies(tester);
    service.sharedReplies.add({
      'id': sharingId(99),
      'record_id': testRecordId,
      'author_id': testPartnerId,
      'sequence': 1,
      'text': 'SYNTHETIC incoming',
      'created_at': sharingInstant,
    });
    service.revision++;
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pumpAndSettle();
    expect(find.text('SYNTHETIC incoming'), findsOneWidget);
  });

  for (final scale in [1.0, 2.0, 3.0]) {
    for (final brightness in Brightness.values) {
      testUiWidgets(
        'sharing and reply controls at 320px ${scale}x ${brightness.name}',
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
          final service = TestSharingService();
          final harness = await mount(tester, service);
          await open(tester);
          for (final label in ['动态', '我的分享']) {
            final paragraph = tester.renderObject<RenderParagraph>(
              find.text(label),
            );
            final natural = TextPainter(
              text: paragraph.text,
              textDirection: paragraph.textDirection,
              textScaler: paragraph.textScaler,
            )..layout();
            expect(
              paragraph.size.width,
              greaterThanOrEqualTo(natural.width - .1),
              reason: '$label width',
            );
            expect(
              paragraph.size.height,
              greaterThanOrEqualTo(natural.height - .1),
              reason: '$label height',
            );
            natural.dispose();
          }
          await capture.shot(tester, scale, 'sharing-${brightness.name}-feed');
          await tapVisible(tester, find.text('我的分享'));
          await capture.shot(tester, scale, 'sharing-${brightness.name}-goals');
          await tapVisible(tester, find.text('动态'));
          await replies(tester);
          await reveal(tester, input);
          await tester.enterText(input, 'SYNTHETIC\n${'\u{1f44d}' * 301}');
          await tester.pumpAndSettle();
          await tapVisible(tester, send);
          expect(service.sharedCommands, isEmpty);
          expect((await controller(harness)).error, '回复最多 300 字。');
          await tester.enterText(input, 'SYNTHETIC reply');
          await tester.pumpAndSettle();
          tester.view.viewInsets = const FakeViewPadding(bottom: 200);
          await tester.pumpAndSettle();
          await reveal(tester, send);
          await tester.pumpAndSettle();
          expect(send.hitTestable(), findsOneWidget);
          expect(tester.getBottomRight(send).dy, lessThanOrEqualTo(368));
          await capture.shot(
            tester,
            scale,
            'sharing-${brightness.name}-keyboard',
          );
          tester.view.resetViewInsets();
          await tapVisible(tester, send);
          await tapVisible(tester, find.byTooltip('删除回复'));
          await tester.ensureVisible(
            find.byKey(const ValueKey('confirm-sharing')),
          );
          await capture.shot(
            tester,
            scale,
            'sharing-${brightness.name}-delete',
          );
          for (final paragraph in tester.renderObjectList<RenderParagraph>(
            find.byType(RichText),
          )) {
            expect(paragraph.didExceedMaxLines, false);
          }
          await tapVisible(tester, find.text('取消'));
          expect(tester.takeException(), isNull);
          await capture.passed(tester, scale);
        },
      );
    }
  }
}
