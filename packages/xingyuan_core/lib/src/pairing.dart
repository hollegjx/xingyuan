part of 'protocol.dart';

const companionProtocol = 'xingyuan.companion.v1';
const invitationAlphabet = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';

enum PairingCommandKind { createInvite, cancelInvite, join, leave }

const pairingStateRoute = '/v1/companion/state';
const pairingCommandRoutes = {
  '/v1/companion/invites/create': PairingCommandKind.createInvite,
  '/v1/companion/invites/cancel': PairingCommandKind.cancelInvite,
  '/v1/companion/join': PairingCommandKind.join,
  '/v1/companion/leave': PairingCommandKind.leave,
};

void _checkCompanionProtocol(Object? value) {
  if (value != companionProtocol) _invalid('companion protocol');
}

String _companionId(Object? value) {
  final result = _id(value);
  if (!RegExp(
    r'^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$',
  ).hasMatch(result)) {
    _invalid('companion id');
  }
  return result;
}

DateTime _companionInstant(Object? value) {
  final text = _text(value, 32);
  final result = DateTime.tryParse(text);
  if (result == null || !result.isUtc || result.toIso8601String() != text) {
    _invalid('companion instant');
  }
  return result;
}

class PairingCommand {
  PairingCommand._(
    this.kind,
    this.operationId,
    this.invitationId,
    this.code,
    this.groupId,
  );

  factory PairingCommand.createInvite(String operationId) =>
      PairingCommand.fromJson(PairingCommandKind.createInvite, {
        'protocol': companionProtocol,
        'operation_id': operationId,
      });
  factory PairingCommand.cancelInvite(
    String operationId,
    String invitationId,
  ) => PairingCommand.fromJson(PairingCommandKind.cancelInvite, {
    'protocol': companionProtocol,
    'operation_id': operationId,
    'invitation_id': invitationId,
  });
  factory PairingCommand.join(String operationId, String code) =>
      PairingCommand.fromJson(PairingCommandKind.join, {
        'protocol': companionProtocol,
        'operation_id': operationId,
        'code': code,
      });
  factory PairingCommand.leave(String operationId, String groupId) =>
      PairingCommand.fromJson(PairingCommandKind.leave, {
        'protocol': companionProtocol,
        'operation_id': operationId,
        'group_id': groupId,
      });

  factory PairingCommand.fromJson(PairingCommandKind kind, Object? value) {
    _bodySize(value);
    final map = _object(value, {
      'protocol',
      'operation_id',
      if (kind == PairingCommandKind.cancelInvite) 'invitation_id',
      if (kind == PairingCommandKind.join) 'code',
      if (kind == PairingCommandKind.leave) 'group_id',
    });
    _checkCompanionProtocol(map['protocol']);
    return PairingCommand._(
      kind,
      _companionId(map['operation_id']),
      kind == PairingCommandKind.cancelInvite
          ? _companionId(map['invitation_id'])
          : null,
      kind == PairingCommandKind.join ? _text(map['code'], 64) : null,
      kind == PairingCommandKind.leave ? _companionId(map['group_id']) : null,
    );
  }

  final PairingCommandKind kind;
  final String operationId;
  final String? invitationId;
  final String? code;
  final String? groupId;

  Map<String, Object?> toJson() => {
    'protocol': companionProtocol,
    'operation_id': operationId,
    if (invitationId != null) 'invitation_id': invitationId,
    if (code != null) 'code': code,
    if (groupId != null) 'group_id': groupId,
  };
}

class PairingInvitation {
  PairingInvitation._(this.id, this.code, this.expiresAt);
  factory PairingInvitation.fromJson(Object? value) {
    final map = _object(value, {'id', 'code', 'expires_at'});
    final code = _text(map['code'], 8);
    if (!RegExp('^[$invitationAlphabet]{8}\$').hasMatch(code)) {
      _invalid('invitation code');
    }
    return PairingInvitation._(
      _companionId(map['id']),
      code,
      _companionInstant(map['expires_at']),
    );
  }
  final String id;
  final String code;
  final DateTime expiresAt;
  Map<String, Object?> toJson() => {
    'id': id,
    'code': code,
    'expires_at': expiresAt.toIso8601String(),
  };
}

class PairingGroup {
  PairingGroup._(this.id, this.partnerId, this.pairedAt);
  factory PairingGroup.fromJson(Object? value) {
    final map = _object(value, {'id', 'partner_id', 'paired_at'});
    return PairingGroup._(
      _companionId(map['id']),
      _companionId(map['partner_id']),
      _companionInstant(map['paired_at']),
    );
  }
  final String id;
  final String partnerId;
  final DateTime pairedAt;
  Map<String, Object?> toJson() => {
    'id': id,
    'partner_id': partnerId,
    'paired_at': pairedAt.toIso8601String(),
  };
}

class PairingState {
  PairingState._(this.memberId, this.group, this.invitation);
  factory PairingState.fromJson(Object? value) {
    _bodySize(value);
    final map = _object(value, {
      'protocol',
      'member_id',
      'group',
      'invitation',
    });
    _checkCompanionProtocol(map['protocol']);
    final memberId = _companionId(map['member_id']);
    final group = map['group'] == null
        ? null
        : PairingGroup.fromJson(map['group']);
    final invitation = map['invitation'] == null
        ? null
        : PairingInvitation.fromJson(map['invitation']);
    if ((group != null && invitation != null) || group?.partnerId == memberId) {
      _invalid('pairing state');
    }
    return PairingState._(memberId, group, invitation);
  }
  final String memberId;
  final PairingGroup? group;
  final PairingInvitation? invitation;
  Map<String, Object?> toJson() => {
    'protocol': companionProtocol,
    'member_id': memberId,
    'group': group?.toJson(),
    'invitation': invitation?.toJson(),
  };
}

class PairingReceipt {
  PairingReceipt._(this.operationId, this.state);
  factory PairingReceipt.fromJson(
    Object? value, {
    required String operationId,
  }) {
    final map = _object(value, {'protocol', 'operation_id', 'state'});
    _checkCompanionProtocol(map['protocol']);
    if (_companionId(map['operation_id']) != operationId) {
      _invalid('operation id');
    }
    return PairingReceipt._(operationId, PairingState.fromJson(map['state']));
  }
  final String operationId;
  final PairingState state;
  Map<String, Object?> toJson() => {
    'protocol': companionProtocol,
    'operation_id': operationId,
    'state': state.toJson(),
  };
}
