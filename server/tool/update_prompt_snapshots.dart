import 'dart:io';

import 'package:xingyuan_server/src/prompts.dart';

void main() {
  Directory('test/fixtures').createSync(recursive: true);
  File('test/fixtures/assistant_prompt.txt')
      .writeAsStringSync(assistantSystemPrompt);
  File('test/fixtures/summary_prompt.txt')
      .writeAsStringSync(summarySystemPrompt);
}
