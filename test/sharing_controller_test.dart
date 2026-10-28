import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/local/app_database.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/data/sync/identity_store.dart';
import 'package:habit_checkin/features/companion/data/companion_service.dart';
import 'package:habit_checkin/features/companion/data/local_pairing_store.dart';
import 'package:habit_checkin/features/companion/data/local_sharing_store.dart';
import 'package:habit_checkin/features/companion/presentation/sharing_controller.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:xingyuan_core/xingyuan_core.dart';

import 'support/pairing_fixtures.dart';
import 'support/sharing_fixtures.dart';
import 'support/test_clock.dart';

class _FinishDelay extends QueryInterceptor {
  bool armed = false;
  bool failDraft = false;
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    if (failDraft && statement.contains('INSERT INTO "sharing_drafts"')) {
      failDraft = false;
      throw StateError('SYNTHETIC local write failure');
    }
    if (armed &&
        statement.contains('INSERT INTO "sharing_commands"') &&
        args.contains('succeeded')) {
      armed = false;
      entered.complete();
      await release.future;
    }
    return executor.runInsert(statement, args);
  }
}

void main() {
  setUpAll(tzdata.initializeTimeZones);
  late AppDatabase db;
  late LocalSharingStore store;
  late SharingController controller;
  late TestSharingService service;
  late _FinishDelay delay;
  setUp(() async {
    delay = _FinishDelay();
    db = AppDatabase(NativeDatabase.memory().interceptWith(delay));
    final lease = await IdentityStore(db).active();
    final goals = LocalGoalRepository(db, TestClock(), identityLease: lease);
    await goals.create(
      const GoalDraft(title: 'SYNTHETIC personal', kind: GoalKind.habit),
    );
    final pairing = await LocalPairingStore.open(
      goals,
      credentialScope: 'a' * 64,
    );
    await pairing.acceptState(
      testPairingState(paired: true),
      expectedRevision: 0,
    );
    store = await LocalSharingStore.open(pairing);
    service = TestSharingService()
      ..seed((await db.select(db.goals).get()).single.globalId);
    controller = SharingController(store: store, service: service);
    await controller.initialize().timeout(
      const Duration(seconds: 3),
      onTimeout: () => throw StateError('initialize timed out'),
    );
  });
  tearDown(() async {
    controller.dispose();
    await db.close();
  });
  Future<void> open() async {
    await controller.refresh().timeout(
      const Duration(seconds: 3),
      onTimeout: () => throw StateError('refresh timed out'),
    );
    await controller
        .openReplies(testRecordId)
        .timeout(
          const Duration(seconds: 3),
          onTimeout: () => throw StateError('openReplies timed out'),
        );
  }

  Future<void> waitForCommand() async {
    for (var i = 0; i < 200 && service.sharedCommands.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(service.sharedCommands, hasLength(1));
  }

  test(
    'no automatic requests; five sends freeze one payload and retain new input',
    () async {
      expect(service.grantReads, 0);
      await open();
      await controller.editReply(testRecordId, 'SYNTHETIC first');
      service.sharedGate = Completer<void>();
      final sends = List.generate(5, (_) => controller.sendReply(testRecordId));
      await waitForCommand();
      await controller.editReply(testRecordId, 'SYNTHETIC next\n\u{1f44d}');
      service.sharedGate!.complete();
      expect((await Future.wait(sends)).where((ok) => ok), hasLength(1));
      expect(service.sharedReplies.single['text'], 'SYNTHETIC first');
      expect(controller.replyText(testRecordId), 'SYNTHETIC next\n\u{1f44d}');
      expect(
        (await store.draft(testRecordId))!.content,
        controller.replyText(testRecordId),
      );
    },
  );

  test('typing during slow receipt storage is not overwritten or left with stale CAS', () async {
    await open();
    await controller.editReply(testRecordId, 'SYNTHETIC first');
    service.sharedGate = Completer<void>();
    final send = controller.sendReply(testRecordId);
    await waitForCommand();
    delay.armed = true;
    service.sharedGate!.complete();
    await delay.entered.future.timeout(const Duration(seconds: 3));
    final edit = controller.editReply(testRecordId, 'SYNTHETIC next');
    delay.release.complete();
    expect(await send, true);
    await edit;
    expect(controller.replyDraftError(testRecordId), isNull);
    expect(controller.replyDraftSaved(testRecordId), true);
    expect((await store.draft(testRecordId))!.content, 'SYNTHETIC next');
  });

  test('lost reply receipt survives controller recreation and retries same ID once', () async {
    await open();
    await controller.editReply(testRecordId, 'SYNTHETIC reply');
    service.afterCommitFailure = const CompanionServiceFailure(
      'timeout',
      outcomeUnknown: true,
    );
    expect(await controller.sendReply(testRecordId), false);
    expect(await controller.sendReply(testRecordId), false);
    controller.dispose();
    controller = SharingController(store: store, service: service);
    await controller.initialize();
    await controller.openReplies(testRecordId);
    expect(service.sharedCommands, hasLength(1));
    expect(controller.replyText(testRecordId), 'SYNTHETIC reply');
    final pending = controller.pending.single;
    expect(pending.row.status, 'uncertain');
    service.afterCommitFailure = null;
    await Future.wait(List.generate(5, (_) => controller.retry(pending)));
    expect(service.sharedCommands, hasLength(2));
    expect(
      service.sharedCommands.last.toJson(),
      service.sharedCommands.first.toJson(),
    );
    expect(service.sharedReplies, hasLength(1));
    expect(controller.replyText(testRecordId), isEmpty);
    expect(controller.pending, isEmpty);
  });

  test(
    'remove retry must not query replies of the just-removed record',
    () async {
      await open();
      service.afterCommitFailure = const CompanionServiceFailure(
        'network',
        outcomeUnknown: true,
      );
      expect(await controller.remove(testRecordId), false);
      final pending = controller.pending.single;
      service.afterCommitFailure = null;
      expect(await controller.retry(pending), true);
      expect(controller.snapshot!.records, isEmpty);
      expect(controller.error, isNull);
      expect(service.replyReads, 0);
    },
  );

  test(
    'reply refresh also replaces the record body and removed photos',
    () async {
      await open();
      service.sharedRecords[0] = {
        ...service.sharedRecords.single,
        'revision': 2,
        'text': 'SYNTHETIC revised',
      };
      service.revision++;
      await controller.refresh(record: testRecordId);
      expect(controller.snapshot!.records.single.text, 'SYNTHETIC revised');
    },
  );

  test(
    'empty and 301 graphemes stay local; 300 emoji with newline send unchanged',
    () async {
      await open();
      for (final text in ['', ' \n ', '\u{1f44d}' * 301]) {
        await controller.editReply(testRecordId, text);
        expect(await controller.sendReply(testRecordId), false);
        expect((await store.draft(testRecordId))!.content, text);
      }
      expect(service.sharedCommands, isEmpty);
      final text = '${'\u{1f44d}\u{1f3fd}' * 299}\n';
      await controller.editReply(testRecordId, text);
      expect(await controller.sendReply(testRecordId), true);
      expect(service.sharedReplies.single['text'], text);
    },
  );

  test(
    'cancel never accepts late receipt and leaves retryable pending operation',
    () async {
      await open();
      await controller.editReply(testRecordId, 'SYNTHETIC');
      service.sharedGate = Completer<void>();
      final send = controller.sendReply(testRecordId);
      await waitForCommand();
      controller.cancelWaiting();
      service.sharedGate!.complete();
      expect(await send, false);
      expect(controller.pending.single.row.status, 'uncertain');
      expect(controller.replyText(testRecordId), 'SYNTHETIC');
      expect(controller.canRetry(controller.pending.single), true);
    },
  );

  test('revocation and simultaneous unpair erase remote cache but retain personal goal', () async {
    await open();
    await controller.editReply(testRecordId, 'SYNTHETIC');
    service.sharedGate = Completer<void>();
    final send = controller.sendReply(testRecordId);
    await waitForCommand();
    await store.pairing.forgetRemote();
    service.sharedGate!.complete();
    expect(await send, false);
    expect(controller.invalidated, true);
    expect(controller.snapshot, isNull);
    expect(controller.replyText(testRecordId), isEmpty);
    expect(await db.select(db.sharedRecordsCache).get(), isEmpty);
    expect(await db.select(db.sharingCommands).get(), isEmpty);
    expect(await db.select(db.goals).get(), hasLength(1));
  });

  test('unauthorized refresh clears scope and inaccessible record clears its draft', () async {
    await open();
    await controller.editReply(testRecordId, 'SYNTHETIC');
    service.sharedRecords.clear();
    await controller.refresh(record: testRecordId);
    expect(controller.snapshot!.records, isEmpty);
    expect(controller.replyText(testRecordId), isEmpty);
    service.sharedReadFailure = const CompanionServiceFailure('unauthorized');
    await controller.refresh();
    expect(controller.invalidated, true);
    expect(await db.select(db.sharingStates).get(), isEmpty);
    expect(await db.select(db.goals).get(), hasLength(1));
  });

  test(
    'snapshot changes restart at most once and never accept a partial page',
    () async {
      await open();
      service.pageSize = 1;
      service.sharedRecords.add(
        syntheticSharedRecord(id: sharingId(9), sequence: 2),
      );
      service.revision++;
      var changed = false;
      service.beforeRead = (kind, request) async {
        if (kind == 'feed' && request.beforeSequence != null && !changed) {
          service.revision++;
          changed = true;
        }
      };
      await controller.refresh();
      expect(controller.snapshot!.records, hasLength(2));
      expect(controller.error, isNull);
      final savedRevision = controller.snapshot!.state.cacheRevision;
      final before = service.grantReads;
      service.beforeRead = (kind, request) async {
        if (kind == 'feed') service.revision++;
      };
      await controller.refresh();
      expect(service.grantReads - before, 2);
      expect(controller.snapshot!.state.cacheRevision, savedRevision);
      expect(controller.error, isNotNull);
    },
  );

  test(
    'dispose revokes retained screen access and erases controller content',
    () async {
      await open();
      await controller.editReply(testRecordId, 'SYNTHETIC');
      final old = controller;
      var invalidated = false;
      old.addListener(() {
        invalidated = old.invalidated;
      });
      old.dispose();
      controller = SharingController(store: store, service: service);
      await controller.initialize();
      expect(invalidated, true);
      expect(old.invalidated, true);
      expect(old.snapshot, isNull);
      expect(old.replyText(testRecordId), isEmpty);
    },
  );

  test(
    'failed draft write blocks sending, preserves input and can be saved again',
    () async {
      await open();
      delay.failDraft = true;
      await controller.editReply(testRecordId, 'SYNTHETIC unsaved');
      expect(controller.replyDraftSaved(testRecordId), false);
      expect(await controller.sendReply(testRecordId), false);
      expect(service.sharedCommands, isEmpty);
      expect(controller.replyText(testRecordId), 'SYNTHETIC unsaved');
      await controller.editReply(
        testRecordId,
        controller.replyText(testRecordId),
      );
      expect(controller.replyDraftSaved(testRecordId), true);
      expect(await controller.sendReply(testRecordId), true);
    },
  );

  test(
    'definitive failure can be discarded without deleting the draft',
    () async {
      await open();
      await controller.editReply(testRecordId, 'SYNTHETIC failed');
      service.sharedFailure = const CompanionServiceFailure('invalid_request');
      expect(await controller.sendReply(testRecordId), false);
      final failed = controller.pending.single;
      expect(failed.row.status, 'failed');
      expect(controller.canRetry(failed), false);
      await controller.discardFailed(failed);
      expect(controller.pending, isEmpty);
      expect((await store.draft(testRecordId))!.content, 'SYNTHETIC failed');
      expect(service.sharedCommands, hasLength(1));
    },
  );

  test(
    'confirmed publication cancellation never resends the old command',
    () async {
      await controller.refresh();
      final queued = await store.enqueue(
        SharingCommand.fromJson(SharingCommandKind.publish, {
          'protocol': companionProtocol,
          'group_id': store.groupId,
          'operation_id': sharingId(80),
          'grant_id': testGrantId,
          'source_id': sharingId(81),
          'base_revision': 0,
          'title': 'SYNTHETIC cancelled goal',
          'occurred_at': sharingInstant,
          'completed_at': null,
          'share_details': true,
          'text': 'SYNTHETIC cancelled text',
          'photo_ids': <String>[],
        }),
      );
      service.sharedFailure = const CompanionServiceFailure(
        'publication_cancelled',
      );
      expect(await controller.retry(queued), false);
      final cancelled = controller.pending.single;
      expect(controller.canRetry(cancelled), false);
      expect(cancelled.row.errorCode, 'publication_cancelled');
      for (var i = 0; i < 5; i++) {
        expect(await controller.retry(cancelled), false);
      }
      expect(service.sharedCommands, hasLength(1));
      expect(controller.pending.single.row.attempts, 1);
      expect(controller.error, contains('已取消'));
    },
  );

  test(
    'five stop taps clear only shared content and cannot restore old grant',
    () async {
      await open();
      await controller.editReply(testRecordId, 'SYNTHETIC shared draft');
      service.sharedGate = Completer<void>();
      final stops = List.generate(5, (_) => controller.stop(testGrantId));
      await waitForCommand();
      service.sharedGate!.complete();
      expect((await Future.wait(stops)).where((ok) => ok), hasLength(1));
      expect(controller.snapshot!.grants, isEmpty);
      expect(controller.snapshot!.records, isEmpty);
      expect(await db.select(db.sharingDrafts).get(), isEmpty);
      expect(await db.select(db.goals).get(), hasLength(1));
      expect(await controller.stop(testGrantId), false);
      expect(service.sharedCommands, hasLength(1));
    },
  );

  test('a delayed photo is rejected after record withdrawal', () async {
    service.sharedRecords[0] = syntheticSharedRecord(photos: [sharingId(20)]);
    await open();
    service.photoGate = Completer<void>();
    final download = controller.downloadPhoto(
      testRecordId,
      sharingId(20),
      service,
      cancellation: CompanionCancellation(),
    );
    final rejected = expectLater(
      download,
      throwsA(
        isA<CompanionServiceFailure>().having(
          (e) => e.code,
          'code',
          'discarded',
        ),
      ),
    );
    service.sharedRecords.clear();
    service.revision++;
    await controller.refresh();
    service.photoGate!.complete();
    await rejected;
  });

  test(
    'acknowledged send is distinguished from a failed refresh and never resent',
    () async {
      await open();
      await controller.editReply(testRecordId, 'SYNTHETIC delivered');
      service.beforeRead = (_, _) async {
        throw const CompanionServiceFailure('network');
      };
      expect(await controller.sendReply(testRecordId), true);
      expect(controller.pending, isEmpty);
      expect(controller.replyText(testRecordId), isEmpty);
      expect(controller.error, startsWith('操作已完成，'));
      service.beforeRead = null;
      await controller.refresh(record: testRecordId);
      expect(
        controller.replies[testRecordId]!.single.text,
        'SYNTHETIC delivered',
      );
      expect(service.sharedCommands, hasLength(1));
    },
  );
}
