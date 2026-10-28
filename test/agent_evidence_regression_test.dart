import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:habit_checkin/features/assistant/data/assistant_service.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:xingyuan_assistant_eval/agent_eval/budget.dart';
import 'package:xingyuan_assistant_eval/agent_eval/fixtures.dart';
import 'package:xingyuan_assistant_eval/agent_eval/live_gate.dart';
import 'package:xingyuan_assistant_eval/agent_eval/scoring.dart';
import 'package:xingyuan_assistant_eval/agent_eval/source_fingerprint.dart';

import '../tool/agent_eval/app_driver.dart';
import '../tool/agent_eval/run_preparation.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);
  late Directory dir;
  setUp(
    () =>
        dir = Directory.systemTemp.createTempSync('agent-evidence-regression-'),
  );
  tearDown(() => dir.deleteSync(recursive: true));
  final scenarios = parseAgentScenarios(
    File('tool/assistant_eval/fixtures/agent_scenarios.json')
        .readAsStringSync(),
  );

  test(
    'build cleanup cannot reopen a consumed synthetic authorization',
    () async {
      final root = '${dir.path}/checkout';
      for (final path in [
        'lib',
        'server/lib',
        'packages/xingyuan_core/lib',
        'tool/agent_eval',
        'tool/assistant_eval/lib/agent_eval',
        'tool/assistant_eval/bin',
        'tool/assistant_eval/test',
        'test',
      ]) {
        Directory('$root/$path').createSync(recursive: true);
        File('$root/$path/synthetic.dart')
            .writeAsStringSync('// synthetic source');
      }
      File('$root/tool/assistant_eval/lib/agent_eval/scoring.dart')
          .writeAsStringSync('// synthetic scorer fingerprint fixture');
      final marker = File('${dir.path}/marker.json')
        ..writeAsStringSync(
          jsonEncode({
            'id': 'synthetic-a4-regression',
            'scope': 'xingyuan-agent-a4-synthetic',
            'owner_authorized': true,
            'max_calls': 1,
            'expires_at': '2099-01-01T00:00:00Z',
            'endpoint': agentRelay,
            'product_digest': productFingerprint(root),
          }),
        );
      await Process.run('chmod', ['600', marker.path]);
      AgentDriverOptions options(String suffix) => AgentDriverOptions.parse([
        '--live',
        '--authorization',
        marker.path,
        '--config',
        '${dir.path}/absent-synthetic-config',
        '--output',
        '${dir.path}/out-$suffix',
      ]);
      // A missing synthetic config guarantees no credential or network access.
      await expectLater(
        runPreparation(options('one'), root, stateHome: '${dir.path}/home'),
        throwsFormatException,
      );
      final build = Directory('$root/build');
      if (build.existsSync()) build.deleteSync(recursive: true);
      await expectLater(
        runPreparation(options('two'), root, stateHome: '${dir.path}/home'),
        throwsA(isA<FileSystemException>()),
      );
      final otherRoot = '${dir.path}/other-checkout';
      for (final entry in Directory(
        root,
      ).listSync(recursive: true, followLinks: false)) {
        if (entry is File && entry.path.endsWith('.dart')) {
          final target = File(
            '$otherRoot/${entry.path.substring(root.length + 1)}',
          );
          target.parent.createSync(recursive: true);
          entry.copySync(target.path);
        }
      }
      await expectLater(
        runPreparation(
          options('three'),
          otherRoot,
          stateHome: '${dir.path}/home',
        ),
        throwsA(isA<FileSystemException>()),
      );
    },
  );

  test(
    'actual persisted rows, not preview digest, determine write evidence',
    () async {
      final budget = EvaluationBudget.claim('${dir.path}/budget');
      addTearDown(budget.close);
      final scenario = scenarios.singleWhere((s) => s.id == 'S19');
      final driver = AppAgentEvaluationDriver(
        metadata: driverMetadata(Directory.current.path, live: false),
        output: dir,
        budget: budget,
        afterApply: (store, receipt) async {
          // Simulate a persistence bug with the right row count but wrong content.
          final row = await store.proposals.read(receipt);
          final ids = (jsonDecode(row.appliedGoalIdsJson!) as List).cast<int>();
          await store.db.customStatement(
            'UPDATE goal_titles SET title=? WHERE goal_id=?',
            ['synthetic-wrong-title', ids.first],
          );
        },
      );
      final trace = await driver.run(scenario);
      final score = scoreAgentTrace(
        scenario,
        trace,
        evidenceKind: 'app_offline',
      ).json;
      expect((score['checks'] as Map)['write_confirmed'], 'fail');
    },
  );

  test(
    'injected cancellation cannot relabel an observed transport failure',
    () async {
      final budget = EvaluationBudget.claim('${dir.path}/budget');
      addTearDown(budget.close);
      final scenario = scenarios.singleWhere((s) => s.id == 'S15');
      final driver = AppAgentEvaluationDriver(
        metadata: driverMetadata(Directory.current.path, live: false),
        output: dir,
        budget: budget,
        interceptResponse: (pending) async {
          try {
            return await pending;
          } on AssistantFailure {
            throw const AssistantFailure(AssistantFailureKind.network);
          }
        },
      );
      final trace = (await driver.run(scenario))!;
      expect(trace.events.last['reason'], 'upstream');
      expect(
        scoreAgentTrace(
          scenario,
          trace,
          evidenceKind: 'app_offline',
        ).json['status'],
        'fail',
      );
    },
  );

  test(
    'premature formal writes are recorded before accepted confirmation',
    () async {
      final budget = EvaluationBudget.claim('${dir.path}/budget');
      addTearDown(budget.close);
      final scenario = scenarios.singleWhere((s) => s.id == 'S19');
      final driver = AppAgentEvaluationDriver(
        metadata: driverMetadata(Directory.current.path, live: false),
        output: dir,
        budget: budget,
        afterLoop: (store, result) async {
          await store.goals.create(
            GoalDraft(
              title: 'synthetic-early',
              kind: GoalKind.single,
              plannedDay: store.goals.clock.read().day,
              startMinute: 600,
              durationMinutes: 30,
            ),
          );
        },
      );
      final trace = (await driver.run(scenario))!;
      final events = trace.events;
      expect(
        events.indexWhere((e) => e['kind'] == 'write'),
        lessThan(
          events.indexWhere(
            (e) => e['kind'] == 'confirm' && e['accepted'] == true,
          ),
        ),
      );
    },
  );

  test('discarded without a changed lease is not identity evidence', () async {
    final budget = EvaluationBudget.claim('${dir.path}/budget');
    addTearDown(budget.close);
    final scenario = scenarios.singleWhere((s) => s.id == 'S16');
    final driver = AppAgentEvaluationDriver(
      metadata: driverMetadata(Directory.current.path, live: false),
      output: dir,
      budget: budget,
      performBoundary: false,
      interceptResponse: (pending) async {
        await pending;
        throw const AssistantFailure(AssistantFailureKind.discarded);
      },
    );
    final trace = (await driver.run(scenario))!;
    expect(trace.events.last['reason'], isNot('identity'));
    expect(driver.diagnostics['S16']!['observed_failure'], 'discarded');
    expect(
      scoreAgentTrace(
        scenario,
        trace,
        evidenceKind: 'app_offline',
      ).json['status'],
      'fail',
    );
  });

  for (final id in ['S15', 'S16']) {
    test(
      'missed $id boundary reports actual committed answer, not intended stop',
      () async {
        final budget = EvaluationBudget.claim('${dir.path}/budget');
        addTearDown(budget.close);
        final scenario = scenarios.singleWhere((s) => s.id == id);
        final driver = AppAgentEvaluationDriver(
          metadata: driverMetadata(Directory.current.path, live: false),
          output: dir,
          budget: budget,
          performBoundary: false,
        );
        final trace = (await driver.run(scenario))!;
        expect(trace.events.last['status'], 'answer');
        expect(trace.events.last['reason'], 'none');
        expect(
          scoreAgentTrace(
            scenario,
            trace,
            evidenceKind: 'app_offline',
          ).json['status'],
          'fail',
        );
      },
    );
  }
}
