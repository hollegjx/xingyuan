import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/assistant/assistant_providers.dart';
import 'package:habit_checkin/features/companion/companion_providers.dart';
import 'package:habit_checkin/features/journal/domain/journal_entry.dart';
import 'package:habit_checkin/features/journal/journal_providers.dart';
import 'package:integration_test/integration_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import '../test/support/journal_fixtures.dart';
import '../test/support/record_fixtures.dart';
import '../test/support/ui_harness.dart';

// Set maximum accessibility content size on the dedicated simulator before
// running. Do not override viewport or text scale to make this gate pass.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);
  setUp(binding.testTextInput.register);
  tearDown(binding.testTextInput.unregister);
  for (final brightness in Brightness.values) {
    testUiWidgets('journal native maximum text ${brightness.name}', (
      tester,
    ) async {
      expect(Platform.isIOS, isTrue);
      tester.platformDispatcher.platformBrightnessTestValue = brightness;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      final semantics = tester.ensureSemantics();
      try {
        final h = UiHarness();
        await h.mount(
          tester,
          journalPhotoFiles: {
            for (final kind in JournalKind.values)
              kind: MemoryJournalPhotoFiles(kind),
          },
          recordPhotoPicker: StubRecordPhotoPicker(),
        );
        final scaler = MediaQuery.textScalerOf(
          tester.element(find.byType(NavigationBar)),
        );
        final effectiveScale = scaler.scale(14) / 14;
        expect(effectiveScale, greaterThanOrEqualTo(3));
        for (final entry in {
          'entry-check-in': ('打卡', '跳到今天的目标'),
          'entry-quick-note': ('随手记', '写一条随手记'),
          'entry-diary': ('写日记', '打开今天的日记'),
          'entry-new-goal': ('新目标', '新建一个目标'),
        }.entries) {
          final finder = find.byKey(ValueKey(entry.key));
          await tester.ensureVisible(finder);
          await tester.pumpAndSettle();
          expect(
            tester.getSemantics(finder),
            matchesSemantics(
              isButton: true,
              hasEnabledState: true,
              isEnabled: true,
              hasTapAction: true,
              label: entry.value.$1,
              hint: entry.value.$2,
            ),
          );
        }
        for (final kind in JournalKind.values) {
          final label = kind == JournalKind.quickNote ? '随手记' : '日记';
          await tapVisible(
            tester,
            find.byKey(
              ValueKey(
                kind == JournalKind.quickNote
                    ? 'entry-quick-note'
                    : 'entry-diary',
              ),
            ),
          );
          final input = find.byKey(const ValueKey('journal-text'));
          await tester.enterText(input, '合成大字号记录：🙂\n第二行。');
          await tester.pumpAndSettle();
          final save = find.byTooltip('保存$label');
          expect(save, findsOneWidget);
          await tapVisible(tester, save);
          expect(input, findsNothing);
          final store = await h.container.read(
            journalStoreProvider(kind).future,
          );
          final saved = await store.savedOn(h.clock.day);
          expect(saved, hasLength(1));
          expect(saved.single.entry.content, '合成大字号记录：🙂\n第二行。');
          expect(tester.takeException(), isNull);
        }
        await tapVisible(tester, find.byTooltip('我的'));
        for (final key in ['my-diary', 'my-quick-notes']) {
          await tapVisible(tester, find.byKey(ValueKey(key)));
          expect(find.textContaining('合成大字号记录'), findsOneWidget);
          await goBack(tester);
        }
        expect(h.container.exists(assistantServiceProvider), isFalse);
        expect(h.container.exists(pairingControllerProvider), isFalse);
        expect(tester.takeException(), isNull);
        debugPrint(
          'JOURNAL_NATIVE_A11Y theme=${brightness.name} '
          'effective_scale=$effectiveScale '
          'physical_size=${tester.view.physicalSize} '
          'dpr=${tester.view.devicePixelRatio}',
        );
      } finally {
        semantics.dispose();
      }
    });
  }
}
