import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/sync/identity_store.dart';
import 'package:habit_checkin/data/sync/local_sync_store.dart';
import 'package:habit_checkin/data/sync/sync_identity.dart';
import 'package:habit_checkin/features/account/identity_coordinator.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:habit_checkin/features/reminders/notification_permissions.dart';
import 'package:habit_checkin/features/reminders/reminder_coordinator.dart';
import 'package:habit_checkin/features/reminders/reminder_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'support/sync_fixtures.dart';
import 'support/test_clock.dart';
import 'support/test_reminder_notifications.dart';
import 'support/ui_harness.dart';

const _transfer = '55555555-5555-4555-8555-555555555555';

void main() {
  setUpAll(tzdata.initializeTimeZones);
  late AppDatabase db;
  late TestClock clock;
  late IdentityStore identities;
  late SerialWork work;
  late TestNotificationPermissions permissions;
  late TestReminderNotifications platform;
  late IdentityCoordinator service;

  IdentityCoordinator coordinator(AppDatabase database) => IdentityCoordinator(
    store: IdentityStore(database),
    clock: clock,
    work: work,
    permissions: permissions,
    notifications: platform,
  );

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    clock = TestClock();
    identities = IdentityStore(db);
    work = SerialWork();
    permissions = TestNotificationPermissions()
      ..access = NotificationAccess.allowed;
    platform = TestReminderNotifications();
    service = coordinator(db);
  });
  tearDown(() => db.close());

  GoalDraft draft({bool reminder = true}) => GoalDraft(
    title: 'TEST identity',
    kind: GoalKind.habit,
    reminderEnabled: reminder,
  );
  LocalGoalRepository repository(IdentityLease lease) => LocalGoalRepository(
    db,
    clock,
    owner: lease.identity.owner,
    identityLease: lease,
  );
  String ownerOf(PendingReminder item) =>
      (jsonDecode(item.payload!) as Map<String, dynamic>)['owner'] as String;

  test(
    'switching without transfer hides guest data and creates zero uploads',
    () async {
      final guest = repository(await identities.active());
      await guest.create(draft());
      await service.resume();
      expect(platform.requests, hasLength(64));
      final result = await service.switchTo(accountA);
      expect(result.remindersNeedRetry, isFalse);
      expect(await repository(result.lease).loadGoals(), isEmpty);
      expect((await db.select(db.goals).get()).single.owner, 'guest');
      expect(await db.select(db.syncOutbox).get(), isEmpty);
      expect(platform.requests, isEmpty);
      await expectLater(guest.create(draft()), throwsA(isA<StaleIdentity>()));
    },
  );

  test(
    'A, B and guest queues, data and reminders remain isolated across switches',
    () async {
      final guestLease = await identities.active();
      await repository(guestLease).create(draft());
      await service.resume();
      final guestIds = platform.requests.keys.toSet();
      final a = (await service.switchTo(accountA)).lease;
      await repository(a).create(draft());
      await service.resume();
      final aIds = platform.requests.keys.toSet();
      expect(aIds.intersection(guestIds), isEmpty);
      final b = (await service.switchTo(accountB)).lease;
      expect(platform.requests, isEmpty);
      expect(await repository(b).loadGoals(), isEmpty);
      await repository(b).create(draft());
      await service.resume();
      expect(
        platform.requests.values.every((r) => ownerOf(r) == accountB.owner),
        isTrue,
      );
      expect(platform.requests.keys.toSet().intersection(aIds), isEmpty);
      await expectLater(
        repository(a).loadGoals(),
        throwsA(isA<StaleIdentity>()),
      );
      final again = (await service.switchTo(accountA)).lease;
      expect((await repository(again).loadGoals()), hasLength(1));
      expect(platform.requests.keys.toSet(), aIds);
      expect(
        platform.requests.values.every((r) => ownerOf(r) == accountA.owner),
        isTrue,
      );
      expect(
        (await db.select(db.syncOutbox).get()).map((r) => r.owner).toSet(),
        {accountA.owner, accountB.owner},
      );
      await service.switchTo(SyncIdentity.guest);
      expect(platform.requests.keys.toSet(), guestIds);
      expect(
        platform.requests.values.every((r) => ownerOf(r) == 'guest'),
        isTrue,
      );
    },
  );

  test('unconfirmed cancellation persists intent and freezes stale commands until retry', () async {
    final guest = repository(await identities.active());
    await guest.create(draft());
    await service.resume();
    platform.ignoreCancel = true;
    await expectLater(service.switchTo(accountA), throwsStateError);
    final state = await identities.read();
    expect(state.owner, 'guest');
    expect(state.targetOwner, accountA.owner);
    expect(state.generation, 1);
    await expectLater(identities.active(), throwsA(isA<StaleIdentity>()));
    await expectLater(guest.create(draft()), throwsA(isA<StaleIdentity>()));
    await expectLater(
      service.switchTo(accountB),
      throwsA(isA<StaleIdentity>()),
    );
    expect(
      platform.requests.values.every((r) => ownerOf(r) == 'guest'),
      isTrue,
    );
    platform.ignoreCancel = false;
    final result = await service.resume();
    expect(result.lease.identity, accountA);
    expect(result.lease.generation, 1);
    expect(platform.requests, isEmpty);
    expect((await identities.read()).targetOwner, isNull);
  });

  test('foreign notifications survive, but untracked own payload blocks activation', () async {
    platform.requests[999] = const PendingReminder(999, 'foreign');
    platform.requests[1000] = PendingReminder(
      1000,
      jsonEncode({
        'source': 'habit-reminder-v1',
        'owner': 'guest',
        'id': 1000,
        'goal': 888,
        'day': '2026-10-09',
      }),
    );
    await expectLater(service.switchTo(accountA), throwsStateError);
    expect(platform.cancelled, isEmpty);
    expect((await identities.read()).owner, 'guest');
    // Remove only the deliberately injected unjournaled test request.
    platform.requests.remove(1000);
    await service.resume();
    expect(platform.requests.keys, [999]);
  });

  test(
    'new scheduling failure does not misreport a committed identity switch',
    () async {
      await LocalGoalRepository(
        db,
        clock,
        owner: accountA.owner,
      ).create(draft());
      platform.dropSchedule = true;
      final result = await service.switchTo(accountA);
      expect(result.lease.identity, accountA);
      expect(result.remindersNeedRetry, isTrue);
      expect((await identities.active()).identity, accountA);
      expect(
        (await repository(result.lease).loadGoals()).single.reminder.status,
        'error',
      );
      platform.dropSchedule = false;
      expect((await service.resume()).remindersNeedRetry, isFalse);
      expect(platform.requests, hasLength(64));
    },
  );

  test(
    'explicit guest transfer moves once with stable IDs and local preferences',
    () async {
      final guest = repository(await identities.active());
      final first = await guest.create(draft());
      final second = await guest.create(draft(reminder: false));
      await guest.setCompleted(second, true, expectedDay: clock.day);
      await guest.archive(second);
      await service.resume();
      final sync = LocalSyncStore(db, clock);
      final before = {
        for (final id in [first, second])
          id: (await sync.readDocument(id, owner: 'guest')).encode(),
      };
      final lease = (await service.switchTo(accountA)).lease;
      expect(await db.select(db.syncOutbox).get(), isEmpty);
      final migrated = await service.importGuest(
        lease: lease,
        transferId: _transfer,
      );
      expect(migrated.remindersNeedRetry, isFalse);
      final goals = await repository(lease).loadGoals();
      expect(goals.map((g) => g.id).toSet(), {first, second});
      expect(goals.first.reminder.enabled, isTrue);
      for (final entry in before.entries) {
        expect(
          (await sync.readDocument(entry.key, owner: accountA.owner)).encode(),
          entry.value,
        );
      }
      expect(
        (await db.select(db.syncOutbox).get()).every(
          (r) => r.kind == 'import_guest',
        ),
        isTrue,
      );
      expect(await db.select(db.syncOutbox).get(), hasLength(2));
      expect(
        platform.requests.values.every((r) => ownerOf(r) == accountA.owner),
        isTrue,
      );
      final freshGuest = await LocalGoalRepository(
        db,
        clock,
      ).create(draft(reminder: false));
      await service.importGuest(lease: lease, transferId: _transfer);
      expect(
        (await (db.select(
          db.goals,
        )..where((r) => r.id.equals(freshGuest))).getSingle()).owner,
        'guest',
      );
      expect(await db.select(db.syncOutbox).get(), hasLength(2));
      final b = (await service.switchTo(accountB)).lease;
      await expectLater(
        service.importGuest(lease: b, transferId: _transfer),
        throwsA(isA<StaleIdentity>()),
      );
      expect(await db.select(db.syncOutbox).get(), hasLength(2));
    },
  );

  test('failed transfer rolls back every owner, operation and transfer marker', () async {
    final guest = LocalGoalRepository(db, clock);
    await guest.create(draft(reminder: false));
    final second = await guest.create(draft(reminder: false));
    final lease = (await service.switchTo(accountA)).lease;
    await db.customStatement(
      "CREATE TRIGGER fail_second_transfer BEFORE INSERT ON sync_outbox "
      "WHEN NEW.goal_id = $second BEGIN SELECT RAISE(ABORT, 'synthetic transfer failure'); END",
    );
    await expectLater(
      service.importGuest(lease: lease, transferId: _transfer),
      throwsException,
    );
    expect(
      (await db.select(db.goals).get()).every((g) => g.owner == 'guest'),
      isTrue,
    );
    expect(
      (await db.select(db.syncStates).get()).every((s) => s.localRevision == 1),
      isTrue,
    );
    expect(await db.select(db.syncOutbox).get(), isEmpty);
    expect(await db.select(db.guestTransfers).get(), isEmpty);
    await db.customStatement('DROP TRIGGER fail_second_transfer');
    await service.importGuest(lease: lease, transferId: _transfer);
    expect(await db.select(db.syncOutbox).get(), hasLength(2));
    expect(await db.select(db.guestTransfers).get(), hasLength(1));
  });

  test(
    'serial work defers identity switch until an earlier command finishes',
    () async {
      final events = <String>[];
      final first = work.run(() async {
        events.add('write');
        await repository(await identities.active())
            .create(draft(reminder: false));
        events.add('saved');
      });
      final second = service
          .switchTo(accountA)
          .then((_) => events.add('switched'));
      await Future.wait([first, second]);
      expect(events, ['write', 'saved', 'switched']);
      expect((await db.select(db.goals).getSingle()).owner, 'guest');
      expect(await db.select(db.syncOutbox).get(), isEmpty);
    },
  );

  test(
    'file reopen resumes a persisted switch before activating the new owner',
    () async {
      await db.close();
      final directory = await Directory.systemTemp.createTemp(
        'identity-switch-',
      );
      final file = File('${directory.path}/test.sqlite');
      final first = AppDatabase(NativeDatabase(file));
      try {
        await LocalGoalRepository(first, clock).create(draft());
        await coordinator(first).resume();
        platform.ignoreCancel = true;
        await expectLater(
          coordinator(first).switchTo(accountA),
          throwsStateError,
        );
      } finally {
        await first.close();
      }
      final reopened = AppDatabase(NativeDatabase(file));
      try {
        final state = await IdentityStore(reopened).read();
        expect(state.owner, 'guest');
        expect(state.targetOwner, accountA.owner);
        platform.ignoreCancel = false;
        final result = await coordinator(reopened).resume();
        expect(result.lease.identity, accountA);
        expect(platform.requests, isEmpty);
        expect(
          (await reopened.select(reopened.goals).getSingle()).owner,
          'guest',
        );
      } finally {
        await reopened.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
