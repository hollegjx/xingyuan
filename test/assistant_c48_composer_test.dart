import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/assistant/data/local_conversation_store.dart';
import 'package:habit_checkin/features/assistant/data/local_memory_store.dart';
import 'package:habit_checkin/features/assistant/domain/agent_run_metadata.dart';
import 'package:habit_checkin/shared/ui/composer.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:xingyuan_core/xingyuan_core.dart';

import 'assistant_conversation_ui_test.dart' show openPlanning, sendText;
import 'assistant_diary_entry_layout_test.dart'
    show entryFrame, input, send, history, viewport, reachableComposer;
import 'journal_diary_capture_test.dart'
    show capture, captureFont, loadDiaryCaptureFont;
import 'support/assistant_fixtures.dart';
import 'support/test_assistant_service.dart';
import 'support/ui_harness.dart';

void composerContract(WidgetTester tester, double scale) {
  final composer = find.byType(XyComposer);
  final editable = tester.state<EditableTextState>(
    find.descendant(of: input, matching: find.byType(EditableText)),
  );
  expect(
    editable.renderEditable.textScaler.scale(16),
    closeTo(16 * scale.clamp(0, 2), .001),
  );
  final layout = find
      .ancestor(of: composer, matching: find.byType(LayoutBuilder))
      .first;
  final available = tester.getSize(layout).height;
  final cap = available * .4;
  expect(tester.widget<XyComposer>(composer).maxHeight, closeTo(cap, .001));
  expect(tester.getSize(composer).height, lessThanOrEqualTo(cap + .001));
  expect(
    tester.getRect(history).bottom,
    lessThanOrEqualTo(tester.getRect(composer).top),
  );
  expect(tester.takeException(), isNull);
}

