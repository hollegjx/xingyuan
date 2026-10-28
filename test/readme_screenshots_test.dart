import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/assistant/assistant_providers.dart';
import 'package:habit_checkin/features/assistant/data/local_memory_store.dart';
import 'package:habit_checkin/features/assistant/domain/agent_run_metadata.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:habit_checkin/features/journal/domain/journal_entry.dart';
import 'package:habit_checkin/features/journal/journal_providers.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'assistant_conversation_ui_test.dart' show openPlanning, sendText;
import 'support/journal_fixtures.dart';
import 'support/record_fixtures.dart';
import 'support/scripted_agent_service.dart';
import 'support/test_assistant_service.dart';
import 'support/ui_harness.dart';

const _output = String.fromEnvironment('README_CAPTURE_DIR');
const _font = String.fromEnvironment('README_CAPTURE_FONT');
const _diary =
    '今天读完了一章，终于看懂了上次折起来的那一页。\n\n'
    '傍晚出门走了一小圈。风有点凉，路边的桂花还开着。'
    '回来的时候买了面包，留一半当明天的早餐。\n\n'
    '还有一件事没做完，先放到明天。今晚想早点休息。';

Future<void> _loadFonts() async {
  for (final font in {
    'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
    'packages/cupertino_icons/CupertinoIcons':
        'packages/cupertino_icons/assets/CupertinoIcons.ttf',
  }.entries) {
    await (FontLoader(font.key)..addFont(rootBundle.load(font.value))).load();
  }
  if (_font.isEmpty) return;
  final bytes = ByteData.sublistView(await File(_font).readAsBytes());
  // Test-process aliases only. No font is bundled or production theme changed.
  for (final family in [
    'Roboto',
    '.SF UI Text',
    '.SF UI Display',
    '.SF Pro Text',
    '.SF Pro Display',
  ]) {
    await (FontLoader(family)..addFont(Future.value(bytes))).load();
  }
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  expect(tester.takeException(), isNull);
  if (_output.isEmpty) return;
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  expect(boundary.debugNeedsPaint, isFalse);
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    try {
      expect(image.width, 780);
      expect(image.height, 1688);
      final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      await Directory(_output).create(recursive: true);
      await File('$_output/$name.png').writeAsBytes(png.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

void _setViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  tester.view.padding = const FakeViewPadding(top: 20, bottom: 20);
  tester.view.viewPadding = const FakeViewPadding(top: 20, bottom: 20);
  tester.view.viewInsets = const FakeViewPadding();
  tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    tester.view.resetPadding();
    tester.view.resetViewPadding();
    tester.view.resetViewInsets();
    tester.platformDispatcher.clearPlatformBrightnessTestValue();
  });
}

