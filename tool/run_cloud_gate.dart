import 'dart:convert';
import 'dart:io';

import 'package:habit_checkin/data/sync/sync_identity.dart';
import 'package:uuid/uuid.dart';

import 'check_cloud_config.dart';
import 'cloud_gate/authorization_probe.dart';
import 'cloud_gate/gate_client.dart';

class GateOptions {
  GateOptions({
    required this.projectRef,
    this.createUsers = false,
    this.cleanupRun,
  });
  final String projectRef;
  final bool createUsers;
  final String? cleanupRun;

  factory GateOptions.parse(List<String> args) {
    final project = args.where((s) => s.startsWith('--project-ref=')).toList();
    final cleanup = args.where((s) => s.startsWith('--cleanup=')).toList();
    if (args.toSet().length != args.length ||
        !args.contains('--live') ||
        project.length != 1 ||
        cleanup.length > 1 ||
        args.any(
          (s) =>
              s != '--live' &&
              s != '--create-test-users' &&
              !project.contains(s) &&
              !cleanup.contains(s),
        )) {
      throw const GateFailure(GateFailureKind.input);
    }
    final ref = project.single.substring('--project-ref='.length);
    final run = cleanup.isEmpty
        ? null
        : cleanup.single.substring('--cleanup='.length);
    if (!RegExp(r'^[a-z0-9]{20}$').hasMatch(ref) ||
        run != null && !SyncIdentity.isUuid(run) ||
        run != null && args.contains('--create-test-users')) {
      throw const GateFailure(GateFailureKind.input);
    }
    return GateOptions(
      projectRef: ref,
      createUsers: args.contains('--create-test-users'),
      cleanupRun: run,
    );
  }
}

class GateManifest {
  const GateManifest({
    required this.projectRef,
    required this.runId,
    required this.ownerA,
    required this.ownerB,
    required this.fixtures,
  });
  final String projectRef;
  final String runId;
  final String ownerA;
  final String ownerB;
  final GateFixtures fixtures;

  Map<String, Object?> toJson() => {
    'version': 1,
    'project_ref': projectRef,
    'run_id': runId,
    'owner_a': ownerA,
    'owner_b': ownerB,
    'fixture_ids': fixtures.ids,
  };

  factory GateManifest.decode(String source, GateOptions options) {
    try {
      final json = jsonDecode(source);
      const fields = {
        'version',
        'project_ref',
        'run_id',
        'owner_a',
        'owner_b',
        'fixture_ids',
        'observed_at',
        'host',
        'report',
        'cleanup_only_passed',
        'logout_passed',
        'passed',
        'requests',
      };
      if (json is! Map<String, dynamic> ||
          !json.keys.every(fields.contains) ||
          json['version'] != 1 ||
          json['project_ref'] != options.projectRef ||
          json['run_id'] != options.cleanupRun ||
          json['owner_a'] is! String ||
          json['owner_b'] is! String ||
          !SyncIdentity.isUuid(json['owner_a'] as String) ||
          !SyncIdentity.isUuid(json['owner_b'] as String) ||
          json['owner_a'] == json['owner_b'] ||
          json['fixture_ids'] is! List ||
          (json['fixture_ids'] as List).length != 3) {
        throw const GateFailure(GateFailureKind.input);
      }
      final ids = (json['fixture_ids'] as List).cast<String>();
      return GateManifest(
        projectRef: options.projectRef,
        runId: options.cleanupRun!,
        ownerA: json['owner_a'] as String,
        ownerB: json['owner_b'] as String,
        fixtures: GateFixtures(ids[0], ids[1], ids[2]),
      );
    } catch (_) {
      throw const GateFailure(GateFailureKind.input);
    }
  }
}

String _readHidden(String label) {
  stdout.write('$label: ');
  final echo = stdin.echoMode;
  try {
    stdin.echoMode = false;
    final result = stdin.readLineSync();
    if (result == null) throw const GateFailure(GateFailureKind.input);
    return result.trim();
  } finally {
    stdin.echoMode = echo;
    stdout.writeln();
  }
}

Future<void> _protect(String path, String mode) async {
  if ((await Process.run('chmod', [mode, path])).exitCode != 0) {
    throw const GateFailure(GateFailureKind.input);
  }
}

