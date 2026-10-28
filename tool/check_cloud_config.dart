import 'dart:convert';
import 'dart:io';

enum CloudConfigIssue {
  invalidJson,
  unexpectedFields,
  invalidProjectUrl,
  invalidPublishableKey,
}

class CloudConfigError implements Exception {
  const CloudConfigError(this.issue);
  final CloudConfigIssue issue;

  @override
  String toString() => 'CloudConfigError(${issue.name})';
}

/// Checks the dedicated hosted-dev client file, never an admin configuration.
void validateCloudClientConfig(String source) {
  final Object? parsed;
  try {
    parsed = jsonDecode(source);
  } on FormatException {
    throw const CloudConfigError(CloudConfigIssue.invalidJson);
  }
  const fields = {'SUPABASE_URL', 'SUPABASE_PUBLISHABLE_KEY'};
  if (parsed is! Map<String, dynamic> ||
      parsed.length != fields.length ||
      !fields.every(parsed.containsKey)) {
    throw const CloudConfigError(CloudConfigIssue.unexpectedFields);
  }
  final rawUrl = parsed['SUPABASE_URL'];
  final url = rawUrl is String ? Uri.tryParse(rawUrl) : null;
  if (url == null ||
      url.scheme != 'https' ||
      url.userInfo.isNotEmpty ||
      url.hasPort ||
      url.hasQuery ||
      url.hasFragment ||
      (url.path.isNotEmpty && url.path != '/') ||
      !RegExp(r'^[a-z0-9]{20}\.supabase\.co$').hasMatch(url.host) ||
      rawUrl != url.toString()) {
    throw const CloudConfigError(CloudConfigIssue.invalidProjectUrl);
  }
  final key = parsed['SUPABASE_PUBLISHABLE_KEY'];
  if (key is! String ||
      key.contains('REPLACE') ||
      !RegExp(r'^sb_publishable_[A-Za-z0-9_-]{20,}$').hasMatch(key)) {
    throw const CloudConfigError(CloudConfigIssue.invalidPublishableKey);
  }
}

Future<String> readLocalCloudClientConfig() async {
  const path = 'config/supabase.local.json';
  if (await FileSystemEntity.type(path, followLinks: false) !=
      FileSystemEntityType.file) {
    throw const FileSystemException('Local client configuration is missing');
  }
  final file = File(path);
  final stat = await file.stat();
  if ((stat.mode & 0x1ff) != 0x180 || stat.size > 16384) {
    throw const FileSystemException('Expected a small owner-only 0600 file');
  }
  final ignored = await Process.run('git', ['check-ignore', '-q', '--', path]);
  final tracked = await Process.run('git', ['ls-files', '-z', '--', path]);
  if (ignored.exitCode != 0 ||
      tracked.exitCode != 0 ||
      (tracked.stdout as String).isNotEmpty) {
    throw const FileSystemException(
      'Expected ignored, untracked configuration',
    );
  }
  final source = await file.readAsString();
  validateCloudClientConfig(source);
  return source;
}

Future<void> main(List<String> args) async {
  if (args.isNotEmpty) {
    stderr.writeln('Usage: dart run tool/check_cloud_config.dart');
    exitCode = 64;
    return;
  }
  try {
    await readLocalCloudClientConfig();
    stdout.writeln(
      'Client configuration checks passed; values withheld. '
      'No network, login or cloud validation was performed.',
    );
  } on CloudConfigError catch (error) {
    stderr.writeln(error.toString());
    exitCode = 1;
  } catch (_) {
    stderr.writeln(
      'Unable to inspect local client configuration; values withheld',
    );
    exitCode = 1;
  }
}
