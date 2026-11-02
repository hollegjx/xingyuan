import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/assistant/assistant_providers.dart';
import 'package:habit_checkin/shared/presentation.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'assistant_settings_ui_test.dart' as fixtures;
import 'journal_diary_capture_test.dart' as pixels;
import 'support/ui_harness.dart';

const _scopeFooter =
    '关掉「发送已有安排」，规划就看不到你的日程，也没法找空档；'
    '关掉「发送记忆」，规划不会参考你的偏好。';
const _agentFooter = '关闭后改用旧版规划：直接给出方案，不会先查空档再排。';

void main() {
  setUpAll(() async {
    tzdata.initializeTimeZones();
    await pixels.loadDiaryCaptureFont();
  });
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 3.0]) {
      testUiWidgets(
        'C46 settings order and controls ${brightness.name} $scale',
        (tester) async {
          tester.view.physicalSize = const Size(320, 568);
          tester.view.devicePixelRatio = 1;
          tester.platformDispatcher.platformBrightnessTestValue = brightness;
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(
            tester.platformDispatcher.clearPlatformBrightnessTestValue,
          );
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          final app = UiHarness();
          final service = fixtures.SettingsTestService();
          final credentials = fixtures.TestDeviceCredentials();
          final boundary = GlobalKey();
          await app.mount(
            tester,
            assistantService: service,
            assistantCredentials: credentials,
            wrapApp: (child) => RepaintBoundary(key: boundary, child: child),
          );
          await fixtures.openAi(tester);
          final groups = tester
              .widgetList<XyGroup>(find.byType(XyGroup))
              .toList();
          expect(groups.map((group) => group.header), [
            '发送范围',
            '规划',
            '记忆',
            '服务状态',
            '设备凭证',
          ]);
          expect(groups.first.margin, const EdgeInsets.only(top: 12));
          expect(groups.first.footer, _scopeFooter);
          expect(groups[1].footer, _agentFooter);
          expect(find.text('AI 设置'), findsOneWidget);
          final before = await app.container.read(
            assistantSettingsProvider.future,
          );
          expect(before.sendSchedule, isTrue);
          expect(before.sendMemories, isTrue);
          expect(before.agentEnabled, isTrue);
          expect(before.consentedAt, isNull);
          expect(service.healthCalls, 0);
          for (final (label, footer) in [
            ('scope', _scopeFooter),
            ('agent', _agentFooter),
          ]) {
            await tester.ensureVisible(find.text(footer));
            await tester.pumpAndSettle();
            final rect = tester.getRect(find.text(footer));
            expect(rect.left, greaterThanOrEqualTo(0));
            expect(rect.right, lessThanOrEqualTo(320));
            if (pixels.captureFont.isNotEmpty) {
              await pixels.capture(
                tester,
                boundary,
                'c46-${brightness.name}-$scale-$label',
                const Size(320, 568),
                text: find.text(footer),
                expectedText: footer,
              );
            }
          }
          await tapVisible(
            tester,
            find.widgetWithText(SwitchListTile, '发送已有安排'),
          );
          var settings = await app.container.read(
            assistantSettingsProvider.future,
          );
          expect(settings.sendSchedule, isFalse);
          expect(settings.sendMemories, isTrue);
          expect(settings.agentEnabled, isTrue);
          await tapVisible(tester, find.widgetWithText(SwitchListTile, '发送记忆'));
          await tapVisible(
            tester,
            find.byKey(const ValueKey('assistant-agent-enabled')),
          );
          settings = await app.container.read(assistantSettingsProvider.future);
          expect(settings.sendMemories, isFalse);
          expect(settings.sendSchedule, isFalse);
          expect(settings.agentEnabled, isFalse);
          expect(settings.sendStats, before.sendStats);
          expect(settings.autoMemory, before.autoMemory);
          expect(settings.consentedAt, isNull);
          expect(service.healthCalls, 0);
          expect(credentials.value, isNull);
          expect(await app.repository.loadGoals(), isEmpty);
          expect(
            await app.database.select(app.database.planProposals).get(),
            isEmpty,
          );
          await goBack(tester);
          await tapVisible(tester, find.text('AI 设置'));
          settings = await app.container.read(assistantSettingsProvider.future);
          expect(settings.agentEnabled, isFalse);
          expect(settings.sendSchedule, isFalse);
          expect(settings.sendMemories, isFalse);
          expect(service.healthCalls, 0);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
