import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/assistant/assistant_providers.dart';
import 'package:habit_checkin/features/journal/domain/journal_entry.dart';
import 'package:habit_checkin/features/journal/journal_providers.dart';
import 'package:integration_test/integration_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import '../test/support/journal_ai_service.dart';
import '../test/support/journal_fixtures.dart';
import '../test/support/test_assistant_service.dart';
import '../test/support/ui_harness.dart';

// Dedicated simulator only. Host keyboard/pointer input, synthetic AI and
// in-memory storage; no clipboard reads, credentials or phone records.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  binding.shouldPropagateDevicePointerEvents = true;
  setUpAll(tzdata.initializeTimeZones);
  testUiWidgets(
    'AI preview dismisses native keyboard and editing remains usable',
    (tester) async {
      expect(Platform.isIOS, isTrue);
      expect(binding.testTextInput.isRegistered, isFalse);
      final metrics = _KeyboardMetrics(tester);
      binding.addObserver(metrics);
      addTearDown(() => binding.removeObserver(metrics));
      final errorHandler = FlutterError.onError;
      var capturedError = false;
      FlutterError.onError = (details) {
        debugPrintSynchronously('JOURNAL_AI_KEYBOARD_ERROR $details');
        if (!capturedError) {
          capturedError = true;
          metrics.dump();
          debugDumpRenderTree();
        }
        errorHandler?.call(details);
      };
      addTearDown(() => FlutterError.onError = errorHandler);
      const source = String.fromEnvironment('JOURNAL_AI_KEYBOARD_SOURCE');
      expect(RegExp(r'^[a-f0-9]{40}$').hasMatch(source), isTrue);
      final h = UiHarness();
      h.clock.setDay(2026, 10, 23);
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
      Finder key(String name) => find.byKey(ValueKey(name));
      final input = key('journal-text');
      TextField field() => tester.widget<TextField>(input);
      Future<void> waitFor(bool Function() condition) async {
        final watch = Stopwatch()..start();
        while (!condition()) {
          if (watch.elapsed > const Duration(minutes: 10)) {
            fail('Host input or native keyboard state did not arrive');
          }
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }

      for (final kind in JournalKind.values) {
        final note = kind == JournalKind.quickNote;
        metrics.mark('${kind.name} opening');
        await tapVisible(
          tester,
          key(note ? 'entry-quick-note' : 'entry-diary'),
        );
        final original = note
            ? 'A quiet day.\nI read a book.'
            : 'A calm evening.\nI wrote a note.';
        metrics.mark('${kind.name} typing');
        debugPrint('JOURNAL_AI_KEYBOARD_TYPE ${kind.name} expected=$original');
        await waitFor(
          () =>
              field().controller!.text == original &&
              tester.view.viewInsets.bottom > 0,
        );
        expect(field().focusNode!.hasFocus, isTrue);
        metrics.mark('${kind.name} requesting');
        await tapVisible(tester, key('journal-ai-request'));
        await waitFor(() => tester.view.viewInsets.bottom == 0);
        expect(key('journal-ai-suggestion'), findsOneWidget);
        expect(field().focusNode!.hasFocus, isFalse);
        metrics.mark('${kind.name} applying');
        if (!note) await tapVisible(tester, find.text('追加'));
        await tapVisible(tester, key('journal-ai-use'));
        final applied = note
            ? service.rewrite
            : '$original\n\n${service.diary}';
        expect(field().controller!.text, applied);
        final store = await h.container.read(journalStoreProvider(kind).future);
        expect(await store.savedOn(h.clock.day), isEmpty);
        metrics.mark('${kind.name} refocus');
        debugPrint('JOURNAL_AI_KEYBOARD_REFOCUS ${kind.name}');
        await waitFor(
          () =>
              field().focusNode!.hasFocus && tester.view.viewInsets.bottom > 0,
        );
        expect(field().controller!.text, applied);
        metrics.mark('${kind.name} dismiss');
        debugPrint('JOURNAL_AI_KEYBOARD_DISMISS ${kind.name}');
        await waitFor(
          () =>
              !field().focusNode!.hasFocus &&
              tester.view.viewInsets.bottom == 0,
        );
        expect(field().controller!.text, applied);
        metrics.mark('${kind.name} undo-save');
        await tapVisible(tester, key('journal-ai-undo'));
        expect(field().controller!.text, original);
        await tapVisible(tester, key('save-journal'));
        final saved = await store.savedOn(h.clock.day);
        expect(saved, hasLength(1));
        expect(saved.single.entry.content, original);
        expect(saved.single.entry.revision, 1);
        debugPrint('JOURNAL_AI_KEYBOARD_PASS ${kind.name} source=$source');
      }
      expect(service.calls, hasLength(2));
      expect(binding.testTextInput.isRegistered, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}

// Keep native metric transitions for the first error without changing them.
class _KeyboardMetrics extends WidgetsBindingObserver {
  _KeyboardMetrics(this.tester);

  final WidgetTester tester;
  final List<String> recent = [];
  String phase = 'mount';

  String snapshot() {
    final view = tester.view;
    final native = [
      for (final nativeView in ui.PlatformDispatcher.instance.views)
        'id=${nativeView.viewId} size=${nativeView.physicalSize} '
            'dpr=${nativeView.devicePixelRatio} '
            'padding=${_edges(nativeView.padding)} '
            'viewPadding=${_edges(nativeView.viewPadding)} '
            'viewInsets=${_edges(nativeView.viewInsets)}',
    ];
    final inputs = find.byKey(const ValueKey('journal-text')).evaluate();
    final media = inputs
        .map(
          (element) =>
              element.getInheritedWidgetOfExactType<MediaQuery>()?.data,
        )
        .toList();
    return '${DateTime.now().toUtc().toIso8601String()} phase=$phase '
        'size=${view.physicalSize} dpr=${view.devicePixelRatio} '
        'padding=${_edges(view.padding)} viewPadding=${_edges(view.viewPadding)} '
        'viewInsets=${_edges(view.viewInsets)} native=$native '
        'editorMedia=$media focus=${FocusManager.instance.primaryFocus?.debugLabel}';
  }

  String _edges(ui.ViewPadding value) =>
      '(${value.left},${value.top},${value.right},${value.bottom})';

  @override
  void didChangeMetrics() {
    final row = snapshot();
    recent.add(row);
    if (recent.length > 40) recent.removeAt(0);
    final nativeInsets = ui.PlatformDispatcher.instance.views.map(
      (view) => view.viewInsets.bottom,
    );
    if (nativeInsets.any((inset) => !inset.isFinite || inset < 0)) {
      debugPrintSynchronously('JOURNAL_AI_KEYBOARD_INVALID $row');
    }
  }

  void mark(String value) {
    phase = value;
    debugPrintSynchronously('JOURNAL_AI_KEYBOARD_METRICS ${snapshot()}');
  }

  void dump() {
    for (final row in recent) {
      debugPrintSynchronously('JOURNAL_AI_KEYBOARD_RECENT $row');
    }
    debugPrintSynchronously('JOURNAL_AI_KEYBOARD_CURRENT ${snapshot()}');
  }
}
