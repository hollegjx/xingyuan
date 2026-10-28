import 'package:test/test.dart';

import '../../packages/xingyuan_core/test/fixture_contract.dart';

void main() {
  for (final fixture in loadContractCases(
    '../packages/xingyuan_core/test/fixtures',
  )) {
    test('server shared protocol ${fixture['id']}', () {
      expect(acceptsContractCase(fixture), fixture['accept']);
    });
  }
}
