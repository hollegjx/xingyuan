import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/data/sync/identity_store.dart';
import 'package:habit_checkin/features/assistant/assistant_providers.dart';
import 'package:habit_checkin/features/assistant/data/local_memory_store.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'assistant_diary_entry_layout_test.dart'
    show
        viewport,
        input,
        send,
        history,
        entryFrame,
        diaryReply,
        reachableComposer;
import 'journal_diary_capture_test.dart'
    show capture, captureFont, loadDiaryCaptureFont;
import 'support/sync_fixtures.dart';
import 'support/diary_capture_pixels.dart';
import 'support/test_assistant_service.dart';
import 'support/ui_harness.dart';

Future<void> seedLongConversation(UiHarness app) async {
  await LocalMemoryStore(app.repository).consent();
  for (final id in ['long-main', 'second']) {
    await app.database
        .into(app.database.assistantSessions)
        .insert(
          AssistantSessionsCompanion.insert(
            id: id,
            owner: 'guest',
            title: id == 'long-main' ? '甲' : '乙',
            createdAt: 1,
            updatedAt: id == 'long-main' ? 2 : 1,
          ),
        );
    for (var i = 0; i < (id == 'long-main' ? 12 : 1); i++) {
      await app.database
          .into(app.database.assistantMessages)
          .insert(
            AssistantMessagesCompanion.insert(
              id: '$id-$i',
              owner: 'guest',
              sessionId: id,
              role: i.isEven ? 'user' : 'assistant',
              content: id == 'long-main'
                  ? '合成长对话 $i：今天读了一章，还有一些地方想再看看。'
                  : '另一会话的私密素材，不应串入。',
              status: 'sent',
              createdAt: i + 1,
            ),
          );
    }
  }
}

// No scrolling helpers: navigation must be reachable at the actual viewport.
Future<void> tapViewport(WidgetTester tester, Finder target) async {
  expect(target.hitTestable(), findsOneWidget);
  await tester.tap(target);
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

void navigationVisible(WidgetTester tester) {
  final bar = tester.getRect(
    find.byKey(const ValueKey('assistant-navigation')),
  );
  final body = tester.getRect(history);
  expect(bar.height, 48);
  expect(bar.bottom, lessThanOrEqualTo(body.top));
  final style = Theme.of(tester.element(history)).textTheme.bodyMedium!;
  final lineHeight =
      MediaQuery.textScalerOf(tester.element(history)).scale(style.fontSize!) *
      (style.height ?? 1);
  expect(body.height, greaterThanOrEqualTo(lineHeight));
  for (final name in ['会话列表', '会话信息', 'AI 设置']) {
    final tool = find.byTooltip(name);
    expect(tool, findsOneWidget);
    expect(tool.hitTestable(), findsOneWidget, reason: '$name at latest reply');
    final rect = tester.getRect(tool);
    expect(rect.width, greaterThanOrEqualTo(44));
    expect(rect.height, greaterThanOrEqualTo(44));
    expect(bar.contains(rect.center), isTrue);
    final data = tester.getSemantics(tool).getSemanticsData();
    // IconButton exposes its accessible name as a semantic tooltip.
    expect(data.tooltip, name);
    expect(data.flagsCollection.isButton, isTrue);
    expect(data.hasAction(ui.SemanticsAction.tap), isTrue);
  }
}

Future<void> verifyNavigationPixels(
  WidgetTester tester,
  GlobalKey key,
  Size size,
) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final regions = [
    for (final name in ['会话列表', '会话信息', 'AI 设置'])
      tester.getRect(
        find.descendant(of: find.byTooltip(name), matching: find.byType(Icon)),
      ),
  ];
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    try {
      expect(image.width, size.width.toInt());
      expect(image.height, size.height.toInt());
      verifyDiaryCapturePixels(
        (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!,
        width: image.width,
        height: image.height,
        textRegions: regions,
      );
    } finally {
      image.dispose();
    }
  });
}

