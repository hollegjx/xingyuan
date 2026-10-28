import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:habit_checkin/app/theme.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/features/assistant/assistant_providers.dart';
import 'package:habit_checkin/features/assistant/data/local_memory_store.dart';
import 'package:habit_checkin/features/assistant/presentation/assistant_conversation_view.dart';
import 'package:habit_checkin/shared/ui/composer.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:xingyuan_core/xingyuan_core.dart';

import 'assistant_conversation_ui_test.dart' show openPlanning, sendText;
import 'assistant_diary_ui_test.dart' show tapDiaryControl;
import 'journal_diary_capture_test.dart'
    show capture, captureDirectory, captureFont, loadDiaryCaptureFont;
import 'support/test_assistant_service.dart';
import 'support/ui_harness.dart';

// Export the actual first frame even if layout failed; assertions still fail.
Future<void> entryFrame(WidgetTester tester, GlobalKey key, String name) async {
  if (captureDirectory.isEmpty) return;
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    try {
      final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      await Directory(captureDirectory).create(recursive: true);
      await File('$captureDirectory/$name.png')
          .writeAsBytes(png.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

const material = '我读完了一章，还没想好是否散步。';
final input = find.byKey(const ValueKey('assistant-input'));
final send = find.byKey(const ValueKey('assistant-send'));
final history = find.byKey(const ValueKey('assistant-conversation-scroll'));
final planningBar = find.byWidgetPredicate(
  (w) => w.runtimeType.toString() == '_PlanningBar',
);

TurnResponse diaryReply(TurnRequest request) => TurnResponse.fromJson({
  'protocol': assistantProtocol,
  'request_id': request.requestId,
  'reply': '请预览。',
  'plan': null,
  'memory_ops': [],
  'diary': {'date': null, 'content': material},
}, request: request);

void viewport(WidgetTester tester, Size size, double scale, Brightness theme) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.view.padding = const FakeViewPadding(top: 20);
  tester.view.viewPadding = const FakeViewPadding(top: 20);
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  tester.platformDispatcher.platformBrightnessTestValue = theme;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    tester.view.resetPadding();
    tester.view.resetViewPadding();
    tester.view.resetViewInsets();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
    tester.platformDispatcher.clearPlatformBrightnessTestValue();
  });
}

void reachableComposer(WidgetTester tester, Size size, double inset) {
  expect(tester.takeException(), isNull);
  expect(input.hitTestable(), findsOneWidget);
  expect(send.hitTestable(), findsOneWidget);
  final composer = tester.getRect(find.byType(XyComposer));
  final scroll = tester.getRect(history);
  expect(scroll.height, greaterThan(0));
  expect(scroll.bottom, lessThanOrEqualTo(composer.top));
  for (final control in [input, send]) {
    final rect = tester.getRect(control);
    expect(rect.left, greaterThanOrEqualTo(0));
    expect(rect.right, lessThanOrEqualTo(size.width));
    expect(rect.top, greaterThanOrEqualTo(composer.top));
    expect(rect.bottom, lessThanOrEqualTo(size.height - inset));
  }
}