void main() {
  setUpAll(() async {
    tzdata.initializeTimeZones();
    if (_output.isNotEmpty && _font.isEmpty) {
      throw StateError('README_CAPTURE_FONT is required when exporting images');
    }
    await _loadFonts();
  });

  testUiWidgets('README journey uses only synthetic local records', (
    tester,
  ) async {
    _setViewport(tester);

    final h = UiHarness();
    h.clock.setDay(2026, 10, 19, hour: 18, minute: 30);
    final reading = await h.repository.create(
      const GoalDraft(
        title: '读几页书',
        kind: GoalKind.habit,
        startMinute: 1200,
        durationMinutes: 20,
      ),
    );
    final walking = await h.repository.create(
      const GoalDraft(title: '出门走走', kind: GoalKind.habit),
    );
    for (final day in [19, 20, 22, 24, 25, 27, 28]) {
      h.clock.setDay(2026, 10, day, hour: 18, minute: 30);
      await h.repository.setCompleted(reading, true, expectedDay: h.clock.day);
      if (day != 20 && day != 25) {
        await h.repository.setCompleted(
          walking,
          true,
          expectedDay: h.clock.day,
        );
      }
    }
    await h.repository.create(
      GoalDraft(
        title: '整理书桌',
        kind: GoalKind.single,
        plannedDay: h.clock.day,
        durationMinutes: 15,
      ),
    );
    final boundary = GlobalKey();
    await h.mount(
      tester,
      recordPhotoFiles: MemoryRecordPhotoFiles(),
      recordPhotoPicker: StubRecordPhotoPicker(),
      journalPhotoFiles: {
        for (final kind in JournalKind.values)
          kind: MemoryJournalPhotoFiles(kind),
      },
      wrapApp: (child) => RepaintBoundary(key: boundary, child: child),
    );
    final notes = await h.container.read(quickNoteStoreProvider.future);
    await saveJournalNotes(notes, [
      '周末想去图书馆，把上次没看完的书找出来。',
      '今天的面包很好吃，下次试试另一种口味。',
    ]);
    await tester.pumpAndSettle();
    expect(find.text('今日已完成 2 项'), findsOneWidget);
    expect(find.text('整理书桌'), findsOneWidget);
    await _capture(tester, boundary, 'today');

    await tapVisible(tester, find.byKey(const ValueKey('entry-diary')));
    await tester.enterText(find.byKey(const ValueKey('journal-text')), _diary);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    expect(find.text('草稿已保存在本机'), findsOneWidget);
    await _capture(tester, boundary, 'diary');
    await tapVisible(tester, find.byKey(const ValueKey('save-journal')));
    final diary = await h.container.read(diaryStoreProvider.future);
    expect((await diary.atDay(h.clock.day))!.entry.content, _diary);

    await tapVisible(tester, find.byTooltip('回顾'));
    expect(
      find.byKey(ValueKey('review-day-${h.clock.day.key}')),
      findsOneWidget,
    );
    await _capture(tester, boundary, 'review');
    expect((await notes.savedOn(h.clock.day)), hasLength(2));
    expect(h.permissions.requests, 0);
  });

  testUiWidgets('README Agent runs local tools before explicit confirmation', (
    tester,
  ) async {
    _setViewport(tester);
    final h = UiHarness();
    h.clock.setDay(2026, 10, 28, hour: 18, minute: 30);
    final day = h.clock.day.key;
    final existing = await h.repository.create(
      GoalDraft(
        title: '晚间拉伸',
        kind: GoalKind.single,
        plannedDay: h.clock.day,
        startMinute: 1200,
        durationMinutes: 30,
      ),
    );
    final memories = LocalMemoryStore(h.repository);
    await memories.add(
      const MemoryDraft(category: '偏好', text: '读书一次 20 分钟，晚上留一点休息时间。'),
    );
    await memories.updateSettings(sendMemories: true, sendSchedule: true);
    final items = [
      {'title': '读几页书', 'date': day, 'start_minute': 1230, 'minutes': 20},
    ];
    final service = ScriptedAgentService();
    // Only model transport is scripted; the app reads and validates local data.
    service.script.addAll([
      (request) async =>
          agentResponse(request, tool: 'get_planning_preferences'),
      (request) async {
        expect(request.results.last['status'], 'ok');
        expect((request.results.last['data'] as Map)['preferences'], [
          {'text': '读书一次 20 分钟，晚上留一点休息时间。'},
        ]);
        return agentResponse(
          request,
          tool: 'query_schedule',
          arguments: {'from': day, 'to': day},
        );
      },
      (request) async {
        expect(request.results.last['status'], 'ok');
        final schedule = (request.results.last['data'] as Map)['items'] as List;
        expect(schedule, hasLength(1));
        expect(schedule.single['title'], '晚间拉伸');
        expect(schedule.single['start_minute'], 1200);
        return agentResponse(
          request,
          tool: 'find_free_slots',
          arguments: {
            'from': day,
            'to': day,
            'minutes': 20,
            'window': {'start_minute': 1200, 'end_minute': 1260},
            'daily_cap': null,
          },
        );
      },
      (request) async {
        expect(request.results.last['status'], 'ok');
        final slots = (request.results.last['data'] as Map)['slots'] as List;
        expect(slots, isNotEmpty);
        expect(slots.first['date'], day);
        expect(slots.first['start_minute'], 1230);
        return agentResponse(
          request,
          tool: 'validate_plan',
          arguments: {'items': items},
        );
      },
      (request) async {
        expect(request.results.last['status'], 'ok');
        return agentResponse(
          request,
          tool: 'submit_plan_draft',
          arguments: {
            'items': items,
            'note': '晚间拉伸之后，20:30 留给读书。\n这份计划还没创建，先看看是否合适。',
          },
        );
      },
    ]);
    final boundary = GlobalKey();
    await h.mount(
      tester,
      assistantService: service,
      assistantCredentials: ConversationTestCredentials(),
      recordPhotoFiles: MemoryRecordPhotoFiles(),
      recordPhotoPicker: StubRecordPhotoPicker(),
      journalPhotoFiles: {
        for (final kind in JournalKind.values)
          kind: MemoryJournalPhotoFiles(kind),
      },
      wrapApp: (child) => RepaintBoundary(key: boundary, child: child),
    );
    await openPlanning(tester);
    await sendText(tester, '今晚 8 点到 9 点，帮我找 20 分钟读书，别和已有安排撞上。');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    final controller = await h.container.read(
      assistantConversationProvider.future,
    );
    final proposal = controller.proposals.single;
    expect(proposal.status, 'draft');
    expect(service.agentRequests, hasLength(5));
    expect(service.script, isEmpty);
    final metadata = AgentRunMetadata.decode(proposal.agentMetadata!);
    expect(metadata.trace.map((step) => step.tool), [
      'get_planning_preferences',
      'query_schedule',
      'find_free_slots',
      'validate_plan',
      'submit_plan_draft',
    ]);
    expect(metadata.trace.every((step) => step.status == 'ok'), isTrue);
    expect(metadata.partial, isEmpty);
    expect((await h.repository.loadGoals()).single.id, existing);
    expect(
      find.byKey(const ValueKey('agent-awaiting-confirmation')),
      findsOneWidget,
    );
    await _capture(tester, boundary, 'agent-chat');

    await tapVisible(
      tester,
      find.byKey(ValueKey('open-proposal-${proposal.id}')),
    );
    await tapVisible(
      tester,
      find.byKey(const ValueKey('agent-trace-proposal')),
    );
    expect(find.text('寻找空档'), findsOneWidget);
    expect(find.text('检查最终草稿'), findsOneWidget);
    expect((await h.repository.loadGoals()).single.id, existing);
    await _capture(tester, boundary, 'agent-plan');

    await tapVisible(
      tester,
      find.byKey(const ValueKey('assistant-apply-plan')),
    );
    final goals = await h.repository.loadGoals();
    expect(goals, hasLength(2));
    final reading = goals.singleWhere(
      (goal) => goal.titleOn(h.clock.day) == '读几页书',
    );
    expect(reading.scheduleOn(h.clock.day).startMinute, 1230);
    expect(reading.scheduleOn(h.clock.day).durationMinutes, 20);
    expect(
      (await h.database.select(h.database.planProposals).get()).single.status,
      'applied',
    );
    expect(service.agentRequests, hasLength(5));
    expect(h.permissions.requests, 0);
  });
}