/// Preserve the cleanup manifest until the complete report is ready.
Future<void> persistGateReport(File file, Map<String, Object?> report) async {
  final encoded = jsonEncode(report);
  if (await FileSystemEntity.type(file.path, followLinks: false) !=
      FileSystemEntityType.file) {
    throw const GateFailure(GateFailureKind.input);
  }
  final temporary = File('${file.path}.pending-${const Uuid().v4()}');
  await temporary.create(exclusive: true);
  try {
    await _protect(temporary.path, '600');
    await temporary.writeAsString(encoded, flush: true);
    await temporary.rename(file.path);
  } finally {
    if (await temporary.exists()) await temporary.delete();
  }
}

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.length == 1 && args.single == '--help') {
    stdout.writeln(
      'Usage: dart run tool/run_cloud_gate.dart --live '
      '--project-ref=<verified-dev-ref> [--create-test-users | --cleanup=<run-id>]\n'
      'Owner-operated diagnostic for synthetic accounts only. '
      'No request is sent in help mode.\n'
      'Live mode sends one OTP per entered inbox, then tests/cleans G3 rows. '
      'It does not test iPhone networks, production sync, or the full G3 gate.',
    );
    return;
  }
  GateClient? client;
  GateSession? sessionA;
  GateSession? sessionB;
  GateManifest? manifest;
  File? manifestFile;
  GateReport? report;
  bool? cleanupOnlyPassed;
  var logoutPassed = true;
  var failed = false;
  try {
    final options = GateOptions.parse(args);
    if (!stdin.hasTerminal || !Platform.isMacOS && !Platform.isLinux) {
      throw const GateFailure(GateFailureKind.input);
    }
    client = GateClient(await readLocalCloudClientConfig());
    if (client.projectRef != options.projectRef) {
      throw const GateFailure(GateFailureKind.input);
    }
    final run = options.cleanupRun ?? const Uuid().v4();
    final directory = Directory('build/cloud-gate');
    await directory.create(recursive: true);
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const GateFailure(GateFailureKind.input);
    }
    await _protect(directory.path, '700');
    final file = File('${directory.path}/$run.json');
    if ((await Process.run('git', [
              'check-ignore',
              '-q',
              '--',
              file.path,
            ])).exitCode !=
            0 ||
        (await Process.run('git', ['ls-files', '--', file.path])).stdout !=
            '') {
      throw const GateFailure(GateFailureKind.input);
    }
    if (options.cleanupRun != null) {
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
              FileSystemEntityType.file ||
          await file.length() > 65536) {
        throw const GateFailure(GateFailureKind.input);
      }
      manifest = GateManifest.decode(await file.readAsString(), options);
    }
    // Fresh tests fail before sending OTP if the schema/key is not ready.
    // Recovery must still be able to clean fixtures after a policy regression.
    if (options.cleanupRun == null) {
      expectDenied(await client.read(const Uuid().v4()), anonymous: true);
    }
    stdout.writeln(
      'Only use the two owner-approved test inboxes. '
      'Inputs are hidden; sessions stay in memory. '
      'Each inbox entry sends one code, without automatic retries.',
    );
    final emailA = _readHidden('Test inbox A');
    await client.sendCode(emailA, createUser: options.createUsers);
    sessionA = await client.verifyCode(emailA, _readHidden('A email code'));
    sessionA = await client.refresh(sessionA);
    await client.verifyIdentity(sessionA);
    final emailB = _readHidden('Test inbox B');
    if (emailA.toLowerCase() == emailB.toLowerCase()) {
      throw const GateFailure(GateFailureKind.input);
    }
    await client.sendCode(emailB, createUser: options.createUsers);
    sessionB = await client.verifyCode(emailB, _readHidden('B email code'));
    sessionB = await client.refresh(sessionB);
    await client.verifyIdentity(sessionB);
    if (sessionA.userId == sessionB.userId) {
      throw const GateFailure(GateFailureKind.accountMismatch);
    }
    if (manifest != null) {
      if (sessionA.userId != manifest.ownerA ||
          sessionB.userId != manifest.ownerB) {
        throw const GateFailure(GateFailureKind.accountMismatch);
      }
      final recovery = File(
        '${directory.path}/$run.cleanup-${const Uuid().v4()}.json',
      );
      await recovery.create(exclusive: true);
      manifestFile = recovery;
      await _protect(recovery.path, '600');
      await recovery.writeAsString(jsonEncode(manifest.toJson()), flush: true);
    } else {
      manifest = GateManifest(
        projectRef: options.projectRef,
        runId: run,
        ownerA: sessionA.userId,
        ownerB: sessionB.userId,
        fixtures: GateFixtures.fresh(),
      );
      await file.create(exclusive: true);
      manifestFile = file;
      await _protect(file.path, '600');
      await file.writeAsString(jsonEncode(manifest.toJson()), flush: true);
    }
    stdout.writeln('Run manifest: ${manifestFile.path}');
    final probe = AuthorizationProbe(
      client: client,
      a: sessionA,
      b: sessionB,
      fixtures: manifest.fixtures,
    );
    if (options.cleanupRun == null) {
      report = await probe.run();
      failed = !report.passed;
      for (final result in report.results) {
        stdout.writeln(
          '${result.check.name}: ${result.failure?.name ?? 'passed'}',
        );
      }
    } else {
      cleanupOnlyPassed = await probe.cleanup();
      failed = !cleanupOnlyPassed;
    }
  } on GateFailure catch (error) {
    stderr.writeln(error.toString());
    failed = true;
  } on CloudConfigError catch (error) {
    stderr.writeln(error.toString());
    failed = true;
  } catch (_) {
    stderr.writeln('Probe failed; sensitive details withheld.');
    failed = true;
  } finally {
    if (client != null) {
      for (final session in [sessionA, sessionB]) {
        if (session == null) continue;
        try {
          await client.logout(session);
        } catch (_) {
          logoutPassed = false;
          failed = true;
        }
      }
    }
    if (manifestFile != null && manifest != null) {
      try {
        await persistGateReport(manifestFile, {
          ...manifest.toJson(),
          'observed_at': DateTime.now().toUtc().toIso8601String(),
          'host': Platform.operatingSystem,
          'report': report?.toJson(),
          'cleanup_only_passed': cleanupOnlyPassed,
          'logout_passed': logoutPassed,
          'passed': !failed,
          'requests': client?.observations,
        });
      } catch (_) {
        failed = true;
        stderr.writeln('Unable to persist the credential-free probe report.');
      }
    }
    if (!logoutPassed) stderr.writeln('Test-session logout not confirmed.');
    if (failed) {
      stderr.writeln(
        'G3 probe did not pass; inspect the report and cleanup state.',
      );
      exitCode = 1;
    } else {
      stdout.writeln(
        '${cleanupOnlyPassed == true ? 'Synthetic cleanup passed; the original probe result is unchanged.' : 'Synthetic API probe/cleanup passed.'} '
        'This is not iPhone network or full G3 acceptance.',
      );
    }
  }
}