Future<void> dragStatePage(WidgetTester tester) async {
  final outer = find.byType(SingleChildScrollView).first;
  final scroll = tester.state<ScrollableState>(
    find.descendant(of: outer, matching: find.byType(Scrollable)).first,
  );
  for (var drag = 0; drag < 2; drag++) {
    final before = scroll.position.pixels;
    await tester.dragFrom(const Offset(160, 380), const Offset(0, -180));
    await tester.pumpAndSettle();
    expect(scroll.position.pixels, greaterThan(before));
    expect(tester.takeException(), isNull);
  }
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
    for (final size in [const Size(320, 568), const Size(390, 844)]) {
      for (final scale in [1.0, 4.0]) {
        final label =
            '${size.width.toInt()}-${scale.toInt()}x-${brightness.name}';
        testUiWidgets('R4 full chat entry $label', (tester) async {
          viewport(tester, size, scale, brightness);
          final boundary = GlobalKey();
          final app = UiHarness();
          await LocalMemoryStore(app.repository).consent();
          final service = ConversationTestService()
            ..onTurn = (request) async => diaryReply(request);
          await app.mount(
            tester,
            assistantService: service,
            assistantCredentials: ConversationTestCredentials(),
            wrapApp: (child) => RepaintBoundary(key: boundary, child: child),
          );
          await openPlanning(tester);
          for (final finder in [
            find.byWidgetPredicate(
              (w) => w.runtimeType.toString() == '_PlanningBar',
            ),
            find.byType(XyComposer),
          ]) {
            final box = tester.renderObject<RenderBox>(finder);
            debugPrint(
              'R4 ${tester.widget(finder).runtimeType}: size=${box.size}, constraints=${box.constraints}, top=${box.localToGlobal(Offset.zero)}',
            );
          }
          await entryFrame(tester, boundary, 'entry-$label');
          reachableComposer(tester, size, 0);
          await capture(
            tester,
            boundary,
            'entry-$label',
            size,
            text: find.descendant(of: planningBar, matching: find.text('规划')),
            expectedText: '规划',
          );
          await tester.enterText(input, '读书');
          tester.view.viewInsets = const FakeViewPadding(bottom: 200);
          await tester.pumpAndSettle();
          reachableComposer(tester, size, 200);
          await capture(
            tester,
            boundary,
            'keyboard-$label',
            size,
            text: input,
            expectedText: '读书',
            editable: true,
          );

          // Programmatic widget composition, not evidence of a real Chinese IME.
          const draft = '今天读书👩🏽‍💻\n还想再读';
          const composing = TextEditingValue(
            text: draft,
            selection: TextSelection.collapsed(offset: draft.length),
            composing: TextRange(start: draft.length - 2, end: draft.length),
          );
          tester.testTextInput.updateEditingValue(composing);
          await tester.pumpAndSettle();
          for (final inset in [200.0, 100.0, 0.0, 200.0, 0.0]) {
            tester.view.viewInsets = FakeViewPadding(bottom: inset);
            await tester.pumpAndSettle();
            reachableComposer(tester, size, inset);
            expect(
              tester.widget<TextField>(input).controller!.value,
              composing,
            );
            final pinned = tester.getRect(input);
            final state = tester.state<ScrollableState>(
              find
                  .descendant(of: history, matching: find.byType(Scrollable))
                  .first,
            );
            state.position.jumpTo(state.position.maxScrollExtent);
            await tester.pumpAndSettle();
            expect(tester.getRect(input), pinned);
          }
          for (final destination in ['会话列表', 'AI 设置']) {
            await tapVisible(tester, find.byTooltip(destination));
            await goBack(tester);
            expect(tester.widget<TextField>(input).controller!.text, draft);
            expect(tester.takeException(), isNull);
          }
          await tapVisible(tester, find.byTooltip('今天'));
          await openPlanning(tester);
          expect(tester.widget<TextField>(input).controller!.text, draft);
          expect(service.requests, isEmpty);
          await sendText(tester, '$material帮我写成日记。');
          expect(service.requests, hasLength(1));
          expect(
            service.requests.single.messages.last.text,
            '$material帮我写成日记。',
          );
          await tapVisible(tester, find.byTooltip('会话信息'));
          await goBack(tester);
          await tapDiaryControl(tester, find.text('预览日记建议'));
          final suggestion = find.byKey(
            const ValueKey('chat-diary-suggestion'),
          );
          await Scrollable.ensureVisible(tester.element(suggestion));
          await tester.pumpAndSettle();
          await capture(
            tester,
            boundary,
            'diary-$label',
            size,
            text: suggestion,
            expectedText: material,
            firstLineOnly: true,
          );
          expect(
            await app.database.select(app.database.diaryEntries).get(),
            isEmpty,
          );
          expect(service.requests, hasLength(1));
          expect(tester.takeException(), isNull);
        }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
      }
    }
    testUiWidgets('R4 busy cancel retains next draft ${brightness.name}', (
      tester,
    ) async {
      const size = Size(320, 568);
      viewport(tester, size, 4, brightness);
      final boundary = GlobalKey();
      final app = UiHarness();
      await LocalMemoryStore(app.repository).consent();
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final service = ConversationTestService()
        ..onTurn = (request) async {
          await release.future;
          return diaryReply(request);
        };
      await app.mount(
        tester,
        assistantService: service,
        assistantCredentials: ConversationTestCredentials(),
        wrapApp: (child) => RepaintBoundary(key: boundary, child: child),
      );
      await openPlanning(tester);
      await sendText(tester, '$material帮我写成日记。', waiting: true);
      final controller = await app.container.read(
        assistantConversationProvider.future,
      );
      expect(controller.busy, isTrue);
      await tester.enterText(input, '下一条👩🏽‍💻\n还没写完');
      tester.view.viewInsets = const FakeViewPadding(bottom: 200);
      await pumpWaiting(tester);
      reachableComposer(tester, size, 200);
      expect(tester.widget<IconButton>(send).onPressed, isNull);
      await tester.tap(send);
      await pumpWaiting(tester);
      expect(service.requests, hasLength(1));
      final cancel = find.byKey(const ValueKey('assistant-cancel'));
      await Scrollable.ensureVisible(tester.element(cancel), alignment: .5);
      await pumpWaiting(tester);
      expect(cancel.hitTestable(), findsOneWidget);
      expect(tester.getSize(cancel).height, greaterThanOrEqualTo(44));
      final label = tester.renderObject<RenderParagraph>(
        find.descendant(of: cancel, matching: find.byType(RichText)),
      );
      final boxes = label.getBoxesForSelection(
        const TextSelection(baseOffset: 0, extentOffset: 4),
      );
      expect(boxes.map((box) => box.top).toSet(), hasLength(1));
      expect(label.textScaler.scale(17), 68);
      await capture(
        tester,
        boundary,
        'cancel-${brightness.name}',
        size,
        text: find.descendant(of: cancel, matching: find.text('取消等待')),
        expectedText: '取消等待',
      );
      await tapVisible(tester, cancel);
      expect(controller.busy, isFalse);
      release.complete();
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(input).controller!.text,
        '下一条👩🏽‍💻\n还没写完',
      );
      expect(service.requests, hasLength(1));
      expect(find.text('预览日记建议'), findsNothing);
      expect(
        await app.database.select(app.database.diaryEntries).get(),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testUiWidgets('R4 consent remains reachable ${brightness.name}', (
      tester,
    ) async {
      viewport(tester, const Size(320, 568), 4, brightness);
      final app = UiHarness();
      final service = ConversationTestService();
      await app.mount(
        tester,
        assistantService: service,
        assistantCredentials: ConversationTestCredentials(),
      );
      await openPlanning(tester, consent: false);
      expect(tester.takeException(), isNull);
      expect(input, findsNothing);
      expect(service.requests, isEmpty);
      await dragStatePage(tester);
      await tapVisible(
        tester,
        find.byKey(const ValueKey('assistant-consent-confirm')),
      );
      reachableComposer(tester, const Size(320, 568), 0);
      expect(service.requests, isEmpty);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testUiWidgets('R4 settings loading and failure scroll ${brightness.name}', (
      tester,
    ) async {
      viewport(tester, const Size(320, 568), 4, brightness);
      final pending = Completer<StoredAssistantSettings>();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            assistantSettingsProvider.overrideWith((ref) => pending.future),
          ],
          child: MaterialApp(
            theme: buildXyTheme(brightness),
            home: const Scaffold(
              body: SafeArea(child: AssistantConversationView()),
            ),
          ),
        ),
      );
      await pumpWaiting(tester);
      expect(find.text('正在读取规划设置'), findsOneWidget);
      expect(tester.takeException(), isNull);
      pending.completeError(StateError('synthetic read failure'));
      await tester.pumpAndSettle();
      expect(find.text('无法读取规划设置'), findsOneWidget);
      await dragStatePage(tester);
      final retry = find.text('重试');
      await tester.ensureVisible(retry);
      await tester.pumpAndSettle();
      expect(retry.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
  }
}
