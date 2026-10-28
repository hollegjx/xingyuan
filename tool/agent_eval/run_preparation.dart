import 'dart:convert';
import 'dart:io';

import 'package:xingyuan_assistant_eval/agent_eval/budget.dart';
import 'package:xingyuan_assistant_eval/agent_eval/fixtures.dart';
import 'package:xingyuan_assistant_eval/agent_eval/live_gate.dart';
import 'package:xingyuan_assistant_eval/agent_eval/report.dart';
import 'package:xingyuan_assistant_eval/agent_eval/source_fingerprint.dart';
import 'package:xingyuan_assistant_eval/agent_eval/trace.dart';
import 'package:xingyuan_server/src/agent_protocol.dart';

import 'app_driver.dart';

AgentRunMetadata driverMetadata(
  String root, {
  required bool live,
  String fixtureVersion = 'agent-c26-v2',
}) => AgentRunMetadata.fromJson({
  'product': productFingerprint(root),
  'test': sourceFingerprint(root, [
    'tool/agent_eval',
    'tool/assistant_eval/lib/agent_eval',
    'tool/assistant_eval/bin',
    'tool/assistant_eval/test',
    'test',
  ]),
  'prompt': digest({'version': agentPromptVersion, 'text': agentSystemPrompt}),
  'tool_schema': digest(agentToolSchemas()),
  'model': digest(live ? 'gpt-6-luna' : 'scripted-wire-v1'),
  'parameters': digest({
    'reasoning_effort': 'none',
    'max_completion_tokens': 1500,
    'tool_choice': 'auto',
    'parallel_tool_calls': false,
    'store': false,
    'automatic_retries': 0,
    'evaluation_limit': 300,
  }),
  'fixture_version': fixtureVersion,
  'seed': 20261028,
  'evidence_kind': live ? 'live' : 'app_offline',
  'scoring_policy': 'trajectory-v1',
  'scorer': sourceFileFingerprint(
    root,
    'tool/assistant_eval/lib/agent_eval/scoring.dart',
  ),
});

Future<Json> runPreparation(
  AgentDriverOptions options,
  String root, {
  String? stateHome,
}) async {
  final metadata = driverMetadata(
    root,
    live: options.live,
    fixtureVersion: options.fixtureVersion,
  );
  final permit = options.live
      ? LivePermit.read(
          live: true,
          marker: options.marker,
          productDigest: metadata.data['product'] as String,
        )
      : null;
  final output = Directory(options.output).absolute;
  if (FileSystemEntity.typeSync(output.path) != FileSystemEntityType.notFound) {
    throw const FormatException('Fresh output required');
  }
  output.parent.createSync(recursive: true);
  File('${output.path}.claim').createSync(exclusive: true);
  output.createSync();
  final home = stateHome ?? Platform.environment['HOME'];
  if (permit != null && (home == null || !Directory(home).isAbsolute)) {
    throw const FormatException('Persistent authorization state unavailable');
  }
  // Host-user state is independent of builds, checkouts and output paths.
  final registry = Directory(
    '$home/Library/Application Support/XingyuanAgentEval/authorizations',
  );
  if (permit != null) registry.createSync(recursive: true);
  final ledgerPath = permit == null
      ? '${output.path}/evaluation.sqlite'
      : '${registry.path}/${permit.id}.sqlite';
  // Claim once, before reading configuration. Reusing a marker with a different
  // output path cannot create a new allowance, including after a failed startup.
  final budget = EvaluationBudget.claim(
    ledgerPath,
    limit: permit?.limit ?? 300,
  );
  try {
    // Preserve the one-shot claim even when fixture setup fails, and validate
    // the selected fixture before any optional configuration access.
    final List<AgentScenario> scenarios;
    try {
      scenarios = parseAgentScenarios(
        File(
          '$root/tool/assistant_eval/fixtures/${agentDriverFixtures[options.fixtureVersion]}',
        ).readAsStringSync(),
      );
    } on FileSystemException {
      throw const FormatException('Fixture unavailable');
    }
    if (scenarios.any(
      (s) => s.data['fixture_version'] != options.fixtureVersion,
    )) {
      throw const FormatException('Fixture selection mismatch');
    }
    final client = permit == null
        ? null
        : await permit.loadConfig(options.config!);
    final driver = AppAgentEvaluationDriver(
      metadata: metadata,
      output: output,
      budget: budget,
      liveClient: client,
      permit: permit,
    );
    final report = await evaluateAgentRun(scenarios, driver);
    const encoder = JsonEncoder.withIndent('  ');
    void write(String name, Object value) =>
        File('${output.path}/$name')
            .writeAsStringSync('${encoder.convert(value)}\n', flush: true);
    write('report.json', report);
    File('${output.path}/report.md')
        .writeAsStringSync(agentReportMarkdown(report), flush: true);
    write('synthetic-traces.json', {
      'metadata': metadata.data,
      'traces': driver.traces.map((t) => t.data).toList(),
    });
    write('adapter-evidence.json', {
      'prompt_version': agentPromptVersion,
      'mode': options.live ? 'live' : 'scripted',
      'attempts': budget.used,
      'limit': budget.limit,
      'cases': driver.diagnostics,
      'native': 'not_run',
      'semantic_review': 'needs_human',
      'presentation': 'covered_by_A2_A3_component_QA_not_reexecuted',
      'scoring_policy': 'trajectory-v1',
      'process_privacy_scan': 'not_observed',
    });
    return report;
  } finally {
    budget.close();
  }
}
