import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/features/assistant/data/local_memory_store.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'support/assistant_fixtures.dart';
import 'support/chat_service.dart';
import 'support/pairing_fixtures.dart';
import 'support/record_fixtures.dart';
import 'support/sharing_fixtures.dart';
import 'support/test_assistant_service.dart';
import 'support/ui_harness.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);
  for (final page in ['chat', 'reply', 'planning']) {
    for (final scale in [1.0, 3.5]) {
      for (final brightness in Brightness.values) {
        testUiWidgets(
          '$page composer stays pinned at $scale ${brightness.name}',
          (tester) async {
            tester.view.physicalSize = const Size(320, 568);
            tester.view.devicePixelRatio = 1;
            tester.platformDispatcher.textScaleFactorTestValue = scale;
            tester.platformDispatcher.platformBrightnessTestValue = brightness;
            addTearDown(() {
              tester.view.resetPhysicalSize();
              tester.view.resetDevicePixelRatio();
              tester.view.resetViewInsets();
              tester.platformDispatcher.clearTextScaleFactorTestValue();
              tester.platformDispatcher.clearPlatformBrightnessTestValue();
            });
            final app = UiHarness();
            final service = TestChatService();
            final assistant = ConversationTestService();
            await app.repository.create(
              const GoalDraft(title: '合成目标', kind: GoalKind.habit),
            );
            service.seed(
              (await app.database.select(app.database.goals).get())
                  .single
                  .globalId,
              partner: true,
            );
            await seedAssistantReply(app.database);
            await LocalMemoryStore(app.repository).consent();
            for (var i = 0; i < 16; i++) {
              service.incoming('合成消息 $i：今天完成了阅读，明天继续。');
              service.sharedReplies.add({
                'id': sharingId(500 + i),
                'record_id': testRecordId,
                'author_id': testPartnerId,
                'sequence': i + 1,
                'text': '合成回复 $i：慢慢来，按自己的节奏。',
                'created_at': sharingInstant,
              });
              await app.database
                  .into(app.database.assistantMessages)
                  .insert(
                    AssistantMessagesCompanion.insert(
                      id: 'composer-message-$i',
                      owner: 'guest',
                      sessionId: 'test-session',
                      role: 'assistant',
                      content: '合成规划 $i：给阅读留出二十分钟。',
                      status: 'sent',
                      createdAt: i + 2,
                    ),
                  );
            }
            await app.mount(
              tester,
              companionService: service,
              assistantService: assistant,
              assistantCredentials: ConversationTestCredentials(),
              recordPhotoFiles: MemoryRecordPhotoFiles(),
            );
            if (page == 'planning') {
              await tapVisible(tester, find.byTooltip('规划'));
            } else {
              await openMenu(tester, '陪伴');
              await tapVisible(
                tester,
                find.byKey(
                  ValueKey(
                    page == 'chat' ? 'open-chat' : 'open-replies-$testRecordId',
                  ),
                ),
              );
            }
            final input = find.byKey(
              ValueKey(switch (page) {
                'chat' => 'chat-input',
                'reply' => 'sharing-reply-input',
                _ => 'assistant-input',
              }),
            );
            final send = find.byKey(
              ValueKey(switch (page) {
                'chat' => 'send-chat',
                'reply' => 'send-sharing-reply',
                _ => 'assistant-send',
              }),
            );
            final history = switch (page) {
              'chat' => find.byKey(const ValueKey('chat-messages')),
              'reply' => find.byType(ListView).last,
              _ => find.byKey(const ValueKey('assistant-conversation-scroll')),
            };
            final scroll = tester.state<ScrollableState>(
              find
                  .descendant(of: history, matching: find.byType(Scrollable))
                  .first,
            );
            const draft = '合成未发送草稿\n第二行';
            await tester.enterText(input, draft);
            await tester.pumpAndSettle();
            for (final keyboard in [false, true, false]) {
              tester.view.viewInsets = FakeViewPadding(
                bottom: keyboard ? 200 : 0,
              );
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull);
              expect(input.hitTestable(), findsOneWidget);
              expect(send.hitTestable(), findsOneWidget);
              expect(
                tester.getRect(send).bottom,
                lessThanOrEqualTo(keyboard ? 368 : 568),
              );
              final pinned = tester.getRect(input);
              expect(scroll.position.maxScrollExtent, greaterThan(300));
              scroll.position.jumpTo(scroll.position.maxScrollExtent / 2);
              await tester.pumpAndSettle();
              for (final dy in [-70.0, 70.0]) {
                final before = scroll.position.pixels;
                await tester.drag(history, Offset(0, dy));
                await tester.pumpAndSettle();
                expect(scroll.position.pixels, isNot(closeTo(before, 1)));
                expect(tester.getRect(input), pinned);
                expect(tester.widget<TextField>(input).controller!.text, draft);
              }
            }
            await tester.tap(input, kind: PointerDeviceKind.touch);
            await tester.pumpAndSettle();
            expect(tester.testTextInput.isVisible, isTrue);
            await tester.tapAt(
              tester.getTopLeft(history) + const Offset(2, 2),
              kind: PointerDeviceKind.touch,
            );
            await tester.pumpAndSettle();
            expect(tester.testTextInput.isVisible, isFalse);
            expect(tester.widget<TextField>(input).controller!.text, draft);
            expect(service.chatCommands, isEmpty);
            expect(service.sharedCommands, isEmpty);
            expect(assistant.requests, isEmpty);
            expect(tester.takeException(), isNull);
          },
          variant: TargetPlatformVariant.only(TargetPlatform.iOS),
        );
      }
    }
  }

  testUiWidgets(
    'iOS choices and discard dialog retain their actions at large text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 3.5;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      });
      final app = UiHarness();
      await app.mount(tester);
      await tapVisible(tester, find.byKey(const ValueKey('entry-new-goal')));
      await tester.enterText(
        find.byKey(const ValueKey('goal-title')),
        '合成未保存目标',
      );
      await tapVisible(tester, find.byKey(const ValueKey('goal-kind')));
      expect(find.byType(CupertinoActionSheet), findsOneWidget);
      await tapVisible(tester, find.text('单次任务').last);
      await tapVisible(tester, find.text('取消'));
      expect(find.byType(CupertinoAlertDialog), findsOneWidget);
      expect(find.byType(CupertinoDialogAction), findsNWidgets(2));
      await tapVisible(
        tester,
        find.byKey(const ValueKey('continue-editing-goal')),
      );
      expect(find.text('合成未保存目标'), findsOneWidget);
      await tapVisible(tester, find.text('取消'));
      await tapVisible(
        tester,
        find.byKey(const ValueKey('discard-goal-changes')),
      );
      expect(await app.repository.loadGoals(), isEmpty);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
