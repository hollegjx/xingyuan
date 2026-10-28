import 'dart:io';

import 'package:xingyuan_assistant_eval/agent_eval/compare_cli.dart';

Future<void> main(List<String> args) async {
  exitCode = await compareReportsCli(args);
}
