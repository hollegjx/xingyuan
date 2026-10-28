import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/app/theme.dart';
import 'package:habit_checkin/features/assistant/domain/agent_run_metadata.dart';
import 'package:habit_checkin/features/assistant/presentation/agent_run_details.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

import 'journal_diary_capture_test.dart' show capture, loadDiaryCaptureFont;

void main() {
  setUpAll(loadDiaryCaptureFont);
  testWidgets('C24 animates normally and resets expansion on scope change', (
    tester,
  ) async {
    var scope = 'proposal';
    late StateSetter change;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            change = setState;
            return MediaQuery(
              data: const MediaQueryData(disableAnimations: false),
              child: SingleChildScrollView(
                child: AgentRunDetails(
                  scope: scope,
                  metadata: AgentRunMetadata(
                    date: CalendarDate(2026, 10, 28),
                    trace: const [AgentTraceEntry('query_schedule', 'ok', 10)],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
    final semantics = tester.ensureSemantics();
    expect(find.byKey(const ValueKey('agent-trace-proposal-0')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('agent-trace-proposal')));
    await tester.pumpAndSettle();
    expect(find.byType(AnimatedSize), findsOneWidget);
    expect(
      tester.widget<AnimatedRotation>(find.byType(AnimatedRotation)).turns,
      0.25,
    );
    expect(
      find.byKey(const ValueKey('agent-trace-proposal-0')),
      findsOneWidget,
    );
    change(() => scope = 'running');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('agent-trace-running-0')), findsOneWidget);
    change(() => scope = 'proposal');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('agent-trace-proposal-0')), findsNothing);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 3.5]) {
      for (final scope in ['running', 'proposal']) {
        testWidgets(
          'C24 $scope trace ${brightness.name} ${scale}x is usable without ambient Material',
          (tester) async {
            tester.view.physicalSize = const Size(320, 568);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            final boundary = GlobalKey();
            await tester.pumpWidget(
              RepaintBoundary(
                key: boundary,
                child: MaterialApp(
                  theme: buildXyTheme(brightness),
                  home: MediaQuery(
                    data: MediaQueryData(
                      size: const Size(320, 568),
                      textScaler: TextScaler.linear(scale),
                      disableAnimations: true,
                    ),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: AgentRunDetails(
                        scope: scope,
                        metadata: AgentRunMetadata(
                          date: CalendarDate(2026, 10, 28),
                          trace: const [
                            AgentTraceEntry('query_schedule', 'partial', 1500),
                            AgentTraceEntry('validate_plan', 'ok', 2000),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            final first = find.byKey(ValueKey('agent-trace-$scope-0'));
            final header = find.byKey(ValueKey('agent-trace-$scope'));
            expect(first, scope == 'running' ? findsOneWidget : findsNothing);
            expect(find.text('2 步 · 3.5 秒'), findsOneWidget);
            expect(find.byType(ExpansionTile), findsNothing);
            await capture(
              tester,
              boundary,
              'c24-${brightness.name}-$scale-$scope',
              const Size(320, 568),
              text: find.text('过程记录'),
              expectedText: '过程记录',
            );
            await tester.tap(header);
            await tester.pumpAndSettle();
            expect(first, scope == 'running' ? findsNothing : findsOneWidget);
            expect(find.byType(AnimatedRotation), findsNothing);
            expect(find.byType(AnimatedSize), findsNothing);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }
}