void main() {
  setUpAll(() async {
    tzdata.initializeTimeZones();
    await loadDiaryCaptureFont();
    if (captureFont.isNotEmpty) {
      final bytes = ByteData.sublistView(await File(captureFont).readAsBytes());
      for (final family in ['CupertinoSystemText', 'CupertinoSystemDisplay']) {
        await (FontLoader(family)..addFont(Future.value(bytes))).load();
      }
    }
  });
  for (final brightness in Brightness.values) {
    for (final large in [false, true]) {
      final size = large ? const Size(320, 568) : const Size(390, 844);
      final scale = large ? 4.0 : 1.0;
      final label = '${large ? '320-4x' : '390-1x'}-${brightness.name}';
      testUiWidgets('long history navigation $label', (tester) async {
        viewport(tester, size, scale, brightness);
        final semantics = tester.ensureSemantics();
        try {
          final boundary = GlobalKey();
          final app = UiHarness();
          await seedLongConversation(app);
          final service = ConversationTestService()
            ..onTurn = (request) async => diaryReply(request);
          await app.mount(
            tester,
            assistantService: service,
            assistantCredentials: ConversationTestCredentials(),
            wrapApp: (child) => RepaintBoundary(key: boundary, child: child),
          );
          await tapViewport(tester, find.byTooltip('规划'));
          final controller = await app.container.read(
            assistantConversationProvider.future,
          );
          expect(controller.session!.id, 'long-main');
          expect(controller.messages, hasLength(12));
          expect(controller.sessions, hasLength(2));
          await tester.enterText(input, '读完一章，帮我写成日记。');
          await tester.pumpAndSettle();
          await tapViewport(tester, send);
          expect(controller.messages, hasLength(14));
          expect(service.requests, hasLength(1));
          expect(service.summaries, isEmpty);
          expect(
            service.requests.single.messages.any(
              (message) => message.text.contains('另一会话的私密素材'),
            ),
            isFalse,
          );
          final scroll = tester.state<ScrollableState>(
            find
                .descendant(of: history, matching: find.byType(Scrollable))
                .first,
          );
          expect(scroll.position.maxScrollExtent, greaterThan(0));
          expect(scroll.position.extentAfter, lessThan(1));
          await entryFrame(tester, boundary, 'navigation-latest-$label');
          navigationVisible(tester);
          await verifyNavigationPixels(tester, boundary, size);
          reachableComposer(tester, size, 0);

          const draft = TextEditingValue(
            text: '合成中文草稿\n下一行尚未发送',
            selection: TextSelection(baseOffset: 2, extentOffset: 6),
          );
          for (final destination in ['会话列表', 'AI 设置', '会话信息']) {
            await tester.showKeyboard(input);
            tester.testTextInput.updateEditingValue(draft);
            tester.view.viewInsets = const FakeViewPadding(bottom: 200);
            await tester.pumpAndSettle();
            navigationVisible(tester);
            await verifyNavigationPixels(tester, boundary, size);
            reachableComposer(tester, size, 200);
            await entryFrame(tester, boundary, 'navigation-focused-$label');
            await tester.tap(find.byTooltip(destination));
            tester.view.viewInsets = const FakeViewPadding();
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            await tapViewport(tester, find.byType(BackButton));
            expect(tester.widget<TextField>(input).controller!.value, draft);
            navigationVisible(tester);
          }

          await tapViewport(tester, find.byTooltip('会话列表'));
          await tapViewport(tester, find.widgetWithText(ListTile, '乙'));
          expect(controller.session!.id, 'second');
          expect(tester.widget<TextField>(input).controller!.text, isEmpty);
          const secondDraft = TextEditingValue(
            text: '乙的未发中文',
            selection: TextSelection(baseOffset: 1, extentOffset: 4),
          );
          await tester.showKeyboard(input);
          tester.testTextInput.updateEditingValue(secondDraft);
          await tester.pumpAndSettle();
          await tapViewport(tester, find.byTooltip('会话列表'));
          await tapViewport(tester, find.widgetWithText(ListTile, '甲'));
          expect(controller.session!.id, 'long-main');
          expect(tester.widget<TextField>(input).controller!.value, draft);
          await tapViewport(tester, find.byTooltip('会话列表'));
          await tapViewport(tester, find.widgetWithText(ListTile, '乙'));
          expect(
            tester.widget<TextField>(input).controller!.value,
            secondDraft,
          );
          await tapViewport(tester, find.byTooltip('会话列表'));
          await tapViewport(tester, find.widgetWithText(ListTile, '甲'));
          expect(tester.widget<TextField>(input).controller!.value, draft);
          expect(scroll.position.extentAfter, lessThan(1));
          navigationVisible(tester);
          await tapViewport(tester, find.text('预览日记建议'));
          final suggestion = find.byKey(
            const ValueKey('chat-diary-suggestion'),
          );
          // Reading the diary may scroll; navigation assertions above never do.
          await Scrollable.ensureVisible(tester.element(suggestion));
          await tester.pumpAndSettle();
          await capture(
            tester,
            boundary,
            'navigation-diary-$label',
            size,
            text: suggestion,
            expectedText: '我读完了一章，还没想好是否散步。',
            firstLineOnly: true,
          );
          await tapViewport(tester, find.byType(BackButton));
          expect(tester.widget<TextField>(input).controller!.value, draft);
          expect(
            await app.database.select(app.database.diaryEntries).get(),
            isEmpty,
          );
          expect(service.requests, hasLength(1));

          final identity = IdentityStore(app.database);
          final original = await identity.active();
          await identity.finish(await identity.begin(accountA));
          await tester.pumpAndSettle();
          expect(input, findsNothing);
          await identity.finish(await identity.begin(original.identity));
          app.container.invalidate(assistantStoreProvider);
          await tester.pumpAndSettle();
          expect(tester.widget<TextField>(input).controller!.text, isEmpty);
          await tapViewport(tester, find.byTooltip('会话列表'));
          await tapViewport(tester, find.widgetWithText(ListTile, '乙'));
          expect(tester.widget<TextField>(input).controller!.text, isEmpty);
          expect(service.requests, hasLength(1));
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
    }
  }
}
