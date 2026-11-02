import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/app/theme.dart';
import 'package:habit_checkin/features/assistant/assistant_providers.dart';
import 'package:habit_checkin/features/assistant/data/local_memory_store.dart';
import 'package:habit_checkin/features/assistant/domain/agent_run_metadata.dart';
import 'package:habit_checkin/features/assistant/presentation/agent_run_details.dart';
import 'package:habit_checkin/features/assistant/presentation/assistant_settings_page.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:habit_checkin/shared/presentation.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:xingyuan_core/xingyuan_core.dart';

import 'assistant_conversation_ui_test.dart' show openPlanning, sendText;
import 'journal_diary_capture_test.dart'
    show capture, captureFont, loadDiaryCaptureFont;
import 'support/scripted_agent_service.dart';
import 'support/test_assistant_service.dart';
import 'support/ui_harness.dart';

Future<void> mountDetails(
  WidgetTester tester,
  AgentRunMetadata metadata, {
  Brightness brightness = Brightness.light,
  double scale = 1,
  GlobalKey? boundary,
}) => tester.pumpWidget(
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
        // The process surface intentionally has no ambient Material (C35).
        child: ColoredBox(
          color: brightness == Brightness.light ? Colors.white : Colors.black,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: AgentRunDetails(metadata: metadata, scope: 'running'),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  setUpAll(() async {
    tzdata.initializeTimeZones();
    await loadDiaryCaptureFont();
  });

  for (final tool in agentTools) {
    testWidgets('C39 partial banner is tool-scoped: $tool', (tester) async {
      final metadata = AgentRunMetadata(
        date: CalendarDate(2026, 10, 31),
        statuses: const ['partial'],
        trace: [AgentTraceEntry(tool, 'partial', 10)],
      );
      final encoded = metadata.encode();
      await mountDetails(tester, metadata);
      final conflictTool = const {
        'find_free_slots',
        'validate_plan',
        'submit_plan_draft',
      }.contains(tool);
      expect(
        find.byKey(const ValueKey('agent-data-running-partial')),
        conflictTool ? findsOneWidget : findsNothing,
      );
      expect(
        find.byKey(const ValueKey('agent-trace-running-0')),
        findsOneWidget,
      );
      expect(metadata.encode(), encoded);
      expect(metadata.banners, [agentDataMessages['partial']]);
      expect(tester.takeException(), isNull);
    });
  }

  for (final status in ['failed', 'truncated']) {
    testWidgets('C39 query $status remains visible beside query partial', (
      tester,
    ) async {
      await mountDetails(
        tester,
        AgentRunMetadata(
          date: CalendarDate(2026, 10, 31),
          statuses: ['partial', status],
          trace: [
            const AgentTraceEntry('query_schedule', 'partial', 10),
            AgentTraceEntry('query_schedule', status, 10),
          ],
        ),
      );
      expect(find.text(agentDataMessages[status]!), findsOneWidget);
      expect(find.text(agentDataMessages['partial']!), findsNothing);
      expect(find.text('去打开'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final tool in agentTools) {
    testWidgets('C39 not_authorized names the switch for $tool', (
      tester,
    ) async {
      await mountDetails(
        tester,
        AgentRunMetadata(
          date: CalendarDate(2026, 10, 31),
          statuses: const ['not_authorized'],
          trace: [AgentTraceEntry(tool, 'not_authorized', 10)],
        ),
      );
      final memory = tool == 'get_planning_preferences';
      final notice = tester.widget<NoticeBanner>(find.byType(NoticeBanner));
      expect(notice.message, contains(memory ? '发送记忆' : '发送已有安排'));
      expect(notice.message, isNot(contains(memory ? '发送已有安排' : '发送记忆')));
      expect(find.widgetWithText(TextButton, '去打开'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('C39 combined refusal and conflict survive cached steps', (
    tester,
  ) async {
    final metadata = AgentRunMetadata(
      date: CalendarDate(2026, 10, 31),
      statuses: const ['not_authorized', 'partial'],
      trace: const [
        AgentTraceEntry('query_schedule', 'not_authorized', 1),
        AgentTraceEntry('get_planning_preferences', 'not_authorized', 1),
        AgentTraceEntry('find_free_slots', 'not_authorized', 1),
        AgentTraceEntry('validate_plan', 'partial', 1),
        AgentTraceEntry('validate_plan', 'duplicate', 1),
      ],
    );
    final encoded = metadata.encode();
    await mountDetails(tester, AgentRunMetadata.decode(encoded));
    expect(find.byType(NoticeBanner), findsNWidgets(2));
    expect(find.text('本轮未获「发送已有安排」、「发送记忆」授权，相关内容未纳入规划。'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '去打开'), findsOneWidget);
    expect(find.text(agentDataMessages['partial']!), findsOneWidget);
    expect(metadata.encode(), encoded);
    expect(tester.takeException(), isNull);
  });

  for (final scenario in ['query', 'untimed-plan', 'overlap', 'later']) {
    testUiWidgets(
      'C39 real runner $scenario keeps wire data and banner scope',
      (tester) async {
        final app = UiHarness();
        final service = ScriptedAgentService();
        final untimed = scenario == 'query' || scenario == 'untimed-plan';
        await app.repository.create(
          GoalDraft(
            title: 'TEST 跑步',
            kind: GoalKind.single,
            plannedDay: app.clock.day,
            startMinute: untimed ? null : 420,
            durationMinutes: untimed ? 30 : null,
          ),
        );
        final items = [
          {
            'title': 'TEST 阅读',
            'date': app.clock.day.key,
            'start_minute': scenario == 'later' ? 540 : 450,
            'minutes': 30,
          },
        ];
        final tools = [
          'query_schedule',
          if (scenario != 'query') ...[
            'find_free_slots',
            'validate_plan',
            'submit_plan_draft',
          ],
        ];
        for (final tool in tools) {
          service.script.add(
            (r) async => agentResponse(
              r,
              tool: tool,
              arguments: switch (tool) {
                'query_schedule' => {
                  'from': app.clock.day.key,
                  'to': app.clock.day.key,
                },
                'find_free_slots' => {
                  'from': app.clock.day.key,
                  'to': app.clock.day.key,
                  'minutes': 30,
                  'window': {'start_minute': 360, 'end_minute': 600},
                  'daily_cap': null,
                },
                _ => {
                  'items': items,
                  if (tool == 'submit_plan_draft') 'note': 'TEST 待确认',
                },
              },
            ),
          );
        }
        if (scenario == 'query') {
          service.script.add((r) async => agentResponse(r, text: 'TEST 查询结果'));
        }
        await app.mount(
          tester,
          assistantService: service,
          assistantCredentials: ConversationTestCredentials(),
        );
        await openPlanning(tester);
        await sendText(tester, 'TEST 本轮请求');
        final controller = await app.container.read(
          assistantConversationProvider.future,
        );
        final metadata = AgentRunMetadata.decode(
          controller.messages.last.agentMetadata!,
        );
        expect(metadata.statuses, contains('partial'));
        expect(metadata.trace.first.tool, 'query_schedule');
        expect(metadata.trace.first.status, 'partial');
        expect(service.agentRequests.last.results.first['status'], 'partial');
        expect(
          find.text(agentDataMessages['partial']!),
          scenario == 'overlap' ? findsOneWidget : findsNothing,
        );
        if (scenario != 'query') {
          expect(service.agentRequests, hasLength(4));
          expect(service.agentRequests.last.results[1]['status'], 'ok');
          expect(metadata.partial, scenario == 'overlap' ? {0} : isEmpty);
          final proposal = controller.proposals.single;
          await tapVisible(
            tester,
            find.byKey(ValueKey('adjust-proposal-${proposal.id}')),
          );
          expect(
            find.text(agentDataMessages['partial']!),
            scenario == 'overlap' ? findsOneWidget : findsNothing,
          );
          if (scenario == 'overlap') {
            expect(find.text('可能和「TEST 跑步」07:00 冲突'), findsOneWidget);
            expect(
              tester
                  .widget<FilledButton>(
                    find.byKey(const ValueKey('assistant-apply-plan')),
                  )
                  .onPressed,
              isNull,
            );
          }
        } else {
          expect(service.agentRequests, hasLength(2));
          expect(controller.proposals, isEmpty);
        }
        expect(await app.repository.loadGoals(), hasLength(1));
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final disabled in ['schedule', 'memories', 'both']) {
    testUiWidgets('C39 $disabled refusal opens settings without resending', (
      tester,
    ) async {
      final app = UiHarness();
      final service = ScriptedAgentService();
      await LocalMemoryStore(app.repository).updateSettings(
        sendSchedule: disabled == 'memories',
        sendMemories: disabled == 'schedule',
      );
      for (final tool in ['query_schedule', 'get_planning_preferences']) {
        service.script.add(
          (r) async => agentResponse(
            r,
            tool: tool,
            arguments: tool == 'query_schedule'
                ? {'from': app.clock.day.key, 'to': app.clock.day.key}
                : {},
          ),
        );
      }
      service.script.add((r) async => agentResponse(r));
      await app.mount(
        tester,
        assistantService: service,
        assistantCredentials: ConversationTestCredentials(),
      );
      await openPlanning(tester);
      await sendText(tester, 'TEST 查看安排和偏好');
      final notice = tester.widget<NoticeBanner>(find.byType(NoticeBanner));
      expect(notice.message.contains('发送已有安排'), disabled != 'memories');
      expect(notice.message.contains('发送记忆'), disabled != 'schedule');
      final controller = await app.container.read(
        assistantConversationProvider.future,
      );
      final messages = controller.messages.map((m) => m.id).toList();
      final metadata = controller.messages.last.agentMetadata;
      final input = find.byKey(const ValueKey('assistant-input'));
      await tester.enterText(input, 'TEST 未发送草稿');
      await tapVisible(tester, find.widgetWithText(TextButton, '去打开'));
      expect(find.byType(AssistantSettingsPage), findsOneWidget);
      expect(service.agentRequests, hasLength(3));
      for (final title in [
        if (disabled != 'memories') '发送已有安排',
        if (disabled != 'schedule') '发送记忆',
      ]) {
        final toggle = find.widgetWithText(SwitchListTile, title);
        expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
        await tapVisible(tester, toggle);
      }
      await goBack(tester);
      await tester.pump(const Duration(seconds: 2));
      expect(service.agentRequests, hasLength(3));
      expect(controller.messages.map((m) => m.id), messages);
      expect(controller.messages.last.agentMetadata, metadata);
      expect(tester.widget<TextField>(input).controller!.text, 'TEST 未发送草稿');
      expect(controller.proposals, isEmpty);
      expect(await app.repository.loadGoals(), isEmpty);
      final settings = await LocalMemoryStore(app.repository).settings();
      expect(settings.sendSchedule, isTrue);
      expect(settings.sendMemories, isTrue);
      service.script.add((r) async => agentResponse(r, text: 'TEST 手动再次发送'));
      await sendText(tester, 'TEST 手动再次发送');
      expect(service.agentRequests, hasLength(4));
      expect(tester.takeException(), isNull);
    });
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 3.5]) {
      testWidgets('C39 combined notice ${brightness.name} ${scale}x action', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final boundary = GlobalKey();
        await mountDetails(
          tester,
          AgentRunMetadata(
            date: CalendarDate(2026, 10, 31),
            statuses: const ['not_authorized'],
            trace: const [
              AgentTraceEntry('query_schedule', 'not_authorized', 10),
              AgentTraceEntry('get_planning_preferences', 'not_authorized', 10),
            ],
          ),
          brightness: brightness,
          scale: scale,
          boundary: boundary,
        );
        final semantics = tester.ensureSemantics();
        final action = find.widgetWithText(TextButton, '去打开');
        expect(action, findsOneWidget);
        final message = tester
            .widget<NoticeBanner>(find.byType(NoticeBanner))
            .message;
        if (scale > 1.6) {
          if (captureFont.isNotEmpty) {
            await tester.pumpAndSettle();
            await capture(
              tester,
              boundary,
              'c41-notice-${brightness.name}-$scale-top',
              const Size(320, 568),
              text: find.text(message),
              expectedText: message,
              firstLineOnly: true,
            );
          }
          await Scrollable.ensureVisible(tester.element(action), alignment: 1);
        } else {
          await tester.ensureVisible(action);
        }
        await tester.pumpAndSettle();
        expect(action.hitTestable(), findsOneWidget);
        if (scale > 1.6) {
          // C41: the large-text action must no longer squeeze the message.
          final paragraph = tester.getRect(find.text(message));
          final button = tester.getRect(action);
          expect(paragraph.width, greaterThan(200));
          expect(button.top, greaterThanOrEqualTo(paragraph.bottom));
          expect(button.left, closeTo(paragraph.left, 0.01));
          expect(button.width, greaterThanOrEqualTo(44));
          expect(button.height, greaterThanOrEqualTo(44));
        }
        expect(
          tester.getSemantics(action),
          matchesSemantics(
            label: '去打开',
            isButton: true,
            hasEnabledState: true,
            isEnabled: true,
            hasTapAction: true,
            isFocusable: true,
            hasFocusAction: true,
          ),
        );
        expect(tester.takeException(), isNull);
        // C38 limits Chinese pixel checks to an explicitly loaded font.
        if (captureFont.isNotEmpty) {
          await capture(
            tester,
            boundary,
            'c39-notice-${brightness.name}-$scale',
            const Size(320, 568),
            text: find.text('去打开'),
            expectedText: '去打开',
          );
        }
        semantics.dispose();
      });
    }
  }
}
