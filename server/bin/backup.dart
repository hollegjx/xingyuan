import 'dart:convert';
import 'dart:io';

import 'package:xingyuan_server/src/companion_backup.dart';
import 'package:xingyuan_server/src/object_store.dart';

Future<void> main(List<String> args) async {
  const allowed = {
    'create': {'--root', '--config'},
    'list': {'--root'},
    'verify': {'--root', '--snapshot'},
    'restore': {'--root', '--snapshot', '--destination'},
    'export': {'--root', '--snapshot'},
  };
  try {
    if (args.isEmpty || !allowed.containsKey(args.first)) {
      throw const FormatException();
    }
    final options = <String, String>{};
    for (var i = 1; i < args.length; i += 2) {
      if (i + 1 >= args.length ||
          !allowed[args.first]!.contains(args[i]) ||
          options.containsKey(args[i]) ||
          args[i + 1].isEmpty) {
        throw const FormatException();
      }
      options[args[i]] = args[i + 1];
    }
    if (!options.containsKey('--root') ||
        (args.first == 'create' && !options.containsKey('--config')) ||
        (args.first == 'restore' &&
            (!options.containsKey('--snapshot') ||
                !options.containsKey('--destination')))) {
      throw const FormatException();
    }
    final backups = await CompanionBackups.open(options['--root']!);
    if (args.first == 'create') {
      final config =
          jsonDecode(await File(options['--config']!).readAsString()) as Map;
      final database = config['companion_database'] as String;
      final objects = await DiskObjectStore.openExisting(
        config['companion_objects'] as String,
      );
      final snapshot = await backups.create(
        database: database,
        objects: objects,
      );
      stdout.writeln(
        jsonEncode({'event': 'backup_complete', ...snapshot.toJson()}),
      );
      return;
    }
    if (args.first == 'list') {
      stdout.writeln(
        jsonEncode((await backups.list()).map((s) => s.toJson()).toList()),
      );
      return;
    }
    final name = options['--snapshot'] ?? (await backups.list()).first.name;
    if (args.first == 'export') {
      await backups.export(name, stdout);
      await stdout.flush();
      return;
    }
    final result = args.first == 'restore'
        ? await backups.restore(name, options['--destination']!)
        : await backups.verify(name);
    stdout.writeln(
      jsonEncode({'event': '${args.first}_complete', ...result.toJson()}),
    );
  } on CompanionBackupFailure catch (error) {
    stderr.writeln(jsonEncode({'event': 'backup_failed', 'code': error.code}));
    exitCode = 1;
  } catch (_) {
    // Exceptions may contain configuration, content or paths; never print them.
    stderr.writeln(
      jsonEncode({
        'event': 'backup_failed',
        'code': 'invalid_input_or_storage',
      }),
    );
    exitCode = 1;
  }
}
