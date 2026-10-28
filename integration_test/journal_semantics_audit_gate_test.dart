import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/assistant/assistant_providers.dart';
import 'package:habit_checkin/features/companion/companion_providers.dart';
import 'package:habit_checkin/features/journal/domain/journal_entry.dart';
import 'package:habit_checkin/features/journal/journal_providers.dart';
import 'package:integration_test/integration_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import '../test/support/journal_ai_service.dart';
import '../test/support/journal_fixtures.dart';
import '../test/support/test_assistant_service.dart';
import '../test/support/ui_harness.dart';

// Synthetic data and memory storage. Inspector evidence and actual speech
// remain separate from the exported Flutter traversal; no model is contacted.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  setUpAll(tzdata.initializeTimeZones);
  setUp(binding.testTextInput.register);
  tearDown(binding.testTextInput.unregister);
  const run = String.fromEnvironment('JOURNAL_AUDIT_RUN');
  const source = String.fromEnvironment('JOURNAL_AUDIT_SOURCE');
  const hold = bool.fromEnvironment('JOURNAL_AUDIT_HOLD');

  testUiWidgets('journal semantics and Inspector checkpoints', (tester) async {
    expect(Platform.isIOS, isTrue);
    expect(RegExp(r'^[a-z0-9-]{8,60}$').hasMatch(run), isTrue);
    expect(RegExp(r'^[a-f0-9]{40}$').hasMatch(source), isTrue);
    final directory = Directory(
      '${Directory.systemTemp.path}/journal-audit-$run',
    );
    expect(directory.existsSync(), isFalse, reason: 'Use a fresh run token');
    directory.createSync();
    debugPrint('JOURNAL_AUDIT_DIRECTORY ${directory.path}');
    final semantics = tester.ensureSemantics();
    try {
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
      Finder key(String value) => find.byKey(ValueKey(value));
      final completed = <String>[];

      Future<void> checkpoint(String name) async {
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final nodes = tester.semantics
            .simulatedAccessibilityTraversal()
            .toList();
        expect(nodes, isNotEmpty);
        final root = tester
            .binding
            .renderViews
            .single
            .owner!
            .semanticsOwner!
            .rootSemanticsNode!;
        File('${directory.path}/$name.json').writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert({
            'run': run,
            'source': source,
            'checkpoint': name,
            'evidence': 'Flutter simulated traversal; not VoiceOver speech or Inspector audit',
            'recorded_at': DateTime.now().toUtc().toIso8601String(),
            'physical_size': tester.view.physicalSize.toString(),
            'dpr': tester.view.devicePixelRatio,
            'tree': root.toStringDeep(
              childOrder: DebugSemanticsDumpOrder.traversalOrder,
            ),
            'traversal': [
              for (final node in nodes)
                {
                  'id': node.id,
                  'label': node.getSemanticsData().label,
                  'value': node.getSemanticsData().value,
                  'hint': node.getSemanticsData().hint,
                  'tooltip': node.getSemanticsData().tooltip,
                  'tap': node.getSemanticsData().hasAction(SemanticsAction.tap),
                  'rect': node.rect.toString(),
                },
            ],
          }),
          flush: true,
        );
        debugPrint('JOURNAL_AUDIT_READY $name');
        if (hold) {
          final watch = Stopwatch()..start();
          final signal = File('${directory.path}/$name.continue');
          while (!signal.existsSync()) {
            if (watch.elapsed > const Duration(minutes: 10)) {
              fail('Inspector checkpoint was not released: $name');
            }
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(signal.readAsStringSync().trim(), name);
        }
        expect(tester.takeException(), isNull);
        completed.add(name);
      }

      final entryOrder = [
        'entry-check-in',
        'entry-quick-note',
        'entry-diary',
        'entry-new-goal',
      ];
      final traversal = tester.semantics
          .simulatedAccessibilityTraversal()
          .toList();
      var previous = -1;
      for (final name in entryOrder) {
        final node = tester.getSemantics(key(name));
        expect(node.getSemanticsData().label, isNotEmpty);
        expect(node.getSemanticsData().hint, isNotEmpty);
        expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
        final index = traversal.indexOf(node);
        expect(index, greaterThan(previous));
        previous = index;
      }
      await checkpoint('today-entries');

      for (final kind in JournalKind.values) {
        final note = kind == JournalKind.quickNote;
        final original = note
            ? 'Synthetic note: I read one page.'
            : 'Synthetic diary: A quiet evening.';
        await tapVisible(
          tester,
          key(note ? 'entry-quick-note' : 'entry-diary'),
        );
        final input = key('journal-text');
        await tester.enterText(input, original);
        await tester.pumpAndSettle();
        tester.widget<TextField>(input).focusNode!.unfocus();
        await checkpoint('${kind.name}-editor');
        for (final action in {
          'journal-add-photo': '\u4ece\u76f8\u518c\u6dfb\u52a0\u7167\u7247',
          'journal-take-photo': '\u62cd\u7167',
        }.entries) {
          final data = tester.getSemantics(key(action.key)).getSemanticsData();
          expect(data.tooltip, action.value);
          expect(data.hasAction(SemanticsAction.tap), isTrue);
        }
        final aiAction = tester
            .getSemantics(key('journal-ai-request'))
            .getSemanticsData();
        expect(aiAction.label, isNotEmpty);
        expect(aiAction.hasAction(SemanticsAction.tap), isTrue);
        await tapVisible(tester, key('journal-ai-request'));
        expect(key('journal-ai-suggestion'), findsOneWidget);
        await checkpoint('${kind.name}-preview');
        if (!note) await tapVisible(tester, find.text('追加'));
        await tapVisible(tester, key('journal-ai-use'));
        expect(key('journal-ai-applied'), findsOneWidget);
        final store = await h.container.read(journalStoreProvider(kind).future);
        expect(await store.savedOn(h.clock.day), isEmpty);
        await checkpoint('${kind.name}-applied');
        await tapVisible(tester, key('journal-ai-undo'));
        expect(tester.widget<TextField>(input).controller!.text, original);
        await tapVisible(tester, key('save-journal'));
        expect(
          (await store.savedOn(h.clock.day)).single.entry.content,
          original,
        );
      }

      await tapVisible(tester, find.byTooltip('\u6211\u7684'));
      await tester.ensureVisible(key('my-diary'));
      await checkpoint('my-journals');
      await tapVisible(tester, find.byTooltip('\u56de\u987e'));
      await tapVisible(tester, key('review-day-${h.clock.day.key}'));
      final diaries = await h.container.read(diaryStoreProvider.future);
      final diary = (await diaries.savedOn(h.clock.day)).single;
      await tester.ensureVisible(key('journal-entry-${diary.entry.id}'));
      await checkpoint('review-journals');
      expect(service.calls, hasLength(2));
      expect(h.container.exists(assistantServiceProvider), isFalse);
      expect(h.container.exists(pairingControllerProvider), isFalse);
      expect(tester.takeException(), isNull);
      File('${directory.path}/complete.json').writeAsStringSync(
        jsonEncode({'source': source, 'run': run, 'completed': completed}),
        flush: true,
      );
      debugPrint(
        'JOURNAL_AUDIT_FLOW_COMPLETE ${completed.length} source=$source',
      );
    } finally {
      semantics.dispose();
    }
  });
}
