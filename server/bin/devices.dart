import 'dart:io';

import 'package:xingyuan_server/src/device_registry.dart';

Future<void> main(List<String> args) async {
  if (args.length < 3 || args.first != '--file') {
    stderr.writeln(
      'Usage: devices --file /private/devices.json issue LABEL | revoke LABEL | list',
    );
    exitCode = 64;
    return;
  }
  try {
    final registry = DeviceRegistry(args[1]);
    switch (args[2]) {
      case 'issue':
        if (args.length != 4) throw const FormatException();
        stdout.writeln(await registry.issue(args[3]));
      case 'revoke':
        if (args.length != 4) throw const FormatException();
        await registry.revoke(args[3]);
        stdout.writeln('Revoked.');
      case 'list':
        if (args.length != 3) throw const FormatException();
        for (final row in await registry.entries()) {
          stdout.writeln(
            '${row['label']} ${row['revoked'] == true ? 'revoked' : 'active'}',
          );
        }
      default:
        throw const FormatException();
    }
  } catch (_) {
    stderr.writeln(
      'Device operation failed; verify label, file and permissions.',
    );
    exitCode = 1;
  }
}
