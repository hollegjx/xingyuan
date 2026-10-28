import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:xingyuan_assistant_eval/agent_eval/budget.dart';
import 'package:xingyuan_assistant_eval/agent_eval/live_gate.dart';

import 'support/cli_process.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('agent-budget-test-'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('separate process cannot reopen active or crashed evaluation', () async {
    final path = '${dir.path}/crash.sqlite';
    final child = await Process.start(Platform.resolvedExecutable, [
      'run',
      'test/support/agent_budget_child.dart',
      path,
    ]);
    final errors = child.stderr.drain<void>();
    try {
      expect(
        await child.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first
            .timeout(const Duration(seconds: 15)),
        'reserved',
      );
      final second = await runCli(Platform.resolvedExecutable, [
        'run',
        'test/support/agent_budget_child.dart',
        path,
      ]);
      expect(second.exitCode, 64);
    } finally {
      expect(child.kill(ProcessSignal.sigkill), isTrue);
      expect(await child.exitCode, isNot(0));
      await errors;
    }
    final db = sqlite3.open(path);
    expect(db.select('SELECT count(*) AS n FROM attempts').single['n'], 1);
    expect(db.select('SELECT outcome FROM attempts').single['outcome'], isNull);
    db.close();
    expect(() => EvaluationBudget.claim(path), throwsA(anything));
  });

  test(
    '300 reservations including failures; 301 is refused without refund',
    () {
      final ledger = EvaluationBudget.claim('${dir.path}/quota.sqlite');
      for (var i = 0; i < 300; i++) {
        final id = ledger.reserve('S01', 1, 1000, attempt: i + 1);
        ledger.settle(id, succeeded: i.isEven);
      }
      expect(ledger.used, 300);
      expect(() => ledger.reserve('S02', 1, 1000), throwsStateError);
      expect(() => ledger.reserve('S01', 1, 1000), throwsA(anything));
      ledger.close();
    },
  );
  test('quota exhaustion, pending failure and replay persist after close', () {
    final path = '${dir.path}/quota.sqlite';
    final ledger = EvaluationBudget.claim(path, limit: 2);
    ledger.reserve('S01', 1, 1000);
    ledger.reserve('S02', 1, 1000);
    expect(() => ledger.reserve('S03', 1, 1000), throwsStateError);
    expect(ledger.used, 2);
    ledger.close();
    expect(() => EvaluationBudget.claim(path), throwsA(anything));
    final db = sqlite3.open(path);
    expect(
      db
          .select('SELECT count(*) AS n FROM attempts WHERE outcome IS NULL')
          .single['n'],
      2,
    );
    db.close();
    File(path).deleteSync(); // Synthetic failure injection; claim survives.
    expect(() => EvaluationBudget.claim(path), throwsA(anything));
  });
  test('concurrent claim and duplicate settlements fail closed', () async {
    final path = '${dir.path}/quota.sqlite';
    final ledger = EvaluationBudget.claim(path, limit: 1);
    expect(() => EvaluationBudget.claim(path), throwsA(anything));
    final id = ledger.reserve('S01', 1, 1);
    ledger.settle(id, succeeded: false);
    expect(() => ledger.settle(id, succeeded: true), throwsStateError);
    expect(ledger.used, 1);
    ledger.close();
  });
  for (final quota in [-1, 0, 301]) {
    test('invalid quota $quota rejected', () {
      expect(
        () => EvaluationBudget.claim('${dir.path}/q', limit: quota),
        throwsFormatException,
      );
      expect(dir.listSync(), isEmpty);
    });
  }
  test('explicit modes and live double gate before configuration reads', () {
    for (final args in <List<String>>[
      [],
      ['--output', '/tmp/x'],
      ['--live', '--output', '/tmp/x'],
      ['--live', '--output', '/tmp/x', '--config', '/unread'],
      ['--scripted', '--output', '/tmp/x', '--config', '/unread'],
      ['--scripted', '--output', '/tmp/x', '--output', '/tmp/y'],
    ]) {
      expect(() => AgentDriverOptions.parse(args), throwsFormatException);
    }
    expect(
      AgentDriverOptions.parse(['--scripted', '--output', '/tmp/x']).live,
      false,
    );
    expect(
      () => LivePermit.read(live: false, marker: '/unread', productDigest: 'a'),
      throwsFormatException,
    );
    expect(
      () => LivePermit.read(live: true, marker: null, productDigest: 'a'),
      throwsFormatException,
    );
  });
  test(
    'synthetic marker binds quota, expiry, source and destination',
    () async {
      final file = File('${dir.path}/marker.json')..writeAsStringSync('');
      await Process.run('chmod', ['600', file.path]);
      final valid = {
        'id': 'synthetic-a4-permit',
        'scope': 'xingyuan-agent-a4-synthetic',
        'owner_authorized': true,
        'max_calls': 300,
        'expires_at': '2099-01-01T00:00:00Z',
        'endpoint': agentRelay,
        'product_digest': 'synthetic-source',
      };
      for (final change in [
        {'owner_authorized': false},
        {'max_calls': 301},
        {'max_calls': 0},
        {'expires_at': '2000-01-01T00:00:00Z'},
        {'endpoint': 'https://elsewhere.invalid'},
        {'product_digest': 'changed'},
        {'scope': 'a0'},
        {'extra': true},
      ]) {
        file.writeAsStringSync(jsonEncode({...valid, ...change}));
        expect(
          () => LivePermit.read(
            live: true,
            marker: file.path,
            productDigest: 'synthetic-source',
          ),
          throwsFormatException,
        );
      }
      file.writeAsStringSync(jsonEncode(valid));
      final permit = LivePermit.read(
        live: true,
        marker: file.path,
        productDigest: 'synthetic-source',
      );
      expect(permit.limit, 300);
      final config = File('${dir.path}/synthetic-config.json')
        ..writeAsStringSync(
          jsonEncode({
            'base_url': 'https://elsewhere.invalid/v1',
            'model': 'gpt-6-luna',
            'model_api_key': 'SYNTHETIC-ONLY',
          }),
        );
      await Process.run('chmod', ['600', config.path]);
      await expectLater(permit.loadConfig(config.path), throwsFormatException);
    },
  );
}
