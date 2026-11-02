import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/app/theme.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:habit_checkin/features/journal/domain/journal_entry.dart';
import 'package:habit_checkin/features/journal/journal_providers.dart';
import 'package:habit_checkin/shared/ui/today_sky.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'journal_diary_capture_test.dart' as pixels;
import 'support/journal_fixtures.dart';
import 'support/record_fixtures.dart';
import 'support/ui_harness.dart';
import 'today_c49_test.dart' show viewport;

dynamic skyPainter(WidgetTester tester) => tester
    .widgetList<CustomPaint>(
      find.descendant(
        of: find.byType(TodaySky),
        matching: find.byType(CustomPaint),
      ),
    )
    .singleWhere(
      (paint) => paint.painter.runtimeType.toString() == '_SkyPainter',
    )
    .painter;

class StarCanvas implements Canvas {
  int stars = 0;
  @override
  void drawPath(Path path, Paint paint) => stars++;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

Future<void> mountSky(
  WidgetTester tester, {
  int hour = 21,
  int done = 1,
  int total = 3,
  bool reduced = false,
  Brightness brightness = Brightness.light,
}) => tester.pumpWidget(
  MaterialApp(
    theme: buildXyTheme(brightness),
    themeAnimationDuration: Duration.zero,
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduced),
      child: Scaffold(
        body: TodaySky(
          done: done,
          total: total,
          hour: hour,
          seed: 1,
          builder: (_, palette) =>
              Text('测试星空', style: TextStyle(color: palette.text)),
        ),
      ),
    ),
  ),
);

