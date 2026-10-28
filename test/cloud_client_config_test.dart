import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../tool/check_cloud_config.dart';

void main() {
  Map<String, Object?> valid() => {
    'SUPABASE_URL': 'https://${'a' * 20}.supabase.co',
    'SUPABASE_PUBLISHABLE_KEY': 'sb_publishable_${'x' * 32}',
  };

  test('accepts only the two public hosted-dev settings', () {
    validateCloudClientConfig(jsonEncode(valid()));
    validateCloudClientConfig(
      jsonEncode({...valid(), 'SUPABASE_URL': '${valid()['SUPABASE_URL']}/'}),
    );
  });

  for (final extra in [
    'SUPABASE_SERVICE_ROLE_KEY',
    'SUPABASE_SECRET_KEY',
    'DATABASE_PASSWORD',
    'SMTP_PASSWORD',
    'ACCESS_TOKEN',
    'OTHER',
  ]) {
    test('rejects additional field $extra without echoing it', () {
      expect(
        () => validateCloudClientConfig(
          jsonEncode({...valid(), extra: 'sensitive-test-value'}),
        ),
        throwsA(isA<CloudConfigError>()),
      );
    });
  }

  for (final (index, key) in [
    'sb_secret_${'x' * 32}',
    'legacy-service-role-placeholder',
    'postgres://user:password@host/db',
    'sb_publishable_REPLACE_WITH_YOUR_KEY',
    'sb_publishable_short',
    ' sb_publishable_${'x' * 32}',
    'sb_publishable_${'x' * 32}\n',
    42,
    null,
  ].indexed) {
    test('rejects non-publishable value at index $index', () {
      expect(
        () => validateCloudClientConfig(
          jsonEncode({...valid(), 'SUPABASE_PUBLISHABLE_KEY': key}),
        ),
        throwsA(
          isA<CloudConfigError>().having(
            (e) => e.issue,
            'issue',
            CloudConfigIssue.invalidPublishableKey,
          ),
        ),
      );
    });
  }

  final base = valid()['SUPABASE_URL'] as String;
  for (final (index, url) in [
    base.replaceFirst('https:', 'http:'),
    base.replaceFirst('://', '://user:password@'),
    '$base:443',
    '$base/rest/v1',
    '$base?token=private',
    '$base#private',
    '$base.evil.invalid',
    'https://localhost',
    ' $base',
    42,
  ].indexed) {
    test('rejects unexpected origin at index $index', () {
      expect(
        () => validateCloudClientConfig(
          jsonEncode({...valid(), 'SUPABASE_URL': url}),
        ),
        throwsA(isA<CloudConfigError>()),
      );
    });
  }

  for (final (index, source) in [
    '[]',
    '{}',
    'null',
    '{"private":',
    'sensitive-test-value',
  ].indexed) {
    test('malformed configuration produces sanitized errors: $index', () {
      try {
        validateCloudClientConfig(source);
        fail('Expected rejection');
      } on CloudConfigError catch (error) {
        expect(error.toString(), isNot(contains('sensitive-test-value')));
        expect(error.toString(), isNot(contains('private')));
      }
    });
  }
}
