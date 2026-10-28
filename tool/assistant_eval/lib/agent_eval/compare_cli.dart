import 'dart:convert';
import 'dart:io';

import 'declared_comparison.dart';
import 'fixtures.dart';
import 'report.dart';

Never _invalid() => throw const FormatException('Invalid report comparison');

class _Revision {
  _Revision(this.repository, this.sha) {
    if (!RegExp(r'^[a-f0-9]{40}$').hasMatch(sha)) _invalid();
    if (_git(['rev-parse', '--verify', '$sha^{commit}']).trim() != sha) {
      _invalid();
    }
  }
  final String repository, sha;
  String _git(List<String> args) {
    final r = Process.runSync('git', [
      '--no-replace-objects',
      ...args,
    ], workingDirectory: repository);
    if (r.exitCode != 0) _invalid();
    return r.stdout as String;
  }

  String read(String path) => _git(['show', '$sha:$path']);
  Json productSources() {
    final entries = _git([
      'ls-tree',
      '-rz',
      '--full-tree',
      sha,
      '--',
      'lib',
      'server/lib',
      'packages/xingyuan_core/lib',
    ]).split('\u0000');
    final result = <String, Object?>{};
    for (final entry in entries.where((e) => e.isNotEmpty)) {
      final parts = entry.split('\t');
      if (parts.length != 2) _invalid();
      final path = parts[1];
      if (!path.endsWith('.dart')) continue;
      if (!parts[0].startsWith('100644 blob ') &&
          !parts[0].startsWith('100755 blob ')) {
        _invalid();
      }
      result[path] = byteDigest(read(path));
    }
    return result;
  }
}

// This command only reads retained reports and Git blobs. No driver/scorer,
// configuration loader, credential reader or live-run entry point is invoked.
Future<int> compareReportsCli(List<String> args) async {
  try {
    const names = {
      '--before',
      '--after',
      '--before-revision',
      '--after-revision',
      '--repository',
      '--review',
      '--output',
    };
    final options = <String, String>{};
    if (args.length != names.length * 2) _invalid();
    for (var i = 0; i < args.length; i += 2) {
      if (!names.contains(args[i]) ||
          options.containsKey(args[i]) ||
          args[i + 1].isEmpty) {
        _invalid();
      }
      options[args[i]] = args[i + 1];
    }
    final out = Directory(options['--output']!);
    if (FileSystemEntity.typeSync(out.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      _invalid();
    }
    final rawA = File(options['--before']!).readAsStringSync(),
        rawB = File(options['--after']!).readAsStringSync();
    final a = object(jsonDecode(rawA)), b = object(jsonDecode(rawB));
    final review = object(
      jsonDecode(File(options['--review']!).readAsStringSync()),
    );
    if (review.length != 4 ||
        !review.keys.every(
          {'schema', 'review_id', 'variables', 'product_changes'}.contains,
        ) ||
        review['schema'] != 'agent-source-review-v1') {
      _invalid();
    }
    final x = _Revision(
          options['--repository']!,
          options['--before-revision']!,
        ),
        y = _Revision(options['--repository']!, options['--after-revision']!);
    String fixtures(_Revision r, Json report) {
      final version = object(report['metadata'])['fixture_version'];
      if (!agentDriverFixtures.containsKey(version)) _invalid();
      return r.read(
        'tool/assistant_eval/fixtures/${agentDriverFixtures[version]}',
      );
    }

    const scorer = 'tool/assistant_eval/lib/agent_eval/scoring.dart';
    final declaration = <String, Object?>{
      'schema': 'agent-treatment-declaration-v1',
      'before_report': digest(a),
      'after_report': digest(b),
      'review_id': review['review_id'],
      'variables': review['variables'],
      'product_changes': review['product_changes'],
      'before_sources': x.productSources(),
      'after_sources': y.productSources(),
      'before_scorer': byteDigest(x.read(scorer)),
      'after_scorer': byteDigest(y.read(scorer)),
      'before_fixtures': fixtures(x, a),
      'after_fixtures': fixtures(y, b),
      'coverage_cases':
          object(a['metadata'])['fixture_version'] ==
                    object(b['metadata'])['fixture_version']
                ? <String>[]
                : c29CoverageCases.toList()
            ..sort(),
    };
    final result = compareAgentRuns(a, b, treatment: declaration);
    result['source_evidence'] = {
      'before_revision': x.sha,
      'after_revision': y.sha,
      'before_report_bytes': byteDigest(rawA),
      'after_report_bytes': byteDigest(rawB),
      'declaration_digest': digest(declaration),
      'original_reports_unchanged': true,
      'rescored': false,
    };
    // A competing creator is an error, not permission to replace its evidence.
    out.parent.createSync(recursive: true);
    final made = await Process.run('mkdir', [out.absolute.path]);
    if (made.exitCode != 0) _invalid();
    const encoder = JsonEncoder.withIndent('  ');
    File('${out.path}/declaration.json')
        .writeAsStringSync('${encoder.convert(declaration)}\n');
    File('${out.path}/comparison.json')
        .writeAsStringSync('${encoder.convert(result)}\n');
    File('${out.path}/comparison.md')
        .writeAsStringSync(comparisonMarkdown(result));
    stdout.writeln(
      'Retained-report comparison written; no rescoring or model calls.',
    );
    return 0;
  } catch (_) {
    stderr.writeln(
      'Invalid report-only comparison. Supply original reports, exact revisions, a reviewed source declaration and a fresh output directory.',
    );
    return 64;
  }
}

String comparisonMarkdown(Json result) {
  final text = StringBuffer('# Declared Treatment Comparison\n\n');
  text.writeln(
    'Observational pairing, not causal or prompt-only proof. Original scores and failures are retained; no rescoring or model execution.',
  );
  text.writeln(
    'Model aliases do not prove identical provider revisions. Manual semantics and product acceptance remain unverified.',
  );
  text.writeln(
    'Paired: ${result['paired']}; machine pass-to-nonpass regressions: ${result['regressions']}.',
  );
  text.writeln(
    'Variables: ${result['declared_variables']}; diagnostic instrumentation changed: ${result['diagnostic_instrumentation_changed']}.',
  );
  text.writeln(
    'Metadata mismatches: ${result['metadata_mismatches']}; separate coverage cases: ${result['coverage_cases']}.\n',
  );
  text.writeln(
    '| Case | Before | After | Paired | Unpaired Reason |\n| --- | --- | --- | --- | --- |',
  );
  for (final p in (result['pairs'] as List).map(object)) {
    text.writeln(
      '| ${p['case_id']} | ${p['before']} | ${p['after']} | ${p['comparable']} | ${p['unpaired_reason'] ?? "none"} |',
    );
  }
  text.writeln(
    '\nExact source hashes, fixture byte/content digests and original metadata are retained in the JSON evidence. Review classifications are attestations, not automatic semantic equivalence. A machine fail-to-fail pair can still contain a semantic regression.',
  );
  return text.toString();
}
