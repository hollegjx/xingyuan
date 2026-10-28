import 'package:integration_test/integration_test.dart';

import '../test/assistant_identity_ui_test.dart' as identity;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  identity.main();
}
