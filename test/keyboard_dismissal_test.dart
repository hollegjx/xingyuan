import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/companion/companion_providers.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'support/chat_service.dart';
import 'support/pairing_fixtures.dart';
import 'support/record_fixtures.dart';
import 'support/sharing_fixtures.dart';
import 'support/test_assistant_service.dart';
import 'support/ui_harness.dart';

Future<void> dismissFromMargin(
  WidgetTester tester,
  Finder field, {
  Offset? outside,
}) async {
  await tester.ensureVisible(field);
  await tester.pumpAndSettle();
  final editable = tester.widget<EditableText>(
    find.descendant(of: field, matching: find.byType(EditableText)),
  );
  final value = editable.controller.value;
  expect(editable.focusNode.hasFocus, isTrue);
  expect(tester.testTextInput.isVisible, isTrue);
  await tester.tapAt(
    outside ?? tester.getTopLeft(field) + const Offset(-6, 24),
    kind: PointerDeviceKind.touch,
  );
  await tester.pumpAndSettle();
  expect(editable.focusNode.hasFocus, isFalse);
  expect(tester.testTextInput.isVisible, isFalse);
  expect(editable.controller.value, value);
}

void main() {
  setUpAll(tzdata.initializeTimeZones);

  testUiWidgets(
    'touching the goal form margin dismisses the keyboard without losing text',
    (tester) async {
      final app = UiHarness();
      await app.mount(tester);
      await tapVisible(tester, find.byKey(const ValueKey('entry-new-goal')));
      final field = find.byKey(const ValueKey('goal-title'));
      await tester.enterText(field, 'SYNTHETIC unsaved goal');
      await dismissFromMargin(tester, field);
      expect(await app.repository.loadGoals(), isEmpty);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testUiWidgets(
    'planning outside touch keeps the unsent draft and does not call the model',
    (tester) async {
      final service = ConversationTestService();
      await UiHarness().mount(
        tester,
        assistantService: service,
        assistantCredentials: ConversationTestCredentials(),
      );
      await tapVisible(tester, find.byTooltip('规划'));
      await tapVisible(
        tester,
        find.byKey(const ValueKey('assistant-consent-confirm')),
      );
      final field = find.byKey(const ValueKey('assistant-input'));
      await tester.enterText(field, 'SYNTHETIC unsent\nsecond line');
      await dismissFromMargin(tester, field);
      await tester.tap(field);
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isTrue);
      await tapVisible(tester, find.byTooltip('今天'));
      expect(tester.testTextInput.isVisible, isFalse);
      await tapVisible(tester, find.byTooltip('规划'));
      expect(tester.testTextInput.isVisible, isFalse);
      expect(
        tester.widget<TextField>(field).controller!.text,
        'SYNTHETIC unsent\nsecond line',
      );
      expect(service.requests, isEmpty);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testUiWidgets('pairing outside touch preserves the code without joining', (
    tester,
  ) async {
    final service = TestCompanionService();
    final app = UiHarness();
    await app.mount(
      tester,
      companionService: service,
      assistantCredentials: ConversationTestCredentials(),
    );
    await openMenu(tester, '陪伴');
    final field = find.byKey(const ValueKey('pairing-code-input'));
    await tester.enterText(field, 'ABCD');
    await dismissFromMargin(tester, field);
    final pairing = await app.container.read(pairingControllerProvider.future);
    expect((await pairing.store.snapshot()).row.draftCode, 'ABCD');
    expect(service.commands, isEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  for (final chat in [false, true]) {
    testUiWidgets(
      '${chat ? 'chat' : 'reply'} outside touch keeps text without sending',
      (tester) async {
        final service = TestChatService();
        final app = UiHarness();
        await app.repository.create(
          const GoalDraft(title: 'SYNTHETIC goal', kind: GoalKind.habit),
        );
        service.seed(
          (await app.database.select(app.database.goals).get()).single.globalId,
          partner: true,
        );
        await app.mount(
          tester,
          companionService: service,
          assistantCredentials: ConversationTestCredentials(),
          recordPhotoFiles: MemoryRecordPhotoFiles(),
        );
        await openMenu(tester, '陪伴');
        await tapVisible(
          tester,
          find.byKey(
            ValueKey(chat ? 'open-chat' : 'open-replies-$testRecordId'),
          ),
        );
        final field = find.byKey(
          ValueKey(chat ? 'chat-input' : 'sharing-reply-input'),
        );
        await tester.enterText(field, 'SYNTHETIC unsent\nsecond line');
        await dismissFromMargin(
          tester,
          field,
          outside: chat ? tester.getCenter(find.text('私聊').first) : null,
        );
        await goBack(tester);
        await tapVisible(
          tester,
          find.byKey(
            ValueKey(chat ? 'open-chat' : 'open-replies-$testRecordId'),
          ),
        );
        expect(
          tester.widget<TextField>(field).controller!.text,
          'SYNTHETIC unsent\nsecond line',
        );
        expect(service.commands, isEmpty);
        expect(service.sharedCommands, isEmpty);
        expect(service.chatCommands, isEmpty);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  }

  testUiWidgets(
    'record outside touch retains the draft without publishing it',
    (tester) async {
      final app = UiHarness();
      final goal = await app.repository.create(
        const GoalDraft(title: 'SYNTHETIC goal', kind: GoalKind.habit),
      );
      await app.mount(tester, recordPhotoFiles: MemoryRecordPhotoFiles());
      await tapVisible(
        tester,
        find.byKey(ValueKey('record-$goal-${app.clock.day.key}')),
      );
      final field = find.byKey(const ValueKey('record-text'));
      await tester.enterText(field, 'SYNTHETIC private draft');
      await dismissFromMargin(tester, field);
      final record =
          (await app.database.select(app.database.dayRecords).get()).single;
      expect(record.draftText, 'SYNTHETIC private draft');
      expect(record.savedAt, isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testUiWidgets(
    'field switching, selection, grouped controls and one-tap actions still work',
    (tester) async {
      await UiHarness().mount(tester);
      final first = FocusNode();
      final second = FocusNode();
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      var groupedTaps = 0;
      var actionTaps = 0;
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      unawaited(
        navigator.push<void>(
          MaterialPageRoute(
            builder: (_) => Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    TextField(key: const ValueKey('first'), focusNode: first),
                    TextFormField(
                      key: const ValueKey('second'),
                      focusNode: second,
                      keyboardType: TextInputType.number,
                    ),
                    TextFieldTapRegion(
                      child: TextButton(
                        onPressed: () => groupedTaps++,
                        child: const Text('Grouped control'),
                      ),
                    ),
                    TextButton(
                      onPressed: () => actionTaps++,
                      child: const Text('Ordinary action'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final firstField = find.byKey(const ValueKey('first'));
      final secondField = find.byKey(const ValueKey('second'));
      await tester.enterText(firstField, 'SYNTHETIC selectable text');
      await tester.tap(firstField);
      await tester.pumpAndSettle();
      expect(first.hasFocus, isTrue);
      final textPosition = tester.getTopLeft(firstField) + const Offset(40, 24);
      await tester.tapAt(textPosition);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(textPosition);
      await tester.pumpAndSettle();
      final editable = tester.widget<EditableText>(
        find.descendant(of: firstField, matching: find.byType(EditableText)),
      );
      expect(editable.controller.selection.isCollapsed, isFalse);
      expect(first.hasFocus, isTrue);

      await tester.tap(secondField);
      await tester.pumpAndSettle();
      expect(first.hasFocus, isFalse);
      expect(second.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
      await tester.enterText(secondField, '25');
      await tapVisible(tester, find.text('Grouped control'));
      expect(groupedTaps, 1);
      expect(second.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
      await tapVisible(tester, find.text('Ordinary action'));
      expect(actionTaps, 1);
      expect(second.hasFocus, isFalse);
      expect(tester.testTextInput.isVisible, isFalse);
      await tester.tap(secondField);
      await tester.pumpAndSettle();
      await dismissFromMargin(tester, secondField);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testUiWidgets(
    'outside touch also dismisses numeric input inside a dialog route',
    (tester) async {
      await UiHarness().mount(tester);
      final context = tester.element(find.byType(NavigationBar));
      unawaited(
        showDialog<void>(
          context: context,
          builder: (_) => const AlertDialog(
            title: Text('SYNTHETIC dialog'),
            content: CupertinoTextField(
              key: ValueKey('dialog-input'),
              keyboardType: TextInputType.number,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('dialog-input'));
      await tester.enterText(field, '25');
      await dismissFromMargin(tester, field);
      expect(find.byType(AlertDialog), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
