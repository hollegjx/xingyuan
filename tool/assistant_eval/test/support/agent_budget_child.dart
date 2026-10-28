import 'dart:io';

import 'package:xingyuan_assistant_eval/agent_eval/budget.dart';

Future<void> main(List<String> args) async {
  try {
    final ledger = EvaluationBudget.claim(args.single);
    ledger.reserve('S01', 1, 1000);
    stdout.writeln('reserved');
    await stdout.flush();
    await Future<void>.delayed(const Duration(hours: 1));
    ledger.close();
  } catch (_) {
    exitCode = 64;
  }
}
