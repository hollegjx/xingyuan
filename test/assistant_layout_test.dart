import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/app/providers.dart';
import 'package:habit_checkin/features/assistant/assistant_providers.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'support/layout_capture.dart';
import 'support/test_assistant_service.dart';
import 'support/ui_harness.dart';

void main() {
  final capture = LayoutCapture();
  setUpAll(() async {
    tzdata.initializeTimeZones();
    await capture.prepare();
  });

  for (final scale in [1.0, 2.0, 3.0]) {
    testUiWidgets(
      'iOS layout at 320px ${scale}x completes editing and confirmation',
      (tester) async {
        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1;
        tester.view.padding = const FakeViewPadding(top: 20);
        tester.view.viewPadding = const FakeViewPadding(top: 20);
        tester.view.viewInsets = const FakeViewPadding();
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPadding);
        addTearDown(tester.view.resetViewPadding);
        addTearDown(tester.view.resetViewInsets);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

        Future<void> usable(Finder finder) async {
          await tester.ensureVisible(finder);
          await tester.pumpAndSettle();
          expect(finder.hitTestable(), findsOneWidget);
          final button = find.ancestor(
            of: finder,
            matching: find.byType(IconButton),
          );
          final target = button.evaluate().isNotEmpty ? button.first : finder;
          expect(target.hitTestable(), findsOneWidget);
          final rect = tester.getRect(target);
          expect(rect.width, greaterThanOrEqualTo(44));
          expect(rect.height, greaterThanOrEqualTo(44));
          expect(rect.top, greaterThanOrEqualTo(0));
          expect(
            rect.bottom,
            lessThanOrEqualTo(568 - tester.view.viewInsets.bottom),
          );
        }

        Future<void> tap(Finder finder) async {
          await usable(finder);
          await tester.tap(finder);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }

        Future<void> keyboard(bool shown) async {
          tester.view.viewInsets = FakeViewPadding(bottom: shown ? 200 : 0);
          await tester.pumpAndSettle();
        }

        Future<void> enter(Finder finder, String value) async {
          await tester.ensureVisible(finder);
          await tester.tap(finder);
          await tester.pumpAndSettle();
          await tester.enterText(finder, value);
          await tester.pumpAndSettle();
        }

        Future<void> shot(String name) => capture.shot(tester, scale, name);

        final app = UiHarness()..clock.setDay(2026, 10, 20, hour: 21);
        final service = ConversationTestService()
          ..onTurn = (request) async =>
              syntheticReply(request, plan: true, memory: true);
        await app.mount(
          tester,
          assistantService: service,
          assistantCredentials: ConversationTestCredentials(),
          wrapApp: capture.wrap,
        );
        await tap(find.byTooltip('规划'));
        expect(service.requests, isEmpty);
        await shot('consent-top');
        final consent = find.byKey(const ValueKey('assistant-consent-confirm'));
        await usable(consent);
        await shot('consent-confirm');
        await tap(consent);

        final input = find.byKey(const ValueKey('assistant-input'));
        await enter(input, 'TEST 明晚阅读并整理章节笔记');
        await keyboard(true);
        final send = find.byKey(const ValueKey('assistant-send'));
        await usable(send);
        await shot('composer-keyboard');
        await tap(send);
        await keyboard(false);
        final controller = await app.container.read(
          assistantConversationProvider.future,
        );
        expect(service.requests, hasLength(1));
        expect(controller.messages, hasLength(2));
        expect(controller.proposals, hasLength(1));
        expect(await app.repository.loadGoals(), isEmpty);
        final proposal = controller.proposals.single;
        final open = find.byKey(ValueKey('open-proposal-${proposal.id}'));
        await usable(open);
        await shot('conversation-proposal');
        await tap(open);
        await shot('preview-top');
        await tap(find.byTooltip('编辑条目'));

        final title = find.byKey(const ValueKey('assistant-plan-title'));
        await enter(title, 'TEST 周三晚上的阅读与章节整理计划');
        await keyboard(true);
        await tester.ensureVisible(title);
        await tester.pumpAndSettle();
        await shot('editor-title-keyboard');
        await keyboard(false);
        FocusManager.instance.primaryFocus?.unfocus();
        await tap(find.byKey(const ValueKey('clear-start-time')));
        await tap(find.byKey(const ValueKey('start-time')));
        final confirmTime = find.byKey(const ValueKey('time-picker-confirm'));
        {
          final wheels = find.byWidgetPredicate(
            (widget) =>
                widget is CupertinoPicker && widget.scrollController != null,
          );
          expect(wheels, findsNWidgets(2));
          await usable(wheels.at(0));
          await usable(wheels.at(1));
          await shot('time-picker-initial');
          await tester.drag(wheels.at(1), const Offset(0, -96));
          await tester.pumpAndSettle();
          final minuteWheel = tester.widget<CupertinoPicker>(wheels.at(1));
          expect(minuteWheel.scrollController!.selectedItem % 60, isNot(30));
          await shot('time-picker-changed');
          minuteWheel.scrollController!.jumpToItem(30);
          await tester.pumpAndSettle();
        }
        await usable(confirmTime);
        await shot('time-picker');
        await tap(confirmTime);
        await keyboard(false);
        final minutes = find.byKey(const ValueKey('duration-minutes'));
        await tester.ensureVisible(minutes);
        await enter(minutes, '45');
        await keyboard(true);
        await tester.ensureVisible(minutes);
        await tester.pumpAndSettle();
        await shot('editor-minutes-keyboard');
        final save = find.byKey(const ValueKey('assistant-save-plan-item'));
        await usable(save);
        expect(
          tester.getBottomRight(find.text('编辑条目')).dy,
          lessThan(tester.getTopLeft(find.text('名称')).dy),
        );
        await shot('editor-save-keyboard');
        await tap(save);
        await keyboard(false);
        final apply = find.byKey(const ValueKey('assistant-apply-plan'));
        await usable(apply);
        await shot('preview-confirm');
        await tap(apply);
        final goal = (await app.repository.loadGoals()).single;
        expect(goal.titleOn(app.clock.day), 'TEST 周三晚上的阅读与章节整理计划');
        expect(goal.scheduleOn(app.clock.day).timing.label, '19:30 · 45 分钟');
        expect(goal.reminder.enabled, isFalse);
        await tester.ensureVisible(find.text('已创建 1 项'));
        await tester.pumpAndSettle();
        await shot('receipt');
        await tap(find.byType(BackButton));
        await tap(find.byTooltip('今天'));
        app.clock.setDay(2026, 10, 21);
        await app.container.read(environmentProvider.notifier).refresh();
        await tester.pumpAndSettle();
        final detail = find.byKey(ValueKey('detail-${goal.id}'));
        await usable(detail);
        await shot('today');

        await tap(find.byKey(const ValueKey('entry-new-goal')));
        await enter(find.byKey(const ValueKey('goal-title')), 'TEST 手动阅读习惯');
        await tap(find.byKey(const ValueKey('start-time')));
        await tap(find.byKey(const ValueKey('time-picker-confirm')));
        await tester.ensureVisible(minutes);
        await enter(minutes, '30');
        await keyboard(true);
        await tester.ensureVisible(minutes);
        await tester.pumpAndSettle();
        await shot('manual-minutes-keyboard');
        final saveGoal = find.byKey(const ValueKey('save-goal'));
        await usable(saveGoal);
        await shot('manual-save-keyboard');
        await tap(saveGoal);
        await keyboard(false);
        expect(await app.repository.loadGoals(), hasLength(2));
        expect(app.permissions.requests, 0);
        expect(app.notifications.requests, isEmpty);
        expect(tester.takeException(), isNull);
        await capture.passed(tester, scale);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  }
}
