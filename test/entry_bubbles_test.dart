import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/app/theme.dart';
import 'package:habit_checkin/shared/ui/entry_bubbles.dart';

void main() {
  for (final scale in [1.0, 3.5]) {
    for (final brightness in Brightness.values) {
      for (final reduced in [false, true]) {
        testWidgets(
          'four entrances at $scale ${brightness.name} reduced=$reduced',
          (tester) async {
            tester.view.physicalSize = const Size(320, 568);
            tester.view.devicePixelRatio = 1;
            addTearDown(() {
              tester.view.resetPhysicalSize();
              tester.view.resetDevicePixelRatio();
            });
            final taps = List.filled(4, 0);
            await tester.pumpWidget(
              MaterialApp(
                theme: buildXyTheme(brightness),
                home: MediaQuery(
                  data: MediaQueryData(
                    size: const Size(320, 568),
                    textScaler: TextScaler.linear(scale),
                    disableAnimations: reduced,
                  ),
                  child: Scaffold(
                    body: SingleChildScrollView(
                      child: Builder(
                        builder: (context) => XyEntryBubbles(
                          entries: todayEntries(
                            context,
                            onCheckIn: () => taps[0]++,
                            onQuickNote: () => taps[1]++,
                            onDiary: () => taps[2]++,
                            onNewGoal: () => taps[3]++,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            final keys = [
              'entry-check-in',
              'entry-quick-note',
              'entry-diary',
              'entry-new-goal',
            ];
            for (var i = 0; i < keys.length; i++) {
              final finder = find.byKey(ValueKey(keys[i]));
              await tester.ensureVisible(finder);
              await tester.tap(finder);
              await tester.pump();
              if (reduced) {
                expect(tester.binding.transientCallbackCount, 0);
                for (final transition in tester.widgetList<ScaleTransition>(
                  find.descendant(
                    of: find.byType(XyEntryBubbles),
                    matching: find.byType(ScaleTransition),
                  ),
                )) {
                  expect(transition.scale.value, 1);
                }
              }
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull);
            }
            expect(taps, [1, 1, 1, 1]);
          },
        );
      }
    }
  }

  testWidgets('disabled entrances expose disabled semantics and ignore taps', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildXyTheme(Brightness.light),
        home: Scaffold(
          body: Builder(
            builder: (context) => XyEntryBubbles(
              entries: todayEntries(
                context,
                onCheckIn: null,
                onQuickNote: null,
                onDiary: null,
                onNewGoal: null,
              ),
            ),
          ),
        ),
      ),
    );
    for (final key in [
      'entry-check-in',
      'entry-quick-note',
      'entry-diary',
      'entry-new-goal',
    ]) {
      final finder = find.byKey(ValueKey(key));
      expect(
        tester.getSemantics(finder),
        matchesSemantics(
          isButton: true,
          hasEnabledState: true,
          isEnabled: false,
          label: switch (key) {
            'entry-check-in' => '打卡',
            'entry-quick-note' => '随手记',
            'entry-diary' => '写日记',
            _ => '新目标',
          },
          hint: switch (key) {
            'entry-check-in' => '跳到今天的目标',
            'entry-quick-note' => '写一条随手记',
            'entry-diary' => '打开今天的日记',
            _ => '新建一个目标',
          },
        ),
      );
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });
}
