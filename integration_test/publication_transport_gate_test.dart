import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/sharing_controller_test.dart' as controller;
import '../test/sharing_network_test.dart' as transport;
import '../test/sharing_store_test.dart' as storage;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isIOS ||
      !const bool.fromEnvironment('PUBLICATION_TRANSPORT_GATE')) {
    throw StateError('Run only on a QA iOS simulator with explicit opt-in.');
  }
  // Synthetic loopback HTTP and temporary databases, never ordinary App data.
  group('Transport', transport.main);
  group('Storage', storage.main);
  group('Controller', controller.main);
}
