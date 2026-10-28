import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/assistant/assistant_providers.dart';
import 'package:habit_checkin/features/assistant/data/device_credential_store.dart';
import 'package:habit_checkin/features/companion/companion_providers.dart';
import 'package:habit_checkin/features/companion/data/companion_service.dart';
import 'package:habit_checkin/features/companion/presentation/chat_controller.dart';
import 'package:habit_checkin/features/records/data/record_photo.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'support/chat_fixtures.dart';
import 'support/chat_service.dart';
import 'support/layout_capture.dart';
import 'support/record_fixtures.dart';
import 'support/ui_harness.dart';

class _Credentials extends DeviceCredentialStore {
  @override
  Future<String?> read() async => 'a' * 43;
}

void main() {
  final capture = LayoutCapture();
  final input = find.byKey(const ValueKey('chat-input'));
  final send = find.byKey(const ValueKey('send-chat'));
  setUpAll(() async {
    tzdata.initializeTimeZones();
    await capture.prepare();
  });

  Future<UiHarness> mount(
    WidgetTester tester,
    TestChatService service, {
    StubRecordPhotoPicker? picker,
    bool foreground = false,
  }) async {
    final h = UiHarness();
    await h.mount(
      tester,
      assistantCredentials: _Credentials(),
      companionService: service,
      recordPhotoPicker: picker,
      recordPhotoFiles: MemoryRecordPhotoFiles(),
      companionForeground: foreground,
      wrapApp: capture.wrap,
    );
    return h;
  }

  Future<void> open(WidgetTester tester) async {
    await openMenu(tester, '陪伴');
    await tapVisible(tester, find.byKey(const ValueKey('open-chat')));
  }

  Future<ChatController> controller(UiHarness h) =>
      h.container.read(chatControllerProvider.future);
  Future<void> enter(WidgetTester tester, String text) async {
    await tester.ensureVisible(input);
    await tester.enterText(input, text);
    await tester.pumpAndSettle();
  }

  Future<void> sendText(WidgetTester tester, String text) async {
    await enter(tester, text);
    await tapVisible(tester, send);
  }

  void lifecycle(WidgetTester tester, bool resumed) {
    for (final state
        in resumed
            ? [
                AppLifecycleState.hidden,
                AppLifecycleState.inactive,
                AppLifecycleState.resumed,
              ]
            : [
                AppLifecycleState.inactive,
                AppLifecycleState.hidden,
                AppLifecycleState.paused,
              ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
  }

  testUiWidgets(
    'chat draft survives back, another page, background and provider reopen',
    (tester) async {
      final service = TestChatService();
      final h = await mount(tester, service);
      await open(tester);
      const text = 'SYNTHETIC\n\u{1f44d} draft';
      await enter(tester, text);
      lifecycle(tester, false);
      lifecycle(tester, true);
      await tester.pumpAndSettle();
      await goBack(tester);
      await tapVisible(tester, find.byKey(const ValueKey('open-sharing')));
      await goBack(tester);
      h.container.invalidate(chatControllerProvider);
      await tester.pumpAndSettle();
      await tapVisible(tester, find.byKey(const ValueKey('open-chat')));
      expect(tester.widget<TextField>(input).controller!.text, text);
      expect((await controller(h)).draftSaved, true);
      expect(service.chatCommands, isEmpty);
    },
  );

  testUiWidgets(
    'five sends stay one while later typing survives a slow response',
    (tester) async {
      final service = TestChatService();
      final h = await mount(tester, service);
      await open(tester);
      final gate = Completer<void>();
      service.chatGate = gate.future;
      await enter(tester, 'SYNTHETIC first');
      for (var i = 0; i < 5; i++) {
        await tester.tap(send);
      }
      await tester.pumpAndSettle();
      expect(service.chatCommands, hasLength(1));
      final pending = find.byKey(
        ValueKey('pending-chat-${service.chatCommands.single.operationId}'),
      );
      final content = find.descendant(
        of: pending,
        matching: find.text('SYNTHETIC first'),
      );
      final status = find.descendant(of: pending, matching: find.text('正在发送'));
      expect(content, findsOneWidget);
      expect(status, findsOneWidget);
      expect(
        tester.getTopLeft(status).dy,
        greaterThan(tester.getBottomLeft(content).dy),
      );
      await enter(tester, 'SYNTHETIC next');
      gate.complete();
      await tester.pumpAndSettle();
      expect(service.chats, hasLength(1));
      expect((await controller(h)).draftText, 'SYNTHETIC next');
      expect(find.text('SYNTHETIC first'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testUiWidgets(
    'uncertain send blocks later sends and retries original ID once',
    (tester) async {
      final service = TestChatService();
      final h = await mount(tester, service);
      await open(tester);
      service.chatAfterCommitFailure = const CompanionServiceFailure(
        'timeout',
        outcomeUnknown: true,
      );
      await sendText(tester, 'SYNTHETIC one');
      final c = await controller(h);
      final op = c.pending.single.row.operationId;
      expect(find.byKey(ValueKey('discard-chat-$op')), findsNothing);
      await sendText(tester, 'SYNTHETIC two');
      expect(service.chatCommands, hasLength(1));
      expect(c.pending.map((p) => p.row.content), [
        'SYNTHETIC one',
        'SYNTHETIC two',
      ]);
      service.chatAfterCommitFailure = null;
      await tapVisible(tester, find.byKey(ValueKey('retry-chat-$op')));
      expect(service.chatCommands.map((c) => c.operationId).take(2), [op, op]);
      expect(service.chats.map((r) => r['text']), [
        'SYNTHETIC one',
        'SYNTHETIC two',
      ]);
      expect(c.pending, isEmpty);
    },
  );

  testUiWidgets(
    'definite offline failure can be discarded only after confirmation',
    (tester) async {
      final service = TestChatService();
      final h = await mount(tester, service);
      await open(tester);
      service.chatFailure = const CompanionServiceFailure('network');
      await sendText(tester, 'SYNTHETIC offline');
      final c = await controller(h);
      final discard = find.byKey(
        ValueKey('discard-chat-${c.pending.single.row.operationId}'),
      );
      await tapVisible(tester, discard);
      await tapVisible(tester, find.text('取消'));
      expect(c.pending, hasLength(1));
      await tapVisible(tester, discard);
      await tapVisible(tester, find.byKey(const ValueKey('confirm-chat')));
      expect(c.pending, isEmpty);
      expect(service.chats, isEmpty);
    },
  );

  testUiWidgets('cancelled refresh cannot claim an uncertain chat was unsent', (
    tester,
  ) async {
    final service = TestChatService();
    final h = await mount(tester, service);
    await open(tester);
    service.chatAfterCommitFailure = const CompanionServiceFailure(
      'timeout',
      outcomeUnknown: true,
    );
    await sendText(tester, 'SYNTHETIC accepted without receipt');
    final c = await controller(h);
    final original = c.pending.single.row.operationId;
    service.chatReadFailure = const CompanionServiceFailure('cancelled');
    await tapVisible(tester, find.byTooltip('刷新消息'));
    expect(c.pending.single.row.operationId, original);
    expect(c.pending.single.row.status, 'uncertain');
    expect(find.byKey(ValueKey('discard-chat-$original')), findsNothing);
    expect(find.text('已取消，尚未发送。'), findsNothing);
  });

  testUiWidgets('only own messages have delete; cancellation keeps message', (
    tester,
  ) async {
    final service = TestChatService()..incoming('SYNTHETIC partner');
    final h = await mount(tester, service);
    await open(tester);
    expect(find.byTooltip('删除消息'), findsNothing);
    await sendText(tester, 'SYNTHETIC mine');
    await tapVisible(tester, find.byTooltip('删除消息'));
    await tapVisible(tester, find.text('取消'));
    expect(service.chats, hasLength(2));
    await tapVisible(tester, find.byTooltip('删除消息'));
    await tapVisible(tester, find.byKey(const ValueKey('confirm-chat')));
    expect(service.chats.single['text'], 'SYNTHETIC partner');
    expect((await controller(h)).snapshot!.messages, hasLength(1));
  });

  testUiWidgets(
    '1000 graphemes, emoji, newline and oversized input preserve draft',
    (tester) async {
      final service = TestChatService();
      final h = await mount(tester, service);
      await open(tester);
      await tapVisible(tester, send);
      expect(service.chatCommands, isEmpty);
      final text = '${'\u{1f44d}' * 999}\n';
      await sendText(tester, '${text}x');
      expect((await controller(h)).draftText, '${text}x');
      expect(service.chatCommands, isEmpty);
      await sendText(tester, text);
      expect(service.chatCommands.single.text, text);
    },
  );

  testUiWidgets('10-second polling stops when covered, left or backgrounded', (
    tester,
  ) async {
    final service = TestChatService();
    await mount(tester, service);
    await open(tester);
    var reads = service.chatReads;
    await tester.pump(const Duration(seconds: 9));
    expect(service.chatReads, reads);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(service.chatReads, ++reads);
    final context = tester.element(input);
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('SYNTHETIC cover')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 20));
    expect(service.chatReads, reads);
    Navigator.of(context).pop();
    await tester.pumpAndSettle();
    lifecycle(tester, false);
    // A paused native engine does not render frames. The live gate must wait
    // without pumping until it has delivered the resume event.
    if (tester.binding is LiveTestWidgetsFlutterBinding) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 20)),
      );
    } else {
      await tester.pump(const Duration(seconds: 20));
    }
    expect(service.chatReads, reads);
    lifecycle(tester, true);
    await tester.pumpAndSettle();
    expect(service.chatReads, ++reads);
    await goBack(tester);
    await tester.pump(const Duration(seconds: 20));
    expect(service.chatReads, reads);
  });

  testUiWidgets(
    'foreground refresh shows local unread; reading latest clears it',
    (tester) async {
      final service = TestChatService()..incoming('SYNTHETIC unseen');
      final h = await mount(tester, service, foreground: true);
      await openMenu(tester, '陪伴');
      expect(find.text('私聊 · 1 条未读'), findsOneWidget);
      await tapVisible(tester, find.byKey(const ValueKey('open-chat')));
      expect((await controller(h)).unread, 0);
      await goBack(tester);
      service.incoming('SYNTHETIC later');
      lifecycle(tester, false);
      lifecycle(tester, true);
      await tester.pumpAndSettle();
      expect(find.text('私聊 · 1 条未读'), findsOneWidget);
      expect(service.chatCommands, isEmpty);
    },
  );

  testUiWidgets('credential change hides content and confirmation overlays', (
    tester,
  ) async {
    final service = TestChatService();
    final h = await mount(tester, service);
    await open(tester);
    await sendText(tester, 'SYNTHETIC mine');
    await tapVisible(tester, find.byTooltip('删除消息'));
    h.container.read(assistantCredentialRevisionProvider.notifier).changed();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('confirm-chat')), findsNothing);
    expect(find.text('SYNTHETIC mine'), findsNothing);
  });

  testUiWidgets('oversized photo leaves chat text editable and sendable', (
    tester,
  ) async {
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
    final service = TestChatService();
    final picker = StubRecordPhotoPicker()
      ..onPick = () async => Uint8List(maxRecordPhotoInputBytes + 1);
    final h = await mount(tester, service, picker: picker);
    await open(tester);
    const text = 'SYNTHETIC text survives oversized photo';
    await enter(tester, text);
    await tapVisible(tester, find.byKey(const ValueKey('chat-library')));
    expect(find.text('照片过大或无法读取，请重新选择'), findsOneWidget);
    expect(tester.widget<TextField>(input).controller!.text, text);
    final c = await controller(h);
    expect(c.draftPhotoId, isNull);
    expect(c.preparing, false);
    expect(await h.database.select(h.database.chatPhotos).get(), isEmpty);
    expect(service.uploads, isEmpty);
    await capture.shot(tester, 1, 'chat-photo-too-large');
    await tapVisible(tester, send);
    expect(service.chats.single['text'], text);
    expect(service.chatCommands.single.photoId, isNull);
    expect(c.pending, isEmpty);
    expect(service.uploads, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testUiWidgets(
    'denied picker keeps text usable; cancelled picker does not clear draft',
    (tester) async {
      final service = TestChatService();
      final picker = StubRecordPhotoPicker()
        ..onPick = () async => throw const RecordPhotoException('未获得相册权限');
      await mount(tester, service, picker: picker);
      await open(tester);
      await enter(tester, 'SYNTHETIC text');
      await tapVisible(tester, find.byKey(const ValueKey('chat-library')));
      expect(find.text('未获得相册权限'), findsOneWidget);
      picker.onPick = () async => null;
      await tapVisible(tester, find.byKey(const ValueKey('chat-library')));
      expect(
        tester.widget<TextField>(input).controller!.text,
        'SYNTHETIC text',
      );
      await tapVisible(tester, send);
      expect(service.chats.single['text'], 'SYNTHETIC text');
    },
  );

  testUiWidgets(
    'photo import, send, full view and remote removal clear pixels',
    (tester) async {
      final service = TestChatService();
      final picker = StubRecordPhotoPicker()..onPick = () async => chatJpeg();
      final h = await mount(tester, service, picker: picker);
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('chat-library')));
      for (
        var i = 0;
        i < 100 && (await controller(h)).draftPhotoId == null;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect((await controller(h)).draftPhotoId, isNotNull);
      await tapVisible(tester, send);
      expect(service.uploads, hasLength(1));
      expect(service.chatCommands.single.photoId, isNotNull);
      final photo = service.chatCommands.single.photoId!;
      await tapVisible(tester, find.byKey(ValueKey('chat-photo-$photo')));
      expect(find.text('聊天图片'), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
      service.chats.clear();
      service.chatRevision++;
      await (await controller(h)).refresh();
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsNothing);
    },
  );

  testUiWidgets(
    'scrolled history and covered routes never consume unread messages',
    (tester) async {
      final service = TestChatService();
      for (var i = 0; i < 25; i++) {
        service.incoming('SYNTHETIC history $i\nsecond line');
      }
      final h = await mount(tester, service);
      await open(tester);
      final c = await controller(h);
      expect(c.snapshot!.messages, hasLength(25));
      expect(c.unread, 0);
      await tester.drag(
        find.byKey(const ValueKey('chat-messages')),
        const Offset(0, 500),
      );
      await tester.pumpAndSettle();
      final scroll = tester
          .widget<ListView>(find.byKey(const ValueKey('chat-messages')))
          .controller!;
      expect(scroll.offset, lessThan(scroll.position.maxScrollExtent - 100));
      service.incoming('SYNTHETIC unseen while scrolling');
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
      expect(scroll.offset, lessThan(scroll.position.maxScrollExtent - 100));
      expect(c.unread, 1);
      final context = tester.element(input);
      unawaited(
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('SYNTHETIC cover')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      service.incoming('SYNTHETIC unseen while covered');
      await c.refresh();
      await tester.pumpAndSettle();
      expect(c.unread, 2);
      Navigator.of(context).pop();
      await tester.pumpAndSettle();
      expect(c.unread, 2);
      for (var i = 0; i < 15 && c.unread != 0; i++) {
        await tester.drag(
          find.byKey(const ValueKey('chat-messages')),
          const Offset(0, -400),
        );
        await tester.pumpAndSettle();
      }
      expect(c.unread, 0);
    },
  );

  testUiWidgets(
    'revocation clears chat draft and cache without deleting personal tables',
    (tester) async {
      final service = TestChatService()..incoming('SYNTHETIC partner');
      final h = await mount(tester, service);
      await open(tester);
      await enter(tester, 'SYNTHETIC private draft');
      final c = await controller(h);
      final before = await h.database.select(h.database.goals).get();
      service.chatReadFailure = const CompanionServiceFailure('unauthorized');
      await tapVisible(tester, find.byTooltip('刷新消息'));
      expect(c.invalidated, true);
      expect(input, findsNothing);
      expect(find.text('SYNTHETIC partner'), findsNothing);
      expect(await h.database.select(h.database.chatStates).get(), isEmpty);
      expect(
        await h.database.select(h.database.chatMessagesCache).get(),
        isEmpty,
      );
      expect(await h.database.select(h.database.goals).get(), before);
    },
  );

  for (final scale in [1.0, 2.0, 3.0]) {
    for (final brightness in Brightness.values) {
      testUiWidgets('chat controls at 320px ${scale}x ${brightness.name}', (
        tester,
      ) async {
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
        final service = TestChatService()..incoming('SYNTHETIC\n你好');
        await mount(tester, service);
        await open(tester);
        await capture.shot(tester, scale, 'chat-${brightness.name}-messages');
        await enter(tester, 'SYNTHETIC\n草稿');
        tester.view.viewInsets = const FakeViewPadding(bottom: 200);
        await tester.pumpAndSettle();
        expect(send.hitTestable(), findsOneWidget);
        expect(tester.getBottomRight(send).dy, lessThanOrEqualTo(368));
        final composer = find
            .ancestor(of: input, matching: find.byType(SingleChildScrollView))
            .first;
        expect(
          tester.getRect(input).top,
          greaterThanOrEqualTo(tester.getRect(composer).top),
        );
        expect(
          tester.getRect(input).bottom,
          lessThanOrEqualTo(tester.getRect(composer).bottom),
        );
        await capture.shot(tester, scale, 'chat-${brightness.name}-keyboard');
        tester.view.resetViewInsets();
        await tester.pumpAndSettle();
        await tapVisible(tester, send);
        expect(find.byTooltip('删除消息').hitTestable(), findsOneWidget);
        await tapVisible(tester, find.byTooltip('删除消息'));
        await tester.ensureVisible(find.byKey(const ValueKey('confirm-chat')));
        await capture.shot(tester, scale, 'chat-${brightness.name}-delete');
        await tapVisible(tester, find.text('取消'));
        for (final paragraph in tester.renderObjectList<RenderParagraph>(
          find.byType(RichText),
        )) {
          expect(paragraph.didExceedMaxLines, false);
        }
        expect(tester.takeException(), isNull);
        await capture.passed(tester, scale);
      });
    }
  }
}
