import 'dart:convert';
import 'dart:io';

import '../test/support/cli_process.dart';

Future<File> traceTarget(Directory root, String path) async {
  final canonicalRoot = await root.resolveSymbolicLinks();
  final temporary = await Directory.systemTemp.resolveSymbolicLinks();
  if (!canonicalRoot.startsWith('$temporary/qa-startup-probe-')) {
    throw ArgumentError('Trace root must be a disposable startup probe');
  }
  final file = File(path);
  final parent = await file.parent.resolveSymbolicLinks();
  if (!parent.startsWith('$canonicalRoot/') ||
      !parent.endsWith('/.dart_tool/lib') ||
      file.uri.pathSegments.last != 'libsqlite3.dylib' ||
      await FileSystemEntity.isLink(file.path)) {
    throw ArgumentError(
      'Only the disposable runtime SQLite asset may be traced',
    );
  }
  return File('$parent/libsqlite3.dylib');
}

Future<Map<String, Object?>> inspectNativeAsset(File file) async {
  final started = DateTime.now().toUtc().toIso8601String();
  try {
    final before = await file.stat();
    if (before.type == FileSystemEntityType.notFound) {
      return {'started': started, 'missing': true};
    }
    final handle = await file.open();
    late final List<int> header;
    try {
      header = await handle.read(4);
    } finally {
      await handle.close();
    }
    final hash = await runCli('/usr/bin/shasum', [
      '-a',
      '256',
      file.path,
    ], timeout: const Duration(seconds: 2));
    final digest = RegExp(r'^([a-f0-9]{64}) ').firstMatch('${hash.stdout}');
    final after = await file.stat();
    return {
      'started': started,
      'finished': DateTime.now().toUtc().toIso8601String(),
      'size_before': before.size,
      'size_after': after.size,
      'modified_before': before.modified.toUtc().toIso8601String(),
      'modified_after': after.modified.toUtc().toIso8601String(),
      'header_hex': header
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join(),
      'sha256': hash.exitCode == 0 ? digest?.group(1) : null,
      'hash_exit': hash.exitCode,
    };
  } catch (error) {
    return {'started': started, 'inspection_error': '$error'};
  }
}

Future<void> main(List<String> args) async {
  const supported = {'otool', 'install_name_tool', 'codesign'};
  final rootPath = Platform.environment['XINGYUAN_NATIVE_TRACE_ROOT'];
  final sample = Platform.environment['XINGYUAN_NATIVE_TRACE_SAMPLE'];
  if (!Platform.isMacOS ||
      args.length < 2 ||
      !supported.contains(args.first) ||
      rootPath == null ||
      sample == null ||
      !RegExp(r'^(serial|overlap|gateway)-[0-9]+$').hasMatch(sample)) {
    stderr.writeln('Native tool tracing requires a synthetic startup probe');
    exitCode = 64;
    return;
  }
  final root = Directory(rootPath);
  final target = await traceTarget(root, args.last);
  final directory = Directory('${root.path}/native-trace');
  await directory.create();
  final log = File('${directory.path}/$sample-${args.first}-$pid.jsonl');
  Future<void> record(String phase, Map<String, Object?> details) async {
    await log.writeAsString(
      '${jsonEncode({'sample': sample, 'tool': args.first, 'wrapper_pid': pid, 'phase': phase, 'at': DateTime.now().toUtc().toIso8601String(), 'target': target.path, ...details})}\n',
      mode: FileMode.append,
    );
  }

  // Inspection is a time interval, not an atomic snapshot or an OS write trace.
  await record('before', {'asset': await inspectNativeAsset(target)});
  try {
    final result = await runCli(
      '/usr/bin/${args.first}',
      args.sublist(1),
      timeout: const Duration(seconds: 10),
    );
    stdout.write(result.stdout);
    stderr.write(result.stderr);
    exitCode = result.exitCode;
    await record('after', {
      'tool_pid': result.pid,
      'exit': result.exitCode,
      'asset': await inspectNativeAsset(target),
    });
  } catch (error) {
    await record('failed', {'error': '$error'});
    stderr.writeln(error);
    exitCode = 70;
  }
}
