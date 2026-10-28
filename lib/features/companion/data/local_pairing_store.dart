import 'dart:convert';

import 'package:characters/characters.dart';
import 'package:drift/drift.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

import '../../../data/local/app_database.dart';
import '../../../data/local/local_goal_repository.dart';
import 'companion_service.dart';

class PairingAttempt {
  PairingAttempt(this.row)
    : command = PairingCommand.fromJson(
        PairingCommandKind.values.byName(row.kind),
        jsonDecode(row.requestJson),
      );
  final StoredPairingCommand row;
  final PairingCommand command;
}

class PairingLocalSnapshot {
  PairingLocalSnapshot(this.row, this.command);
  final StoredPairingState row;
  final PairingAttempt? command;
  PairingState? get state => row.stateJson == null
      ? null
      : PairingState.fromJson(jsonDecode(row.stateJson!));
}

class LocalPairingStore {
  LocalPairingStore._(this.goals, this.credentialScope, this.generation);
  final LocalGoalRepository goals;
  final String credentialScope;
  final int generation;
  AppDatabase get db => goals.db;
  String get owner => goals.owner;
  int get _now => goals.clock.read().instant.microsecondsSinceEpoch;

  static Future<void> forgetCredential(
    LocalGoalRepository goals, {
    required bool Function() isCurrent,
  }) => goals.db.transaction(() async {
    await goals.requireActiveIdentity();
    final db = goals.db;
    final old = await (db.select(
      db.pairingStates,
    )..where((row) => row.owner.equals(goals.owner))).getSingleOrNull();
    if (!isCurrent() || old == null) return;
    await db.clearSharingContent(goals.owner);
    await (db.delete(
      db.pairingCommands,
    )..where((row) => row.owner.equals(goals.owner))).go();
    await db
        .into(db.pairingStates)
        .insertOnConflictUpdate(
          old
              .copyWith(
                generation: old.generation + 1,
                stateRevision: old.stateRevision + 1,
                stateJson: const Value(null),
                refreshedAt: const Value(null),
                draftCode: '',
                draftRevision: old.draftRevision + 1,
              )
              .toCompanion(false),
        );
  });

