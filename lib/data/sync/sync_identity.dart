class SyncIdentity {
  const SyncIdentity._(this.owner);

  static const guest = SyncIdentity._('guest');
  static final _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );

  factory SyncIdentity.account(String verifiedUserId) {
    final id = verifiedUserId.toLowerCase();
    if (!_uuid.hasMatch(id)) {
      throw const FormatException('Invalid account identifier');
    }
    return SyncIdentity._('user:$id');
  }

  static SyncIdentity? tryParse(String owner) {
    if (owner == guest.owner) return guest;
    if (!owner.startsWith('user:') || !_uuid.hasMatch(owner.substring(5))) {
      return null;
    }
    return SyncIdentity._(owner);
  }

  static bool isUuid(String value) => _uuid.hasMatch(value);

  final String owner;
  bool get isGuest => owner == 'guest';
  String? get userId => isGuest ? null : owner.substring(5);

  @override
  bool operator ==(Object other) =>
      other is SyncIdentity && other.owner == owner;

  @override
  int get hashCode => owner.hashCode;
}

class IdentityLease {
  const IdentityLease(this.identity, this.generation);

  final SyncIdentity identity;
  final int generation;
}
