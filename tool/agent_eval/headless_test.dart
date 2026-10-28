import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:xingyuan_assistant_eval/agent_eval/live_gate.dart';

import 'run_preparation.dart';

void main() {
  const encoded = String.fromEnvironment('AGENT_EVAL_OPTIONS');
  test(
    'explicitly gated headless Agent evaluation',
    () async {
      try {
        final args = (jsonDecode(
          utf8.decode(base64Url.decode(encoded)),
        ) as List).cast<String>();
        final options = AgentDriverOptions.parse(args);
        tzdata.initializeTimeZones();
        await runPreparation(
          options,
          Directory.current.resolveSymbolicLinksSync(),
        );
      } catch (_) {
        // Even loader exceptions must not reflect configuration or credentials.
        fail(
          'Agent preparation failed; no automatic retry and no quota refund.',
        );
      }
    },
    skip: encoded.isEmpty ? 'Use the explicitly gated driver CLI.' : false,
    timeout: const Timeout(Duration(minutes: 25)),
  );
}
