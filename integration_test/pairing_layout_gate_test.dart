import 'package:integration_test/integration_test.dart';

import '../test/pairing_ui_test.dart' as suite;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  suite.main();
}
