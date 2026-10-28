import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/publication_http_test.dart' as http;
import '../test/publication_outbox_test.dart' as storage;
import '../test/publication_runner_test.dart' as runner;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isIOS ||
      !const bool.fromEnvironment('PUBLICATION_OUTBOX_GATE')) {
    throw StateError('Run only on a QA iOS simulator with explicit opt-in.');
  }
  // All records, credentials, databases and photo directories are synthetic.
  group('Outbox', storage.main);
  group('Runner', runner.main);
  group('HTTP', http.main);
}
