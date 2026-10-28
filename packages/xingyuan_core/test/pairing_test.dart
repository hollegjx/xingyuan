import 'package:test/test.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

void main() {
  const operation = '00000000-0000-4000-8000-000000000001';
  const otherOperation = '00000000-0000-4000-8000-000000000002';
  const memberA = '00000000-0000-4000-8000-000000000011';
  const memberB = '00000000-0000-4000-8000-000000000012';
  const group = '00000000-0000-4000-8000-000000000021';
  const invitation = '00000000-0000-4000-8000-000000000031';
  test(
    'operation identifiers cannot contain credential or free text shapes',
    () {
      expect(
        () => PairingCommand.createInvite('private-message'),
        throwsFormatException,
      );
      expect(
        () => PairingCommand.createInvite('a' * 43),
        throwsFormatException,
      );
      expect(
        () => PairingCommand.createInvite('ABCDEFGH'),
        throwsFormatException,
      );
    },
  );
  test('pair commands roundtrip with no client-selected member identity', () {
    final commands = [
      PairingCommand.createInvite(operation),
      PairingCommand.cancelInvite(operation, invitation),
      PairingCommand.join(operation, 'ABCDEFGH'),
      PairingCommand.leave(operation, group),
    ];
    for (final command in commands) {
      expect(
        PairingCommand.fromJson(command.kind, command.toJson()).toJson(),
        command.toJson(),
      );
      expect(
        () => PairingCommand.fromJson(command.kind, {
          ...command.toJson(),
          'member_id': 'spoofed-member',
        }),
        throwsFormatException,
      );
    }
    expect(() => PairingCommand.createInvite('bad/id'), throwsFormatException);
    expect(
      () => PairingCommand.join(operation, 'x' * 65),
      throwsFormatException,
    );
    expect(
      () => PairingCommand.leave(operation, '../outside'),
      throwsFormatException,
    );
  });

  test('state and receipt strictly validate nullable pairing/invitation', () {
    final body = <String, Object?>{
      'protocol': companionProtocol,
      'member_id': memberA,
      'group': {
        'id': group,
        'partner_id': memberB,
        'paired_at': '2026-10-21T10:00:00.000Z',
      },
      'invitation': null,
    };
    expect(PairingState.fromJson(body).toJson(), body);
    final receipt = {
      'protocol': companionProtocol,
      'operation_id': operation,
      'state': body,
    };
    expect(
      PairingReceipt.fromJson(receipt, operationId: operation).toJson(),
      receipt,
    );
    expect(
      () => PairingReceipt.fromJson(receipt, operationId: otherOperation),
      throwsFormatException,
    );
    expect(
      () => PairingState.fromJson({...body, 'member_id': memberB}),
      throwsFormatException,
    );
    expect(
      () => PairingState.fromJson({...body, 'goals': []}),
      throwsFormatException,
    );
    expect(
      () => PairingState.fromJson({
        ...body,
        'invitation': {
          'id': invitation,
          'code': 'ABCDEFGH',
          'expires_at': '2026-10-22T10:00:00.000Z',
        },
      }),
      throwsFormatException,
    );
  });
}
