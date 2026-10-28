import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:xingyuan_assistant_eval/agent_eval/live_gate.dart';

import '../tool/agent_eval/run_preparation.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);
  test(
    'scripted relay executes real App loop, localhost backend and report',
    () async {
      final base = Directory.systemTemp.createTempSync(
        'agent-app-driver-test-',
      );
      addTearDown(() => base.deleteSync(recursive: true));
      final path = '${base.path}/output';
      final options = AgentDriverOptions.parse([
        '--scripted',
        '--output',
        path,
      ]);
      final report = await runPreparation(options, Directory.current.path);
      expect(report['executed'], 20);
      expect(report['not_run'], 0);
      expect(report['failed'], 0);
      expect(report['incomplete'], 0);
      expect(report['passed'], 20);
      expect(report['product_acceptance'], 'not_run');
      final trace = jsonDecode(
        File('$path/synthetic-traces.json').readAsStringSync(),
      ) as Map;
      final traces = (trace['traces'] as List).cast<Map>();
      Map find(String id) => traces.singleWhere((t) => t['case_id'] == id);
      List<Map> events(String id, String kind) => (find(id)['events'] as List)
          .cast<Map>()
          .where((e) => e['kind'] == kind)
          .toList();
      expect(events('S01', 'model'), hasLength(1));
      expect(events('S01', 'tool'), isEmpty);
      expect(events('S03', 'validation').last['phase'], 'final');
      expect(events('S04', 'validation').map((e) => e['status']), [
        'invalid',
        'ok',
      ]);
      expect(events('S06', 'validation').single['status'], 'partial');
      expect(events('S07', 'validation').single['status'], 'partial');
      expect(events('S08', 'tool').single['executed'], false);
      expect(events('S09', 'tool').single['status'], 'failed');
      expect(events('S13', 'tool').map((e) => e['status']), [
        'ok',
        'duplicate',
        'invalid',
      ]);
      expect(events('S13', 'model'), hasLength(3));
      expect(events('S14', 'model'), hasLength(6));
      for (final id in ['S15', 'S16']) {
        expect(events(id, 'boundary'), hasLength(1));
        expect(events(id, 'preview'), isEmpty);
        expect(events(id, 'write'), isEmpty);
        expect(events(id, 'model'), hasLength(1));
      }
      expect(events('S18', 'validation').last['status'], 'invalid');
      expect(events('S18', 'write'), isEmpty);
      expect(events('S19', 'write').single['count'], 2);
      for (final row in traces) {
        expect(row['protected_before'], row['protected_after']);
      }
      final evidence = jsonDecode(
        File('$path/adapter-evidence.json').readAsStringSync(),
      ) as Map;
      for (final id in ['S15', 'S16']) {
        expect(evidence['cases'][id]['assistant_sent'], 0);
        expect(evidence['cases'][id]['observed_failure'], isNotNull);
      }
      expect(
        evidence['attempts'],
        traces.fold<int>(
          0,
          (n, t) =>
              n +
              (t['events'] as List)
                  .where((e) => e['kind'] == 'model' && e['dispatched'] == true)
                  .length,
        ),
      );
      final safe = File('$path/report.json').readAsStringSync();
      expect(safe, isNot(contains('SYNTHETIC_DIARY')));
      expect(safe, isNot(contains('synthetic-only')));
      await expectLater(
        runPreparation(options, Directory.current.path),
        throwsFormatException,
      );
      final evidencePath = Platform.environment['AGENT_PREPARATION_EVIDENCE'];
      if (evidencePath != null) {
        final dest = Directory(evidencePath);
        expect(dest.existsSync(), false);
        dest.createSync();
        for (final file in [
          'report.json',
          'report.md',
          'adapter-evidence.json',
          'synthetic-traces.json',
          'evaluation.sqlite',
        ]) {
          File('$path/$file').copySync('${dest.path}/$file');
        }
      }
    },
  );
}
