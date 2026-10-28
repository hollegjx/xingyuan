import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/sync/goal_document.dart';
import 'package:habit_checkin/data/sync/sync_identity.dart';
import 'package:habit_checkin/data/sync/sync_protocol.dart';

import 'support/sync_fixtures.dart';

void main() {
  test(
    'replaying a frozen v1 operation retains its version and original keys',
    () {
      final legacy = syntheticDocumentJson();
      final request = SyncRequest(
        identity: accountA,
        operationId: '44444444-4444-4444-8444-444444444444',
        kind: SyncOperationKind.create,
        baseRevision: 0,
        document: GoalDocument.fromJson(legacy),
      );
      expect(request.toJson()['document'], legacy);
      final current = GoalDocument.fromJson(request.document.toJson());
      final newRequest = SyncRequest(
        identity: accountA,
        operationId: '55555555-5555-4555-8555-555555555555',
        kind: SyncOperationKind.edit,
        baseRevision: 1,
        document: current,
      );
      expect((newRequest.toJson()['document'] as Map)['version'], 2);
    },
  );

  test('v1 is read compatibly and normalized to explicit v2 timing', () {
    final legacy = syntheticDocument();
    expect(legacy.sourceVersion, 1);
    final canonical = legacy.toJson();
    expect(canonical['version'], 2);
    expect((canonical['schedules'] as List).single['start_minute'], isNull);
    expect(GoalDocument.fromJson(canonical).sourceVersion, 2);
    final missing = legacy.toJson();
    (missing['schedules'] as List).single.remove('duration_minutes');
    expect(() => GoalDocument.fromJson(missing), throwsFormatException);
    for (final pair in [
      [-1, 30],
      [1440, null],
      [420, 4],
      [420, 481],
      [1430, 11],
    ]) {
      final invalid = legacy.toJson();
      final row = (invalid['schedules'] as List).single;
      row['start_minute'] = pair[0];
      row['duration_minutes'] = pair[1];
      expect(() => GoalDocument.fromJson(invalid), throwsFormatException);
    }
  });

  test('explicit v2 null clears timing while v1 absence preserves it', () {
    final value = syntheticDocument().toJson();
    final row = (value['schedules'] as List).single;
    row['start_minute'] = 420;
    row['duration_minutes'] = 30;
    final timed = GoalDocument.fromJson(value);
    expect(
      syntheticDocument()
          .retainingHistoryFrom(timed)
          .schedules
          .single
          .startMinute,
      420,
    );
    final explicitClear = GoalDocument.fromJson(syntheticDocument().toJson());
    expect(
      explicitClear.retainingHistoryFrom(timed).schedules.single.startMinute,
      isNull,
    );
    expect(timed.hasSameResult(explicitClear), isFalse);
  });

  test('identity parsing distinguishes guest, verified account IDs and legacy owners', () {
    expect(SyncIdentity.tryParse('guest'), SyncIdentity.guest);
    expect(SyncIdentity.tryParse(accountA.owner), accountA);
    expect(accountA.userId, '11111111-1111-4111-8111-111111111111');
    expect(SyncIdentity.tryParse('user:a'), isNull);
    expect(SyncIdentity.tryParse('legacy-test-owner'), isNull);
    expect(
      () => SyncIdentity.account('email@example.test'),
      throwsFormatException,
    );
  });

  test('document roundtrip is sorted, immutable and retains false history', () {
    final value = syntheticDocumentJson();
    (value['titles'] as List).insert(0, {
      'effective_day': '2026-10-11',
      'title': 'TEST later',
    });
    (value['check_ins'] as List).add(syntheticCheckIn(completed: false));
    final document = GoalDocument.fromJson(value);
    expect(document.titles.first.title, 'TEST first');
    expect(document.checkIns.single.completed, isFalse);
    expect(GoalDocument.decode(document.encode()).encode(), document.encode());
    (value['titles'] as List).clear();
    expect(document.titles, hasLength(2));
    expect(() => document.titles.clear(), throwsUnsupportedError);
    expect(document.toJson().keys, isNot(contains('owner')));
    expect(document.toJson().keys, isNot(contains('reminders')));
  });

  test('allowlist rejects foreign fields at root and in history rows', () {
    for (final key in ['owner_id', 'reminders', 'private_note', 'token']) {
      final value = syntheticDocumentJson()..[key] = 'TEST forbidden';
      expect(() => GoalDocument.fromJson(value), throwsFormatException);
    }
    final nested = syntheticDocumentJson();
    (nested['titles'] as List).first['note'] = 'TEST private';
    expect(() => GoalDocument.fromJson(nested), throwsFormatException);
  });

  test(
    'malformed types, dates, IDs, histories and archive pairs are rejected',
    () {
      final cases = <Map<String, dynamic>>[
        syntheticDocumentJson()..['version'] = 3,
        syntheticDocumentJson()..['kind'] = 0.0,
        syntheticDocumentJson()..['id'] = 'not-a-uuid',
        syntheticDocumentJson()..['created_day'] = '2026-02-30',
        syntheticDocumentJson()..['archived_day'] = '2026-10-11',
        syntheticDocumentJson()..['created_at'] = 9007199254740992,
        syntheticDocumentJson()..['titles'] = [],
        syntheticDocumentJson()
          ..['schedules'] = [
            {'effective_day': '2026-10-09', 'weekdays': 0, 'planned_day': null},
          ],
        syntheticDocumentJson()
          ..['check_ins'] = [syntheticCheckIn(), syntheticCheckIn()],
        syntheticDocumentJson()
          ..['check_ins'] = [
            {...syntheticCheckIn(), 'occurrence_key': 'once'},
          ],
      ];
      for (final value in cases) {
        expect(() => GoalDocument.fromJson(value), throwsFormatException);
      }
    },
  );

  test('decoding errors never echo private document contents', () {
    try {
      GoalDocument.decode('{"secret-note":"TEST do not log"');
      fail('Malformed input must fail');
    } on FormatException catch (error) {
      expect(error.toString(), isNot(contains('secret-note')));
      expect(error.toString(), isNot(contains('TEST do not log')));
      expect(error.source, isNull);
    }
  });

  test(
    'same-day completion ignores device event clock and zone, not real content',
    () {
      final first = syntheticDocumentJson()
        ..['check_ins'] = [syntheticCheckIn()];
      final second = syntheticDocumentJson()
        ..['check_ins'] = [
          syntheticCheckIn(at: 1791522200000000, zone: 'Europe/London'),
        ];
      final a = GoalDocument.fromJson(first);
      expect(a.hasSameResult(GoalDocument.fromJson(second)), isTrue);
      second['check_ins'] = [syntheticCheckIn(completed: false)];
      expect(a.hasSameResult(GoalDocument.fromJson(second)), isFalse);
      expect(
        syntheticDocument().hasSameResult(GoalDocument.fromJson(second)),
        isTrue,
      );
      (second['titles'] as List).first['title'] = 'TEST other title';
      expect(
        syntheticDocument().hasSameResult(GoalDocument.fromJson(second)),
        isFalse,
      );
    },
  );

  test('overdue single actual completion dates are not interchangeable', () {
    final single = syntheticDocumentJson()
      ..['kind'] = 1
      ..['schedules'] = [
        {
          'effective_day': '2026-10-09',
          'weekdays': 0,
          'planned_day': '2026-10-09',
        },
      ]
      ..['check_ins'] = [
        {
          ...syntheticCheckIn(),
          'occurrence_key': 'once',
          'planned_day': '2026-10-09',
        },
      ];
    final original = GoalDocument.fromJson(single);
    single['check_ins'] = [
      {
        ...syntheticCheckIn(day: '2026-10-10'),
        'occurrence_key': 'once',
        'planned_day': '2026-10-09',
      },
    ];
    expect(original.hasSameResult(GoalDocument.fromJson(single)), isFalse);
  });

  test(
    'omitting historical keys does not delete them or mutate immutable origin',
    () {
      final history = syntheticDocumentJson()
        ..['check_ins'] = [syntheticCheckIn()];
      (history['titles'] as List).add({
        'effective_day': '2026-10-10',
        'title': 'TEST historic rename',
      });
      final previous = GoalDocument.fromJson(history);
      final sparse = syntheticDocument().retainingHistoryFrom(previous);
      expect(sparse.titles, hasLength(2));
      expect(sparse.checkIns, hasLength(1));
      final other = GoalDocument.fromJson(
        syntheticDocumentJson(id: '44444444-4444-4444-8444-444444444444'),
      );
      expect(() => other.retainingHistoryFrom(previous), throwsFormatException);
    },
  );
}
