import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/assistant/assistant_providers.dart';
import 'package:habit_checkin/features/assistant/data/local_memory_store.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'assistant_conversation_ui_test.dart' show openPlanning, sendText;
import 'journal_diary_capture_test.dart' show capture, loadDiaryCaptureFont;
import 'support/scripted_agent_service.dart';
import 'support/test_assistant_service.dart';
import 'support/ui_harness.dart';

void main() {
  setUpAll(() async {
    tzdata.initializeTimeZones();
    await loadDiaryCaptureFont();
  });
  Finder key(String value) => find.byKey(ValueKey(value));

  for (final change in ['conflict', 'daily_cap', 'partial', 'midnight']) {
    for (final brightness in Brightness.values) {
      for (final scale in [1.0, 3.5]) {
        testUiWidgets(
          'A3 $change ${brightness.name} ${scale}x blocks confirmation with explicit recovery choices',
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
            final boundary = GlobalKey();
            final app = UiHarness();
            final service = ScriptedAgentService();
            if (change == 'partial') {
              await app.repository.create(
                GoalDraft(
                  title: 'TEST original unknown',
                  kind: GoalKind.single,
                  plannedDay: app.clock.day,
                ),
              );
            }
            if (change == 'daily_cap') {
              service.script.add(
                (r) async => agentResponse(
                  r,
                  tool: 'find_free_slots',
                  arguments: {
                    'from': app.clock.day.key,
                    'to': app.clock.day.key,
                    'minutes': 30,
                    'window': null,
                    'daily_cap': 60,
                  },
                ),
              );
            }
            service.script.add(
              (r) async => agentResponse(
                r,
                tool: 'submit_plan_draft',
                arguments: {
                  'items': [
                    {
                      'title': 'TEST confirmed plan',
                      'date': app.clock.day.key,
                      'start_minute': 600,
                      'minutes': 30,
                    },
                  ],
                  'note': '',
                },
              ),
            );
            await app.mount(
              tester,
              assistantService: service,
              assistantCredentials: ConversationTestCredentials(),
              wrapApp: (child) => RepaintBoundary(key: boundary, child: child),
            );
            await openPlanning(tester);
            await sendText(tester, 'TEST plan');
            final controller = await app.container.read(
              assistantConversationProvider.future,
            );
            final original = controller.proposals.single;
            if (change == 'conflict') {
              final waiting = key('agent-awaiting-confirmation');
              await tester.ensureVisible(waiting);
              await tester.pumpAndSettle();
              await capture(
                tester,
                boundary,
                'c24-waiting-${brightness.name}-$scale',
                size,
                text: waiting,
                expectedText: '等你确认',
              );
            }
            if (change == 'daily_cap') {
              await tester.enterText(
                key('assistant-input'),
                'TEST unsent draft',
              );
            }
            await tapVisible(tester, key('open-proposal-${original.id}'));
            if (change == 'partial') {
              await tapVisible(tester, key('agent-partial-acknowledgement'));
            }
            if (change == 'midnight') {
              app.clock.setDay(2026, 10, 10);
            } else {
              await app.repository.create(
                GoalDraft(
                  title: 'TEST changed schedule',
                  kind: GoalKind.single,
                  plannedDay: app.clock.day,
                  startMinute: change == 'conflict'
                      ? 600
                      : change == 'daily_cap'
                      ? 800
                      : null,
                  durationMinutes: change == 'partial' ? null : 40,
                ),
              );
            }
            final goalsBefore = await app.repository.loadGoals();
            await tapVisible(tester, key('assistant-apply-plan'));
            expect(find.text('安排有变化'), findsOneWidget);
            expect(key('agent-replan'), findsOneWidget);
            expect(key('agent-return-edit'), findsOneWidget);
            expect(key('assistant-apply-plan'), findsNothing);
            expect(
              await app.repository.loadGoals(),
              hasLength(goalsBefore.length),
            );
            final current = await controller.store.proposals.read(original.id);
            expect(current.status, 'draft');
            expect(current.itemsJson, original.itemsJson);
            expect(current.appliedGoalIdsJson, isNull);
            expect(
              find.text(switch (change) {
                'conflict' => '与已有安排或本计划其他项冲突',
                'daily_cap' => '超过每日时长上限',
                'midnight' => '日期超出规划范围',
                _ => '无法完整判断此项的冲突',
              }),
              findsWidgets,
            );
            final calls = service.agentRequests.length;
            final notice = find.text('安排有变化');
            await tester.ensureVisible(notice);
            await tester.pumpAndSettle();
            await capture(
              tester,
              boundary,
              'a3-$change-${brightness.name}-$scale',
              size,
              text: notice,
              expectedText: '安排有变化',
            );
            if (change == 'partial') {
              await tapVisible(tester, key('agent-return-edit'));
              expect(find.text('安排有变化'), findsNothing);
              final ack = key('agent-partial-acknowledgement');
              expect(tester.widget<CheckboxListTile>(ack).value, isFalse);
              expect(
                tester
                    .widget<FilledButton>(key('assistant-apply-plan'))
                    .onPressed,
                isNull,
              );
              await tapVisible(tester, ack);
              await tapVisible(tester, key('assistant-apply-plan'));
              expect(
                await app.repository.loadGoals(),
                hasLength(goalsBefore.length + 1),
              );
            } else {
              await tapVisible(tester, key('agent-replan'));
              expect(key('assistant-input'), findsOneWidget);
              expect(
                tester
                    .widget<TextField>(key('assistant-input'))
                    .controller!
                    .text,
                change == 'daily_cap' ? 'TEST unsent draft' : contains('重新规划'),
              );
              expect(
                await app.repository.loadGoals(),
                hasLength(goalsBefore.length),
              );
            }
            expect(service.agentRequests, hasLength(calls));
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }

  for (final action in ['revoke', 'cancel', 'double_tap']) {
    testUiWidgets('A3 $action preserves explicit creation boundary', (
      tester,
    ) async {
      final app = UiHarness();
      final service = ScriptedAgentService();
      service.script.add(
        (r) async => agentResponse(
          r,
          tool: 'submit_plan_draft',
          arguments: {
            'items': [
              {
                'title': 'TEST task',
                'date': app.clock.day.key,
                'start_minute': 600,
                'minutes': 30,
              },
            ],
            'note': '',
          },
        ),
      );
      await app.mount(
        tester,
        assistantService: service,
        assistantCredentials: ConversationTestCredentials(),
      );
      await openPlanning(tester);
      await sendText(tester, 'TEST request');
      final controller = await app.container.read(
        assistantConversationProvider.future,
      );
      final original = controller.proposals.single;
      await tapVisible(tester, key('open-proposal-${original.id}'));
      if (action == 'revoke') {
        await LocalMemoryStore(app.repository)
            .updateSettings(sendSchedule: false);
        await tapVisible(tester, key('assistant-apply-plan'));
        expect(find.textContaining('授权已变化'), findsOneWidget);
      } else if (action == 'cancel') {
        await goBack(tester);
      } else {
        final button = key('assistant-apply-plan');
        await tester.ensureVisible(button);
        await tester.tap(button);
        await tester.tap(button);
        await tester.pumpAndSettle();
      }
      expect(
        await app.repository.loadGoals(),
        hasLength(action == 'double_tap' ? 1 : 0),
      );
      expect(
        (await controller.store.proposals.read(original.id)).status,
        action == 'double_tap' ? 'applied' : 'draft',
      );
      expect(service.agentRequests, hasLength(1));
      expect(tester.takeException(), isNull);
    });
  }
}
