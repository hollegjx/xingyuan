import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/journal_interaction_regression_test.dart' as interaction;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Programmatic input must not race a real iOS keyboard's editing state.
  // journal_lifecycle_gate_test separately requires real, unmocked OS input.
  setUp(() {
    binding.testTextInput.register();
    expect(binding.testTextInput.isRegistered, isTrue);
  });
  tearDown(binding.testTextInput.unregister);
  interaction.main();
}
