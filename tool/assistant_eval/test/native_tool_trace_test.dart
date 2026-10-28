import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import '../tool/native_tool_trace.dart';

void main() {
  late Directory root;
  late File asset;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('qa-startup-probe-test-');
    asset = File('${root.path}/overlap/.dart_tool/lib/libsqlite3.dylib');
    await asset.parent.create(recursive: true);
    await asset.writeAsString('synthetic-native-asset');
  });
  tearDown(() => root.delete(recursive: true));

  test('trace accepts only its temporary runtime asset', () async {
    final result = await traceTarget(root, asset.path);
    expect(
      await result.resolveSymbolicLinks(),
      await asset.resolveSymbolicLinks(),
    );
    await expectLater(
      traceTarget(root, '${asset.parent.path}/other.dylib'),
      throwsArgumentError,
    );
    await expectLater(
      traceTarget(Directory.current, asset.path),
      throwsArgumentError,
    );
    final outside = await Directory.systemTemp.createTemp('qa-trace-outside-');
    addTearDown(() => outside.delete(recursive: true));
    await expectLater(
      traceTarget(root, '${outside.path}/libsqlite3.dylib'),
      throwsArgumentError,
    );
  });

  test('trace rejects a symlink instead of following its target', () async {
    final target = File('${root.path}/untouched')
      ..writeAsStringSync('synthetic');
    await asset.delete();
    await Link(asset.path).create(target.path);
    await expectLater(traceTarget(root, asset.path), throwsArgumentError);
    expect(await target.readAsString(), 'synthetic');
  });

  test(
    'inspection preserves bytes and distinguishes empty and missing',
    () async {
      final snapshot = await inspectNativeAsset(asset);
      expect(snapshot['size_before'], 22);
      expect(snapshot['size_after'], 22);
      expect(snapshot['header_hex'], '73796e74');
      expect(
        snapshot['sha256'],
        '${sha256.convert(utf8.encode('synthetic-native-asset'))}',
      );
      expect(await asset.readAsString(), 'synthetic-native-asset');
      await asset.writeAsString('');
      expect((await inspectNativeAsset(asset))['size_before'], 0);
      await asset.delete();
      expect((await inspectNativeAsset(asset))['missing'], isTrue);
    },
  );
}
