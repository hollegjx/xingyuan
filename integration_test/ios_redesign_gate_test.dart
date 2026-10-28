import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/assistant/data/local_memory_store.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:habit_checkin/features/journal/domain/journal_entry.dart';
import 'package:integration_test/integration_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import '../test/support/assistant_fixtures.dart';
import '../test/support/chat_service.dart';
import '../test/support/journal_fixtures.dart';
import '../test/support/layout_capture.dart';
import '../test/support/record_fixtures.dart';
import '../test/support/test_assistant_service.dart';
import '../test/support/ui_harness.dart';

// Synthetic, in-memory services only. This never reads phone data or connects
// to the model/companion backend. Exports are native-renderer images, not OS UI.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final capture = LayoutCapture();
  // Renderer captures use a synthetic viewport. Real keyboard metrics belong
  // to the physical simulator display and are tested by the lifecycle gate.
  setUp(binding.testTextInput.register);
  tearDown(binding.testTextInput.unregister);
  setUpAll(() async {
    tzdata.initializeTimeZones();
    await capture.prepare();
  });
  for (final brightness in Brightness.values) {
    testUiWidgets('iOS redesign ${brightness.name} screen journey', (
      tester,
    ) async {
      expect(Platform.isIOS, isTrue);
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(top: 20);
      tester.view.viewPadding = const FakeViewPadding(top: 20);
      tester.view.viewInsets = const FakeViewPadding();
      tester.platformDispatcher.platformBrightnessTestValue = brightness;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.view.resetPadding();
        tester.view.resetViewPadding();
        tester.view.resetViewInsets();
        tester.platformDispatcher.clearPlatformBrightnessTestValue();
      });
      final h = UiHarness();
      final service = TestChatService();
      final assistant = ConversationTestService();
      await h.repository.create(
        const GoalDraft(title: '阅读二十分钟', kind: GoalKind.habit),
      );
      await h.repository.create(
        GoalDraft(
          title: '整理书桌',
          kind: GoalKind.single,
          plannedDay: h.clock.day,
        ),
      );
      service.seed(
        (await h.database.select(h.database.goals).get()).first.globalId,
        partner: true,
      );
      for (var i = 0; i < 20; i++) {
        service.incoming('合成对话 $i：今天读了几页书，准备明天继续。');
      }
      await seedAssistantReply(h.database);
      await LocalMemoryStore(h.repository).consent();
      await h.mount(
        tester,
        companionService: service,
        assistantService: assistant,
        assistantCredentials: ConversationTestCredentials(),
        recordPhotoFiles: MemoryRecordPhotoFiles(),
        journalPhotoFiles: {
          for (final kind in JournalKind.values)
            kind: MemoryJournalPhotoFiles(kind),
        },
        recordPhotoPicker: StubRecordPhotoPicker(),
        wrapApp: capture.wrap,
      );
      Future<void> shot(String name) =>
          capture.shot(tester, 1, '${brightness.name}-$name');
      await shot('today');
      for (final entry in ['quick-note', 'diary']) {
        await tapVisible(tester, find.byKey(ValueKey('entry-$entry')));
        await tester.enterText(
          find.byKey(const ValueKey('journal-text')),
          '合成记录：今天读了一小段书。\n留一点时间给自己。',
        );
        await tester.pumpAndSettle();
        await shot(entry);
        await tapVisible(tester, find.byKey(const ValueKey('save-journal')));
      }
      await shot('today-with-journal');
      await openMenu(tester, '陪伴');
      await shot('companion');
      await tapVisible(tester, find.byKey(const ValueKey('open-chat')));
      await shot('chat-latest');
      final input = find.byKey(const ValueKey('chat-input'));
      final pinned = tester.getRect(input);
      final history = find.byKey(const ValueKey('chat-messages'));
      final scroll = tester.state<ScrollableState>(
        find.descendant(of: history, matching: find.byType(Scrollable)).first,
      );
      final before = scroll.position.pixels;
      await tester.drag(history, const Offset(0, 240));
      await tester.pumpAndSettle();
      expect(scroll.position.pixels, lessThan(before));
      expect(tester.getRect(input), pinned);
      await shot('chat-scrolled');
      await goBack(tester);
      await tapVisible(tester, find.byTooltip('规划'));
      await shot('planning');
      await tapVisible(tester, find.byTooltip('今天'));
      await tapVisible(tester, find.byKey(const ValueKey('entry-new-goal')));
      await shot('new-goal');
      await goBack(tester);
      await openMenu(tester, '设置');
      await shot('settings');
      await tapVisible(tester, find.byKey(const ValueKey('my-diary')));
      await shot('notebook');
      await goBack(tester);
      await goBack(tester);
      await tapVisible(tester, find.byTooltip('回顾'));
      await shot('review');
      expect(service.chatCommands, isEmpty);
      expect(service.sharedCommands, isEmpty);
      expect(assistant.requests, isEmpty);
      expect(tester.takeException(), isNull);
      await capture.passed(tester, 1);
    });
  }
}
