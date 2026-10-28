import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/assistant/assistant_providers.dart';
import 'package:habit_checkin/features/assistant/data/device_credential_store.dart';
import 'package:habit_checkin/features/companion/companion_providers.dart';
import 'package:habit_checkin/features/companion/data/companion_service.dart';
import 'package:habit_checkin/features/companion/presentation/companion_home_view.dart';
import 'package:habit_checkin/features/companion/presentation/sharing_page.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:habit_checkin/shared/presentation.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'support/chat_service.dart';
import 'support/pairing_fixtures.dart';
import 'support/record_fixtures.dart';
import 'support/sharing_fixtures.dart';
import 'support/ui_harness.dart';

class _Credentials extends DeviceCredentialStore {
  String token = 'a' * 43;

  @override
  Future<String?> read() async => token;
}

void main() {
  setUpAll(tzdata.initializeTimeZones);

  Future<UiHarness> mount(
    WidgetTester tester,
    TestCompanionService service, {
    _Credentials? credentials,
    bool foreground = false,
  }) async {
    final h = UiHarness();
    final id = await h.repository.create(
      const GoalDraft(title: 'SYNTHETIC private', kind: GoalKind.habit),
    );
    await h.repository.setCompleted(id, true, expectedDay: h.clock.day);
    if (service is TestSharingService) {
      service.seed(
        (await h.database.select(h.database.goals).get()).single.globalId,
        partner: true,
        photos: [sharingId(88)],
      );
    }
    await h.mount(
      tester,
      companionService: service,
      assistantCredentials: credentials ?? _Credentials(),
      companionForeground: foreground,
      recordPhotoFiles: MemoryRecordPhotoFiles(),
      recordPhotoPicker: StubRecordPhotoPicker(),
    );
    return h;
  }

  Finder navigationBadges() => find.descendant(
    of: find.byType(NavigationBar),
    matching: find.byType(Badge),
  );

  testUiWidgets('top-level destinations are explicit and companion is lazy', (
    tester,
  ) async {
    final service = TestCompanionService();
    final h = await mount(tester, service);
    expect(find.byType(CompanionHomeView), findsNothing);
    expect(h.container.exists(pairingControllerProvider), false);
    expect(h.container.exists(chatControllerProvider), false);
    for (final label in ['设置', '目标管理', '新建目标']) {
      expect(find.byTooltip(label), findsNothing);
    }
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).destinations,
      hasLength(5),
    );
    await tapVisible(tester, find.byKey(const ValueKey('entry-new-goal')));
    expect(find.byType(BackButton), findsOneWidget);
    await goBack(tester);
    await openMenu(tester, '设置');
    expect(find.text('系统通知'), findsOneWidget);
    expect(find.byType(BackButton), findsNothing);
    await openMenu(tester, '目标管理');
    expect(find.byType(BackButton), findsOneWidget);
    await goBack(tester);
    await goBack(tester);
    await openMenu(tester, '陪伴');
    expect(find.byType(CompanionHomeView), findsOneWidget);
    expect(find.text('尚未配对'), findsOneWidget);
    final input = find.byKey(const ValueKey('pairing-code-input'));
    await tester.enterText(input, 'ABCD');
    await tester.pumpAndSettle();
    await goBack(tester);
    expect(find.byType(CompanionHomeView), findsNothing);
    await openMenu(tester, '陪伴');
    expect(tester.widget<TextField>(input).controller!.text, 'ABCD');
    expect(service.commands, isEmpty);
    expect((await h.repository.loadGoals()).single.completions, hasLength(1));
  });

  testUiWidgets(
    'credential change closes upper routes and needs manual reopen',
    (tester) async {
      final credentials = _Credentials();
      final service = TestCompanionService()
        ..current = testPairingState(invited: true);
      final h = await mount(tester, service, credentials: credentials);
      await openMenu(tester, '陪伴');
      expect(find.text('ABCDEFGH'), findsOneWidget);
      await tapVisible(tester, find.byTooltip('设备凭证设置'));
      expect(
        find.byKey(const ValueKey('assistant-credential')),
        findsOneWidget,
      );
      credentials.token = 'b' * 43;
      service.current = testPairingState();
      h.container.read(assistantCredentialRevisionProvider.notifier).changed();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('assistant-credential')), findsNothing);
      expect(find.text('ABCDEFGH'), findsNothing);
      expect(find.textContaining('设备凭证已变化'), findsOneWidget);
      expect(find.byKey(const ValueKey('join-pairing')), findsNothing);
      await tester.pump(const Duration(seconds: 1));
      expect(find.textContaining('设备凭证已变化'), findsOneWidget);
      await tapVisible(tester, find.text('重新打开'));
      expect(find.text('尚未配对'), findsOneWidget);
      expect(find.byKey(const ValueKey('join-pairing')), findsOneWidget);
      expect(service.commands, isEmpty);
      expect((await h.repository.loadGoals()).single.completions, hasLength(1));
    },
  );

  testUiWidgets(
    'recent shares count photos; full feed and replies fetch them',
    (tester) async {
      final service = TestSharingService();
      await mount(tester, service);
      await openMenu(tester, '陪伴');
      expect(find.text('SYNTHETIC shared note'), findsOneWidget);
      expect(find.text('1 张照片'), findsOneWidget);
      expect(service.photoReads, isEmpty);
      expect(find.byType(SharingSessionBoundary), findsNothing);
      await tapVisible(tester, find.byKey(const ValueKey('open-sharing')));
      expect(service.photoReads, [sharingId(88)]);
      expect(find.byType(Image), findsOneWidget);
      await goBack(tester);
      final before = service.photoReads.length;
      await tapVisible(
        tester,
        find.byKey(ValueKey('open-replies-$testRecordId')),
      );
      expect(service.photoReads.length, before + 1);
      expect(find.byType(Image), findsOneWidget);
      expect(find.byKey(const ValueKey('sharing-reply-input')), findsOneWidget);
      expect(service.sharedCommands, isEmpty);
    },
  );

  testUiWidgets(
    'invalid sharing in tab does not dismiss an unrelated upper page',
    (tester) async {
      final service = TestSharingService();
      final h = await mount(tester, service);
      await openMenu(tester, '陪伴');
      expect(find.byType(SharingSessionBoundary), findsNothing);
      await tapVisible(tester, find.byTooltip('设备凭证设置'));
      service.sharedReadFailure = const CompanionServiceFailure(
        'pair_unavailable',
      );
      await (await h.container.read(sharingControllerProvider.future))
          .refresh();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('assistant-credential')),
        findsOneWidget,
      );
      await goBack(tester);
      expect(find.text('分享状态已变化，请刷新确认。'), findsOneWidget);
      expect(find.text('SYNTHETIC shared note'), findsNothing);
      expect(service.photoReads, isEmpty);
      expect((await h.repository.loadGoals()).single.completions, hasLength(1));
    },
  );

  testUiWidgets(
    'tab badge observes an existing unread controller without opening chat',
    (tester) async {
      final service = TestChatService()..incoming('SYNTHETIC unread');
      final h = await mount(tester, service, foreground: true);
      final foreground = h.container.read(companionForegroundProvider)!;
      await foreground.idle;
      await tester.pumpAndSettle();
      expect(find.byType(CompanionHomeView), findsNothing);
      expect(h.container.exists(chatControllerProvider), true);
      expect((await h.container.read(chatControllerProvider.future)).unread, 1);
      expect(navigationBadges(), findsWidgets);
      expect(
        tester
            .widgetList<Badge>(navigationBadges())
            .every((b) => b.isLabelVisible),
        true,
      );
      expect(
        find.descendant(of: navigationBadges(), matching: find.text('1')),
        findsWidgets,
      );
      expect(service.chatCommands, isEmpty);
    },
  );

  testUiWidgets(
    'tab badge does not create chat while foreground has not loaded it',
    (tester) async {
      final gate = Completer<void>();
      final service = TestChatService()..beforeRead = (_, _) => gate.future;
      final h = await mount(tester, service, foreground: true);
      try {
        expect(h.container.exists(pairingControllerProvider), true);
        expect(h.container.exists(chatControllerProvider), false);
        expect(navigationBadges(), findsNothing);
        expect(service.chatReads, 0);
        await tester.pump(const Duration(seconds: 1));
        expect(h.container.exists(chatControllerProvider), false);
        expect(service.chatReads, 0);
      } finally {
        gate.complete();
        await h.container.read(companionForegroundProvider)!.idle;
        await tester.pumpAndSettle();
      }
    },
  );

  for (final foreground in [false, true]) {
    testUiWidgets(
      'chat notifications during another build apply after the frame (foreground=$foreground)',
      (tester) async {
        final service = TestChatService();
        final h = await mount(tester, service, foreground: foreground);
        await openMenu(tester, '陪伴');
        await tapVisible(tester, find.byKey(const ValueKey('open-chat')));
        final chat = await h.container.read(chatControllerProvider.future);
        var invoked = false;
        final entry = OverlayEntry(
          builder: (_) {
            if (!invoked) {
              invoked = true;
              unawaited(chat.editText('SYNTHETIC during build'));
            }
            return const SizedBox.shrink();
          },
        );
        Overlay.of(tester.element(find.byKey(const ValueKey('chat-input'))))
            .insert(entry);
        try {
          await tester.pump();
          expect(tester.takeException(), isNull);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(
            tester
                .widget<TextField>(find.byKey(const ValueKey('chat-input')))
                .controller!
                .text,
            'SYNTHETIC during build',
          );
          expect(service.chatCommands, isEmpty);
        } finally {
          entry.remove();
          entry.dispose();
        }
      },
    );
  }

  testUiWidgets('loading appears after 350ms without moving adjacent content', (
    tester,
  ) async {
    const following = ValueKey('following-content');
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              StatusPanel(message: 'SYNTHETIC loading', loading: true),
              SizedBox(key: following, height: 20),
            ],
          ),
        ),
      ),
    );
    final opacity = find.descendant(
      of: find.byType(DelayedReveal),
      matching: find.byType(AnimatedOpacity),
    );
    final before = tester.getRect(find.byKey(following));
    expect(tester.widget<AnimatedOpacity>(opacity).opacity, 0);
    await tester.pump(const Duration(milliseconds: 349));
    expect(tester.widget<AnimatedOpacity>(opacity).opacity, 0);
    expect(tester.getRect(find.byKey(following)), before);
    await tester.pump(const Duration(milliseconds: 1));
    expect(tester.widget<AnimatedOpacity>(opacity).opacity, 1);
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.getRect(find.byKey(following)), before);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });
}
