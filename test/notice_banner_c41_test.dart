import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/app/theme.dart';
import 'package:habit_checkin/shared/presentation.dart';

void main() {
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 22 / 14, 1.6, 3.5]) {
      for (final withAction in [false, true]) {
        testWidgets('C41 ${brightness.name} $scale action=$withAction', (
          tester,
        ) async {
          tester.view.physicalSize = const Size(320, 568);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          var taps = 0;
          await tester.pumpWidget(
            MaterialApp(
              theme: buildXyTheme(brightness),
              home: MediaQuery(
                data: MediaQueryData(
                  size: const Size(320, 568),
                  textScaler: TextScaler.linear(scale),
                ),
                child: Scaffold(
                  body: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: NoticeBanner(
                      message: 'TEST notice with an action',
                      action: withAction ? 'Open' : null,
                      actionKey: const ValueKey('c41-action'),
                      onAction: withAction ? () => taps++ : null,
                    ),
                  ),
                ),
              ),
            ),
          );
          final text = find.text('TEST notice with an action');
          final action = find.byKey(const ValueKey('c41-action'));
          final container = tester.widget<Container>(
            find
                .descendant(
                  of: find.byType(NoticeBanner),
                  matching: find.byType(Container),
                )
                .first,
          );
          final stacked = withAction && scale * 14 > 22;
          expect(container.child, stacked ? isA<Column>() : isA<Row>());
          if (withAction) {
            await tester.ensureVisible(action);
            await tester.pumpAndSettle();
            final textRect = tester.getRect(text);
            final buttonRect = tester.getRect(action);
            if (stacked) {
              expect(textRect.width, greaterThan(200));
              expect(buttonRect.top, greaterThanOrEqualTo(textRect.bottom));
              expect(buttonRect.left, closeTo(textRect.left, 0.01));
              expect(buttonRect.width, greaterThanOrEqualTo(44));
              expect(buttonRect.height, greaterThanOrEqualTo(44));
            } else {
              expect(buttonRect.left, greaterThanOrEqualTo(textRect.right));
            }
            expect(action.hitTestable(), findsOneWidget);
            await tester.tap(action);
            expect(taps, 1);
          } else {
            expect(action, findsNothing);
          }
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
}
