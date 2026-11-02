import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/assistant/data/device_credential_store.dart';
import 'package:habit_checkin/features/assistant/data/local_memory_store.dart';
import 'package:habit_checkin/shared/presentation.dart';
import 'package:habit_checkin/features/assistant/data/assistant_service.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'support/test_assistant_service.dart';
import 'journal_diary_capture_test.dart' as pixels;
import 'support/pairing_fixtures.dart';
import 'support/sharing_fixtures.dart';
import 'support/ui_harness.dart';
import 'today_c49_test.dart' show viewport;

class _Credentials extends DeviceCredentialStore {
  @override
  Future<String?> read() async => 'a' * 43;
}

const _copy = [
  '确认后，你发给助手的内容会经过星愿后端、所有者的模型中转 model-relay.example.com，由 gpt-6-luna 处理。星愿后端不保存正文，中转的留存规则以中转方为准。',
  '每次对话会发送：当前对话、会话摘要、有效记忆、今天起 14 天的已有安排，以及活跃目标近 14 天的完成次数。记忆、已有安排和完成情况可以在 AI 设置里分别关闭。',
  '你让助手写日记或回顾某一天时，它会读取那一天的目标完成情况、打卡文字、随手记和日记文字，只限今天和之前 7 天。读今天不再询问；读更早的日子会先问你。每次读了什么，对话里都会写明。',
  '照片从不发送。助手不会自己翻看你的历史记录，也不会把你没点名的日子发出去。生成的日记只是草稿，你确认之前不会保存。',
  '可以在 AI 设置里关闭“按请求读取随手记和日记”，关闭后助手照样能聊天和排日程。不确认授权也能继续使用目标、打卡、日记和本地提醒；确认前不会访问 AI 服务。',
];

int _fullParagraph(WidgetTester tester, Finder text, String expected) {
  final widget = tester.widget<Text>(text);
  expect(widget.data, expected);
  expect(widget.maxLines, isNull);
  expect(widget.overflow, isNot(TextOverflow.ellipsis));
  final paragraph = tester.renderObject<RenderParagraph>(
    find.descendant(of: text, matching: find.byType(RichText)),
  );
  expect(paragraph.didExceedMaxLines, isFalse);
  final painter = TextPainter(
    text: paragraph.text,
    textDirection: paragraph.textDirection,
    textScaler: paragraph.textScaler,
  )..layout(maxWidth: paragraph.size.width);
  try {
    expect(paragraph.size.height, closeTo(painter.height, .01));
    // C60: a wrapping trailing space can have a selection box outside the
    // paragraph. Check every visible character; keep full text/height checks.
    for (var index = 0; index < expected.length; index++) {
      if (expected[index].trim().isEmpty) continue;
      final boxes = paragraph.getBoxesForSelection(
        TextSelection(baseOffset: index, extentOffset: index + 1),
      );
      expect(boxes, isNotEmpty);
      for (final box in boxes) {
        expect(box.left, greaterThanOrEqualTo(-.01));
        expect(box.right, lessThanOrEqualTo(paragraph.size.width + .01));
        expect(box.bottom, lessThanOrEqualTo(paragraph.size.height + .01));
      }
    }
    return painter.computeLineMetrics().length;
  } finally {
    painter.dispose();
  }
}

