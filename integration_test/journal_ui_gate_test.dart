import 'package:integration_test/integration_test.dart';

import '../test/journal_ui_test.dart' as journal;

// Reuse the exact widget assertions with the native iOS renderer and dialogs.
// These programmatic inputs are separate from the host-operated lifecycle gate.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  journal.main();
}
