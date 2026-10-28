import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/assistant/assistant_providers.dart';
import 'package:habit_checkin/features/assistant/data/local_memory_store.dart';
import 'package:habit_checkin/features/assistant/domain/agent_run_metadata.dart';
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

  testUiWidgets(
    'background stops pending Agent and foreground does not resume it',
    (tester) async {
      final app = UiHarness();
      final service = ScriptedAgentService();
      final release = Completer<void>();
      service.script.add((request) async {
        await release.future;
        return agentResponse(request, text: 'TEST late background');
      });
      await app.mount(
        tester,
        assistantService: service,
        assistantCredentials: ConversationTestCredentials(),
      );
      await openPlanning(tester);
      await sendText(tester, 'TEST planning', waiting: true);
      final controller = await app.container.read(
        assistantConversationProvider.future,
      );
      try {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await pumpWaiting(tester);
        expect(controller.busy, isFalse);
        await controller.send('TEST forbidden background');
        expect(service.agentRequests, hasLength(1));
      } finally {
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        release.complete();
        await tester.pumpAndSettle();
      }
      expect(find.text('TEST late background'), findsNothing);
      expect(service.agentRequests, hasLength(1));
      expect(
        await app.database.select(app.database.planProposals).get(),
        isEmpty,
      );
      expect(await app.repository.loadGoals(), isEmpty);
    },
  );

  testUiWidgets(
    'invalid draft keeps adjustment stage while model repairs; cancel discards late plan',
    (tester) async {
      final app = UiHarness();
      final service = ScriptedAgentService();
      service.script.add(
        (r) async => agentResponse(
          r,
          tool: 'submit_plan_draft',
          arguments: {
            'items': [
              {
                'title': 'TEST invalid',
                'date': app.clock.day.key,
                'start_minute': 1430,
                'minutes': 30,
              },
            ],
            'note': '',
          },
        ),
      );
      final repair = Completer<void>();
      service.script.add((r) async {
        await repair.future;
        return agentResponse(r, text: 'TEST late');
      });
      await app.mount(
        tester,
        assistantService: service,
        assistantCredentials: ConversationTestCredentials(),
      );
      await openPlanning(tester);
      await sendText(tester, 'TEST request', waiting: true);
      try {
        expect(service.agentRequests, hasLength(2));
        expect(find.text('发现冲突，正在调整'), findsOneWidget);
        await tapVisible(tester, key('assistant-cancel'), settle: false);
      } finally {
        if (!repair.isCompleted) repair.complete();
        await tester.pumpAndSettle();
      }
      expect(find.text('TEST late'), findsNothing);
      expect(
        await app.database.select(app.database.planProposals).get(),
        isEmpty,
      );
      expect(await app.repository.loadGoals(), isEmpty);
    },
  );

  testUiWidgets(
    'default-on Agent toggle persists off and uses legacy after navigation',
    (tester) async {
      final app = UiHarness();
      final service = ScriptedAgentService();
      await app.mount(
        tester,
        assistantService: service,
        assistantCredentials: ConversationTestCredentials(),
      );
      await openPlanning(tester);
      await tapVisible(tester, find.byTooltip('AI 设置'));
      final toggle = key('assistant-agent-enabled');
      expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
      await tapVisible(tester, toggle);
      expect(
        (await LocalMemoryStore(app.repository).settings()).agentEnabled,
        isFalse,
      );
      await goBack(tester);
      await sendText(tester, 'TEST legacy');
      expect(service.requests, hasLength(1));
      expect(service.agentRequests, isEmpty);
    },
  );

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 3.5]) {
      testUiWidgets(
        'partial proposal checkbox, trace, cancel and explicit apply ${brightness.name} ${scale}x',
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
          await app.repository.create(
            GoalDraft(
              title: 'TEST private existing',
              kind: GoalKind.single,
              plannedDay: app.clock.day,
            ),
          );
          service.script.add(
            (r) async => agentResponse(
              r,
              tool: 'submit_plan_draft',
              arguments: {
                'items': [
                  {
                    'title': 'TEST 待确认任务',
                    'date': app.clock.day.key,
                    'start_minute': 600,
                    'minutes': 30,
                  },
                  {
                    'title': 'TEST 明日任务',
                    'date': app.clock.day.addDays(1).key,
                    'start_minute': 600,
                    'minutes': 30,
                  },
                ],
                'note': 'TEST 草稿，仅供确认',
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
          await sendText(tester, 'TEST 请规划');
          final controller = await app.container.read(
            assistantConversationProvider.future,
          );
          final proposal = controller.proposals.single;
          final metadata = AgentRunMetadata.decode(
            controller.messages.last.agentMetadata!,
          );
          expect(metadata.partial, {0});
          expect(metadata.encode(), isNot(contains('private existing')));
          await tapVisible(tester, key('open-proposal-${proposal.id}'));
          expect(key('agent-item-issue-agent-0'), findsOneWidget);
          expect(key('agent-item-issue-agent-1'), findsNothing);
          final confirm = key('assistant-apply-plan');
          expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
          await tapVisible(tester, key('agent-trace-proposal'));
          expect(find.textContaining('检查最终草稿'), findsOneWidget);
          expect(find.text('TEST private existing'), findsNothing);
          await goBack(tester);
          expect(await app.repository.loadGoals(), hasLength(1));
          await tapVisible(tester, key('open-proposal-${proposal.id}'));
          final ack = key('agent-partial-acknowledgement');
          await tapVisible(tester, ack);
          expect(tester.widget<CheckboxListTile>(ack).value, isTrue);
          expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
          await Scrollable.ensureVisible(
            tester.element(confirm),
            alignment: 0.8,
          );
          await tester.pumpAndSettle();
          expect(confirm.hitTestable(), findsOneWidget);
          await capture(
            tester,
            boundary,
            'agent-${brightness.name}-${scale}x-confirm',
            size,
            text: confirm,
            expectedText: '确认创建',
          );
          await tapVisible(tester, confirm);
          expect(await app.repository.loadGoals(), hasLength(3));
          expect(
            (await controller.store.proposals.read(proposal.id)).status,
            'applied',
          );
          expect(service.agentRequests, hasLength(1));
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final status in agentDataMessages.keys) {
    testUiWidgets(
      'fixed $status banner and metadata-only trace are deterministic',
      (tester) async {
        const size = Size(320, 568);
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });
        final app = UiHarness();
        final service = ScriptedAgentService();
        final boundary = GlobalKey();
        if (status == 'not_authorized') {
          await LocalMemoryStore(app.repository)
              .updateSettings(sendSchedule: false);
        } else if (status == 'partial') {
          await app.repository.create(
            GoalDraft(
              title: 'TEST secret',
              kind: GoalKind.single,
              plannedDay: app.clock.day,
            ),
          );
        } else if (status == 'truncated') {
          for (var i = 0; i < 61; i++) {
            await app.repository.create(
              GoalDraft(
                title: 'TEST secret$i',
                kind: GoalKind.single,
                plannedDay: app.clock.day,
                startMinute: 600,
                durationMinutes: 30,
              ),
            );
          }
        }
        if (status != 'failed') {
          service.script.add(
            (r) async => agentResponse(
              r,
              tool: 'query_schedule',
              arguments: {'from': app.clock.day.key, 'to': app.clock.day.key},
            ),
          );
        }
        service.script.add((r) async => agentResponse(r, text: 'TEST answer'));
        await app.mount(
          tester,
          assistantService: service,
          assistantCredentials: ConversationTestCredentials(),
          wrapApp: (child) => RepaintBoundary(key: boundary, child: child),
        );
        await openPlanning(tester);
        await sendText(tester, 'TEST request');
        final controller = await app.container.read(
          assistantConversationProvider.future,
        );
        if (status == 'failed') {
          // Render the production widget with the failure metadata contract.
          final metadata = AgentRunMetadata(
            date: service.agentRequests.single.now.date,
            statuses: ['failed'],
            trace: const [AgentTraceEntry('query_schedule', 'failed', 15)],
          );
          await app.database.customStatement(
            'UPDATE assistant_messages SET agent_metadata = ? WHERE id = ?',
            [metadata.encode(), controller.messages.last.id],
          );
          await controller.refresh();
          await tester.pumpAndSettle();
        }
        expect(find.text(agentDataMessages[status]!), findsOneWidget);
        final message = controller.messages.last;
        await tapVisible(tester, key('agent-trace-${message.id}'));
        expect(find.text('查询安排'), findsOneWidget);
        expect(key('agent-trace-${message.id}-0'), findsOneWidget);
        expect(find.textContaining('TEST secret'), findsNothing);
        final banner = find.text(agentDataMessages[status]!);
        await Scrollable.ensureVisible(tester.element(banner), alignment: 0.1);
        await tester.pumpAndSettle();
        await capture(
          tester,
          boundary,
          'agent-banner-$status',
          size,
          text: banner,
          expectedText: agentDataMessages[status]!,
        );
      },
    );
  }
}
