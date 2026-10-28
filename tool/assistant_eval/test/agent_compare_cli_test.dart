import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:xingyuan_assistant_eval/agent_eval/compare_cli.dart';
import 'package:xingyuan_assistant_eval/agent_eval/declared_comparison.dart';
import 'package:xingyuan_assistant_eval/agent_eval/fixtures.dart';

void main() {
  late Directory dir;
  late String before, after;
  late Json a, b, review;
  final fixture = File('fixtures/agent_scenarios.json').readAsStringSync();
  const path = 'server/lib/src/prompts/agent_v2.dart';
  void write(String name, String text) {
    final f = File('${dir.path}/$name');
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(text);
  }

  String git(List<String> args) {
    final r = Process.runSync(
      'git',
      args,
      workingDirectory: dir.path,
      environment: {
        'GIT_AUTHOR_NAME': 'Synthetic QA',
        'GIT_AUTHOR_EMAIL': 'qa@example.invalid',
        'GIT_COMMITTER_NAME': 'Synthetic QA',
        'GIT_COMMITTER_EMAIL': 'qa@example.invalid',
      },
    );
    expect(r.exitCode, 0);
    return (r.stdout as String).trim();
  }

  Json report(String text) => {
    'schema': 'agent-eval-report-v1',
    'scoring_policy': 'trajectory-v1',
    'metadata': {
      'product': digest({path: byteDigest(text)}),
      'prompt': digest(text),
      'tool_schema': digest('tools'),
      'test': digest('tests'),
      'model': digest('model'),
      'parameters': digest('parameters'),
      'fixture_version': 'agent-c26-v2',
      'seed': 20261028,
      'evidence_kind': 'live',
      'scoring_policy': 'trajectory-v1',
    },
    'cases': [
      for (final s in parseAgentScenarios(fixture))
        {
          'case_id': s.id,
          'fixture_digest': s.fingerprint,
          'status': 'fail',
          'assessment': 'trajectory-v1',
          for (final key in [
            'model_calls',
            'extra_queries',
            'forbidden_requests',
            'denied_requests',
            'illegal_executions',
            'illegal_outbound',
            'canary_leaks',
          ])
            key: 0,
        },
    ],
  };
  setUp(() {
    dir = Directory.systemTemp.createTempSync('c29-report-only-test-');
    git(['init', '--quiet']);
    write(path, 'before');
    write(
      'tool/assistant_eval/lib/agent_eval/scoring.dart',
      'unchanged scorer',
    );
    write('tool/assistant_eval/fixtures/agent_scenarios.json', fixture);
    git(['add', '.']);
    git([
      '-c',
      'core.hooksPath=/dev/null',
      'commit',
      '--no-gpg-sign',
      '-qm',
      'before',
    ]);
    before = git(['rev-parse', 'HEAD']);
    write(path, 'after');
    git(['add', path]);
    git([
      '-c',
      'core.hooksPath=/dev/null',
      'commit',
      '--no-gpg-sign',
      '-qm',
      'after',
    ]);
    after = git(['rev-parse', 'HEAD']);
    a = report('before');
    b = report('after');
    review = {
      'schema': 'agent-source-review-v1',
      'review_id': 'C29-cli-test',
      'variables': ['prompt'],
      'product_changes': [
        {
          'path': path,
          'before': byteDigest('before'),
          'after': byteDigest('after'),
          'kind': 'prompt',
        },
      ],
    };
  });
  tearDown(() => dir.deleteSync(recursive: true));
  List<String> args() {
    write('a.json', jsonEncode(a));
    write('b.json', jsonEncode(b));
    write('review.json', jsonEncode(review));
    return [
      '--before',
      '${dir.path}/a.json',
      '--after',
      '${dir.path}/b.json',
      '--before-revision',
      before,
      '--after-revision',
      after,
      '--repository',
      dir.path,
      '--review',
      '${dir.path}/review.json',
      '--output',
      '${dir.path}/out',
    ];
  }

  test(
    'report-only CLI pairs original statuses without rescoring or mutation',
    () async {
      expect(await compareReportsCli(args()), 0);
      final output = object(
        jsonDecode(File('${dir.path}/out/comparison.json').readAsStringSync()),
      );
      expect(output['paired'], 20);
      expect(
        (output['pairs'] as List)
            .map(object)
            .every((p) => p['before'] == 'fail' && p['after'] == 'fail'),
        true,
      );
      expect(File('${dir.path}/a.json').readAsStringSync(), jsonEncode(a));
      expect(File('${dir.path}/b.json').readAsStringSync(), jsonEncode(b));
      expect(File('${dir.path}/out/declaration.json').existsSync(), true);
      expect(
        File('${dir.path}/out/comparison.md').readAsStringSync(),
        contains('not causal'),
      );
      expect(await compareReportsCli(args()), 64);
    },
  );
  for (final kind in [
    'unknown_option',
    'symbolic_revision',
    'unreviewed_hash',
    'product_mismatch',
    'unknown_review_field',
    'scorer_change',
  ]) {
    test('invalid $kind leaves no output', () async {
      if (kind == 'unreviewed_hash') {
        object((review['product_changes'] as List).single)['after'] = digest(
          'wrong',
        );
      }
      if (kind == 'product_mismatch') {
        object(b['metadata'])['product'] = digest('wrong');
      }
      if (kind == 'unknown_review_field') {
        review['unsafe'] = 'PRIVATE_C29_CANARY';
      }
      if (kind == 'scorer_change') {
        write('tool/assistant_eval/lib/agent_eval/scoring.dart', 'changed');
        git(['add', '.']);
        git([
          '-c',
          'core.hooksPath=/dev/null',
          'commit',
          '--no-gpg-sign',
          '-qm',
          'scorer',
        ]);
        after = git(['rev-parse', 'HEAD']);
      }
      final values = args();
      if (kind == 'unknown_option') {
        values.addAll(['--live', 'PRIVATE_C29_CANARY']);
      }
      if (kind == 'symbolic_revision') {
        values[values.indexOf('--after-revision') + 1] = 'HEAD';
      }
      expect(await compareReportsCli(values), 64);
      expect(Directory('${dir.path}/out').existsSync(), false);
    });
  }
}
