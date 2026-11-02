import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/app/theme.dart';
import 'package:habit_checkin/features/goals/presentation/goal_timing_fields.dart';

import 'journal_diary_capture_test.dart' as pixels;

void main() {
  setUpAll(() async {
    await pixels.loadDiaryCaptureFont();
    if (pixels.captureFont.isNotEmpty) {
      final bytes = ByteData.sublistView(
        await File(pixels.captureFont).readAsBytes(),
      );
      for (final family in ['CupertinoSystemText', 'CupertinoSystemDisplay']) {
        await (FontLoader(family)..addFont(Future.value(bytes))).load();
      }
    }
  });

  final minutes = find.byKey(const ValueKey('duration-minutes'));
  Finder button(String tooltip) => find.byWidgetPredicate(
    (widget) => widget is IconButton && widget.tooltip == tooltip,
  );
  final minus = button('减少 5 分钟');
  final plus = button('增加 5 分钟');
  final clear = button('清除预计分钟');

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 1.6, 1.625, 1.65, 2.0, 3.0]) {
      testWidgets('C45 ${brightness.name} layout at $scale', (tester) async {
        final boundary = GlobalKey();
        await _mount(tester, brightness, scale, boundary: boundary);
        await tester.ensureVisible(minutes);
        await tester.pumpAndSettle();
        if (pixels.captureFont.isNotEmpty) {
          await pixels.capture(
            tester,
            boundary,
            'c45-${brightness.name}-$scale',
            const Size(320, 568),
            text: find.text('分钟'),
            expectedText: '分钟',
          );
        }
        final field = tester.getRect(minutes);
        if (scale > 1.625) {
          expect(field.width, greaterThanOrEqualTo(250));
          expect(field.top, greaterThanOrEqualTo(0));
          expect(field.bottom, lessThanOrEqualTo(368));
          expect(
            MediaQuery.textScalerOf(tester.element(minutes)).scale(16),
            closeTo(16 * scale, 0.01),
          );
          for (final control in [minus, plus, clear]) {
            expect(
              tester.getRect(control).top,
              greaterThanOrEqualTo(field.bottom),
            );
          }
        } else {
          expect(tester.getRect(minus).right, lessThanOrEqualTo(field.left));
          expect(tester.getRect(plus).left, greaterThanOrEqualTo(field.right));
          expect(tester.getRect(plus).top, closeTo(field.top, 0.01));
        }
        for (final control in [minus, plus, clear]) {
          await tester.ensureVisible(control);
          await tester.pumpAndSettle();
          expect(control.hitTestable(), findsOneWidget);
          expect(tester.getSize(control).width, greaterThanOrEqualTo(44));
          expect(tester.getSize(control).height, greaterThanOrEqualTo(44));
        }
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets(
      'C44 ${brightness.name} controls and scale switch retain draft',
      (tester) async {
        final state = await _mount(tester, brightness, 3);
        Future<void> tap(Finder finder) async {
          await tester.ensureVisible(finder);
          await tester.pumpAndSettle();
          await tester.tap(finder);
          await tester.pumpAndSettle();
        }

        await tap(plus);
        expect(state.currentState!.duration, 35);
        await tap(minus);
        expect(state.currentState!.duration, 30);
        await tap(clear);
        expect(state.currentState!.duration, isNull);
        expect(tester.widget<IconButton>(clear).onPressed, isNull);
        await tap(plus);
        expect(state.currentState!.duration, 30);
        await tester.ensureVisible(minutes);
        await tester.enterText(minutes, '475');
        await tester.pumpAndSettle();
        await tap(plus);
        await tap(plus);
        expect(state.currentState!.duration, 480);
        await tester.ensureVisible(minutes);
        await tester.enterText(minutes, '5');
        await tester.pumpAndSettle();
        await tap(minus);
        expect(state.currentState!.duration, 5);
        state.currentState!.changeScale(1.625);
        await tester.pumpAndSettle();
        expect(tester.widget<TextFormField>(minutes).controller!.text, '5');
        state.currentState!.changeScale(1.65);
        await tester.pumpAndSettle();
        expect(tester.widget<TextFormField>(minutes).controller!.text, '5');
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('C44 ${brightness.name} disabled controls and validation', (
      tester,
    ) async {
      final state = await _mount(tester, brightness, 3);
      await tester.ensureVisible(minutes);
      await tester.enterText(minutes, '481');
      await tester.pumpAndSettle();
      expect(state.currentState!.form.currentState!.validate(), isFalse);
      await tester.pumpAndSettle();
      for (final scale in [1.625, 1.65, 2.0, 3.0]) {
        state.currentState!.changeScale(scale);
        await tester.pumpAndSettle();
        expect(tester.widget<TextFormField>(minutes).controller!.text, '481');
        expect(state.currentState!.form.currentState!.validate(), isFalse);
      }
      await tester.enterText(minutes, '45');
      await tester.pumpAndSettle();
      expect(state.currentState!.form.currentState!.validate(), isTrue);
      state.currentState!.disable();
      await tester.pumpAndSettle();
      expect(tester.widget<TextFormField>(minutes).enabled, isFalse);
      for (final finder in [minus, plus, clear]) {
        expect(tester.widget<IconButton>(finder).onPressed, isNull);
      }
      expect(state.currentState!.duration, 45);
      expect(tester.takeException(), isNull);
    });
  }
}

Future<GlobalKey<_TimingHarnessState>> _mount(
  WidgetTester tester,
  Brightness brightness,
  double scale, {
  GlobalKey? boundary,
}) async {
  tester.view.physicalSize = const Size(320, 568);
  tester.view.devicePixelRatio = 1;
  tester.view.viewInsets = const FakeViewPadding(bottom: 200);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewInsets);
  final state = GlobalKey<_TimingHarnessState>();
  await tester.pumpWidget(
    RepaintBoundary(
      key: boundary,
      child: _TimingHarness(key: state, brightness: brightness, scale: scale),
    ),
  );
  await tester.pumpAndSettle();
  return state;
}

class _TimingHarness extends StatefulWidget {
  const _TimingHarness({
    required this.brightness,
    required this.scale,
    super.key,
  });

  final Brightness brightness;
  final double scale;

  @override
  State<_TimingHarness> createState() => _TimingHarnessState();
}

class _TimingHarnessState extends State<_TimingHarness> {
  final form = GlobalKey<FormState>();
  int? duration = 30;
  bool enabled = true;
  late double scale = widget.scale;

  void changeScale(double value) => setState(() => scale = value);
  void disable() => setState(() => enabled = false);

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: buildXyTheme(widget.brightness)
        .copyWith(platform: TargetPlatform.iOS),
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Form(
              key: form,
              child: GoalTimingFields(
                startMinute: 600,
                durationMinutes: duration,
                enabled: enabled,
                onStartChanged: (_) {},
                onDurationChanged: (value) => setState(() => duration = value),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
