import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/chat_network_test.dart' as transport;
import '../test/chat_controller_test.dart' as controller;
import '../test/chat_photo_files_test.dart' as files;
import '../test/chat_store_test.dart' as storage;
import '../test/drift/chat_migration_test.dart' as migration;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isIOS || !const bool.fromEnvironment('CHAT_STORAGE_GATE')) {
    throw StateError('Run only on a QA iOS simulator with explicit opt-in.');
  }
  // Synthetic loopback requests and temporary fixtures, never the ordinary DB.
  group('Transport', transport.main);
  group('Storage', storage.main);
  group('Photos', files.main);
  group('Migration', migration.main);
  group('Controller', controller.main);
}