void main() {
  setUpAll(() async {
    tzdata.initializeTimeZones();
    await pixels.loadDiaryCaptureFont();
  });

  testWidgets('C67 palettes follow four time windows and dark stays night', (
    tester,
  ) async {
    for (final hour in [0, 4, 5, 9, 10, 15, 16, 18, 19, 23]) {
      await mountSky(tester, hour: hour, reduced: true);
      final SkyPalette palette = skyPainter(tester).palette;
      expect(palette.night, hour < 5 || hour >= 19);
      expect(
        palette.top,
        hour < 5 || hour >= 19
            ? const Color(0xFF1B2140)
            : hour < 10
            ? const Color(0xFFF6E4DA)
            : hour < 16
            ? const Color(0xFFE2EDF1)
            : const Color(0xFFF1D6CD),
      );
      await mountSky(
        tester,
        hour: hour,
        reduced: true,
        brightness: Brightness.dark,
      );
      expect((skyPainter(tester).palette as SkyPalette).night, isTrue);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'C67 initial twinkle stops at six seconds and lighting at 1100ms',
    (tester) async {
      await mountSky(tester);
      await tester.pump(const Duration(seconds: 3));
      expect(skyPainter(tester).twinkle, closeTo(.5, .001));
      await tester.pump(const Duration(seconds: 3));
      expect(skyPainter(tester).twinkle, 1);
      await tester.pump(
        const Duration(microseconds: 1),
      ); // C68 endpoint cleanup.
      expect(tester.binding.hasScheduledFrame, isFalse);
      await mountSky(tester, done: 2);
      expect(skyPainter(tester).light, 0);
      await tester.pump(const Duration(milliseconds: 550));
      expect(skyPainter(tester).light, closeTo(.5, .001));
      await tester.pump(const Duration(milliseconds: 550));
      expect(skyPainter(tester).light, 1);
      await tester.pump(
        const Duration(microseconds: 1),
      ); // C68 endpoint cleanup.
      expect(tester.binding.hasScheduledFrame, isFalse);
      await mountSky(tester, done: 1);
      expect(skyPainter(tester).light, 1);
    },
  );

  testWidgets('C67 reduced motion starts static and done changes stay static', (
    tester,
  ) async {
    await mountSky(tester, reduced: true);
    expect(skyPainter(tester).twinkle, 1);
    expect(skyPainter(tester).light, 1);
    await tester.pump(); // Flush final layout without advancing animation time.
    expect(tester.binding.hasScheduledFrame, isFalse);
    await mountSky(tester, done: 2, reduced: true);
    expect(skyPainter(tester).light, 1);
    await tester.pump(); // Flush final layout without advancing animation time.
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('C67 enabling reduced motion stops active sky animation', (
    tester,
  ) async {
    await mountSky(tester);
    await tester.pump(const Duration(milliseconds: 100));
    await mountSky(tester, done: 2);
    await tester.pump(const Duration(milliseconds: 100));
    await mountSky(tester, done: 2, reduced: true);
    expect(skyPainter(tester).light, 1);
    await tester.pump(); // Flush final layout without advancing animation time.
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('C67 each of ten goals has a constellation star', (tester) async {
    await mountSky(tester, total: 10, done: 10, reduced: true);
    final canvas = StarCanvas();
    (skyPainter(tester) as CustomPainter).paint(canvas, const Size(320, 176));
    expect(canvas.stars, 10);
  });

  for (final reduced in [false, true]) {
    testWidgets('C67 RiseIn finite entrance reduced=$reduced', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: reduced),
            child: const RiseIn(order: 1, child: Text('测试卡片')),
          ),
        ),
      );
      final fade = find.descendant(
        of: find.byType(RiseIn),
        matching: find.byType(FadeTransition),
      );
      if (reduced) {
        expect(fade, findsNothing);
        expect(find.text('测试卡片'), findsOneWidget);
      } else {
        expect(tester.widget<FadeTransition>(fade).opacity.value, 0);
        await tester.pump(const Duration(milliseconds: 490));
        expect(tester.widget<FadeTransition>(fade).opacity.value, 1);
      }
      await tester.pump(
        const Duration(microseconds: 1),
      ); // C68 endpoint cleanup.
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testUiWidgets(
      'C67 quick note save removes wish overlay by 1300ms reduced=$reduced',
      (tester) async {
        tester.platformDispatcher.accessibilityFeaturesTestValue =
            FakeAccessibilityFeatures(disableAnimations: reduced);
        addTearDown(
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
        );
        final app = UiHarness();
        await app.mount(
          tester,
          journalPhotoFiles: {
            for (final kind in JournalKind.values)
              kind: MemoryJournalPhotoFiles(kind),
          },
          recordPhotoPicker: StubRecordPhotoPicker(),
        );
        await tapVisible(
          tester,
          find.byKey(const ValueKey('entry-quick-note')),
        );
        await tester.enterText(
          find.byKey(const ValueKey('journal-text')),
          '测试保存星愿',
        );
        await tester.pumpAndSettle();
        final wish = find.byWidgetPredicate(
          (widget) => widget.runtimeType.toString() == '_WishRise',
        );
        final save = find.byKey(const ValueKey('save-journal'));
        await tester.tap(save);
        for (
          var i = 0;
          i < 100 &&
              (reduced ? save.evaluate().isNotEmpty : wish.evaluate().isEmpty);
          i++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
          await tester.pump();
        }
        if (!reduced) {
          expect(wish, findsOneWidget);
          expect(
            find.descendant(of: wish, matching: find.byType(IgnorePointer)),
            findsOneWidget,
          );
          await tester
              .pump(); // Establish overlay ticker epoch at the current time.
          await tester.pump(const Duration(milliseconds: 600));
          expect(wish, findsOneWidget);
          await tester.pump(const Duration(milliseconds: 700));
          final animated = tester.widget<AnimatedBuilder>(
            find.descendant(of: wish, matching: find.byType(AnimatedBuilder)),
          );
          expect((animated.animation as Animation<double>).value, 1);
          await tester.pump(const Duration(microseconds: 1));
          await tester.pump();
        }
        expect(wish, findsNothing);
        await tester.pumpAndSettle();
        final store = await app.container.read(quickNoteStoreProvider.future);
        expect(
          (await store.savedOn(app.clock.day)).single.entry.content,
          '测试保存星愿',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final scenario in [
    (7, Brightness.light, 1.0),
    (12, Brightness.light, 1.0),
    (17, Brightness.light, 1.0),
    (21, Brightness.light, 1.0),
    (21, Brightness.dark, 1.0),
    (21, Brightness.light, 3.5),
  ]) {
    final (hour, brightness, scale) = scenario;
    testUiWidgets('C67 today sky capture $hour ${brightness.name} $scale', (
      tester,
    ) async {
      viewport(tester, brightness, scale);
      final app = UiHarness()..clock.setDay(2026, 11, 1, hour: hour);
      for (var i = 0; i < 5; i++) {
        final id = await app.repository.create(
          GoalDraft(title: '测试目标$i', kind: GoalKind.habit),
        );
        if (i < 2) {
          await app.repository.setCompleted(
            id,
            true,
            expectedDay: app.clock.day,
          );
        }
      }
      final boundary = GlobalKey();
      await app.mount(
        tester,
        wrapApp: (child) => RepaintBoundary(key: boundary, child: child),
      );
      final summary = find.byKey(const ValueKey('today-summary'));
      await tester.ensureVisible(summary);
      await tester.pumpAndSettle();
      final sky = tester.widget<TodaySky>(find.byType(TodaySky));
      expect(sky.done, 2);
      expect(sky.total, 5);
      expect(sky.hour, hour);
      final box =
          tester.widget<DecoratedBox>(summary).decoration as BoxDecoration;
      expect(box.color, tester.element(summary).xy.card);
      expect(box.gradient, isNull);
      expect(box.boxShadow, isNull);
      final count = find.byKey(const ValueKey('today-count'));
      expect(
        tester.getSize(find.byType(TodaySky)).height,
        greaterThanOrEqualTo(176),
      );
      if (pixels.captureFont.isNotEmpty) {
        await pixels.capture(
          tester,
          boundary,
          'c67-today-$hour-${brightness.name}-$scale',
          const Size(320, 568),
          text: count,
          expectedText: '已点亮 2 颗星',
          firstLineOnly: true,
        );
      }
      // C68: serif selection boxes can exceed line boxes without clipping.
      final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(of: count, matching: find.byType(RichText)),
      );
      expect(paragraph.didExceedMaxLines, isFalse);
      final rect = paragraph.localToGlobal(Offset.zero) & paragraph.size;
      final summaryRect = tester.getRect(summary);
      expect(rect.left, greaterThanOrEqualTo(summaryRect.left));
      expect(rect.right, lessThanOrEqualTo(summaryRect.right));
      expect(rect.top, greaterThanOrEqualTo(summaryRect.top));
      expect(rect.bottom, lessThanOrEqualTo(summaryRect.bottom));
      expect(tester.takeException(), isNull);
    });
  }
}
