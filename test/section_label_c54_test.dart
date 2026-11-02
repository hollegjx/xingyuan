import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/app/theme.dart';
import 'package:habit_checkin/features/assistant/data/device_credential_store.dart';
import 'package:habit_checkin/features/companion/presentation/sharing_page.dart';
import 'package:habit_checkin/shared/presentation.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'journal_diary_capture_test.dart' as pixels;
import 'support/sharing_fixtures.dart';
import 'support/ui_harness.dart';
import 'today_c49_test.dart' show viewport;

class _Credentials extends DeviceCredentialStore {
  @override
  Future<String?> read() async => 'a' * 43;
}

void main() {
  setUpAll(() async {
    tzdata.initializeTimeZones();
    await pixels.loadDiaryCaptureFont();
  });
  const stackedKey = ValueKey('section-label-stacked');
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 3.5]) {
      testUiWidgets('C54 companion section ${brightness.name} ${scale}x', (
        tester,
      ) async {
        viewport(tester, brightness, scale);
        final app = UiHarness();
        final service = TestSharingService();
        final boundary = GlobalKey();
        await app.mount(
          tester,
          assistantCredentials: _Credentials(),
          companionService: service,
          wrapApp: (child) => RepaintBoundary(key: boundary, child: child),
        );
        await openMenu(tester, '陪伴');
        final section = find.byWidgetPredicate(
          (widget) => widget is SectionLabel && widget.title == '最近的分享',
        );
        final title = find.descendant(
          of: section,
          matching: find.text('最近的分享'),
        );
        final action = find.descendant(
          of: section,
          matching: find.byKey(const ValueKey('open-sharing')),
        );
        final stacked = find.descendant(
          of: section,
          matching: find.byKey(stackedKey),
        );
        await tester.ensureVisible(title);
        await tester.pumpAndSettle();
        final titleRect = tester.getRect(title);
        final actionRect = tester.getRect(action);
        if (scale == 1) {
          expect(stacked, findsNothing);
          expect(
            (actionRect.center.dy - titleRect.center.dy).abs(),
            lessThanOrEqualTo(4),
          );
        } else {
          expect(stacked, findsOneWidget);
          final paragraph = tester.renderObject<RenderParagraph>(
            find.descendant(of: title, matching: find.byType(RichText)),
          );
          final painter = TextPainter(
            text: paragraph.text,
            textDirection: paragraph.textDirection,
            textScaler: paragraph.textScaler,
          )..layout(maxWidth: paragraph.size.width);
          try {
            expect(painter.computeLineMetrics().length, lessThanOrEqualTo(2));
            expect(
              titleRect.height,
              lessThanOrEqualTo(2 * painter.preferredLineHeight + 1),
            );
          } finally {
            painter.dispose();
          }
          expect(actionRect.top, greaterThanOrEqualTo(titleRect.bottom));
        }
        expect(tester.getSize(action).height, greaterThanOrEqualTo(44));
        expect(tester.widget<TextButton>(action).onPressed, isNotNull);
        expect(tester.takeException(), isNull);
        if (pixels.captureFont.isNotEmpty) {
          await pixels.capture(
            tester,
            boundary,
            'c54-companion-${brightness.name}-$scale',
            const Size(320, 568),
            text: title,
            expectedText: '最近的分享',
          );
        }
        await tapVisible(tester, action);
        expect(find.byType(SharingPage), findsOneWidget);
        expect(
          tester.widget<SharingPage>(find.byType(SharingPage)).initialTab,
          0,
        );
        expect(service.sharedCommands, isEmpty);
        expect(service.photoReads, isEmpty);
        expect(await app.repository.loadGoals(), isEmpty);
        expect(await app.database.select(app.database.checkIns).get(), isEmpty);
        expect(app.permissions.requests, 0);
        expect(tester.takeException(), isNull);
      });
    }
    testWidgets('C54 no trailing stays unstacked ${brightness.name} 3.5x', (
      tester,
    ) async {
      viewport(tester, brightness, 3.5);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildXyTheme(brightness),
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(3.5)),
            child: const Scaffold(
              body: SingleChildScrollView(child: SectionLabel('最近的分享')),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(stackedKey), findsNothing);
      expect(find.text('最近的分享'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(SectionLabel),
          matching: find.byType(Row),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