void main() {
  setUpAll(() async {
    tzdata.initializeTimeZones();
    await loadDiaryCaptureFont();
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0, 2.01, 3.5]) {
      testUiWidgets(
        'C48 pinned composer ${brightness.name} ${scale}x keeps content full scale',
        (tester) async {
          const size = Size(320, 568);
          viewport(tester, size, scale, brightness);
          final app = UiHarness();
          final service = ConversationTestService();
          final store = LocalConversationStore(app.repository);
          await store.memories.consent();
          await seedAssistantReply(app.database);
          final id = await store.proposals.saveDraft(
            sessionId: 'test-session',
            messageId: 'test-message',
            preview: syntheticPreview(day: app.clock.day.key),
            agentMetadata: AgentRunMetadata(
              date: CalendarDate.parse(app.clock.day.key),
            ),
          );
          final boundary = GlobalKey();
          await app.mount(
            tester,
            assistantStore: store,
            assistantService: service,
            assistantCredentials: ConversationTestCredentials(),
            wrapApp: (child) => RepaintBoundary(key: boundary, child: child),
          );
          await openPlanning(tester);
          final fieldController = tester.widget<TextField>(input).controller!;
          composerContract(tester, scale);
          reachableComposer(tester, size, 0);
          final message = find.byKey(
            const ValueKey('assistant-message-test-message'),
          );
          expect(
            MediaQuery.textScalerOf(tester.element(message)).scale(16),
            16 * scale,
          );
          expect(
            MediaQuery.textScalerOf(tester.element(find.text('TEST item 0')))
                .scale(16),
            16 * scale,
          );
          final confirm = find.byKey(ValueKey('open-proposal-$id'));
          expect(
            MediaQuery.textScalerOf(tester.element(confirm)).scale(16),
            16 * scale,
          );
          expect(tester.widget<IconButton>(send).onPressed, isNull);
          await tester.enterText(input, '读书');
          await tester.pumpAndSettle();
          if (captureFont.isNotEmpty) {
            await capture(
              tester,
              boundary,
              'c48-${brightness.name}-$scale-short',
              size,
              text: input,
              expectedText: '读书',
              editable: true,
            );
          }
          const value = TextEditingValue(
            text: '测试第一行\n测试第二行\n测试第三行\n测试第四行\n测试第五行\n测试第六行',
            selection: TextSelection.collapsed(offset: 35),
            composing: TextRange(start: 32, end: 35),
          );
          tester.testTextInput.updateEditingValue(value);
          tester.view.viewInsets = const FakeViewPadding(bottom: 200);
          await tester.pumpAndSettle();
          composerContract(tester, scale);
          reachableComposer(tester, size, 200);
          expect(fieldController.value, value);
          expect(tester.widget<IconButton>(send).onPressed, isNotNull);
          await entryFrame(
            tester,
            boundary,
            'c48-${brightness.name}-$scale-long-keyboard',
          );
          for (final next in [1.0, 3.5, 2.0, scale]) {
            tester.platformDispatcher.textScaleFactorTestValue = next;
            await tester.pumpAndSettle();
            composerContract(tester, next);
            expect(
              tester.widget<TextField>(input).controller,
              same(fieldController),
            );
            expect(fieldController.value, value);
          }
          tester.testTextInput.updateEditingValue(TextEditingValue.empty);
          tester.view.viewInsets = const FakeViewPadding();
          await tester.pumpAndSettle();
          await tester.ensureVisible(confirm);
          await tester.pumpAndSettle();
          expect(confirm.hitTestable(), findsOneWidget);
          expect(tester.getSize(confirm).height, greaterThanOrEqualTo(44));
          if (captureFont.isNotEmpty) {
            await capture(
              tester,
              boundary,
              'c48-${brightness.name}-$scale-draft',
              size,
              text: find.text('确认添加'),
              expectedText: '确认添加',
            );
          }
          expect((await store.proposals.read(id)).status, 'draft');
          expect(await app.repository.loadGoals(), isEmpty);
          expect(
            await app.database.select(app.database.checkIns).get(),
            isEmpty,
          );
          expect(service.requests, isEmpty);
          expect(service.summaries, isEmpty);
          expect(service.healthCalls, 0);
          expect(app.permissions.requests, 0);
          expect(tester.takeException(), isNull);
        },
      );
    }

    testUiWidgets(
      'C48 busy composer ${brightness.name} retains next input across scaling',
      (tester) async {
        const size = Size(320, 568);
        viewport(tester, size, 2, brightness);
        final app = UiHarness();
        await LocalMemoryStore(app.repository).consent();
        final release = Completer<void>();
        final service = ConversationTestService()
          ..onTurn = (request) async {
            await release.future;
            return syntheticReply(request);
          };
        await app.mount(
          tester,
          assistantService: service,
          assistantCredentials: ConversationTestCredentials(),
        );
        await openPlanning(tester);
        await sendText(tester, 'TEST explicit first send', waiting: true);
        expect(service.requests, hasLength(1));
        await tester.enterText(input, '下一条仍是草稿');
        await tester.pump();
        final fieldController = tester.widget<TextField>(input).controller!;
        final value = fieldController.value;
        try {
          for (final scale in [3.5, 1.0, 2.01]) {
            tester.platformDispatcher.textScaleFactorTestValue = scale;
            tester.view.viewInsets = const FakeViewPadding(bottom: 200);
            await pumpWaiting(tester);
            composerContract(tester, scale);
            reachableComposer(tester, size, 200);
            expect(fieldController.value, value);
            expect(tester.widget<IconButton>(send).onPressed, isNull);
            expect(service.requests, hasLength(1));
          }
        } finally {
          release.complete();
          await tester.pumpAndSettle();
        }
        expect(fieldController.value, value);
        expect(tester.widget<IconButton>(send).onPressed, isNotNull);
        expect(service.requests, hasLength(1));
        await tapVisible(tester, send);
        expect(service.requests, hasLength(2));
        expect(service.requests.last.messages.last.text, value.text);
        expect(fieldController.text, isEmpty);
        expect(await app.repository.loadGoals(), isEmpty);
        expect(service.summaries, isEmpty);
        expect(app.permissions.requests, 0);
      },
    );

    testUiWidgets('C48 shared composer ${brightness.name} remains unclamped', (
      tester,
    ) async {
      final controller = TextEditingController(text: 'TEST shared');
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(3.5)),
            child: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: XyComposer(
                  maxHeight: 200,
                  field: TextField(controller: controller),
                  send: const IconButton(
                    onPressed: null,
                    icon: Icon(Icons.send),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      expect(
        tester
            .state<EditableTextState>(find.byType(EditableText))
            .renderEditable
            .textScaler
            .scale(16),
        56,
      );
      expect(tester.widget<XyComposer>(find.byType(XyComposer)).maxHeight, 200);
      expect(tester.takeException(), isNull);
    });
  }
}
