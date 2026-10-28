import 'dart:io';

import 'package:crypto/crypto.dart';

import 'fixtures.dart';

String sourceFileFingerprint(String root, String path) =>
    sha256.convert(File('$root/$path').readAsBytesSync()).toString();

String sourceFingerprint(String root, List<String> directories) {
  final hashes = <String, String>{};
  for (final directory in directories) {
    for (final entry in Directory(
      '$root/$directory',
    ).listSync(recursive: true, followLinks: false)) {
      if (entry is File && entry.path.endsWith('.dart')) {
        hashes[entry.path.substring(root.length + 1)] = sha256
            .convert(entry.readAsBytesSync())
            .toString();
      }
    }
  }
  if (hashes.isEmpty) throw const FormatException('Missing sources');
  return digest(hashes);
}

String productFingerprint(String root) => sourceFingerprint(root, [
  'lib',
  'server/lib',
  'packages/xingyuan_core/lib',
]);
