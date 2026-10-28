import 'dart:convert';
import 'dart:io';

String? privatePathReason(String path) {
  final parts = path.split('/');
  if (parts.any(
    (part) => const {
      '.ai-bus',
      '.claude',
      '.codex',
      '.stfolder',
      '.stignore',
      '.stversions',
      '.git',
      '.dart_tool',
      'build',
      'private',
      'backups',
      'xcuserdata',
    }.contains(part),
  )) {
    return 'private or generated directory';
  }
  final name = parts.last;
  if ((name == '.env' || name.startsWith('.env.')) && name != '.env.example') {
    return 'environment configuration';
  }
  if (path.startsWith('config/') &&
      name.endsWith('.json') &&
      !name.endsWith('.example.json')) {
    return 'non-example configuration';
  }
  if (RegExp(
    r'\.(?:db|sqlite|sqlite3)(?:-(?:wal|shm|journal))?$|\.(?:pem|key|p8|p12|jks|keystore|mobileprovision|provisionprofile|ipa|dump|xcuserstate)$',
    caseSensitive: false,
  ).hasMatch(name)) {
    return 'database, credential or signing artifact';
  }
  if (RegExp(r'^GOAL(?:-.*)?\.md$').hasMatch(name)) {
    return 'internal planning record';
  }
  return null;
}

List<String> privateTextReasons(String text) => [
  if (RegExp(r'/(?:Users|home)/[A-Za-z0-9._-]+').hasMatch(text))
    'personal absolute home path',
  if (RegExp(r'-----BEGIN (?:RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----')
      .hasMatch(text))
    'private-key header',
  if (RegExp(r'DEVELOPMENT_TEAM\s*=\s*[A-Z0-9]{10}\s*;').hasMatch(text))
    'Apple development-team identifier',
];

Future<void> main() async {
  final listing = await Process.run('git', ['ls-files', '-z']);
  if (listing.exitCode != 0) {
    stderr.writeln('Run the release guard from a Git repository.');
    exitCode = 2;
    return;
  }
  final paths = (listing.stdout as String)
      .split('\x00')
      .where((path) => path.isNotEmpty)
      .toSet();
  if (paths.isEmpty) {
    stderr.writeln(
      'Stage the intended release files before running the guard.',
    );
    exitCode = 2;
    return;
  }
  var failures = 0;
  for (final path in paths) {
    final reasons = <String>[
      if (privatePathReason(path) case final String reason) reason,
    ];
    // Inspect the index so unstaged cleanup cannot hide a staged secret.
    final blob = await Process.run('git', [
      'show',
      ':$path',
    ], stdoutEncoding: null);
    if (blob.exitCode != 0) {
      reasons.add('cannot inspect staged content');
    } else {
      final bytes = blob.stdout as List<int>;
      if (!bytes.contains(0)) {
        reasons.addAll(
          privateTextReasons(utf8.decode(bytes, allowMalformed: true)),
        );
      }
    }
    if (reasons.isNotEmpty) {
      failures++;
      stderr.writeln('$path: ${reasons.join(', ')}');
    }
  }
  stdout.writeln(
    'Release path/privacy checks: ${paths.length} files, $failures rejected.',
  );
  stdout.writeln(
    'Also run a redacting secret scan and manually review the release.',
  );
  if (failures != 0) exitCode = 1;
}
