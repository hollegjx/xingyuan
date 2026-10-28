import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

String credentialHash(String token) =>
    sha256.convert(utf8.encode(token)).toString();

bool constantTimeEqual(String left, String right) {
  var difference = left.length ^ right.length;
  for (var index = 0; index < max(left.length, right.length); index++) {
    difference |=
        (index < left.length ? left.codeUnitAt(index) : 0) ^
        (index < right.length ? right.codeUnitAt(index) : 0);
  }
  return difference == 0;
}

class DeviceRegistry {
  DeviceRegistry(this.path);
  final String path;

  Future<List<Map<String, dynamic>>> entries() async {
    final file = File(path);
    if (!await file.exists()) return [];
    if ((await file.stat()).mode & 0x3f != 0) {
      throw const FormatException('Device file permissions');
    }
    final value = jsonDecode(await file.readAsString());
    if (value is! List || value.length > 100) {
      throw const FormatException('Device registry');
    }
    final labels = <String>{};
    return value.map((row) {
      if (row is! Map<String, dynamic> ||
          row.length != 3 ||
          row['label'] is! String ||
          !RegExp(r'^[a-zA-Z0-9_-]{1,64}$').hasMatch(row['label'] as String) ||
          !labels.add(row['label'] as String) ||
          row['hash'] is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(row['hash'] as String) ||
          row['revoked'] is! bool) {
        throw const FormatException('Device registry');
      }
      return Map<String, dynamic>.from(row);
    }).toList();
  }

  Future<String?> authenticate(String? authorization) async {
    if (authorization == null ||
        !RegExp(r'^Bearer [A-Za-z0-9_-]{43}$').hasMatch(authorization)) {
      return null;
    }
    final hash = credentialHash(authorization.substring(7));
    String? matched;
    // Read on every request: revocation does not wait for a service restart.
    for (final entry in await entries()) {
      final matches = constantTimeEqual(hash, entry['hash'] as String);
      if (matches && entry['revoked'] == false) {
        matched = entry['label'] as String;
      }
    }
    return matched;
  }

  Future<String> issue(String label) async {
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,64}$').hasMatch(label)) {
      throw const FormatException('Device label');
    }
    final rows = await entries();
    if (rows.length >= 100 || rows.any((row) => row['label'] == label)) {
      throw const FormatException('Device label exists or registry full');
    }
    final random = Random.secure();
    final token = base64UrlEncode(List.generate(32, (_) => random.nextInt(256)))
        .replaceAll('=', '');
    rows.add({'label': label, 'hash': credentialHash(token), 'revoked': false});
    await _save(rows);
    return token;
  }

  Future<void> revoke(String label) async {
    final rows = await entries();
    final found = rows.where((row) => row['label'] == label).singleOrNull;
    if (found == null) throw const FormatException('Unknown device');
    found['revoked'] = true;
    await _save(rows);
  }

  Future<void> _save(List<Map<String, dynamic>> rows) async {
    final parent = Directory(File(path).parent.path);
    if (!await parent.exists()) {
      throw const FormatException('Create private registry directory first');
    }
    final temp = await parent.createTemp('.xingyuan-device-');
    try {
      final file = File('${temp.path}/devices.json');
      await file.writeAsString(jsonEncode(rows), flush: true);
      final mode = await Process.run('chmod', ['600', file.path]);
      if (mode.exitCode != 0) {
        throw const FileSystemException('Private file permissions');
      }
      await file.rename(path);
    } finally {
      await temp.delete(recursive: true);
    }
  }
}
