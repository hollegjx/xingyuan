part of 'protocol.dart';

const publicationResolveRoute = '/v1/companion/records/resolve';
const publicationRejectionCodes = {
  'publication_cancelled',
  'sharing_unavailable',
  'history_not_shareable',
  'revision_conflict',
  'photo_unavailable',
  'operation_conflict',
};

/// Resolves a prior publication without retransmitting its private payload.
/// An absent operation is permanently rejected under its original fingerprint.
class PublicationResolveRequest {
  PublicationResolveRequest._(this.groupId, this.operationId, this.fingerprint);
  factory PublicationResolveRequest.fromJson(Object? value) {
    _bodySize(value);
    final map = _object(value, {
      'protocol',
      'group_id',
      'operation_id',
      'fingerprint',
    });
    _checkCompanionProtocol(map['protocol']);
    final fingerprint = _text(map['fingerprint'], 64);
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(fingerprint)) {
      _invalid('publication fingerprint');
    }
    return PublicationResolveRequest._(
      _companionId(map['group_id']),
      _companionId(map['operation_id']),
      fingerprint,
    );
  }
  final String groupId;
  final String operationId;
  final String fingerprint;
  Map<String, Object?> toJson() => {
    'protocol': companionProtocol,
    'group_id': groupId,
    'operation_id': operationId,
    'fingerprint': fingerprint,
  };
}

class PublicationResolution {
  PublicationResolution._(this.request, this.receipt, this.errorCode);
  factory PublicationResolution.fromJson(
    Object? value, {
    required PublicationResolveRequest request,
  }) {
    _bodySize(value);
    final map = _object(value, {
      'protocol',
      'group_id',
      'operation_id',
      'fingerprint',
      'receipt',
      'error_code',
    });
    _checkCompanionProtocol(map['protocol']);
    if (map['group_id'] != request.groupId ||
        map['operation_id'] != request.operationId ||
        map['fingerprint'] != request.fingerprint) {
      _invalid('publication resolution identity');
    }
    SharingReceipt? receipt;
    String? error;
    if (map['receipt'] != null) {
      if (map['error_code'] != null) _invalid('publication resolution result');
      final result = _object(map['receipt'], {
        'protocol',
        'group_id',
        'operation_id',
        'resource_id',
        'revision',
      });
      _checkCompanionProtocol(result['protocol']);
      if (result['group_id'] != request.groupId ||
          result['operation_id'] != request.operationId) {
        _invalid('publication receipt identity');
      }
      receipt = SharingReceipt._(
        request.operationId,
        request.groupId,
        _companionId(result['resource_id']),
        _integer(result['revision'], 1, _maxSequence),
      );
    } else {
      error = _text(map['error_code'], 64);
      if (!publicationRejectionCodes.contains(error)) {
        _invalid('publication rejection');
      }
    }
    return PublicationResolution._(request, receipt, error);
  }
  final PublicationResolveRequest request;
  final SharingReceipt? receipt;
  final String? errorCode;
  void validateCommand(SharingCommand command) {
    if (command.kind != SharingCommandKind.publish ||
        command.operationId != request.operationId ||
        command.groupId != request.groupId) {
      _invalid('resolved command');
    }
    if (receipt case final value?) {
      SharingReceipt.fromJson(value.toJson(), command: command);
    }
  }

  Map<String, Object?> toJson() => {
    ...request.toJson(),
    'receipt': receipt?.toJson(),
    'error_code': errorCode,
  };
}
