import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/assistant/assistant_providers.dart';
import 'package:habit_checkin/features/companion/companion_providers.dart';
import 'package:habit_checkin/features/journal/domain/journal_entry.dart';
import 'package:integration_test/integration_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import '../test/support/journal_ai_service.dart';
import '../test/support/journal_fixtures.dart';
import '../test/support/test_assistant_service.dart';
import '../test/support/ui_harness.dart';

// One synthetic Today checkpoint per native process. Host AX/Inspector evidence
// is required separately; the test does not assert that native bridging works.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  setUpAll(tzdata.initializeTimeZones);
  const run = String.fromEnvironment('JOURNAL_BRIDGE_RUN');
  const source = String.fromEnvironment('JOURNAL_BRIDGE_SOURCE');
  const forward = bool.fromEnvironment('JOURNAL_BRIDGE_FORWARD');

  testWidgets('Today native semantics forwarding A/B checkpoint', (
    tester,
  ) async {
    expect(Platform.isIOS, isTrue);
    expect(RegExp(r'^[a-z0-9-]{8,60}$').hasMatch(run), isTrue);
    expect(RegExp(r'^[a-f0-9]{40}$').hasMatch(source), isTrue);
    final directory = Directory(
      '${Directory.systemTemp.path}/journal-bridge-$run',
    );
    expect(directory.existsSync(), isFalse, reason: 'Use a fresh run token');
    directory.createSync();
    final native = ui.PlatformDispatcher.instance;
    final notifications = <bool>[];
    Map<String, Object> state() => {
      'framework_semantics_enabled': binding.semanticsEnabled,
      'framework_handles': binding.debugOutstandingSemanticsHandles,
      'platform_requested_semantics': native.semanticsEnabled,
      'dispatcher_type': binding.platformDispatcher.runtimeType.toString(),
    };
    void write(String name, Map<String, Object?> values) {
      File('${directory.path}/$name.json').writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
          'source': source,
          'run': run,
          'explicit_forwarding': forward,
          'recorded_at': DateTime.now().toUtc().toIso8601String(),
          'native_notifications': notifications,
          ...values,
        }),
        flush: true,
      );
    }

    write('before', state());
    final semantics = tester.ensureSemantics();
    try {
      if (forward) {
        native.setSemanticsTreeEnabled(binding.semanticsEnabled);
        notifications.add(binding.semanticsEnabled);
      }
      final h = UiHarness();
      h.clock.setDay(2026, 10, 25);
      final service = SyntheticJournalAi();
      await h.mount(
        tester,
        journalAiService: service,
        assistantCredentials: ConversationTestCredentials(),
        journalPhotoFiles: {
          for (final kind in JournalKind.values)
            kind: MemoryJournalPhotoFiles(kind),
        },
      );
      final assistant = await h.container.read(assistantStoreProvider.future);
      await assistant.memories.consent();
      h.container.invalidate(assistantSettingsProvider);
      await tester.pumpAndSettle();
      final traversal = tester.semantics
          .simulatedAccessibilityTraversal()
          .toList();
      var previous = -1;
      for (final key in [
        'entry-check-in',
        'entry-quick-note',
        'entry-diary',
        'entry-new-goal',
      ]) {
        final node = tester.getSemantics(find.byKey(ValueKey(key)));
        final data = node.getSemanticsData();
        expect(data.label, isNotEmpty);
        expect(data.hint, isNotEmpty);
        expect(data.hasAction(SemanticsAction.tap), isTrue);
        final index = traversal.indexOf(node);
        expect(index, greaterThan(previous));
        previous = index;
      }
      write('today', {
        ...state(),
        'evidence': 'Flutter traversal; host AX/Inspector recorded separately',
        'physical_size': tester.view.physicalSize.toString(),
        'dpr': tester.view.devicePixelRatio,
        'traversal': [
          for (final node in traversal)
            {
              'label': node.getSemanticsData().label,
              'hint': node.getSemanticsData().hint,
              'tooltip': node.getSemanticsData().tooltip,
              'value': node.getSemanticsData().value,
              'tap': node.getSemanticsData().hasAction(SemanticsAction.tap),
              'rect': node.rect.toString(),
            },
        ],
      });
      debugPrint('JOURNAL_BRIDGE_READY ${directory.path} forward=$forward');
      final signal = File('${directory.path}/today.continue');
      final watch = Stopwatch()..start();
      while (!signal.existsSync()) {
        if (watch.elapsed > const Duration(minutes: 8)) {
          fail('Host did not finish the Today AX/Inspector observation');
        }
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(signal.readAsStringSync().trim(), 'today');
      expect(service.calls, isEmpty);
      expect(h.container.exists(assistantServiceProvider), isFalse);
      expect(h.container.exists(pairingControllerProvider), isFalse);
      expect(tester.takeException(), isNull);
      write('flow-complete', state());
    } finally {
      // Own the only test-created handle; preserve any platform-owned handle.
      semantics.dispose();
      if (forward) {
        native.setSemanticsTreeEnabled(binding.semanticsEnabled);
        notifications.add(binding.semanticsEnabled);
      }
      write('cleanup', state());
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(Duration.zero);
    }
  }, semanticsEnabled: false);
}
