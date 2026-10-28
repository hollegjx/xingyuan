import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:xingyuan_server/src/companion_backup.dart';
import 'package:xingyuan_server/src/companion_media.dart';
import 'package:xingyuan_server/src/companion_store.dart';
import 'package:xingyuan_server/src/object_store.dart';

import 'support/media_fixtures.dart';
import 'support/sharing_fixtures.dart';

void main() {
  late Directory directory;
  late File config;
  late CompanionStore store;
  late CompanionBackups backups;
  late DiskObjectStore objects;
  late String photo;
  const secret = 'SYNTHETIC_BACKUP_CONFIG_SECRET';
  late String executable;
  Directory? compiled;

  setUpAll(() async {
    final supplied = Platform.environment['XINGYUAN_BACKUP_EXECUTABLE'];
    if (supplied != null) {
      executable = supplied;
    } else {
      compiled = await Directory.systemTemp.createTemp('backup-cli-build-');
      final build = await Process.run(Platform.resolvedExecutable, [
        'build',
        'cli',
        '--target=bin/backup.dart',
        '--output=${compiled!.path}/cli',
      ]);
      expect(build.exitCode, 0, reason: build.stderr as String);
      executable = '${compiled!.path}/cli/bundle/bin/backup';
    }
    expect(File(executable).isAbsolute, isTrue);
    expect(await File(executable).exists(), isTrue);
  });
  tearDownAll(() async => compiled?.delete(recursive: true));

  Future<ProcessResult> cli(List<String> args, {bool binary = false}) =>
      Process.run(
        executable,
        args,
        stdoutEncoding: binary ? null : utf8,
      ).timeout(const Duration(seconds: 30));

  void failedPrivately(ProcessResult result) {
    expect(result.exitCode, 1);
    expect(result.stdout, isEmpty);
    final error = jsonDecode(result.stderr as String) as Map;
    expect(error.keys.toSet(), {'event', 'code'});
    expect(error['event'], 'backup_failed');
    expect(result.stderr, isNot(contains(secret)));
    expect(result.stderr, isNot(contains(directory.path)));
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('backup-cli-');
    store = CompanionStore.open('${directory.path}/data.db');
    objects = await DiskObjectStore.open('${directory.path}/objects');
    final group = pairForSharing(store);
    photo = (await CompanionMedia(
      store,
      objects,
    ).upload('qa-a', mediaUpload(group, null), () async {})).photo.id;
    backups = await CompanionBackups.open('${directory.path}/backups');
    config = await File('${directory.path}/config.json').writeAsString(
      jsonEncode({
        'model_api_key': secret,
        'companion_database': '${directory.path}/data.db',
        'companion_objects': objects.directory,
      }),
    );
    expect((await Process.run('chmod', ['600', config.path])).exitCode, 0);
  });
  tearDown(() async {
    store.close();
    await directory.delete(recursive: true);
  });

  test(
    'CLI create, list, verify, binary export and fresh restore preserve photos',
    () async {
      final created = await cli([
        'create',
        '--config',
        config.path,
        '--root',
        backups.directory,
      ]);
      expect(created.exitCode, 0, reason: created.stderr as String);
      final metadata = jsonDecode(created.stdout as String) as Map;
      expect(metadata['event'], 'backup_complete');
      expect(metadata['photos'], 1);
      expect(created.stdout, isNot(contains(secret)));
      final name = metadata['snapshot'] as String;
      final listed = await cli(['list', '--root', backups.directory]);
      expect(listed.exitCode, 0);
      expect(
        (jsonDecode(listed.stdout as String) as List).single['snapshot'],
        name,
      );
      expect(
        (await cli(['verify', '--root', backups.directory, '--snapshot', name]))
            .exitCode,
        0,
      );
      final exported = await cli([
        'export',
        '--root',
        backups.directory,
      ], binary: true);
      expect(exported.exitCode, 0);
      expect(exported.stderr, isEmpty);
      final archive = await File('${directory.path}/export.tar.gz')
          .writeAsBytes(exported.stdout as List<int>);
      final imported = await Directory('${directory.path}/imported').create();
      expect(
        (await Process.run('tar', [
          '-xzf',
          archive.path,
          '-C',
          imported.path,
        ])).exitCode,
        0,
      );
      final restoredPath = '${directory.path}/restored';
      final restored = await cli([
        'restore',
        '--root',
        imported.path,
        '--snapshot',
        name,
        '--destination',
        restoredPath,
      ]);
      expect(restored.exitCode, 0);
      expect(
        jsonDecode(restored.stdout as String)['event'],
        'restore_complete',
      );
      expect(
        await (await DiskObjectStore.openExisting('$restoredPath/objects'))
            .read(photo),
        await objects.read(photo),
      );
      expect(
        await File('$restoredPath/data.db').readAsBytes(),
        await File('${backups.directory}/$name/data.db').readAsBytes(),
      );
      expect(await File('$restoredPath/config.json').exists(), isFalse);
      failedPrivately(
        await cli([
          'restore',
          '--root',
          imported.path,
          '--snapshot',
          name,
          '--destination',
          restoredPath,
        ]),
      );
    },
  );

  test(
    'malformed config and arguments never print inputs or initialize sources',
    () async {
      await config.writeAsString('{"model_api_key":"$secret",broken');
      failedPrivately(
        await cli([
          'create',
          '--config',
          config.path,
          '--root',
          backups.directory,
        ]),
      );
      failedPrivately(
        await cli([
          'create',
          '--config',
          secret,
          '--config',
          config.path,
          '--root',
          backups.directory,
        ]),
      );
      failedPrivately(
        await cli([
          'verify',
          '--root',
          backups.directory,
          '--snapshot',
          '../$secret',
        ]),
      );
      await config.writeAsString(
        jsonEncode({
          'companion_database': '${directory.path}/absent.db',
          'companion_objects': '${directory.path}/absent-objects',
        }),
      );
      failedPrivately(
        await cli([
          'create',
          '--config',
          config.path,
          '--root',
          backups.directory,
        ]),
      );
      expect(await File('${directory.path}/absent.db').exists(), isFalse);
      expect(
        await Directory('${directory.path}/absent-objects').exists(),
        isFalse,
      );
      expect(await backups.list(), isEmpty);
    },
  );

  test(
    'a separate process cannot read or prune while backup lock is held',
    () async {
      final snapshot = await backups.create(
        database: '${directory.path}/data.db',
        objects: objects,
      );
      final lock = await File('${backups.directory}/.lock')
          .open(mode: FileMode.append);
      await lock.lock();
      try {
        failedPrivately(
          await cli([
            'create',
            '--root',
            backups.directory,
            '--config',
            config.path,
          ]),
        );
        failedPrivately(await cli(['export', '--root', backups.directory]));
      } finally {
        await lock.close();
      }
      expect((await backups.list()).single.name, snapshot.name);
      expect(
        (await cli([
          'create',
          '--root',
          backups.directory,
          '--config',
          config.path,
        ])).exitCode,
        0,
      );
      expect((await backups.list()).length, 2);
    },
  );

  test(
    'Mac export wrapper uses explicit host and never overwrites files',
    () async {
      final snapshot = await backups.create(
        database: '${directory.path}/data.db',
        objects: objects,
      );
      final archive = File('${directory.path}/source.tar.gz');
      final sink = archive.openWrite();
      try {
        await backups.export(snapshot.name, sink);
      } finally {
        await sink.close();
      }
      final commands = await Directory('${directory.path}/commands').create();
      final fakeSsh = await File('${commands.path}/ssh').writeAsString(
        '#!/bin/sh\n'
        'printf "%s\\n" "\$@" > "\$SYNTHETIC_SSH_ARGS"\n'
        'if [ "\${SYNTHETIC_SSH_FAIL:-0}" = 1 ]; then exit 7; fi\n'
        'cat "\$SYNTHETIC_ARCHIVE"\n',
      );
      expect((await Process.run('chmod', ['700', fakeSsh.path])).exitCode, 0);
      final sshConfig = await File('${directory.path}/ssh-config')
          .writeAsString('# synthetic; no real SSH runs');
      final arguments = File('${directory.path}/ssh-args');
      final destination = '${directory.path}/mac-backup.tar.gz';
      Future<ProcessResult> exportTo(String path, {bool fail = false}) =>
          Process.run(
            'sh',
            [
              'deploy/export-companion-backup.sh',
              sshConfig.path,
              'owner-configured-host',
              path,
            ],
            environment: {
              'PATH': '${commands.path}:${Platform.environment['PATH']}',
              'SYNTHETIC_SSH_ARGS': arguments.path,
              'SYNTHETIC_ARCHIVE': archive.path,
              'SYNTHETIC_SSH_FAIL': fail ? '1' : '0',
            },
          );
      expect((await exportTo(destination)).exitCode, 0);
      expect(
        await File(destination).readAsBytes(),
        await archive.readAsBytes(),
      );
      expect((await File(destination).stat()).mode & 0x1ff, 0x180);
      final passed = await arguments.readAsLines();
      expect(passed.take(2), ['-F', sshConfig.path]);
      expect(
        passed,
        containsAll([
          'BatchMode=yes',
          'PreferredAuthentications=publickey',
          'PasswordAuthentication=no',
          'KbdInteractiveAuthentication=no',
          'StrictHostKeyChecking=yes',
          'ConnectionAttempts=1',
          'owner-configured-host',
        ]),
      );
      await arguments.delete();
      expect((await exportTo(destination)).exitCode, isNot(0));
      expect(await arguments.exists(), isFalse);
      expect(
        await File(destination).readAsBytes(),
        await archive.readAsBytes(),
      );
      expect(
        (await exportTo(
          '${directory.path}/failed.tar.gz',
          fail: true,
        )).exitCode,
        7,
      );
      expect(await File('${directory.path}/failed.tar.gz').exists(), isFalse);
      expect(
        await directory
            .list()
            .where((e) => e.path.contains('.xingyuan-export.'))
            .isEmpty,
        isTrue,
      );
    },
  );

  test(
    'killed lock owner releases OS lock without touching abandoned files',
    () async {
      final process = await Process.start(Platform.resolvedExecutable, [
        'test/support/backup_lock_holder.dart',
        '${backups.directory}/.lock',
      ]);
      final errors = process.stderr.drain<void>();
      final lines = StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      try {
        expect(
          await lines.moveNext().timeout(const Duration(seconds: 20)),
          isTrue,
        );
        expect(lines.current, 'locked');
        final abandoned = await Directory(
          '${backups.directory}/.building-interrupted',
        ).create();
        final file = await File('${abandoned.path}/data.db')
            .writeAsString('SYNTHETIC interrupted copy');
        failedPrivately(await cli(['list', '--root', backups.directory]));
        process.kill(ProcessSignal.sigkill);
        await process.exitCode.timeout(const Duration(seconds: 10));
        expect(
          (await cli([
            'create',
            '--root',
            backups.directory,
            '--config',
            config.path,
          ])).exitCode,
          0,
        );
        expect(await file.readAsString(), 'SYNTHETIC interrupted copy');
        expect((await backups.list()).length, 1);
      } finally {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode;
        await lines.cancel();
        await errors;
      }
    },
  );
}