  static Future<LocalPairingStore> open(
    LocalGoalRepository goals, {
    required String credentialScope,
  }) async {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(credentialScope)) {
      throw const FormatException('Credential scope');
    }
    final db = goals.db;
    return db.transaction(() async {
      await goals.requireActiveIdentity();
      final old = await (db.select(
        db.pairingStates,
      )..where((row) => row.owner.equals(goals.owner))).getSingleOrNull();
      final changed = old == null || old.credentialScope != credentialScope;
      final generation = old == null ? 0 : old.generation + (changed ? 1 : 0);
      if (changed) {
        await db.clearSharingContent(goals.owner);
        await (db.delete(
          db.pairingCommands,
        )..where((row) => row.owner.equals(goals.owner))).go();
        await db
            .into(db.pairingStates)
            .insertOnConflictUpdate(
              StoredPairingState(
                owner: goals.owner,
                credentialScope: credentialScope,
                generation: generation,
                stateRevision: 0,
                draftCode: '',
                draftRevision: 0,
              ).toCompanion(false),
            );
      }
      return LocalPairingStore._(goals, credentialScope, generation);
    });
  }

  Future<StoredPairingState> _current() async {
    await goals.requireActiveIdentity();
    final row = await (db.select(
      db.pairingStates,
    )..where((row) => row.owner.equals(owner))).getSingleOrNull();
    if (row == null ||
        row.credentialScope != credentialScope ||
        row.generation != generation) {
      throw const CompanionServiceFailure('discarded');
    }
    return row;
  }

  Future<bool> isCurrent() async {
    try {
      await db.transaction(_current);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<StoredPairingCommand?> _command() => (db.select(
    db.pairingCommands,
  )..where((row) => row.owner.equals(owner))).getSingleOrNull();

  Future<PairingLocalSnapshot> snapshot() => db.transaction(() async {
    final row = await _current();
    final command = await _command();
    return PairingLocalSnapshot(
      row,
      command == null ? null : PairingAttempt(command),
    );
  });

  Future<int> writeDraft(String text, {required int expectedRevision}) =>
      db.transaction(() async {
        final row = await _current();
        if (row.draftRevision != expectedRevision) {
          throw const CompanionServiceFailure('draft_conflict');
        }
        if (text.characters.length > 1024) {
          throw const CompanionServiceFailure('request_too_large');
        }
        final next = row.draftRevision + 1;
        await db
            .into(db.pairingStates)
            .insertOnConflictUpdate(
              row
                  .copyWith(draftCode: text, draftRevision: next)
                  .toCompanion(false),
            );
        return next;
      });

  Future<void> recoverInterrupted() => db.transaction(() async {
    await _current();
    final old = await _command();
    if (old?.status == 'sending') {
      await db
          .into(db.pairingCommands)
          .insertOnConflictUpdate(
            old!
                .copyWith(
                  status: 'uncertain',
                  errorCode: const Value('interrupted'),
                  updatedAt: _now,
                )
                .toCompanion(false),
          );
    }
  });

  Future<PairingAttempt> start(PairingCommand command) =>
      db.transaction(() async {
        final current = await _current();
        final old = await _command();
        if (old != null && old.status != 'failed') {
          throw const CompanionServiceFailure('operation_pending');
        }
        final serialized = jsonEncode(command.toJson());
        if (old?.operationId == command.operationId &&
            (old!.requestJson != serialized || old.kind != command.kind.name)) {
          throw const CompanionServiceFailure('operation_conflict');
        }
        final row = StoredPairingCommand(
          owner: owner,
          operationId: command.operationId,
          generation: generation,
          kind: command.kind.name,
          requestJson: serialized,
          status: 'sending',
          attempts: 1,
          baseStateRevision: current.stateRevision,
          baseDraftRevision: current.draftRevision,
          startedAt: _now,
          updatedAt: _now,
        );
        await db
            .into(db.pairingCommands)
            .insertOnConflictUpdate(row.toCompanion(false));
        return PairingAttempt(row);
      });

  Future<PairingAttempt> retry() => db.transaction(() async {
    final current = await _current();
    final old = await _command();
    if (old == null || old.status == 'sending') {
      throw const CompanionServiceFailure('operation_pending');
    }
    final row = old.copyWith(
      status: 'sending',
      attempts: old.attempts + 1,
      errorCode: const Value(null),
      retryAfter: const Value(null),
      baseStateRevision: current.stateRevision,
      updatedAt: _now,
    );
    await db
        .into(db.pairingCommands)
        .insertOnConflictUpdate(row.toCompanion(false));
    return PairingAttempt(row);
  });

  Future<bool> _matching(PairingAttempt attempt) async {
    final old = await _command();
    return old != null &&
        old.owner == owner &&
        old.generation == generation &&
        attempt.row.owner == owner &&
        attempt.row.generation == generation &&
        old.operationId == attempt.row.operationId &&
        old.requestJson == attempt.row.requestJson &&
        old.kind == attempt.row.kind &&
        old.attempts == attempt.row.attempts &&
        old.status == 'sending';
  }

  void _sameMember(StoredPairingState current, PairingState state) {
    if (current.stateJson != null &&
        PairingState.fromJson(jsonDecode(current.stateJson!)).memberId !=
            state.memberId) {
      throw const CompanionServiceFailure(
        'invalid_response',
        outcomeUnknown: true,
      );
    }
  }

  Future<void> _clearChangedGroup(
    StoredPairingState current,
    PairingState state,
  ) async {
    final old = current.stateJson == null
        ? null
        : PairingState.fromJson(jsonDecode(current.stateJson!));
    if (old?.group?.id != state.group?.id ||
        old?.group?.partnerId != state.group?.partnerId) {
      await db.clearSharingContent(owner);
    }
  }

  Future<bool> finish(PairingAttempt attempt, PairingReceipt receipt) =>
      db.transaction(() async {
        final current = await _current();
        if (!await _matching(attempt)) return false;
        final valid = PairingReceipt.fromJson(
          receipt.toJson(),
          operationId: attempt.command.operationId,
        );
        _sameMember(current, valid.state);
        await (db.delete(
          db.pairingCommands,
        )..where((row) => row.owner.equals(owner))).go();
        if (current.stateRevision != attempt.row.baseStateRevision) {
          return false;
        }
        final clearDraft =
            attempt.command.kind == PairingCommandKind.join &&
            valid.state.group != null &&
            current.draftRevision == attempt.row.baseDraftRevision &&
            current.draftCode == attempt.command.code;
        await _clearChangedGroup(current, valid.state);
        await db
            .into(db.pairingStates)
            .insertOnConflictUpdate(
              current
                  .copyWith(
                    stateJson: Value(jsonEncode(valid.state.toJson())),
                    stateRevision: current.stateRevision + 1,
                    refreshedAt: Value(_now),
                    draftCode: clearDraft ? '' : current.draftCode,
                    draftRevision: current.draftRevision + (clearDraft ? 1 : 0),
                  )
                  .toCompanion(false),
            );
        return true;
      });

  Future<bool> fail(PairingAttempt attempt, CompanionServiceFailure failure) =>
      db.transaction(() async {
        await _current();
        if (!await _matching(attempt)) return false;
        final old = (await _command())!;
        await db
            .into(db.pairingCommands)
            .insertOnConflictUpdate(
              old
                  .copyWith(
                    status: failure.outcomeUnknown ? 'uncertain' : 'failed',
                    errorCode: Value(_safeError(failure.code)),
                    retryAfter: Value(
                      failure.retryAfter == null
                          ? null
                          : _now +
                                failure.retryAfter! *
                                    Duration.microsecondsPerSecond,
                    ),
                    updatedAt: _now,
                  )
                  .toCompanion(false),
            );
        return true;
      });

  Future<bool> acceptState(
    PairingState state, {
    required int expectedRevision,
  }) => db.transaction(() async {
    final current = await _current();
    if (current.stateRevision != expectedRevision) return false;
    _sameMember(current, state);
    await _clearChangedGroup(current, state);
    await db
        .into(db.pairingStates)
        .insertOnConflictUpdate(
          current
              .copyWith(
                stateJson: Value(jsonEncode(state.toJson())),
                stateRevision: current.stateRevision + 1,
                refreshedAt: Value(_now),
              )
              .toCompanion(false),
        );
    return true;
  });

  Future<void> forgetRemote() => db.transaction(() async {
    final current = await _current();
    await db.clearSharingContent(owner);
    await db
        .into(db.pairingStates)
        .insertOnConflictUpdate(
          current
              .copyWith(
                stateJson: const Value(null),
                refreshedAt: const Value(null),
                stateRevision: current.stateRevision + 1,
              )
              .toCompanion(false),
        );
  });
}

String _safeError(String code) =>
    const {
      'unconfigured',
      'not_found',
      'credential',
      'unauthorized',
      'forbidden',
      'pair_gone',
      'invite_invalid',
      'invite_expired',
      'invite_used',
      'invite_cancelled',
      'already_paired',
      'invite_owner_paired',
      'invite_self',
      'invite_rate_limited',
      'device_busy',
      'operation_conflict',
      'discarded',
      'cancelled',
      'timeout',
      'network',
      'unavailable',
      'invalid_response',
      'invalid_request',
      'invalid_content_type',
      'request_too_large',
      'request_read_timeout',
      'request_interrupted',
    }.contains(code)
    ? code
    : 'unavailable';
