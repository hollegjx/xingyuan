import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:habit_checkin/features/journal/domain/journal_entry.dart';
import 'package:habit_checkin/features/journal/journal_providers.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'support/journal_fixtures.dart';
import 'support/record_fixtures.dart';
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
}
