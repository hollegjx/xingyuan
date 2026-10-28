import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  test('offline CLI suites must not share concurrent native asset builds', () {
    final file = File('dart_test.yaml');
    final config = file.existsSync()
        ? loadYaml(file.readAsStringSync()) as Map
        : const <String, Object?>{};
    expect(
      config['concurrency'],
      1,
      reason:
          'CLI suites run dart in this package and share .dart_tool assets.',
    );
  });
}
