import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/sync/identity_store.dart';
import 'package:habit_checkin/data/sync/sync_identity.dart';
import 'package:habit_checkin/features/companion/data/companion_service.dart';
import 'package:habit_checkin/features/companion/data/local_pairing_store.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:uuid/uuid.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

import 'support/test_clock.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);
  late AppDatabase db;
  late LocalGoalRepository goals;
  late LocalPairingStore store;
  late Directory directory;
  const member = '00000000-0000-4000-8000-000000000001';
  const partner = '00000000-0000-4000-8000-000000000002';
  const group = '00000000-0000-4000-8000-000000000003';
  String id() => const Uuid().v4();
  PairingState state({bool paired = false, String memberId = member}) =>
      PairingState.fromJson({
        'protocol': companionProtocol,
        'member_id': memberId,
        'group': paired
            ? {
                'id': group,
                'partner_id': partner,
                'paired_at': '2026-10-21T10:00:00.000Z',
              }
            : null,
        'invitation': null,
      });
  PairingReceipt receipt(
    PairingAttempt attempt, {
    bool paired = false,
    String memberId = member,
  }) => PairingReceipt.fromJson({
    'protocol': companionProtocol,
    'operation_id': attempt.command.operationId,
    'state': state(paired: paired, memberId: memberId).toJson(),
  }, operationId: attempt.command.operationId);
  Future<void> bind() async {
    final lease = await IdentityStore(db).active();
    goals = LocalGoalRepository(
      db,
      TestClock()..setDay(2026, 10, 21),
      owner: lease.identity.owner,
      identityLease: lease,
    );
    store = await LocalPairingStore.open(goals, credentialScope: 'a' * 64);
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('pairing-local-');
    db = AppDatabase(NativeDatabase(File('${directory.path}/test.sqlite')));
    await bind();
  });
  tearDown(() async {
    await db.close();
    await directory.delete(recursive: true);
  });

  test('draft and interrupted operation survive process-like reopen without resending', () async {
    await store.writeDraft('TEST\n😀', expectedRevision: 0);
    final attempt = await store.start(PairingCommand.join(id(), 'ABCDEFGH'));
    await db.close();
    db = AppDatabase(NativeDatabase(File('${directory.path}/test.sqlite')));
    await bind();
    await store.recoverInterrupted();
    final snapshot = await store.snapshot();
    expect(snapshot.row.draftCode, 'TEST\n😀');
    expect(snapshot.command!.command.toJson(), attempt.command.toJson());
    expect(snapshot.command!.row.status, 'uncertain');
    expect(snapshot.command!.row.errorCode, 'interrupted');
    final retry = await store.retry();
    expect(retry.command.operationId, attempt.command.operationId);
    expect(retry.row.attempts, 2);
    expect(await store.finish(retry, receipt(retry, paired: true)), true);
    expect((await store.snapshot()).state!.group!.id, group);
  });

  test(
    'one pending command and late attempts cannot overwrite a retry',
    () async {
      final first = await store.start(PairingCommand.createInvite(id()));
      await expectLater(
        store.start(PairingCommand.createInvite(id())),
        throwsA(isA<CompanionServiceFailure>()),
      );
      await store.fail(
        first,
        const CompanionServiceFailure('timeout', outcomeUnknown: true),
      );
      await expectLater(
        store.start(PairingCommand.createInvite(id())),
        throwsA(isA<CompanionServiceFailure>()),
      );
      final retry = await store.retry();
      expect(await store.finish(first, receipt(first)), false);
      expect(
        await store.fail(
          first,
          const CompanionServiceFailure('network', outcomeUnknown: true),
        ),
        false,
      );
      expect(await store.finish(retry, receipt(retry)), true);
      expect((await store.snapshot()).command, isNull);
      expect(await store.finish(retry, receipt(retry)), false);
    },
  );

  test(
    'confirmed rejection permits a new operation without losing the draft',
    () async {
      await store.writeDraft('WRONG', expectedRevision: 0);
      final first = await store.start(PairingCommand.join(id(), 'WRONG'));
      await store.fail(first, const CompanionServiceFailure('invite_invalid'));
      expect((await store.snapshot()).row.draftCode, 'WRONG');
      final next = await store.start(PairingCommand.join(id(), 'ABCDEFGH'));
      expect(next.command.operationId, isNot(first.command.operationId));
      expect(await store.finish(next, receipt(next, paired: true)), true);
    },
  );

  test(
    'a successful join never erases a newer draft or changes personal data',
    () async {
      final goal = await goals.create(
        const GoalDraft(title: 'TEST personal', kind: GoalKind.habit),
      );
      await store.writeDraft('ABCDEFGH', expectedRevision: 0);
      final attempt = await store.start(PairingCommand.join(id(), 'ABCDEFGH'));
      await store.writeDraft('NEXT-DRAFT', expectedRevision: 1);
      await store.finish(attempt, receipt(attempt, paired: true));
      expect((await store.snapshot()).row.draftCode, 'NEXT-DRAFT');
      final leave = await store.start(PairingCommand.leave(id(), group));
      await store.finish(leave, receipt(leave));
      expect((await store.snapshot()).state!.group, isNull);
      expect((await goals.loadGoals()).single.id, goal);
      expect(await db.select(db.checkIns).get(), isEmpty);
    },
  );

  test('credential changes isolate caches and reject old store after switching back', () async {
    final initial = store;
    await store.acceptState(state(paired: true), expectedRevision: 0);
    await store.writeDraft('private-code', expectedRevision: 0);
    final attempt = await store.start(PairingCommand.leave(id(), group));
    final changed = await LocalPairingStore.open(
      goals,
      credentialScope: 'b' * 64,
    );
    expect((await changed.snapshot()).state, isNull);
    expect((await changed.snapshot()).row.draftCode, isEmpty);
    expect((await changed.snapshot()).command, isNull);
    expect(await initial.isCurrent(), false);
    await expectLater(
      initial.finish(attempt, receipt(attempt)),
      throwsA(isA<CompanionServiceFailure>()),
    );
    final back = await LocalPairingStore.open(goals, credentialScope: 'a' * 64);
    expect((await back.snapshot()).state, isNull);
    expect(await initial.isCurrent(), false);
    expect(await back.isCurrent(), true);
  });

  test(
    'stale refresh/draft and different-member responses cannot overwrite state',
    () async {
      expect(
        await store.acceptState(state(paired: true), expectedRevision: 0),
        true,
      );
      expect(await store.acceptState(state(), expectedRevision: 0), false);
      await store.writeDraft('first', expectedRevision: 0);
      await expectLater(
        store.writeDraft('stale', expectedRevision: 0),
        throwsA(isA<CompanionServiceFailure>()),
      );
      await expectLater(
        store.acceptState(state(memberId: partner), expectedRevision: 1),
        throwsA(isA<CompanionServiceFailure>()),
      );
      final attempt = await store.start(PairingCommand.leave(id(), group));
      expect(
        await store.acceptState(state(paired: true), expectedRevision: 1),
        true,
      );
      expect(await store.finish(attempt, receipt(attempt)), false);
      final snapshot = await store.snapshot();
      expect(snapshot.state!.group!.id, group);
      expect(snapshot.command, isNull);
      expect(snapshot.row.draftCode, 'first');
      await store.forgetRemote();
      expect((await store.snapshot()).state, isNull);
      expect((await store.snapshot()).row.draftCode, 'first');
    },
  );

  test(
    'no plaintext credential is persisted in pairing state or commands',
    () async {
      final token = 'secret-credential-not-stored';
      await expectLater(
        LocalPairingStore.open(goals, credentialScope: token),
        throwsFormatException,
      );
      final attempt = await store.start(PairingCommand.createInvite(id()));
      await store.finish(attempt, receipt(attempt));
      final rows = await db.customSelect('SELECT * FROM pairing_states').get();
      expect(
        jsonEncode(rows.map((row) => row.data).toList()),
        isNot(contains(token)),
      );
    },
  );

  test(
    'identity changes isolate state and invalidate old leases even on return',
    () async {
      await store.writeDraft('guest-draft', expectedRevision: 0);
      await store.acceptState(state(paired: true), expectedRevision: 0);
      final old = store;
      final pending = await old.start(PairingCommand.leave(id(), group));
      final identities = IdentityStore(db);
      final change = await identities.begin(SyncIdentity.account(partner));
      expect(await old.isCurrent(), false);
      await identities.finish(change);
      await bind();
      expect((await store.snapshot()).state, isNull);
      expect((await store.snapshot()).command, isNull);
      expect((await store.snapshot()).row.draftCode, isEmpty);
      await store.writeDraft('account-draft', expectedRevision: 0);
      await expectLater(
        old.finish(pending, receipt(pending)),
        throwsA(isA<StaleIdentity>()),
      );
      await identities.finish(await identities.begin(SyncIdentity.guest));
      await bind();
      expect(await old.isCurrent(), false);
      expect((await store.snapshot()).row.draftCode, 'guest-draft');
      expect((await store.snapshot()).state!.group!.id, group);
      await store.recoverInterrupted();
      expect((await store.snapshot()).command!.row.status, 'uncertain');
      await expectLater(
        old.writeDraft('stale', expectedRevision: 1),
        throwsA(isA<StaleIdentity>()),
      );
    },
  );
}
