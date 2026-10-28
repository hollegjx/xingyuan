import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/shared/presentation.dart';

void main() {
  group('chatTimeLabel', () {
    final now = DateTime(2026, 10, 23, 16);

    test('today uses a zero-padded clock without a day prefix', () {
      expect(chatTimeLabel(DateTime(2026, 10, 23, 8, 5), now: now), '08:05');
    });

    test('yesterday and the preceding six days use relative calendar days', () {
      expect(
        chatTimeLabel(DateTime(2026, 10, 22, 14, 5), now: now),
        '昨天 14:05',
      );
      for (final (day, weekday) in [
        (21, '三'),
        (20, '二'),
        (19, '一'),
        (18, '日'),
        (17, '六'),
      ]) {
        expect(
          chatTimeLabel(DateTime(2026, 10, day, 14, 5), now: now),
          '周$weekday 14:05',
        );
      }
    });

    test(
      'seven days and older use dates, adding the year only when needed',
      () {
        expect(
          chatTimeLabel(DateTime(2026, 10, 16, 14, 5), now: now),
          '10月16日 14:05',
        );
        expect(
          chatTimeLabel(DateTime(2026, 10, 3, 14, 5), now: now),
          '10月3日 14:05',
        );
        expect(
          chatTimeLabel(DateTime(2025, 10, 3, 14, 5), now: now),
          '2025年10月3日 14:05',
        );
      },
    );

    test('relative days take precedence across a year boundary', () {
      final newYear = DateTime(2026);
      expect(
        chatTimeLabel(DateTime(2025, 12, 31, 21, 40), now: newYear),
        '昨天 21:40',
      );
      expect(
        chatTimeLabel(DateTime(2025, 12, 30, 21, 40), now: newYear),
        '周二 21:40',
      );
      expect(
        chatTimeLabel(DateTime(2025, 12, 25, 21, 40), now: newYear),
        '2025年12月25日 21:40',
      );
    });

    test('calendar days stay correct across DST transitions', () {
      for (final date in [DateTime(2026, 3, 9), DateTime(2026, 11, 2)]) {
        expect(
          chatTimeLabel(
            DateTime(date.year, date.month, date.day - 1, 23, 55),
            now: date,
          ),
          '昨天 23:55',
        );
        expect(
          chatTimeLabel(
            DateTime(date.year, date.month, date.day - 2, 23, 55),
            now: date,
          ),
          '周六 23:55',
        );
      }
    });

    test('UTC inputs are displayed in local time, including the reference', () {
      final local = DateTime(2026, 10, 22, 23, 59);
      expect(
        chatTimeLabel(local.toUtc(), now: DateTime(2026, 10, 23).toUtc()),
        '昨天 23:59',
      );
    });

    test('future dates are explicit, not mislabeled as recent weekdays', () {
      expect(
        chatTimeLabel(DateTime(2026, 10, 24, 14, 5), now: now),
        '10月24日 14:05',
      );
      expect(
        chatTimeLabel(DateTime(2027, 1, 1, 14, 5), now: now),
        '2027年1月1日 14:05',
      );
    });
  });

  group('chatDividerLabel', () {
    final first = DateTime(2026, 10, 23, 14, 5);

    test('the first message always has a divider', () {
      expect(chatDividerLabel(first, null, now: first), '14:05');
    });

    test('same-day gaps below thirty minutes have no divider', () {
      for (final gap in [
        Duration.zero,
        const Duration(minutes: 1),
        const Duration(minutes: 30) - const Duration(microseconds: 1),
      ]) {
        expect(chatDividerLabel(first.add(gap), first, now: first), isNull);
      }
    });

    test('exactly thirty minutes and larger gaps have a divider', () {
      expect(
        chatDividerLabel(
          first.add(const Duration(minutes: 30)),
          first,
          now: first,
        ),
        '14:35',
      );
      expect(
        chatDividerLabel(
          first.add(const Duration(hours: 1)),
          first,
          now: first,
        ),
        '15:05',
      );
    });

    test('a different local day divides even with a one-minute gap', () {
      for (final midnight in [DateTime(2026), DateTime(2026, 10, 23)]) {
        expect(
          chatDividerLabel(
            midnight.toUtc(),
            midnight.subtract(const Duration(minutes: 1)).toUtc(),
            now: midnight.toUtc(),
          ),
          '00:00',
        );
      }
    });

    test('the threshold uses elapsed time across a clock change', () {
      final before = DateTime.utc(2026, 11, 1, 8, 50);
      final after = DateTime.utc(2026, 11, 1, 9, 20);
      expect(
        chatDividerLabel(after, before, now: after),
        chatTimeLabel(after, now: after),
      );
    });
  });

  test(
    'relative labels compare calendar days across DST and year boundaries',
    () {
      for (final date in [DateTime(2026, 3, 9), DateTime(2026, 11, 2)]) {
        expect(
          momentLabel(
            DateTime(date.year, date.month, date.day - 1, 8, 5),
            now: date,
          ),
          '昨天 08:05',
        );
        expect(
          momentLabel(
            DateTime(date.year, date.month, date.day, 8, 5),
            now: date,
          ),
          '今天 08:05',
        );
      }
      expect(
        momentLabel(DateTime(2025, 12, 31, 21, 40), now: DateTime(2026)),
        '昨天 21:40',
      );
      expect(
        momentLabel(DateTime(2025, 12, 30, 21, 40), now: DateTime(2026)),
        '2025年12月30日 21:40',
      );
      expect(
        momentLabel(DateTime(2026, 10, 3, 7, 10), now: DateTime(2026, 10, 22)),
        '10月3日 07:10',
      );
      expect(
        momentLabel(DateTime(2026, 3, 9, 7, 10), now: DateTime(2026, 3, 8)),
        '3月9日 07:10',
      );
    },
  );
}
