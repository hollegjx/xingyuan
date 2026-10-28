import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/drift/publication_migration_test.dart' as migration;
import '../test/publication_store_test.dart' as publication;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isIOS ||
      !const bool.fromEnvironment('PUBLICATION_STORAGE_GATE')) {
    throw StateError('Run only on a QA iOS simulator with explicit opt-in.');
  }
  // Both suites create and remove their own synthetic temporary databases.
  // Neither opens the ordinary App database or uses a credential/network.
  group('Migration', migration.main);
  group('Publication', publication.main);
}
