import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'package:xingyuan_core/xingyuan_core.dart';
import 'package:xingyuan_server/src/companion_store.dart';

void main() {
  late Directory directory;
  late CompanionStore store;
  late DateTime now;
  String id() => const Uuid().v4();
  PairingCommand create([String? operation]) =>
      PairingCommand.createInvite(operation ?? id());
  PairingCommand join(String code, [String? operation]) =>
      PairingCommand.join(operation ?? id(), code);
  PairingCommand leave(String group, [String? operation]) =>
      PairingCommand.leave(operation ?? id(), group);
  PairingReceipt apply(String device, PairingCommand command) =>
      store.execute(device, command);
  Matcher failure(String code) =>
      isA<CompanionFailure>().having((error) => error.code, 'code', code);

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('companion-store-');
    now = DateTime.utc(2026, 10, 21, 10);
    store = CompanionStore.open('${directory.path}/data.db', now: () => now);
  });
  tearDown(() async {
    store.close();
    await directory.delete(recursive: true);
  });

  test('stable members, private state and restart persistence', () {
    final a = store.state('qa-a');
    expect(a.group, isNull);
    expect(a.invitation, isNull);
    final invite = apply('qa-a', create()).state.invitation!;
    final pair = apply('qa-b', join(invite.code)).state.group!;
    expect(store.state('qa-a').group!.partnerId, store.state('qa-b').memberId);
    expect(store.state('qa-a').memberId, a.memberId);
    expect(store.state('qa-c').group, isNull);
    store.close();
    store = CompanionStore.open('${directory.path}/data.db', now: () => now);
    expect(store.state('qa-a').memberId, a.memberId);
    expect(store.state('qa-a').group!.id, pair.id);
    expect(store.state('qa-b').group!.id, pair.id);
    expect(store.state('qa-b').invitation, isNull);
  });

  test('create/cancel/join/leave are durable and payload-bound idempotent', () {
    final command = create();
    final first = apply('qa-a', command);
    final invite = first.state.invitation!;
    expect(apply('qa-a', command).state.invitation!.code, invite.code);
    expect(apply('qa-a', create()).state.invitation!.id, invite.id);
    expect(
      () => apply('qa-a', join(invite.code, command.operationId)),
      throwsA(failure('operation_conflict')),
    );
    final joinCommand = join(invite.code);
    final pair = apply('qa-b', joinCommand).state.group!;
    expect(apply('qa-b', joinCommand).state.group!.id, pair.id);
    final leaveCommand = leave(pair.id);
    expect(apply('qa-a', leaveCommand).state.group, isNull);
    expect(apply('qa-a', leaveCommand).state.group, isNull);
    expect(apply('qa-b', leave(pair.id)).state.group, isNull);
    expect(() => apply('qa-b', joinCommand), throwsA(failure('pair_gone')));
    expect(() => apply('qa-a', command), throwsA(failure('invite_used')));
    final next = apply('qa-a', create()).state.invitation!;
    final cancel = PairingCommand.cancelInvite(id(), next.id);
    expect(apply('qa-a', cancel).state.invitation, isNull);
    expect(apply('qa-a', cancel).state.invitation, isNull);
    expect(
      () => apply('qa-b', join(next.code)),
      throwsA(failure('invite_cancelled')),
    );
  });

  test('codes are eight unambiguous characters and expire at exactly 24h', () {
    final command = create();
    final invite = apply('qa-a', command).state.invitation!;
    expect(
      invite.code,
      matches(RegExp(r'^[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{8}$')),
    );
    expect(invite.expiresAt, now.add(const Duration(hours: 24)));
    expect(
      () => apply('qa-a', join(invite.code)),
      throwsA(failure('invite_self')),
    );
    now = invite.expiresAt;
    expect(store.state('qa-a').invitation, isNull);
    expect(
      () => apply('qa-b', join(invite.code)),
      throwsA(failure('invite_expired')),
    );
    expect(() => apply('qa-a', command), throwsA(failure('invite_expired')));
    expect(apply('qa-a', create()).state.invitation!.id, isNot(invite.id));
  });

  test('five wrong attempts throttle for ten minutes across restarts', () {
    final retry = join('WRONG');
    expect(() => apply('qa-b', retry), throwsA(failure('invite_invalid')));
    for (var i = 0; i < 8; i++) {
      expect(() => apply('qa-b', retry), throwsA(failure('invite_invalid')));
    }
    for (var i = 0; i < 3; i++) {
      expect(
        () => apply('qa-b', join('22222222')),
        throwsA(failure('invite_invalid')),
      );
    }
    expect(
      () => apply('qa-b', join('WRONG')),
      throwsA(failure('invite_rate_limited')),
    );
    store.close();
    store = CompanionStore.open('${directory.path}/data.db', now: () => now);
    final invite = apply('qa-a', create()).state.invitation!;
    expect(
      () => apply('qa-b', join(invite.code)),
      throwsA(failure('invite_rate_limited')),
    );
    expect(store.state('qa-a').group, isNull);
    now = now.add(const Duration(minutes: 10));
    expect(apply('qa-b', join(invite.code)).state.group, isNotNull);
  });

  test('only two members and one pair; used invite cannot add a third', () {
    final invite = apply('qa-a', create()).state.invitation!;
    final bInvite = apply('qa-b', create()).state.invitation!;
    final group = apply('qa-b', join(invite.code)).state.group!;
    expect(store.state('qa-b').invitation, isNull);
    expect(
      () => apply('qa-c', join(invite.code)),
      throwsA(failure('invite_used')),
    );
    expect(
      () => apply('qa-c', join(bInvite.code)),
      throwsA(failure('invite_cancelled')),
    );
    expect(() => apply('qa-a', create()), throwsA(failure('already_paired')));
    final cInvite = apply('qa-c', create()).state.invitation!;
    expect(
      () => apply('qa-b', join(cInvite.code)),
      throwsA(failure('already_paired')),
    );
    expect(() => apply('qa-c', leave(group.id)), throwsA(failure('forbidden')));
    expect(
      () => apply('qa-c', PairingCommand.cancelInvite(id(), invite.id)),
      throwsA(failure('forbidden')),
    );
    expect(store.state('qa-a').group!.id, group.id);
  });

  test('old leave retries cannot remove a new pair', () {
    final invite = apply('qa-a', create()).state.invitation!;
    final group = apply('qa-b', join(invite.code)).state.group!;
    final oldLeave = leave(group.id);
    apply('qa-a', oldLeave);
    final next = apply('qa-a', create()).state.invitation!;
    final current = apply('qa-c', join(next.code)).state.group!;
    expect(apply('qa-a', oldLeave).state.group!.id, current.id);
    expect(apply('qa-b', leave(group.id)).state.group, isNull);
    expect(store.state('qa-c').group!.id, current.id);
  });

  test(
    'separate SQLite connections serialize simultaneous joins and leaves',
    () async {
      final other = CompanionStore.open(
        '${directory.path}/data.db',
        now: () => now,
      );
      try {
        final invite = apply('qa-a', create()).state.invitation!;
        final results = await Future.wait([
          Future(() => apply('qa-b', join(invite.code))),
          Future(() {
            try {
              return other.execute('qa-c', join(invite.code));
            } on CompanionFailure catch (error) {
              expect(error.code, 'invite_used');
              return null;
            }
          }),
        ]);
        expect(results.whereType<PairingReceipt>().length, 1);
        final group = store.state('qa-a').group!;
        await Future.wait([
          Future(() => apply('qa-a', leave(group.id))),
          Future(() => other.execute('qa-b', leave(group.id))),
        ]);
        expect(other.state('qa-b').group, isNull);
        expect(store.state('qa-a').group, isNull);
      } finally {
        other.close();
      }
    },
  );

  test(
    'online backup restores to a fresh path without changing source',
    () async {
      final invite = apply('qa-a', create()).state.invitation!;
      final group = apply('qa-b', join(invite.code)).state.group!;
      final target = '${directory.path}/restored.db';
      await store.backupTo(target);
      final restored = CompanionStore.open(target, now: () => now);
      try {
        expect(restored.state('qa-a').group!.id, group.id);
        expect(restored.state('qa-b').memberId, store.state('qa-b').memberId);
        expect(
          () => store.backupTo(target),
          throwsA(isA<FileSystemException>()),
        );
      } finally {
        restored.close();
      }
    },
  );

  test('unknown schema or unrelated file is rejected without mutation', () {
    final filename = '${directory.path}/future.db';
    final future = sqlite3.open(filename);
    future.execute('CREATE TABLE owner_data (value TEXT)');
    future.execute("INSERT INTO owner_data VALUES ('preserve')");
    future.userVersion = 99;
    future.close();
    expect(
      () => CompanionStore.open(filename),
      throwsA(isA<FormatException>()),
    );
    final check = sqlite3.open(filename);
    expect(check.userVersion, 99);
    expect(
      check.select('SELECT value FROM owner_data').single['value'],
      'preserve',
    );
    check.close();
  });

  test('unrelated version one database is rejected before any write', () {
    final filename = '${directory.path}/unrelated.db';
    final unrelated = sqlite3.open(filename);
    unrelated.execute('CREATE TABLE private_data (value TEXT)');
    unrelated.execute("INSERT INTO private_data VALUES ('keep-exactly')");
    unrelated.userVersion = 1;
    unrelated.close();
    final before = File(filename).readAsBytesSync();
    expect(
      () => CompanionStore.open(filename),
      throwsA(isA<FormatException>()),
    );
    expect(File(filename).readAsBytesSync(), before);
  });
}