void main() {
  setUpAll(() async {
    tzdata.initializeTimeZones();
    await pixels.loadDiaryCaptureFont();
  });
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 3.5]) {
      for (final paired in [false, true]) {
        testUiWidgets('C57 hero ${brightness.name} ${scale}x paired=$paired', (
          tester,
        ) async {
          viewport(tester, brightness, scale);
          final app = UiHarness();
          final service = TestSharingService()
            ..current = testPairingState(paired: paired);
          final boundary = GlobalKey();
          await app.mount(
            tester,
            assistantCredentials: _Credentials(),
            companionService: service,
            wrapApp: (child) => RepaintBoundary(key: boundary, child: child),
          );
          await openMenu(tester, '陪伴');
          final title = find.byKey(const ValueKey('companion-hero-title'));
          final status = find.byKey(const ValueKey('companion-hero-status'));
          final stars = find.byWidgetPredicate(
            (widget) => widget.runtimeType.toString() == '_TwinStars',
          );
          final stacked = find.byKey(const ValueKey('companion-hero-stacked'));
          final titleText = paired ? '已配对' : '尚未配对';
          final statusText = paired ? '只有你主动分享的内容，TA 才看得到' : '邀请一位朋友，互相陪伴';
          expect(tester.widget<Text>(title).data, titleText);
          final lines = _fullParagraph(tester, status, statusText);
          if (scale == 1) {
            expect(stacked, findsNothing);
            final row = find
                .ancestor(of: stars, matching: find.byType(Row))
                .first;
            expect(find.descendant(of: row, matching: title), findsOneWidget);
            expect(
              tester.getRect(stars).right,
              lessThanOrEqualTo(tester.getRect(title).left),
            );
          } else {
            expect(stacked, findsOneWidget);
            expect(
              tester.getRect(stars).bottom,
              lessThanOrEqualTo(tester.getRect(title).top),
            );
            if (paired) expect(lines, greaterThan(3));
          }
          if (pixels.captureFont.isNotEmpty) {
            await pixels.capture(
              tester,
              boundary,
              'c57-hero-${brightness.name}-$scale-${paired ? 'paired' : 'unpaired'}',
              const Size(320, 568),
              text: title,
              expectedText: titleText,
            );
          }
          if (paired) {
            final chat = find.byKey(const ValueKey('open-chat'));
            await tester.ensureVisible(chat);
            await tester.pumpAndSettle();
            final icon = find.descendant(
              of: chat,
              matching: find.byType(XyIconTile),
            );
            expect(
              tester.widget<XyIconTile>(icon).color,
              Theme.of(tester.element(icon)).colorScheme.primary,
            );
          }
          expect(service.commands, isEmpty);
          expect(service.sharedCommands, isEmpty);
          expect(await app.repository.loadGoals(), isEmpty);
          expect(app.permissions.requests, 0);
          expect(tester.takeException(), isNull);
        });
      }
      testUiWidgets('C73 consent ${brightness.name} ${scale}x', (tester) async {
        viewport(tester, brightness, scale);
        final app = UiHarness();
        final service = ConversationTestService();
        final boundary = GlobalKey();
        await app.mount(
          tester,
          assistantService: service,
          assistantCredentials: _Credentials(),
          wrapApp: (child) => RepaintBoundary(key: boundary, child: child),
        );
        final memories = LocalMemoryStore(app.repository);
        expect((await memories.settings()).consentVersion, 0);
        await tapVisible(tester, find.byTooltip('助手'));
        const names = ['route', 'content', 'records', 'boundary', 'choice'];
        const headers = ['去向', '内容', '你的记录', '隐私边界', '你的选择'];
        const indices = [
          [0],
          [1],
          [2],
          [3],
          [4],
        ];
        var lastBottom = double.negativeInfinity;
        for (var i = 0; i < names.length; i++) {
          final group = find.byKey(
            ValueKey(
              names[i] == 'records'
                  ? 'assistant-record-consent'
                  : 'consent-group-${names[i]}',
            ),
          );
          expect(tester.widget<XyGroup>(group).header, headers[i]);
          final rect = tester.getRect(group);
          expect(rect.top, greaterThanOrEqualTo(lastBottom));
          lastBottom = rect.bottom;
          for (final index in indices[i]) {
            final point = find.text(_copy[index]);
            expect(point, findsOneWidget);
            expect(find.descendant(of: group, matching: point), findsOneWidget);
            _fullParagraph(tester, point, _copy[index]);
          }
        }
        final paragraphOrder = find
            .byType(Text)
            .evaluate()
            .map((element) => (element.widget as Text).data)
            .where((text) => _copy.contains(text))
            .toList();
        expect(paragraphOrder, _copy);
        expect(service.requests, isEmpty);
        expect((await memories.settings()).consentVersion, 0);
        if (pixels.captureFont.isNotEmpty) {
          await pixels.capture(
            tester,
            boundary,
            'c59-consent-${brightness.name}-$scale-top',
            const Size(320, 568),
            text: find.text('助手').first,
            expectedText: '规划',
          );
        }
        final confirm = find.byKey(const ValueKey('assistant-consent-confirm'));
        await tester.ensureVisible(confirm);
        await tester.pumpAndSettle();
        expect(confirm.hitTestable(), findsOneWidget);
        expect(tester.getSize(confirm).height, greaterThanOrEqualTo(44));
        expect(tester.takeException(), isNull);
        if (pixels.captureFont.isNotEmpty) {
          await pixels.capture(
            tester,
            boundary,
            'c59-consent-${brightness.name}-$scale-bottom',
            const Size(320, 568),
            text: find.text('同意并继续'),
            expectedText: '同意并继续',
          );
        }
        await tester.tap(confirm);
        await tester.pumpAndSettle();
        final settings = await memories.settings();
        expect(settings.consentVersion, assistantConsentVersion);
        expect(settings.consentedAt, isNotNull);
        expect(find.byKey(const ValueKey('assistant-input')), findsOneWidget);
        expect(service.requests, isEmpty);
        expect(await app.repository.loadGoals(), isEmpty);
        expect(app.permissions.requests, 0);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
