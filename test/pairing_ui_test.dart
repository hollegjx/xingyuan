import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/sync/identity_store.dart';
import 'package:habit_checkin/data/sync/sync_identity.dart';
import 'package:habit_checkin/features/assistant/assistant_providers.dart';
import 'package:habit_checkin/features/assistant/data/device_credential_store.dart';
import 'package:habit_checkin/features/assistant/presentation/assistant_settings_page.dart';
import 'package:habit_checkin/features/companion/companion_providers.dart';
import 'package:habit_checkin/features/companion/data/companion_service.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:xingyuan_core/xingyuan_core.dart';

import 'support/layout_capture.dart';
import 'support/chat_service.dart';
import 'support/pairing_fixtures.dart';
import 'support/ui_harness.dart' hide tapVisible;

Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  // Flush the preceding input/layout update before scrolling to another row.
  await tester.pumpAndSettle();
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  expect(finder.hitTestable(), findsOneWidget);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

class _Credentials extends DeviceCredentialStore {
  String? token = 'a' * 43;
  @override
  Future<String?> read() async => token;
}

void main() {
  final capture = LayoutCapture();
  setUpAll(() async {
    tzdata.initializeTimeZones();
    await capture.prepare();
  });
  Future<UiHarness> mount(
    WidgetTester tester,
    TestCompanionService service, {
    _Credentials? credentials,
  }) async {
    final harness = UiHarness();
    await harness.mount(
      tester,
      assistantCredentials: credentials ?? _Credentials(),
      companionService: service,
      wrapApp: capture.wrap,
    );
    return harness;
  }

  Future<void> open(WidgetTester tester) => openMenu(tester, '陪伴');
  Future<void> confirm(WidgetTester tester) =>
      tapVisible(tester, find.byKey(const ValueKey('confirm-pairing')));
  final input = find.byKey(const ValueKey('pairing-code-input'));

  testUiWidgets(
    'pairing input boundaries reject empty and 65, preserve exactly 64',
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
      final service = TestCompanionService();
      final harness = await mount(tester, service);
      await open(tester);
      final controller = await harness.container.read(
        pairingControllerProvider.future,
      );
      final maximum = '${'\u{1f44d}\u{1f3fd}' * 62}\nA';
      expect(maximum.characters.length, 64);
      expect(maximum.length, greaterThan(64));
      for (final invalid in ['', ' \n\t ', '${maximum}B']) {
        await tester.ensureVisible(input);
        await tester.enterText(input, invalid);
        await tester.pumpAndSettle();
        await tapVisible(tester, find.byKey(const ValueKey('join-pairing')));
        expect(find.byKey(const ValueKey('confirm-pairing')), findsOneWidget);
        expect(service.commands, isEmpty);
        await confirm(tester);
        expect(find.text('邀请码不正确，请检查后重试。'), findsOneWidget);
        expect(service.commands, isEmpty);
        expect(controller.snapshot!.command, isNull);
        expect(tester.widget<TextField>(input).controller!.text, invalid);
        expect((await controller.store.snapshot()).row.draftCode, invalid);
      }
      await tester.ensureVisible(input);
      await capture.shot(tester, 1, 'pairing-boundary-65');
      await goBack(tester);
      await open(tester);
      expect(tester.widget<TextField>(input).controller!.text, '${maximum}B');

      // The length boundary permits submission, not a valid invitation claim.
      service.failure = const CompanionServiceFailure('invite_invalid');
      await tester.ensureVisible(input);
      await tester.enterText(input, maximum);
      await tester.pumpAndSettle();
      await capture.shot(tester, 1, 'pairing-boundary-64');
      await tapVisible(tester, find.byKey(const ValueKey('join-pairing')));
      await confirm(tester);
      expect(service.commands, hasLength(1));
      expect(service.commands.single.code, maximum);
      expect(find.text('邀请码不正确，请检查后重试。'), findsOneWidget);
      expect(find.text('已配对'), findsNothing);
      expect(tester.widget<TextField>(input).controller!.text, maximum);
      expect((await controller.store.snapshot()).row.draftCode, maximum);
      service.failure = null;
      await tester.ensureVisible(input);
      await tester.enterText(input, 'ABCDEFGH');
      await tester.pumpAndSettle();
      await tapVisible(tester, find.byKey(const ValueKey('join-pairing')));
      await confirm(tester);
      expect(service.commands, hasLength(2));
      expect(service.commands.last.code, 'ABCDEFGH');
      expect(
        service.commands.last.operationId,
        isNot(service.commands.first.operationId),
      );
      expect(find.text('已配对'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await capture.passed(tester, 1);
    },
  );

  for (final child in ['open-chat', 'open-sharing']) {
    for (final offline in [false, true]) {
      testUiWidgets(
        'return from $child drops revoked pairing before ${offline ? 'failed' : 'slow'} refresh',
        (tester) async {
          final service = TestChatService();
          final harness = await mount(tester, service);
          final id = await harness.repository.create(
            const GoalDraft(title: 'TEST private', kind: GoalKind.habit),
          );
          await harness.repository.setCompleted(
            id,
            true,
            expectedDay: harness.clock.day,
          );
          await open(tester);
          expect(find.text('已配对'), findsOneWidget);
          await tapVisible(tester, find.byKey(ValueKey(child)));
          service.current = testPairingState();
          if (child == 'open-chat') {
            service.chatReadFailure = const CompanionServiceFailure(
              'pair_gone',
            );
            await (await harness.container.read(chatControllerProvider.future))
                .refresh();
          } else {
            service.sharedReadFailure = const CompanionServiceFailure(
              'pair_gone',
            );
            await (await harness.container.read(
              sharingControllerProvider.future,
            )).refresh();
          }
          await tester.pumpAndSettle();
          final reads = service.reads;
          if (offline) {
            service.readFailure = const CompanionServiceFailure('network');
          } else {
            service.readGate = Completer<void>();
          }
          await goBack(tester);
          expect(find.text('已配对'), findsNothing);
          expect(find.byKey(const ValueKey('open-chat')), findsNothing);
          expect(find.byKey(const ValueKey('open-sharing')), findsNothing);
          expect(service.reads, reads + 1);
          if (!offline) {
            expect(find.text('正在确认配对状态…'), findsOneWidget);
            expect(find.text('尚未配对'), findsNothing);
            service.readGate!.complete();
            await tester.pumpAndSettle();
            expect(find.text('尚未配对'), findsOneWidget);
          } else {
            expect(find.text('配对状态尚未确认。'), findsOneWidget);
          }
          expect((await harness.repository.loadGoals()).single.id, id);
          expect(
            (await harness.database.select(harness.database.checkIns).get())
                .single
                .completed,
            true,
          );
          expect(service.commands, isEmpty);
          expect(service.chatCommands, isEmpty);
          expect(service.sharedCommands, isEmpty);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final invalid in ['', 'bad', 'a' * 42, '${'a' * 42}!']) {
    testUiWidgets(
      'invalid credential keeps nested settings and pairing draft (${invalid.length} chars)',
      (tester) async {
        final service = TestCompanionService();
        final credentials = _Credentials();
        final harness = await mount(tester, service, credentials: credentials);
        await open(tester);
        await tester.enterText(input, 'ABCD2345');
        await tester.pumpAndSettle();
        final controller = await harness.container.read(
          pairingControllerProvider.future,
        );
        final revision = harness.container.read(
          assistantCredentialRevisionProvider,
        );
        await tapVisible(tester, find.byTooltip('设备凭证设置'));
        await tester.enterText(
          find.byKey(const ValueKey('assistant-credential')),
          invalid,
        );
        await tapVisible(
          tester,
          find.byKey(const ValueKey('assistant-save-credential')),
        );
        expect(find.byType(AssistantSettingsPage), findsOneWidget);
        expect(find.textContaining('原有凭证未更改'), findsOneWidget);
        expect(
          harness.container.read(assistantCredentialRevisionProvider),
          revision,
        );
        expect(credentials.token, 'a' * 43);
        await goBack(tester);
        expect(tester.widget<TextField>(input).controller!.text, 'ABCD2345');
        expect((await controller.store.snapshot()).row.draftCode, 'ABCD2345');
        expect(service.commands, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testUiWidgets(
    'initial slow refresh never claims an unconfirmed unpaired state',
    (tester) async {
      final service = TestCompanionService()..readGate = Completer<void>();
      await mount(tester, service);
      await open(tester);
      expect(find.text('尚未配对'), findsNothing);
      expect(find.text('正在确认配对状态…'), findsOneWidget);
      service.readGate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('尚未配对'), findsOneWidget);
    },
  );

  testUiWidgets(
    'input survives back, tabs, background and reopening without sending',
    (tester) async {
      final service = TestCompanionService();
      final harness = await mount(tester, service);
      expect(service.reads, 0);
      await open(tester);
      await tester.enterText(input, 'AB😀\nCD');
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
      await tapVisible(tester, find.text('回顾').last);
      await tapVisible(tester, find.text('今天').last);
      await open(tester);
      expect(tester.widget<TextField>(input).controller!.text, 'AB😀\nCD');
      final controller = await harness.container.read(
        pairingControllerProvider.future,
      );
      expect((await controller.store.snapshot()).row.draftCode, 'AB😀\nCD');
      expect(service.commands, isEmpty);
    },
  );

  testUiWidgets(
    'five create taps make one invite, cancellation requires confirmation',
    (tester) async {
      final service = TestCompanionService()..gate = Completer<void>();
      await mount(tester, service);
      await open(tester);
      final create = find.byKey(const ValueKey('create-pairing-invite'));
      for (var i = 0; i < 5; i++) {
        await tester.tap(create);
      }
      await tester.pumpAndSettle();
      expect(service.commands, hasLength(1));
      expect(find.text('正在提交配对操作…'), findsOneWidget);
      service.gate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('ABCDEFGH'), findsOneWidget);
      final cancel = find.byKey(const ValueKey('cancel-pairing-invite'));
      await tapVisible(tester, cancel);
      await tapVisible(tester, find.text('取消').last);
      expect(service.commands, hasLength(1));
      await tapVisible(tester, cancel);
      await confirm(tester);
      expect(service.commands.last.kind, PairingCommandKind.cancelInvite);
      expect(find.byKey(const ValueKey('pairing-invite-code')), findsNothing);
    },
  );

  testUiWidgets(
    'join timeout retains draft and explicit retry uses same operation',
    (tester) async {
      final service = TestCompanionService()
        ..failure = const CompanionServiceFailure(
          'timeout',
          outcomeUnknown: true,
        );
      await mount(tester, service);
      await open(tester);
      await tester.enterText(input, 'ABCDEFGH');
      await tapVisible(tester, find.byKey(const ValueKey('join-pairing')));
      await confirm(tester);
      expect(find.textContaining('结果尚未确认'), findsOneWidget);
      await goBack(tester);
      await open(tester);
      expect(service.commands, hasLength(1));
      expect(tester.widget<TextField>(input).controller!.text, 'ABCDEFGH');
      service.failure = null;
      await tapVisible(tester, find.byKey(const ValueKey('retry-pairing')));
      expect(service.commands, hasLength(2));
      expect(service.commands.first.toJson(), service.commands.last.toJson());
      expect(find.text('已配对'), findsOneWidget);
    },
  );

  for (final rejection in const {
    'invite_invalid': '邀请码不正确，请检查后重试。',
    'invite_expired': '邀请码已过期，请对方重新生成。',
    'invite_used': '邀请码已被使用。',
    'already_paired': '你已经有一个配对，请刷新查看。',
    'invite_rate_limited': '输错次数过多，请稍后再试。',
  }.entries) {
    testUiWidgets(
      'pairing rejection ${rejection.key} preserves input and personal data',
      (tester) async {
        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1;
        tester.view.padding = const FakeViewPadding(top: 20);
        tester.view.viewPadding = const FakeViewPadding(top: 20);
        tester.view.viewInsets = const FakeViewPadding();
        tester.platformDispatcher.textScaleFactorTestValue = 3;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPadding);
        addTearDown(tester.view.resetViewPadding);
        addTearDown(tester.view.resetViewInsets);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final limited = rejection.key == 'invite_rate_limited';
        final service = TestCompanionService()
          ..failure = CompanionServiceFailure(
            rejection.key,
            retryAfter: limited ? 600 : null,
          );
        final harness = await mount(tester, service);
        final id = await harness.repository.create(
          const GoalDraft(title: 'TEST private', kind: GoalKind.habit),
        );
        await harness.repository.setCompleted(
          id,
          true,
          expectedDay: harness.clock.day,
        );
        await open(tester);
        await tester.ensureVisible(input);
        await tester.enterText(input, 'ABCDEFGH');
        await tester.pumpAndSettle();
        await tapVisible(tester, find.byKey(const ValueKey('join-pairing')));
        await confirm(tester);
        final controller = await harness.container.read(
          pairingControllerProvider.future,
        );
        expect(controller.snapshot!.command!.row.status, 'failed');
        expect(controller.snapshot!.command!.row.errorCode, rejection.key);
        expect(controller.snapshot!.command!.row.retryAfter != null, limited);
        expect(controller.hasUncertainOperation, false);
        expect(find.byKey(const ValueKey('retry-pairing')), findsNothing);
        final message = find.text(rejection.value);
        expect(message, findsOneWidget);
        await tester.ensureVisible(message);
        await capture.shot(tester, 3, 'pairing-rejected-${rejection.key}');
        expect(
          tester.renderObject<RenderParagraph>(message).didExceedMaxLines,
          false,
        );
        await goBack(tester);
        await open(tester);
        expect(tester.widget<TextField>(input).controller!.text, 'ABCDEFGH');
        expect(service.commands, hasLength(1));
        if (rejection.key == 'already_paired') {
          service.current = testPairingState(paired: true);
          await tapVisible(tester, find.byTooltip('刷新配对'));
          expect(find.text('已配对'), findsOneWidget);
          expect(find.byKey(const ValueKey('join-pairing')), findsNothing);
          expect(service.commands, hasLength(1));
        } else if (!limited) {
          service.failure = null;
          await tester.ensureVisible(input);
          await tester.enterText(input, 'NEW45678');
          await tester.pumpAndSettle();
          await tapVisible(tester, find.byKey(const ValueKey('join-pairing')));
          await confirm(tester);
          expect(find.text('已配对'), findsOneWidget);
          expect(service.commands, hasLength(2));
          expect(
            service.commands.last.operationId,
            isNot(service.commands.first.operationId),
          );
          expect(service.commands.last.code, 'NEW45678');
        }
        expect((await harness.repository.loadGoals()).single.id, id);
        expect(
          (await harness.database.select(harness.database.checkIns).get())
              .single
              .completed,
          true,
        );
        expect(tester.takeException(), isNull);
        await capture.passed(tester, 3);
      },
    );
  }

  testUiWidgets(
    'refresh error remains visible alongside a different stored rejection',
    (tester) async {
      final service = TestCompanionService()
        ..failure = const CompanionServiceFailure('invite_expired');
      final harness = await mount(tester, service);
      await open(tester);
      await tester.enterText(input, 'ABCDEFGH');
      await tester.pumpAndSettle();
      await tapVisible(tester, find.byKey(const ValueKey('join-pairing')));
      await confirm(tester);
      service.readFailure = const CompanionServiceFailure('network');
      await tapVisible(tester, find.byTooltip('刷新配对'));
      expect(find.text('网络连接失败，请重试。'), findsOneWidget);
      expect(find.text('邀请码已过期，请对方重新生成。'), findsOneWidget);
      final controller = await harness.container.read(
        pairingControllerProvider.future,
      );
      expect(controller.snapshot!.command!.row.errorCode, 'invite_expired');
      expect(tester.widget<TextField>(input).controller!.text, 'ABCDEFGH');
      expect(service.commands, hasLength(1));
      service.readFailure = null;
      await tapVisible(tester, find.byTooltip('刷新配对'));
      expect(find.text('网络连接失败，请重试。'), findsNothing);
      expect(find.text('邀请码已过期，请对方重新生成。'), findsOneWidget);
      expect(service.commands, hasLength(1));
    },
  );

  testUiWidgets(
    'leave cancellation keeps pair and confirmed leave keeps personal data',
    (tester) async {
      final service = TestCompanionService()
        ..current = testPairingState(paired: true);
      final harness = await mount(tester, service);
      final id = await harness.repository.create(
        const GoalDraft(title: 'TEST private', kind: GoalKind.habit),
      );
      await open(tester);
      final leave = find.byKey(const ValueKey('leave-pairing'));
      await tapVisible(tester, leave);
      await tapVisible(tester, find.text('取消').last);
      expect(service.commands, isEmpty);
      await tapVisible(tester, leave);
      await confirm(tester);
      expect(service.commands.single.groupId, testGroupId);
      expect(find.text('尚未配对'), findsOneWidget);
      expect((await harness.repository.loadGoals()).single.id, id);
    },
  );

  testUiWidgets(
    'credential change closes confirmation and hides old invite permanently',
    (tester) async {
      final service = TestCompanionService()
        ..current = testPairingState(invited: true);
      final credentials = _Credentials();
      final harness = await mount(tester, service, credentials: credentials);
      await open(tester);
      await tapVisible(
        tester,
        find.byKey(const ValueKey('cancel-pairing-invite')),
      );
      credentials.token = 'b' * 43;
      harness.container
          .read(assistantCredentialRevisionProvider.notifier)
          .changed();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('ABCDEFGH'), findsNothing);
      expect(find.textContaining('设备凭证已变化'), findsOneWidget);
      credentials.token = 'a' * 43;
      harness.container
          .read(assistantCredentialRevisionProvider.notifier)
          .changed();
      await tester.pumpAndSettle();
      expect(find.text('ABCDEFGH'), findsNothing);
      expect(service.commands, isEmpty);
    },
  );

  testUiWidgets(
    'identity change closes confirmation and old route never revives',
    (tester) async {
      final service = TestCompanionService()
        ..current = testPairingState(paired: true);
      final harness = await mount(tester, service);
      await open(tester);
      await tapVisible(tester, find.byKey(const ValueKey('leave-pairing')));
      final identity = IdentityStore(harness.database);
      await identity.finish(
        await identity.begin(SyncIdentity.account(testPartnerId)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('已配对'), findsNothing);
      await identity.finish(await identity.begin(SyncIdentity.guest));
      await tester.pumpAndSettle();
      expect(find.text('已配对'), findsNothing);
      expect(service.commands, isEmpty);
    },
  );

  testUiWidgets(
    'missing credential keeps personal app usable and does not connect',
    (tester) async {
      final service = TestCompanionService();
      await mount(tester, service, credentials: _Credentials()..token = null);
      await open(tester);
      expect(find.text('请在设置中检查设备凭证。'), findsOneWidget);
      expect(service.reads, 0);
      expect(service.commands, isEmpty);
      await goBack(tester);
      expect(find.text('今天'), findsWidgets);
    },
  );

  for (final scale in [1.0, 2.0, 3.0]) {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      testUiWidgets(
        'pairing 320px scale $scale system $brightness input/invite/leave',
        (tester) async {
          tester.view.physicalSize = const Size(320, 568);
          tester.view.devicePixelRatio = 1;
          tester.view.padding = const FakeViewPadding(top: 20);
          tester.view.viewPadding = const FakeViewPadding(top: 20);
          tester.view.viewInsets = const FakeViewPadding();
          tester.platformDispatcher.platformBrightnessTestValue = brightness;
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.view.resetPadding);
          addTearDown(tester.view.resetViewPadding);
          addTearDown(tester.view.resetViewInsets);
          addTearDown(
            tester.platformDispatcher.clearPlatformBrightnessTestValue,
          );
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          final service = TestCompanionService();
          await mount(tester, service);
          await open(tester);
          // 陪伴 is a tab: its title sits in the header, not an AppBar.
          final title = find.text('尚未配对');
          expect(
            tester.renderObject<RenderParagraph>(title).didExceedMaxLines,
            false,
          );
          await tester.ensureVisible(input);
          await tester.enterText(input, '😀' * 65);
          await tester.pumpAndSettle();
          await capture.shot(tester, scale, 'pairing-${brightness.name}-input');
          await tester.enterText(input, 'ABCDEFGH');
          await tapVisible(
            tester,
            find.byKey(const ValueKey('create-pairing-invite')),
          );
          await tester.ensureVisible(
            find.byKey(const ValueKey('pairing-invite-code')),
          );
          await capture.shot(
            tester,
            scale,
            'pairing-${brightness.name}-invite',
          );
          await tapVisible(tester, find.byKey(const ValueKey('join-pairing')));
          await confirm(tester);
          await capture.shot(
            tester,
            scale,
            'pairing-${brightness.name}-paired',
          );
          await tapVisible(tester, find.byKey(const ValueKey('leave-pairing')));
          await tester.ensureVisible(
            find.byKey(const ValueKey('confirm-pairing')),
          );
          await capture.shot(tester, scale, 'pairing-${brightness.name}-leave');
          await confirm(tester);
          expect(find.text('尚未配对'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await capture.passed(tester, scale);
        },
      );
    }
  }
}
