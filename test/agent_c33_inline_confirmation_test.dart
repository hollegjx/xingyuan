import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/app/providers.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/sync/identity_store.dart';
import 'package:habit_checkin/features/assistant/assistant_providers.dart';
import 'package:habit_checkin/features/assistant/data/local_conversation_store.dart';
import 'package:habit_checkin/features/assistant/data/local_proposal_store.dart';
import 'package:habit_checkin/features/assistant/domain/agent_run_metadata.dart';
import 'package:habit_checkin/features/assistant/domain/plan_preview.dart';
import 'package:habit_checkin/features/assistant/presentation/assistant_proposal_page.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:habit_checkin/features/reminders/notification_permissions.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:xingyuan_core/xingyuan_core.dart';

import 'assistant_conversation_ui_test.dart' show openPlanning;
import 'journal_diary_capture_test.dart' show capture, loadDiaryCaptureFont;
import 'support/assistant_fixtures.dart';
import 'support/scripted_agent_service.dart';
import 'support/sync_fixtures.dart';
import 'support/test_assistant_service.dart';
import 'support/ui_harness.dart';

class _Proposals extends LocalProposalStore {
  _Proposals(super.goals);
  Future<void> Function()? afterInspection;
  Future<void> Function()? beforeApply;
  int inspections = 0;
  int applies = 0;
  String? token;

  @override
  Future<AgentConfirmationCheck?> inspectAgent(
    String id,
    PlanPreview preview,
  ) async {
    inspections++;
    final result = await super.inspectAgent(id, preview);
    final hook = afterInspection;
    afterInspection = null;
    await hook?.call();
    return result;
  }

  @override
  Future<List<int>> apply(
    String id,
    PlanPreview preview, {
    bool partialAcknowledged = false,
    String? expectedAgentValidation,
  }) async {
    applies++;
    token = expectedAgentValidation;
    final hook = beforeApply;
    beforeApply = null;
    await hook?.call();
    return super.apply(
      id,
      preview,
      partialAcknowledged: partialAcknowledged,
      expectedAgentValidation: expectedAgentValidation,
    );
  }
}

class _Store extends LocalConversationStore {
  _Store(super.goals);
  late final _proposals = _Proposals(goals);
  @override
  _Proposals get proposals => _proposals;
}

class _Fixture {
  final app = UiHarness();
  final service = ScriptedAgentService();
  late _Store store;
  late PlanPreview preview;
  late String id;
  Finder get confirm => find.byKey(ValueKey('open-proposal-$id'));

  Future<void> mount(
    WidgetTester tester, {
    bool agent = true,
    bool reminders = false,
    GlobalKey? boundary,
  }) async {
    final lease = await IdentityStore(app.database).active();
    store = _Store(
      LocalGoalRepository(app.database, app.clock, identityLease: lease),
    );
    await store.memories.consent();
    await seedAssistantReply(app.database);
    preview = syntheticPreview(count: 2, reminders: reminders);
    id = await store.proposals.saveDraft(
      sessionId: 'test-session',
      messageId: 'test-message',
      preview: preview,
      agentMetadata: agent
          ? AgentRunMetadata(date: CalendarDate.parse(app.clock.day.key))
          : null,
    );
    await app.mount(
      tester,
      assistantStore: store,
      assistantService: service,
      assistantCredentials: ConversationTestCredentials(),
      wrapApp: boundary == null
          ? null
          : (child) => RepaintBoundary(key: boundary, child: child),
    );
    await openPlanning(tester);
  }

  Future<void> unchanged({int goals = 0}) async {
    expect(await app.repository.loadGoals(), hasLength(goals));
    final row = await app.database
        .select(app.database.planProposals)
        .getSingle();
    expect(row.status, 'draft');
    expect(row.appliedGoalIdsJson, isNull);
    expect(service.agentRequests, isEmpty);
    expect(service.requests, isEmpty);
    expect(app.permissions.requests, 0);
  }

  Future<void> addConflict({bool unknown = false}) async {
    await app.repository.create(
      GoalDraft(
        title: 'TEST changed schedule',
        kind: GoalKind.single,
        plannedDay: app.clock.day,
        startMinute: 1140, // C36 partial requires an overlapping timed row.
        durationMinutes: unknown ? null : 30,
      ),
    );
  }
}

