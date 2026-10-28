import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:xingyuan_server/src/device_registry.dart';

import '../tool/prepare_companion_journey.dart';

void main() {
  late Directory parent;
  late String path;
  setUp(() async {
    parent = await Directory.systemTemp.createTemp('companion-journey-test-');
    path = '${parent.path}/new-run';
  });
  tearDown(() => parent.delete(recursive: true));

  test(
    'new journey isolates credentials and exports no token in metadata',
    () async {
      final metadata = await prepareJourney(path, 'synthetic-journey');
      final registry = DeviceRegistry('$path/devices.json');
      final tokens = <String>{};
      for (final role in ['a', 'b']) {
        final file = File('$path/client-$role.json');
        final client = jsonDecode(await file.readAsString()) as Map;
        final token = client['COMPANION_JOURNEY_TOKEN'] as String;
        expect(tokens.add(token), true);
        expect((await file.stat()).mode & 0x3f, 0);
        expect(jsonEncode(metadata).contains(token), false);
        expect(
          await registry.authenticate('Bearer $token'),
          'qa-synthetic-journey-$role',
        );
        expect(
          client['COMPANION_JOURNEY_URL'],
          'http://127.0.0.1:${metadata['port']}',
        );
      }
      expect((await Directory(path).stat()).mode & 0x3f, 0);
      await revokeJourney(path);
      for (final token in tokens) {
        expect(await registry.authenticate('Bearer $token'), isNull);
      }
    },
  );

  test('existing directories are never replaced', () async {
    await prepareJourney(path, 'synthetic-journey');
    final before = await File('$path/devices.json').readAsBytes();
    await expectLater(
      prepareJourney(path, 'synthetic-another'),
      throwsFormatException,
    );
    expect(await File('$path/devices.json').readAsBytes(), before);
    await expectLater(
      prepareJourney('relative', 'synthetic-run'),
      throwsFormatException,
    );
  });

  test('invite transfer is bound to run role and phase', () async {
    await prepareJourney(path, 'synthetic-journey');
    final report = File('${parent.path}/invite.json');
    final data = {
      'run': 'synthetic-journey',
      'role': 'a',
      'phase': 'invite',
      'invitation': 'ABCDEFGH',
    };
    await report.writeAsString(jsonEncode({...data, 'run': 'wrong-run'}));
    await expectLater(
      copyJourneyInvite(path, report.path),
      throwsFormatException,
    );
    var client =
        jsonDecode(await File('$path/client-b.json').readAsString()) as Map;
    expect(client.containsKey('COMPANION_JOURNEY_INVITE'), false);
    await report.writeAsString(jsonEncode(data));
    await copyJourneyInvite(path, report.path);
    client =
        jsonDecode(await File('$path/client-b.json').readAsString()) as Map;
    expect(client['COMPANION_JOURNEY_INVITE'], 'ABCDEFGH');
    expect((await File('$path/client-b.json').stat()).mode & 0x3f, 0);
  });
}
