import 'dart:async';

import 'package:habit_checkin/features/companion/data/companion_service.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

const testMemberId = '00000000-0000-4000-8000-000000000001';
const testPartnerId = '00000000-0000-4000-8000-000000000002';
const testGroupId = '00000000-0000-4000-8000-000000000003';
const testInviteId = '00000000-0000-4000-8000-000000000004';

PairingState testPairingState({bool paired = false, bool invited = false}) =>
    PairingState.fromJson({
      'protocol': companionProtocol,
      'member_id': testMemberId,
      'group': paired
          ? {
              'id': testGroupId,
              'partner_id': testPartnerId,
              'paired_at': '2026-10-21T10:00:00.000Z',
            }
          : null,
      'invitation': invited
          ? {
              'id': testInviteId,
              'code': 'ABCDEFGH',
              'expires_at': '2026-10-22T10:00:00.000Z',
            }
          : null,
    });

class TestCompanionService implements CompanionService {
  @override
  bool configured = true;
  PairingState current = testPairingState();
  final commands = <PairingCommand>[];
  int reads = 0;
  Completer<void>? gate;
  Completer<void>? readGate;
  CompanionServiceFailure? failure;
  CompanionServiceFailure? readFailure;

  @override
  Future<PairingState> state({
    required CompanionAccess access,
    CompanionCancellation? cancellation,
  }) async {
    reads++;
    final captured = current;
    await readGate?.future;
    if (!await access.isCurrent()) {
      throw const CompanionServiceFailure('discarded');
    }
    if (readFailure case final value?) throw value;
    return captured;
  }

  @override
  Future<PairingReceipt> execute(
    PairingCommand command, {
    required CompanionAccess access,
    CompanionCancellation? cancellation,
  }) async {
    commands.add(command);
    await gate?.future;
    if (!await access.isCurrent()) {
      throw const CompanionServiceFailure('discarded', outcomeUnknown: true);
    }
    if (failure case final value?) throw value;
    current = switch (command.kind) {
      PairingCommandKind.createInvite => testPairingState(invited: true),
      PairingCommandKind.join => testPairingState(paired: true),
      _ => testPairingState(),
    };
    return PairingReceipt.fromJson({
      'protocol': companionProtocol,
      'operation_id': command.operationId,
      'state': current.toJson(),
    }, operationId: command.operationId);
  }
}
