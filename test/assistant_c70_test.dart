import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/assistant/data/local_conversation_store.dart';
import 'package:habit_checkin/features/journal/domain/journal_entry.dart';
import 'package:habit_checkin/features/journal/presentation/journal_editor_page.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'support/journal_fixtures.dart';
import 'support/test_assistant_service.dart';
import 'support/ui_harness.dart';

void main() {
  const directory = String.fromEnvironment('C70_CAPTURE_DIR');
  const font = String.fromEnvironment('C70_CAPTURE_FONT');
  setUpAll(() async {
    tzdata.initializeTimeZones();
    if (font.isNotEmpty) {
      final bytes = ByteData.sublistView(await File(font).readAsBytes());
      for (final family in [
        'Roboto',
        '.SF UI Text',
        '.SF UI Display',
        '.SF Pro Text',
        '.SF Pro Display',
        'CupertinoSystemText',
        'CupertinoSystemDisplay',
      ]) {
        await (FontLoader(family)..addFont(Future.value(bytes))).load();
      }
      await (FontLoader('XySerif')
            ..addFont(rootBundle.load('assets/fonts/XySerif-400.ttf'))
            ..addFont(rootBundle.load('assets/fonts/XySerif-600.ttf')))
          .load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      await (FontLoader('packages/cupertino_icons/CupertinoIcons')..addFont(
            rootBundle.load(
              'packages/cupertino_icons/assets/CupertinoIcons.ttf',
            ),
          ))
          .load();
    }
  });
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 3.5]) {
      testUiWidgets('C70 today diary entry ${brightness.name} $scale', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.platformBrightnessTestValue = brightness;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          tester.platformDispatcher.clearPlatformBrightnessTestValue();
          tester.platformDispatcher.clearTextScaleFactorTestValue();
        });
        final app = UiHarness()..clock.setDay(2026, 11, 1, hour: 22);
        await LocalConversationStore(app.repository).memories.consent();
        final boundary = GlobalKey();
        final service = ConversationTestService();
        await app.mount(
          tester,
          journalPhotoFiles: {
            for (final kind in JournalKind.values)
              kind: MemoryJournalPhotoFiles(kind),
          },
          assistantService: service,
          assistantCredentials: ConversationTestCredentials(),
          wrapApp: (child) => RepaintBoundary(key: boundary, child: child),
        );
        await tapVisible(tester, find.byTooltip('助手'));
        expect(find.text('今天想做点什么？'), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (directory.isNotEmpty) {
          await tester.runAsync(() async {
            final render =
                boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await render.toImage();
            try {
              final data = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              await Directory(directory).create(recursive: true);
              await File('$directory/${brightness.name}-$scale.png')
                  .writeAsBytes(data!.buffer.asUint8List());
            } finally {
              image.dispose();
            }
          });
        }
        final diaryEntry = find.byKey(const ValueKey('assistant-write-diary'));
        await tester.ensureVisible(diaryEntry);
        await tester.pump();
        await tester.tap(diaryEntry);
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)),
        );
        await tester.pump(const Duration(milliseconds: 500));
        final editor = tester.widget<JournalEditorPage>(
          find.byType(JournalEditorPage),
        );
        expect(editor.kind, JournalKind.diary);
        expect(editor.day, app.clock.read().day);
        expect(service.requests, isEmpty);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
