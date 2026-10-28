import 'package:flutter_test/flutter_test.dart';

import '../tool/check_public_release.dart';

void main() {
  test('private paths are rejected even when explicitly staged', () {
    for (final path in [
      '.ai-bus/status.md',
      '.claude/settings.json',
      '.stversions/old.txt',
      'private/devices.json',
      'config/assistant.local.json',
      'server/.env.production',
      'backup.sqlite-wal',
      'signing.p12',
      'GOAL-agent.md',
    ]) {
      expect(privatePathReason(path), isNotNull, reason: path);
    }
  });

  test('source, schemas and placeholder examples remain permitted', () {
    for (final path in [
      'lib/main.dart',
      'config/assistant-client.example.json',
      '.env.example',
      'drift_schemas/app_database/drift_schema_v13.json',
      'server/test/fixtures/companion_schema_v1.sql',
      'README.md',
    ]) {
      expect(privatePathReason(path), isNull, reason: path);
    }
  });

  test(
    'private text rules detect identifiers without returning their values',
    () {
      final home = '/${'Users'}/${'synthetic-user'}/repo';
      final team = 'DEVELOPMENT_TEAM = ${'SYNTH12345'};';
      expect(privateTextReasons(home), ['personal absolute home path']);
      expect(privateTextReasons(team), ['Apple development-team identifier']);
      expect(privateTextReasons('https://assistant.example.invalid'), isEmpty);
      expect(privateTextReasons('DEVELOPMENT_TEAM = "";'), isEmpty);
    },
  );
}
