import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/assistant/assistant_providers.dart';
import 'package:habit_checkin/features/assistant/domain/agent_run_metadata.dart';
import 'package:habit_checkin/features/assistant/presentation/assistant_proposal_page.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'assistant_conversation_ui_test.dart' show openPlanning, sendText;
import 'journal_diary_capture_test.dart'
    show capture, captureFont, loadDiaryCaptureFont;
import 'support/scripted_agent_service.dart';
import 'support/test_assistant_service.dart';
import 'support/ui_harness.dart';

void main() {
  setUpAll(() async {
    tzdata.initializeTimeZones();
    await loadDiaryCaptureFont();
  });

  test('C36 legacy issue without with keeps its original fallback', () {
    expect(
      agentUnknownScheduleMessage({'index': 0, 'code': 'unknown_schedule'}),
      '无法完整判断此项的冲突',
    );
    expect(agentStatusLabels['partial'], '无法完整判断');
  });

  // C36 owner decision, with the existing card's zero-padded 24-hour time.
  for (final scenario in ['untimed', 'overdue', 'overlap', 'later']) {
    for (final brightness in Brightness.values) {
      for (final scale in [1.0, 3.5]) {
        testUiWidgets(
          'C36 $scenario ${brightness.name} ${scale}x explicit confirmation',
          (tester) async {
            const size = Size(320, 568);
            tester.view.physicalSize = size;
            tester.view.devicePixelRatio = 1;
            tester.platformDispatcher.textScaleFactorTestValue = scale;
            tester.platformDispatcher.platformBrightnessTestValue = brightness;
            addTearDown(() {
              tester.view.resetPhysicalSize();
              tester.view.resetDevicePixelRatio();
              tester.platformDispatcher.clearTextScaleFactorTestValue();
              tester.platformDispatcher.clearPlatformBrightnessTestValue();
            });
            final app = UiHarness();
            final service = ScriptedAgentService();
            final boundary = GlobalKey();
            if (scenario == 'overdue') app.clock.setDay(2026, 10, 8);
            await app.repository.create(
              GoalDraft(
                title: '跑步',
                kind: scenario == 'untimed' ? GoalKind.habit : GoalKind.single,
                weekdays: scenario == 'untimed' ? 127 : 0,
                plannedDay: scenario == 'untimed' ? null : app.clock.day,
                startMinute: scenario == 'untimed' ? null : 420,
                durationMinutes: scenario == 'untimed' || scenario == 'overdue'
                    ? 30
                    : null,
              ),
            );
            if (scenario == 'overdue') app.clock.setDay(2026, 10, 9);
            final items = [
              {
                'title': 'TEST 阅读',
                'date': app.clock.day.key,
                'start_minute': scenario == 'later' ? 540 : 450,
                'minutes': 30,
              },
            ];
            for (final tool in [
              'get_planning_preferences',
              'find_free_slots',
              'validate_plan',
              'submit_plan_draft',
            ]) {
              service.script.add(
                (r) async => agentResponse(
                  r,
                  tool: tool,
                  arguments: switch (tool) {
                    'get_planning_preferences' => <String, dynamic>{},
                    'find_free_slots' => <String, dynamic>{
                      'from': app.clock.day.key,
                      'to': app.clock.day.key,
                      'minutes': 30,
                      'window': {'start_minute': 360, 'end_minute': 600},
                      'daily_cap': null,
                    },
                    _ => <String, dynamic>{
                      'items': items,
                      if (tool == 'submit_plan_draft') 'note': 'TEST 待确认',
                    },
                  },
                ),
              );
            }
            await app.mount(
              tester,
              assistantService: service,
              assistantCredentials: ConversationTestCredentials(),
              wrapApp: (child) => RepaintBoundary(key: boundary, child: child),
            );
            await openPlanning(tester);
            await sendText(tester, 'TEST 安排阅读');
            final controller = await app.container.read(
              assistantConversationProvider.future,
            );
            final proposal = controller.proposals.single;
            final metadata = AgentRunMetadata.decode(proposal.agentMetadata!);
            expect(metadata.partial, scenario == 'overlap' ? {0} : isEmpty);
            expect(metadata.encode(), isNot(contains('跑步')));
            final results = service.agentRequests.last.results;
            expect(results[1]['status'], 'ok');
            expect(results[1]['data']['unknown_dates'], isEmpty);
            if (scenario == 'overlap' || scenario == 'later') {
              expect(
                (results[1]['data']['slots'] as List).where(
                  (s) => s['start_minute'] >= 420 && s['start_minute'] < 480,
                ),
                isEmpty,
              );
            }
            expect(
              results[2]['status'],
              scenario == 'overlap' ? 'partial' : 'ok',
            );
            await tapVisible(
              tester,
              find.byKey(ValueKey('open-proposal-${proposal.id}')),
            );
            if (scenario == 'overlap') {
              expect(find.byType(AssistantProposalPage), findsOneWidget);
              final issue = find.text('可能和「跑步」07:00 冲突');
              expect(issue, findsOneWidget);
              expect(find.text('我已了解可能的冲突'), findsOneWidget);
              final confirm = find.byKey(
                const ValueKey('assistant-apply-plan'),
              );
              expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
              expect(await app.repository.loadGoals(), hasLength(1));
              await tester.ensureVisible(issue);
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull);
              // C38: Chinese pixel/selection bounds need an explicit font;
              // Ahem's square glyphs do not represent Chinese text layout.
              if (captureFont.isNotEmpty) {
                await capture(
                  tester,
                  boundary,
                  'c36-overlap-${brightness.name}-$scale',
                  size,
                  text: issue,
                  expectedText: '可能和「跑步」07:00 冲突',
                );
              }
              await tapVisible(
                tester,
                find.byKey(const ValueKey('agent-partial-acknowledgement')),
              );
              await tapVisible(tester, confirm);
            } else {
              expect(find.byType(AssistantProposalPage), findsNothing);
              expect(
                find.byKey(const ValueKey('agent-partial-acknowledgement')),
                findsNothing,
              );
              expect(find.text('已添加 1 项'), findsOneWidget);
            }
            expect(
              (await controller.store.proposals.read(proposal.id)).status,
              'applied',
            );
            expect(await app.repository.loadGoals(), hasLength(2));
            expect(service.agentRequests, hasLength(4));
            expect(service.requests, isEmpty);
            expect(app.permissions.requests, 0);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }
}
