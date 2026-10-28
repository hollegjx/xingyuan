import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/companion_foreground_test.dart' as foreground;
import '../test/publication_editor_test.dart' as editor;
import '../test/publication_ui_test.dart' as ui;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isIOS || !const bool.fromEnvironment('PUBLICATION_UI_GATE')) {
    throw StateError('Run only on a QA iOS simulator with explicit opt-in.');
  }
  // Real App lifecycle and screens; synthetic services and isolated databases.
  group('Foreground', foreground.main);
  group('Editor', editor.main);
  group('UI', ui.main);
}
