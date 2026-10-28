import 'dart:io';

Future<void> main(List<String> args) async {
  final lock = await File(args.single).open(mode: FileMode.append);
  try {
    await lock.lock();
    stdout.writeln('locked');
    await stdin.drain<void>();
  } finally {
    await lock.close();
  }
}
