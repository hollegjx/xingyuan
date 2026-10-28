import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/app/providers.dart';
import 'package:habit_checkin/data/sync/identity_store.dart';
import 'package:habit_checkin/data/sync/sync_identity.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:habit_checkin/features/records/data/record_photo.dart';
import 'package:habit_checkin/features/records/presentation/day_record_page.dart';
import 'package:image/image.dart' as img;
import 'package:timezone/data/latest.dart' as tzdata;

import 'support/record_fixtures.dart';
import 'support/layout_capture.dart';
import 'support/ui_harness.dart';

void main() {
  final capture = LayoutCapture();
  setUpAll(() async {
    tzdata.initializeTimeZones();
    await capture.prepare();
  });

  Future<int> seed(UiHarness app) => app.repository.create(
    const GoalDraft(
      title: 'TEST record goal',
      kind: GoalKind.habit,
      weekdays: 127,
    ),
  );

  Future<void> open(WidgetTester tester, UiHarness app, int goal) => tapVisible(
    tester,
    find.byKey(ValueKey('record-$goal-${app.clock.day.key}')),
  );

  testUiWidgets(
    'draft survives back and tab switch; five saves publish once in today detail review',
    (tester) async {
      final app = UiHarness();
      final goal = await seed(app);
      await app.mount(tester, recordPhotoFiles: MemoryRecordPhotoFiles());
      await open(tester, app, goal);
      await tester.enterText(
        find.byKey(const ValueKey('record-text')),
        'TEST saved after return\nsecond line',
      );
      // Leave without waiting for the draft write first.
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(DayRecordPage), findsNothing);
      await tapVisible(tester, find.text('回顾').last);
      await tapVisible(tester, find.text('今天').last);
      await open(tester, app, goal);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('record-text')))
            .controller!
            .text,
        'TEST saved after return\nsecond line',
      );
      final save = find.byKey(const ValueKey('save-record'));
      await tester.ensureVisible(save);
      for (var i = 0; i < 5; i++) {
        await tester.tap(save);
      }
      await tester.pumpAndSettle();
      expect(find.byType(DayRecordPage), findsNothing);
      expect(find.text('TEST saved after return\nsecond line'), findsOneWidget);
      final row =
          (await app.database.select(app.database.dayRecords).get()).single;
      expect(row.revision, 1);
      await tapVisible(tester, find.byKey(ValueKey('detail-$goal')));
      expect(find.text('TEST saved after return\nsecond line'), findsOneWidget);
      await goBack(tester);
      await tapVisible(tester, find.text('回顾').last);
      expect(find.text('TEST saved after return\nsecond line'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testUiWidgets(
    'empty and oversized input stay editable, Unicode boundary saves without truncation',
    (tester) async {
      final app = UiHarness();
      final goal = await seed(app);
      await app.mount(tester, recordPhotoFiles: MemoryRecordPhotoFiles());
      await open(tester, app, goal);
      await tapVisible(tester, find.byKey(const ValueKey('save-record')));
      expect(find.text('请写下文字或添加照片'), findsOneWidget);
      final text = '${'👨‍👩‍👧‍👦' * 498}\ne\u0301';
      await tester.enterText(
        find.byKey(const ValueKey('record-text')),
        '$text!',
      );
      await tester.pumpAndSettle();
      await tapVisible(tester, find.byKey(const ValueKey('save-record')));
      expect(find.byType(DayRecordPage), findsOneWidget);
      expect(
        (await app.database.select(app.database.dayRecords).get())
            .single
            .savedAt,
        isNull,
      );
      await tester.enterText(find.byKey(const ValueKey('record-text')), text);
      await tester.pumpAndSettle();
      await tapVisible(tester, find.byKey(const ValueKey('save-record')));
      expect(
        (await app.database.select(app.database.dayRecords).get())
            .single
            .content,
        text,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testUiWidgets('oversized photo leaves record text editable and saveable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 20);
    tester.view.viewPadding = const FakeViewPadding(top: 20);
    tester.view.viewInsets = const FakeViewPadding();
    tester.platformDispatcher.textScaleFactorTestValue = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    addTearDown(tester.view.resetViewInsets);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final app = UiHarness();
    final goal = await seed(app);
    final files = MemoryRecordPhotoFiles();
    final picker = StubRecordPhotoPicker()
      ..onPick = () async => Uint8List(maxRecordPhotoInputBytes + 1);
    await app.mount(
      tester,
      recordPhotoFiles: files,
      recordPhotoPicker: picker,
      wrapApp: capture.wrap,
    );
    await open(tester, app, goal);
    final input = find.byKey(const ValueKey('record-text'));
    const text = 'SYNTHETIC text survives oversized photo';
    await tester.enterText(input, text);
    await tester.pumpAndSettle();
    await tapVisible(tester, find.byKey(const ValueKey('record-library')));
    expect(find.text('照片过大或无法读取，请重新选择'), findsOneWidget);
    expect(tester.widget<TextField>(input).controller!.text, text);
    expect(files.entries, isEmpty);
    expect(await app.database.select(app.database.recordPhotos).get(), isEmpty);
    await capture.shot(tester, 1, 'record-photo-too-large');
    await tapVisible(tester, find.byKey(const ValueKey('save-record')));
    final saved =
        (await app.database.select(app.database.dayRecords).get()).single;
    expect(saved.content, text);
    expect(saved.savedAt, isNotNull);
    expect(await app.database.select(app.database.checkIns).get(), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testUiWidgets(
    'denied photo permission does not block saving or check-in; deletion confirms independently',
    (tester) async {
      final app = UiHarness();
      final goal = await seed(app);
      final picker = StubRecordPhotoPicker()
        ..onPick = () async =>
            throw const RecordPhotoException('未获得相机权限，仍可写文字或从相册选照片');
      await app.mount(
        tester,
        recordPhotoFiles: MemoryRecordPhotoFiles(),
        recordPhotoPicker: picker,
      );
      await open(tester, app, goal);
      await tester.enterText(
        find.byKey(const ValueKey('record-text')),
        'TEST independent record',
      );
      await tester.pumpAndSettle();
      await tapVisible(tester, find.byKey(const ValueKey('record-camera')));
      expect(find.textContaining('未获得相机权限'), findsOneWidget);
      await tapVisible(tester, find.byKey(const ValueKey('save-record')));
      await tapVisible(tester, find.byKey(ValueKey('complete-$goal')));
      await tapVisible(tester, find.byKey(ValueKey('undo-$goal')));
      expect(find.text('TEST independent record'), findsOneWidget);
      await tapVisible(tester, find.byKey(ValueKey('complete-$goal')));
      await open(tester, app, goal);
      await tapVisible(tester, find.byKey(const ValueKey('delete-record')));
      await tapVisible(tester, find.text('取消'));
      expect(
        (await app.database.select(app.database.dayRecords).get())
            .single
            .content,
        'TEST independent record',
      );
      await tapVisible(tester, find.byKey(const ValueKey('delete-record')));
      await tapVisible(
        tester,
        find.byKey(const ValueKey('confirm-delete-record')),
      );
      expect(find.text('TEST independent record'), findsNothing);
      expect(
        (await app.database.select(app.database.checkIns).get())
            .single
            .completed,
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testUiWidgets(
    'identity change dismisses deletion and never revives old record editor',
    (tester) async {
      final app = UiHarness();
      final goal = await seed(app);
      await app.mount(tester, recordPhotoFiles: MemoryRecordPhotoFiles());
      await open(tester, app, goal);
      await tester.enterText(
        find.byKey(const ValueKey('record-text')),
        'TEST private input',
      );
      await tester.pumpAndSettle();
      await tapVisible(tester, find.byKey(const ValueKey('delete-record')));
      final identity = IdentityStore(app.database);
      await identity.finish(
        await identity.begin(
          SyncIdentity.account('55555555-5555-4555-8555-555555555555'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byKey(const ValueKey('record-text')), findsNothing);
      await identity.finish(await identity.begin(SyncIdentity.guest));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('record-text')), findsNothing);
      expect(
        (await app.database.select(app.database.dayRecords).get())
            .single
            .draftText,
        'TEST private input',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testUiWidgets(
    'pending picker and midnight preserve original date, cancellation remains harmless',
    (tester) async {
      final app = UiHarness();
      final day = app.clock.day;
      final goal = await seed(app);
      final picked = Completer<Uint8List?>();
      final picker = StubRecordPhotoPicker()..onPick = () => picked.future;
      await app.mount(
        tester,
        recordPhotoFiles: MemoryRecordPhotoFiles(),
        recordPhotoPicker: picker,
      );
      await open(tester, app, goal);
      await tester.enterText(
        find.byKey(const ValueKey('record-text')),
        'TEST midnight',
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('record-library')));
      for (var i = 0; i < 5; i++) {
        await tester.tap(find.byKey(const ValueKey('record-library')));
      }
      await tester.pump();
      expect(picker.calls, 1);
      app.clock.setDay(day.year, day.month, day.day + 1);
      await app.container.read(environmentProvider.notifier).refresh();
      picked.complete(null);
      await tester.pumpAndSettle();
      await tapVisible(tester, find.byKey(const ValueKey('save-record')));
      expect(
        (await app.database.select(app.database.dayRecords).get()).single.day,
        day.key,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testUiWidgets('archiving a goal keeps its unsaved record draft readable', (
    tester,
  ) async {
    final app = UiHarness();
    final goal = await seed(app);
    await app.mount(tester, recordPhotoFiles: MemoryRecordPhotoFiles());
    await open(tester, app, goal);
    await tester.enterText(
      find.byKey(const ValueKey('record-text')),
      'TEST archived draft remains readable',
    );
    await tester.pumpAndSettle();
    await goBack(tester);
    await tapVisible(tester, find.byKey(ValueKey('detail-$goal')));
    await tapVisible(tester, find.byKey(const ValueKey('archive-goal')));
    await tapVisible(tester, find.byKey(const ValueKey('confirm-archive')));
    await open(tester, app, goal);
    expect(find.text('TEST archived draft remains readable'), findsOneWidget);
    expect(find.byKey(const ValueKey('record-text')), findsNothing);
    expect(find.byKey(const ValueKey('save-record')), findsNothing);
    expect(
      (await app.database.select(app.database.dayRecords).get())
          .single
          .draftText,
      'TEST archived draft remains readable',
    );
  });

  testUiWidgets(
    'two photo imports, one removal and preview preserve the selected pixels',
    (tester) async {
      final app = UiHarness();
      final goal = await seed(app);
      final source = img.Image(width: 40, height: 30);
      img.fill(source, color: img.ColorRgb8(200, 60, 90));
      final picker = StubRecordPhotoPicker()
        ..onPick = () async => img.encodePng(source);
      final files = MemoryRecordPhotoFiles();
      await app.mount(
        tester,
        recordPhotoFiles: files,
        recordPhotoPicker: picker,
      );
      await open(tester, app, goal);
      Future<void> import(int count) async {
        await tester.ensureVisible(
          find.byKey(const ValueKey('record-library')),
        );
        await tester.tap(find.byKey(const ValueKey('record-library')));
        await tester.pump();
        // Let the real image isolate finish, then deliver its result in the widget zone.
        for (var attempt = 0; attempt < 200; attempt++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 25)),
          );
          await tester.pump();
          if (find.byTooltip('移除照片').evaluate().length == count) break;
        }
        await tester.pumpAndSettle();
        expect(find.byTooltip('移除照片'), findsNWidgets(count));
      }

      await import(1);
      await import(2);
      final before = await app.database.select(app.database.recordPhotos).get();
      await tapVisible(
        tester,
        find.byKey(ValueKey('remove-photo-${before.last.id}')),
      );
      expect(find.byTooltip('移除照片'), findsOneWidget);
      await tapVisible(tester, find.byKey(const ValueKey('save-record')));
      final photo =
          (await app.database.select(app.database.recordPhotos).get()).single;
      expect(photo.id, before.first.id);
      expect(files.entries, hasLength(1));
      await tapVisible(tester, find.byKey(ValueKey('photo-${photo.id}')));
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final scale in [1.0, 2.0, 3.0]) {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      testUiWidgets('record editor fits 320px scale $scale $brightness', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1;
        tester.view.padding = const FakeViewPadding(top: 20);
        tester.view.viewPadding = const FakeViewPadding(top: 20);
        tester.view.viewInsets = const FakeViewPadding();
        tester.platformDispatcher.platformBrightnessTestValue = brightness;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPadding);
        addTearDown(tester.view.resetViewPadding);
        addTearDown(tester.view.resetViewInsets);
        addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final app = UiHarness();
        final goal = await seed(app);
        await app.mount(
          tester,
          recordPhotoFiles: MemoryRecordPhotoFiles(),
          wrapApp: capture.wrap,
        );
        await open(tester, app, goal);
        expect(
          MediaQuery.textScalerOf(
            tester.element(find.byKey(const ValueKey('record-text'))),
          ).scale(10),
          10 * scale,
        );
        await tester.enterText(
          find.byKey(const ValueKey('record-text')),
          'TEST 多行记录\n今天调整了安排',
        );
        await tester.pumpAndSettle();
        expect(tester.getRect(find.byType(AppBar)).top, 0);
        tester.view.viewInsets = const FakeViewPadding(bottom: 200);
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const ValueKey('record-text')));
        await tester.pumpAndSettle();
        await capture.shot(tester, scale, 'record-${brightness.name}-input');
        await tester.ensureVisible(find.byKey(const ValueKey('save-record')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('save-record')).hitTestable(),
          findsOneWidget,
        );
        expect(
          tester.getRect(find.byKey(const ValueKey('save-record'))).bottom,
          lessThanOrEqualTo(368),
        );
        await capture.shot(tester, scale, 'record-${brightness.name}-save');
        tester.view.viewInsets = const FakeViewPadding();
        await tester.pumpAndSettle();
        await tapVisible(tester, find.byKey(const ValueKey('save-record')));
        expect(find.byType(DayRecordPage), findsNothing);
        expect(tester.takeException(), isNull);
        await capture.passed(tester, scale);
      });
    }
  }
}
