import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/assistant/assistant_providers.dart';
import 'package:habit_checkin/features/companion/companion_providers.dart';
import 'package:habit_checkin/features/journal/domain/journal_entry.dart';
import 'package:habit_checkin/features/journal/journal_providers.dart';
import 'package:habit_checkin/features/records/data/record_photo_picker.dart';
import 'package:habit_checkin/features/records/record_providers.dart';
import 'package:integration_test/integration_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import '../test/support/journal_ai_service.dart';
import '../test/support/journal_fixtures.dart';
import '../test/support/test_assistant_service.dart';
import '../test/support/ui_harness.dart';

// Real platform picker; only record storage, credentials and AI are isolated.
// The host separately records/restores the dedicated simulator's photo state.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  setUpAll(tzdata.initializeTimeZones);
  setUp(binding.testTextInput.register);
  tearDown(binding.testTextInput.unregister);
  const run = String.fromEnvironment('JOURNAL_PHOTO_RUN');
  const source = String.fromEnvironment('JOURNAL_PHOTO_SOURCE');
  const state = String.fromEnvironment('JOURNAL_PHOTO_STATE');

  testUiWidgets('real photo picker cancellation preserves journal editing', (
    tester,
  ) async {
    expect(Platform.isIOS, isTrue);
    expect(RegExp(r'^[a-z0-9-]{8,60}$').hasMatch(run), isTrue);
    expect(RegExp(r'^[a-f0-9]{40}$').hasMatch(source), isTrue);
    expect(['revoked', 'granted', 'reset'], contains(state));
    final directory = Directory(
      '${Directory.systemTemp.path}/journal-photo-$run',
    );
    expect(directory.existsSync(), isFalse, reason: 'Use a fresh run token');
    directory.createSync();
    debugPrint('JOURNAL_PHOTO_DIRECTORY ${directory.path}');
    final h = UiHarness();
    h.clock.setDay(2026, 10, 25);
    final ai = SyntheticJournalAi();
    await h.mount(
      tester,
      assistantCredentials: ConversationTestCredentials(),
      journalAiService: ai,
      journalPhotoFiles: {
        for (final kind in JournalKind.values)
          kind: MemoryJournalPhotoFiles(kind),
      },
    );
    expect(
      h.container.read(recordPhotoPickerProvider).runtimeType,
      RecordPhotoPicker,
    );
    Finder key(String value) => find.byKey(ValueKey(value));
    final completed = <String>[];

    Future<void> checkpoint(String name) async {
      File('${directory.path}/$name.json').writeAsStringSync(
        jsonEncode({
          'source': source,
          'run': run,
          'host_requested_state': state,
          'checkpoint': name,
          'recorded_at': DateTime.now().toUtc().toIso8601String(),
          'scope': 'Host screenshot and permission-state evidence required separately',
        }),
        flush: true,
      );
      debugPrint('JOURNAL_PHOTO_READY $name');
      final signal = File('${directory.path}/$name.continue');
      final watch = Stopwatch()..start();
      while (!signal.existsSync()) {
        if (watch.elapsed > const Duration(minutes: 5)) {
          fail('Host did not finish real picker inspection: $name');
        }
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(signal.readAsStringSync().trim(), name);
      completed.add(name);
    }

    for (final kind in JournalKind.values) {
      await tapVisible(
        tester,
        key(kind == JournalKind.quickNote ? 'entry-quick-note' : 'entry-diary'),
      );
      final input = key('journal-text');
      final original = 'Synthetic $state ${kind.name} before picker.';
      await tester.enterText(input, original);
      await tester.pumpAndSettle();
      tester.widget<TextField>(input).focusNode!.unfocus();
      await tester.pumpAndSettle();
      await tapVisible(tester, key('journal-add-photo'), settle: false);
      await checkpoint('${kind.name}-picker');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tester.widget<TextField>(input).controller!.text, original);
      final store = await h.container.read(journalStoreProvider(kind).future);
      expect(await store.savedOn(h.clock.day), isEmpty);
      final edited = '$original After cancellation.';
      await tester.enterText(input, edited);
      await tester.pumpAndSettle();
      tester.widget<TextField>(input).focusNode!.unfocus();
      await tapVisible(tester, key('save-journal'));
      final saved = (await store.savedOn(h.clock.day)).single;
      expect(saved.entry.content, edited);
      expect(saved.savedPhotos, isEmpty);
      expect(saved.draftPhotos, isEmpty);
      await checkpoint('${kind.name}-saved');
    }
    expect(ai.calls, isEmpty);
    expect(h.container.exists(assistantServiceProvider), isFalse);
    expect(h.container.exists(pairingControllerProvider), isFalse);
    expect(tester.takeException(), isNull);
    File('${directory.path}/complete.json').writeAsStringSync(
      jsonEncode({
        'source': source,
        'run': run,
        'state': state,
        'completed': completed,
      }),
      flush: true,
    );
    debugPrint('JOURNAL_PHOTO_FLOW_COMPLETE $state ${completed.length}');
  });
}
