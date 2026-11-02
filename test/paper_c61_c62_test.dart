import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/app/theme.dart';
import 'package:habit_checkin/features/journal/domain/journal_entry.dart';
import 'package:habit_checkin/features/journal/presentation/journal_editor_page.dart';
import 'package:habit_checkin/shared/presentation.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'journal_diary_capture_test.dart' as pixels;
import 'support/journal_fixtures.dart';
import 'support/record_fixtures.dart';
import 'support/ui_harness.dart';
import 'today_c49_test.dart' show viewport;

void main() {
  setUpAll(() async {
    tzdata.initializeTimeZones();
    await pixels.loadDiaryCaptureFont();
  });
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 3.5]) {
      testUiWidgets('C61 C62 paper journey ${brightness.name} $scale', (
        tester,
      ) async {
        viewport(tester, brightness, scale);
        final app = UiHarness()..clock.setDay(2026, 11, 1);
        final boundary = GlobalKey();
        await app.mount(
          tester,
          journalPhotoFiles: {
            for (final kind in JournalKind.values)
              kind: MemoryJournalPhotoFiles(kind),
          },
          recordPhotoPicker: StubRecordPhotoPicker(),
          wrapApp: (child) => RepaintBoundary(key: boundary, child: child),
        );
        Future<void> shot(
          String page,
          Finder text,
          String expected, {
          bool editable = false,
          bool firstLineOnly = false,
        }) async {
          if (pixels.captureFont.isEmpty) return;
          await pixels.capture(
            tester,
            boundary,
            'paper-$page-${brightness.name}-$scale',
            const Size(320, 568),
            text: text,
            expectedText: expected,
            editable: editable,
            firstLineOnly: firstLineOnly,
          );
        }

        final context = tester.element(
          find.byKey(const ValueKey('today-summary')),
        );
        final theme = Theme.of(context);
        expect(theme.textTheme.headlineSmall!.fontFamily, xySerif);
        expect(
          theme.colorScheme.primary,
          brightness == Brightness.light
              ? const Color(0xFF4E7D72)
              : const Color(0xFF8DBBAE),
        );
        expect(
          theme.scaffoldBackgroundColor,
          brightness == Brightness.light
              ? const Color(0xFFF5F6F2)
              : const Color(0xFF141816),
        );
        expect(find.byKey(const ValueKey('entry-check-in')), findsNothing);
        final newGoal = find.byKey(const ValueKey('entry-new-goal'));
        expect(tester.widget<IconButton>(newGoal).tooltip, '新目标');
        expect(tester.getSize(newGoal).width, greaterThanOrEqualTo(44));
        expect(tester.getSize(newGoal).height, greaterThanOrEqualTo(44));
        final greeting = find.textContaining(
          RegExp(r'^(早上好|中午好|下午好|晚上好|夜深了)$'),
        );
        expect(
          MediaQuery.textScalerOf(tester.element(greeting)).scale(20),
          closeTo(20 * (scale > 1.6 ? 1.6 : scale), .01),
        );
        expect(
          MediaQuery.textScalerOf(tester.element(find.text('今天也慢慢来。')))
              .scale(20),
          closeTo(20 * scale, .01),
        );
        await shot(
          'today',
          greeting,
          tester.widget<Text>(greeting).data!,
          firstLineOnly: true,
        );

        await tapVisible(
          tester,
          find.byKey(const ValueKey('entry-quick-note')),
        );
        expect(find.byType(JournalEditorPage), findsOneWidget);
        final input = find.byKey(const ValueKey('journal-text'));
        final field = tester.widget<TextField>(input);
        expect(field.style!.fontFamily, xySerif);
        expect(field.style!.fontSize, 18);
        expect(field.style!.height, 1.85);
        expect(field.decoration!.filled, isFalse);
        expect(
          MediaQuery.textScalerOf(tester.element(input)).scale(18),
          closeTo(18 * scale, .01),
        );
        final save = find.byKey(const ValueKey('save-journal'));
        expect(
          MediaQuery.textScalerOf(tester.element(save)).scale(20),
          closeTo(20 * (scale > 1.6 ? 1.6 : scale), .01),
        );
        expect(save.hitTestable(), findsOneWidget);
        expect(tester.getSize(save).height, greaterThanOrEqualTo(44));
        await tester.enterText(input, '测试记录');
        await tester.pumpAndSettle();
        await shot('quick-note', input, '测试记录', editable: true);
        await goBack(tester);

        await tapVisible(tester, find.byTooltip('我的'));
        final groups = tester
            .widgetList<XyGroup>(find.byType(XyGroup))
            .toList();
        for (final footer in [
          '随手记和日记只存在这台手机上。用 AI 润色时只发送这一条；生成日记时发送当天的打卡和随手记文字。照片从不发送。',
          '提醒会提前排好。很久不打开星愿，排好的提醒可能会用完；打开一次就会补上。',
          '目标和打卡都保存在这台手机上，暂时没有云端备份。删除星愿会一并删除这些记录。',
        ]) {
          expect(groups.where((group) => group.footer == footer), hasLength(1));
        }
        expect(find.text('连接、发送范围和记忆'), findsOneWidget);
        await shot(
          'my',
          find.descendant(
            of: find.byType(TabHeader),
            matching: find.text('我的'),
          ),
          '我的',
        );
        await tapVisible(tester, find.byTooltip('回顾'));
        await shot(
          'review',
          find.descendant(
            of: find.byType(TabHeader),
            matching: find.text('回顾'),
          ),
          '回顾',
        );
        expect(await app.repository.loadGoals(), isEmpty);
        expect(await app.database.select(app.database.checkIns).get(), isEmpty);
        expect(app.permissions.requests, 0);
        expect(app.notifications.requests, isEmpty);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