void main() {
  setUpAll(() async {
    tzdata.initializeTimeZones();
    await loadDiaryCaptureFont();
  });

  for (final reminders in [false, true]) {
    testUiWidgets(
      'C33 eligible Agent applies inline with token and reminders=$reminders',
      (tester) async {
        final f = _Fixture();
        f.app.permissions.access = NotificationAccess.allowed;
        await f.mount(tester, reminders: reminders);
        await f.unchanged();
        final oldReads = f.app.permissions.reads;
        await tapVisible(tester, f.confirm);
        expect(find.byType(AssistantProposalPage), findsNothing);
        expect(find.text('已添加 2 项'), findsOneWidget);
        expect(f.store.proposals.applies, 1);
        expect(f.store.proposals.token, isNotNull);
        expect(await f.app.repository.loadGoals(), hasLength(2));
        expect((await f.store.proposals.read(f.id)).status, 'applied');
        if (reminders) expect(f.app.permissions.reads, greaterThan(oldReads));
        expect(f.app.permissions.requests, 0);
        expect(f.app.container.read(reminderReportProvider).hasError, isFalse);
        if (reminders) expect(f.app.notifications.requests, hasLength(2));
        expect(f.service.agentRequests, isEmpty);
        await tapVisible(tester, find.byKey(ValueKey('undo-proposal-${f.id}')));
        await tapVisible(
          tester,
          find.byKey(const ValueKey('assistant-undo-confirm')),
        );
        expect(await f.app.repository.loadGoals(), isEmpty);
      },
    );
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 3.5]) {
      testUiWidgets(
        'C33 card ${brightness.name} ${scale}x confirmation and receipt stay reachable',
        (tester) async {
          final size = scale == 1 ? const Size(390, 844) : const Size(320, 568);
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          tester.view.padding = const FakeViewPadding(top: 20);
          tester.view.viewPadding = const FakeViewPadding(top: 20);
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          tester.platformDispatcher.platformBrightnessTestValue = brightness;
          addTearDown(() {
            tester.view.resetPhysicalSize();
            tester.view.resetDevicePixelRatio();
            tester.view.resetPadding();
            tester.view.resetViewPadding();
            tester.platformDispatcher.clearTextScaleFactorTestValue();
            tester.platformDispatcher.clearPlatformBrightnessTestValue();
          });
          final f = _Fixture();
          final boundary = GlobalKey();
          await f.mount(tester, boundary: boundary);
          final header = find.byKey(const ValueKey('assistant-navigation'));
          expect(tester.getTopLeft(header).dy, 20);
          await tester.ensureVisible(f.confirm);
          await tester.pumpAndSettle();
          expect(f.confirm.hitTestable(), findsOneWidget);
          expect(tester.getSize(f.confirm).height, greaterThanOrEqualTo(44));
          await capture(
            tester,
            boundary,
            'c33-${brightness.name}-$scale-draft',
            size,
            text: find.text('确认添加'),
            expectedText: '确认添加',
          );
          await tapVisible(tester, f.confirm);
          expect(find.byType(AssistantProposalPage), findsNothing);
          final undo = find.byKey(ValueKey('undo-proposal-${f.id}'));
          await tester.ensureVisible(undo);
          await tester.pumpAndSettle();
          expect(undo.hitTestable(), findsOneWidget);
          expect(tester.getSize(undo).height, greaterThanOrEqualTo(44));
          await capture(
            tester,
            boundary,
            'c33-${brightness.name}-$scale-applied',
            size,
            text: find.text('撤销'),
            expectedText: '撤销',
          );
          expect(await f.app.repository.loadGoals(), hasLength(2));
          expect(f.service.agentRequests, isEmpty);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final reason in [
    'legacy',
    'conflict',
    'partial',
    'expired',
    'permission',
    'permission_error',
    'revoked',
    'edited',
    'empty',
  ]) {
    testUiWidgets(
      'C33 $reason falls back without creation or automatic permission',
      (tester) async {
        final f = _Fixture();
        await f.mount(
          tester,
          agent: reason != 'legacy',
          reminders: reason.startsWith('permission'),
        );
        if (reason == 'conflict' || reason == 'partial') {
          await f.addConflict(unknown: reason == 'partial');
        }
        if (reason == 'expired') f.app.clock.setDay(2026, 10, 10);
        if (reason == 'permission_error') {
          f.app.permissions.failure = StateError('TEST permission');
        }
        if (reason == 'revoked') {
          await f.store.memories.updateSettings(sendSchedule: false);
        }
        if (reason == 'edited' || reason == 'empty') {
          await f.store.proposals.editDraft(
            f.id,
            reason == 'empty'
                ? PlanPreview([])
                : f.preview.remove(f.preview.items.last.id),
          );
        }
        await tapVisible(tester, f.confirm);
        expect(find.byType(AssistantProposalPage), findsOneWidget);
        expect(f.store.proposals.applies, 0);
        await f.unchanged(
          goals: reason == 'conflict' || reason == 'partial' ? 1 : 0,
        );
        if (reason == 'partial') {
          expect(
            find.byKey(const ValueKey('agent-partial-acknowledgement')),
            findsOneWidget,
          );
        }
      },
    );
  }

  for (final change in ['conflict', 'edit', 'revoke', 'apply_failure']) {
    testUiWidgets('C33 $change between inspection and transaction falls back', (
      tester,
    ) async {
      final f = _Fixture();
      await f.mount(tester);
      f.store.proposals.beforeApply = () async {
        switch (change) {
          case 'conflict':
            await f.addConflict();
          case 'edit':
            await f.store.proposals.editDraft(
              f.id,
              f.preview.remove(f.preview.items.last.id),
            );
          case 'revoke':
            await f.store.memories.updateSettings(sendSchedule: false);
          case 'apply_failure':
            throw StateError('TEST apply failure');
        }
      };
      await tapVisible(tester, f.confirm);
      expect(f.store.proposals.applies, 1);
      expect(f.store.proposals.token, isNotNull);
      expect(find.byType(AssistantProposalPage), findsOneWidget);
      await f.unchanged(goals: change == 'conflict' ? 1 : 0);
    });
  }

  testUiWidgets(
    'C33 reconciliation failure opens saved receipt without applying twice',
    (tester) async {
      final f = _Fixture();
      f.app.permissions.access = NotificationAccess.allowed;
      await f.mount(tester, reminders: true);
      f.app.notifications.failure = StateError('TEST reconciliation');
      await tapVisible(tester, f.confirm);
      expect(find.byType(AssistantProposalPage), findsOneWidget);
      expect(f.store.proposals.applies, 1);
      expect(await f.app.repository.loadGoals(), hasLength(2));
      expect(find.text('提醒安排或取消未确认，记录已保存。'), findsOneWidget);
      expect((await f.store.proposals.read(f.id)).status, 'applied');
      expect(f.service.agentRequests, isEmpty);
    },
  );

  testUiWidgets(
    'C33 reminder permission is reread instead of trusting cached allowance',
    (tester) async {
      final f = _Fixture();
      f.app.permissions.access = NotificationAccess.allowed;
      await f.mount(tester, reminders: true);
      f.app.permissions.access = NotificationAccess.off;
      await tapVisible(tester, f.confirm);
      expect(find.byType(AssistantProposalPage), findsOneWidget);
      expect(f.store.proposals.applies, 0);
      await f.unchanged();
    },
  );

  testUiWidgets(
    'C33 pending inspection deduplicates callbacks and late repeated confirmation',
    (tester) async {
      final f = _Fixture();
      await f.mount(tester);
      final release = Completer<void>();
      f.store.proposals.afterInspection = () => release.future;
      final confirm = tester.widget<FilledButton>(f.confirm).onPressed!;
      confirm();
      confirm();
      try {
        await pumpWaiting(tester);
        expect(f.store.proposals.inspections, 1);
        expect(tester.widget<FilledButton>(f.confirm).onPressed, isNull);
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(ValueKey('adjust-proposal-${f.id}')),
              )
              .onPressed,
          isNull,
        );
        await f.unchanged();
      } finally {
        release.complete();
        await tester.pumpAndSettle();
      }
      expect(f.store.proposals.applies, 1);
      expect(await f.app.repository.loadGoals(), hasLength(2));
      confirm();
      await tester.pumpAndSettle();
      expect(f.store.proposals.applies, 1);
      expect(await f.app.repository.loadGoals(), hasLength(2));
    },
  );

  testUiWidgets(
    'C33 fallback is a single route even with repeated stale callbacks',
    (tester) async {
      final f = _Fixture();
      await f.mount(tester, agent: false);
      final confirm = tester.widget<FilledButton>(f.confirm).onPressed!;
      confirm();
      confirm();
      await tester.pumpAndSettle();
      confirm();
      await tester.pumpAndSettle();
      await goBack(tester);
      expect(find.byType(AssistantProposalPage), findsNothing);
      expect(
        find.byType(AssistantProposalPage, skipOffstage: false),
        findsNothing,
      );
      await f.unchanged();
    },
  );

  for (final change in ['identity', 'session', 'disposed']) {
    testUiWidgets(
      'C33 $change while inspection is pending cannot save or open stale content',
      (tester) async {
        final f = _Fixture();
        await f.mount(tester);
        final release = Completer<void>();
        f.store.proposals.afterInspection = () => release.future;
        tester.widget<FilledButton>(f.confirm).onPressed!();
        try {
          await pumpWaiting(tester);
          expect(f.store.proposals.inspections, 1);
          if (change == 'identity') {
            final ids = IdentityStore(f.app.database);
            await ids.finish(await ids.begin(accountA));
          } else if (change == 'session') {
            await (await f.app.container.read(
              assistantConversationProvider.future,
            )).create();
          } else {
            await tester.pumpWidget(const SizedBox.shrink());
          }
          await tester.pump();
        } finally {
          release.complete();
          await tester.pumpAndSettle();
        }
        expect(f.store.proposals.applies, 0);
        expect(find.byType(AssistantProposalPage), findsNothing);
        final rows = await f.app.database.select(f.app.database.goals).get();
        expect(rows, isEmpty);
        expect(f.service.agentRequests, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
