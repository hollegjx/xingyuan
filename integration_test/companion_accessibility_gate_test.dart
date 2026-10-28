import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/analysis/analysis_providers.dart';
import 'package:habit_checkin/features/assistant/data/device_credential_store.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:integration_test/integration_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import '../test/support/analysis_fixtures.dart';
import '../test/support/chat_service.dart';
import '../test/support/layout_capture.dart';
import '../test/support/pairing_fixtures.dart';
import '../test/support/record_fixtures.dart';
import '../test/support/sharing_fixtures.dart';
import '../test/support/ui_harness.dart';

class _Credentials extends DeviceCredentialStore {
  @override
  Future<String?> read() async => 'a' * 43;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final capture = LayoutCapture();
  setUpAll(() async {
    tzdata.initializeTimeZones();
    await capture.prepare();
  });

  testUiWidgets('system maximum accessibility size keeps six pages usable', (
    tester,
  ) async {
    expect(Platform.isIOS, true);
    expect(
      const bool.fromEnvironment('COMPANION_ACCESSIBILITY_GATE'),
      true,
      reason: 'Opt in only on the dedicated QA simulator.',
    );
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 20);
    tester.view.viewPadding = const FakeViewPadding(top: 20);
    tester.view.viewInsets = const FakeViewPadding();
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.view.resetPadding();
      tester.view.resetViewPadding();
      tester.view.resetViewInsets();
    });
    final h = UiHarness();
    final goal = await h.repository.create(
      const GoalDraft(title: '合成记录', kind: GoalKind.habit),
    );
    final service = TestChatService()..current = testPairingState();
    service.seed(
      (await h.database.select(h.database.goals).get()).single.globalId,
      partner: true,
    );
    final analysis = TestDayAnalysisService();
    await h.mount(
      tester,
      assistantCredentials: _Credentials(),
      companionService: service,
      dayAnalysisService: analysis,
      recordPhotoFiles: MemoryRecordPhotoFiles(),
      recordPhotoPicker: StubRecordPhotoPicker(),
      wrapApp: capture.wrap,
    );
    final scale =
        MediaQuery.textScalerOf(
          tester.element(find.byKey(const ValueKey('entry-new-goal'))),
        ).scale(14) /
        14;
    expect(
      scale,
      greaterThan(3),
      reason: 'Select actual iOS accessibility-extra-extra-extra-large first.',
    );
    expect(tester.platformDispatcher.platformBrightness, Brightness.dark);
    debugPrint('COMPANION_ACCESSIBILITY effective14pxScale=$scale system=dark');

    Future<void> reveal(Finder finder) async {
      if (finder.evaluate().isEmpty) {
        final state = tester.state<ScrollableState>(
          find
              .descendant(
                of: find.byType(ListView).last,
                matching: find.byType(Scrollable),
              )
              .first,
        );
        state.position.jumpTo(state.position.minScrollExtent);
        await tester.pumpAndSettle();
        for (var i = 0; i < 100 && finder.evaluate().isEmpty; i++) {
          state.position.jumpTo(
            (state.position.pixels + 120).clamp(
              state.position.minScrollExtent,
              state.position.maxScrollExtent,
            ),
          );
          await tester.pumpAndSettle();
        }
      }
      expect(finder, findsOneWidget);
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }

    Future<void> tap(Finder finder) async {
      await reveal(finder);
      expect(finder.hitTestable(), findsOneWidget);
      await tester.tap(finder);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }

    Future<void> shot(String name, Finder finder) async {
      await reveal(finder);
      await capture.shot(tester, scale, 'system-max-$name');
    }

    Future<void> disclosure(String name, String text) async {
      final finder = find.text(text);
      await reveal(finder);
      final scroll = Scrollable.of(tester.element(finder));
      final paragraph = tester.renderObject<RenderParagraph>(finder);
      final viewport = tester.getRect(find.byWidget(scroll.widget));
      Rect character(int offset) {
        final box = paragraph
            .getBoxesForSelection(
              TextSelection(baseOffset: offset, extentOffset: offset + 1),
            )
            .single
            .toRect();
        return box.shift(paragraph.localToGlobal(Offset.zero));
      }

      expect(viewport.contains(character(0).center), true);
      expect(scroll.position.maxScrollExtent, greaterThan(0));
      scroll.position.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(viewport.contains(character(text.length - 1).center), true);
      expect(tester.takeException(), isNull);
      await capture.shot(tester, scale, 'system-max-$name-disclosure');
    }

    await tap(find.byKey(ValueKey('record-$goal-${h.clock.day.key}')));
    final recordInput = find.byKey(const ValueKey('record-text'));
    await reveal(recordInput);
    await tester.enterText(recordInput, '合成草稿\n\u{1f44d}');
    await tester.pumpAndSettle();
    final recordSave = find.byKey(const ValueKey('save-record'));
    await shot('record', recordSave);
    await tap(recordSave);
    expect(
      (await h.database.select(h.database.dayRecords).get()).single.content,
      '合成草稿\n\u{1f44d}',
    );

    await tap(find.byKey(const ValueKey('open-day-analysis')));
    await tap(find.byKey(const ValueKey('analyze-today')));
    final consent = find.byKey(const ValueKey('consent-day-analysis'));
    await shot('analysis-consent', consent);
    await disclosure(
      'analysis',
      '将把你当天的目标名称、计划时间和分钟数、完成状态和时间、已保存的文字记录发送到星愿后端和模型服务。照片、未保存草稿、聊天、记忆和其他日期不发送。分析结果仅保存在本机，不分享给他人。',
    );
    await tap(consent);
    expect(analysis.requests, hasLength(1));
    await shot('analysis-result', find.text('TEST 合成分析结果'));
    final store = await h.container.read(dayAnalysisStoreProvider.future);
    final result = (await store.list()).single;
    await tap(find.byKey(ValueKey('analysis-payload-${result.id}')));
    expect(find.textContaining('合成记录'), findsOneWidget);
    await shot('analysis-payload', find.byType(BackButton));
    await tap(find.byType(BackButton));
    await tap(find.byType(BackButton));

    await openMenu(tester, '陪伴');
    final code = find.byKey(const ValueKey('pairing-code-input'));
    await reveal(code);
    await tester.enterText(code, 'ABCDEFGH');
    await tester.pumpAndSettle();
    final join = find.byKey(const ValueKey('join-pairing'));
    await shot('pairing-input', join);
    await tap(join);
    final confirm = find.byKey(const ValueKey('confirm-pairing'));
    await shot('pairing-confirm', confirm);
    await disclosure('pairing', '配对后，个人目标仍然默认私密。只有你主动开启的分享内容才会发送给对方。');
    await tap(confirm);
    expect(find.text('已配对'), findsOneWidget);
    expect(service.commands, hasLength(1));

    await tap(find.byKey(const ValueKey('open-sharing')));
    final replies = find.byKey(ValueKey('open-replies-$testRecordId'));
    await shot('sharing', replies);
    await tap(replies);
    final replyInput = find.byKey(const ValueKey('sharing-reply-input'));
    await reveal(replyInput);
    await tester.enterText(replyInput, '合成回复\n\u{1f44d}');
    await tester.pumpAndSettle();
    final replySend = find.byKey(const ValueKey('send-sharing-reply'));
    await shot('reply', replySend);
    await tap(replySend);
    expect(service.sharedReplies.single['text'], '合成回复\n\u{1f44d}');
    await tap(find.byType(BackButton));
    await tap(find.byType(BackButton));

    await tap(find.byKey(const ValueKey('open-chat')));
    final chatInput = find.byKey(const ValueKey('chat-input'));
    await reveal(chatInput);
    await tester.enterText(chatInput, '合成私聊\n\u{1f44d}');
    await tester.pumpAndSettle();
    final chatSend = find.byKey(const ValueKey('send-chat'));
    await shot('chat-draft', chatSend);
    await tap(chatSend);
    expect(service.chats.single['text'], '合成私聊\n\u{1f44d}');
    await shot('chat-sent', find.text('合成私聊\n\u{1f44d}'));
    expect(await h.repository.loadGoals(), hasLength(1));
    expect(await h.database.select(h.database.checkIns).get(), isEmpty);
    expect(h.permissions.requests, 0);
    expect(tester.takeException(), isNull);
    await capture.passed(tester, scale);
    debugPrint('COMPANION_ACCESSIBILITY six_pages_passed=true');
  });
}
