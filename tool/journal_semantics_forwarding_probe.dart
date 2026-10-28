import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

// Opt-in SDK diagnostic, not an App acceptance test. Never calls the engine.
// Run with flutter test tool/journal_semantics_forwarding_probe.dart.
void main() {
  test('recording dispatcher captures enable and disable', () {
    final delegate = _RecordingDispatcher();
    delegate.setSemanticsTreeEnabled(true);
    delegate.setSemanticsTreeEnabled(false);
    expect(delegate.treeStates, [true, false]);
  });

  test('test dispatcher forwards semantics tree enable and disable', () {
    final delegate = _RecordingDispatcher();
    final dispatcher = TestPlatformDispatcher(platformDispatcher: delegate);
    dispatcher.setSemanticsTreeEnabled(true);
    dispatcher.setSemanticsTreeEnabled(false);
    expect(
      delegate.treeStates,
      [true, false],
      reason:
          'An empty list means the test wrapper swallowed both calls. '
          'This diagnoses SDK forwarding, not native Inspector behavior.',
    );
  });
}

class _RecordingDispatcher implements ui.PlatformDispatcher {
  final treeStates = <bool>[];

  @override
  Iterable<ui.Display> get displays => const [];

  @override
  Iterable<ui.FlutterView> get views => const [];

  @override
  ui.VoidCallback? onMetricsChanged;

  @override
  ui.ViewFocusChangeCallback? onViewFocusChange;

  @override
  void setSemanticsTreeEnabled(bool enabled) => treeStates.add(enabled);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
