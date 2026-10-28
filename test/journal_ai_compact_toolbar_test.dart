import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/assistant/assistant_providers.dart';
import 'package:habit_checkin/features/journal/domain/journal_entry.dart';
import 'package:habit_checkin/features/journal/journal_providers.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'assistant_diary_ui_test.dart' show tapDiaryControl;
import 'journal_diary_capture_test.dart' show loadDiaryCaptureFont;
import 'journal_writing_space_test.dart'
    show configure, keyboard, openEditor, writing;
import 'support/ui_harness.dart';

void main() {
  setUpAll(() async {
    tzdata.initializeTimeZones();
    await loadDiaryCaptureFont();
  });
  Finder key(String value) => find.byKey(ValueKey(value));
  for (final kind in JournalKind.values) {
    for (final theme in Brightness.values) {
      for (final scenario in [
        (width: 600.0, scale: 1.6, compact: false),
        (width: 600.0, scale: 1.61, compact: true),
        (width: 240.0, scale: 1.6, compact: true),
        (width: 320.0, scale: 3.5, compact: true),
        (width: 320.0, scale: 4.0, compact: true),
      ]) {
        testUiWidgets(
          'C22 toolbar ${kind.name} ${theme.name} ${scenario.width}/${scenario.scale}',
          (tester) async {
            configure(tester, Size(scenario.width, 844), scenario.scale, theme);
            final (app, ai) = await openEditor(tester, GlobalKey(), kind);
            keyboard(tester, 200);
            await tester.pumpAndSettle();
            final action = key('journal-ai-request');
            expect(action.hitTestable(), findsOneWidget);
            expect(
              find.descendant(
                of: key('journal-editor-scroll'),
                matching: action,
              ),
              findsNothing,
            );
            final rect = tester.getRect(action);
            expect(rect.width, greaterThanOrEqualTo(44));
            expect(rect.height, greaterThanOrEqualTo(44));
            final label = kind == JournalKind.diary ? 'AI 写日记' : '润色';
            expect(find.byTooltip(label), findsOneWidget);
            expect(
              find.descendant(of: action, matching: find.text(label)),
              scenario.compact ? findsNothing : findsOneWidget,
            );
            final handle = tester.ensureSemantics();
            try {
              await tester.pump();
              final semantics = tester.getSemantics(action).getSemanticsData();
              expect(semantics.label, label);
              expect(semantics.flagsCollection.isButton, isTrue);
              expect(semantics.hasAction(ui.SemanticsAction.tap), isTrue);
            } finally {
              handle.dispose();
            }
            final button = tester.widget<TextButton>(action);
            expect(button.onPressed, isNotNull);
            expect(button.style!.shape!.resolve({}), isA<StadiumBorder>());
            expect(
              button.style!.backgroundColor!.resolve({})!.a,
              greaterThan(0),
            );
            expect(
              MediaQuery.textScalerOf(tester.element(key('journal-text')))
                  .scale(17),
              closeTo(17 * scenario.scale, .001),
            );
            await tapDiaryControl(tester, action);
            expect(find.text('开启 AI 功能'), findsOneWidget);
            expect(ai.calls, isEmpty);
            expect(app.container.exists(assistantServiceProvider), isFalse);
            await tapDiaryControl(tester, find.text('取消'));
            final store = await app.container.read(
              journalStoreProvider(kind).future,
            );
            expect(await store.savedOn(app.clock.day), isEmpty);
            expect(
              (await store.onDay(app.clock.day)).single.entry.draftText,
              writing.text,
            );
            expect(tester.takeException(), isNull);
          },
          variant: TargetPlatformVariant.only(TargetPlatform.iOS),
        );
      }
    }
  }
}
