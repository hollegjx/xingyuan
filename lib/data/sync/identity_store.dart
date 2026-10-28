import 'package:drift/drift.dart';

import '../local/app_database.dart';
import 'sync_identity.dart';

class StaleIdentity implements Exception {
  const StaleIdentity();
}

class IdentityStore {
  IdentityStore(this.db);
  final AppDatabase db;

  Future<StoredIdentityState> read() =>
      db.select(db.identityStates).getSingle();

  Future<IdentityLease> active() async {
    final state = await read();
    final identity = SyncIdentity.tryParse(state.owner);
    if (state.targetOwner != null || identity == null) {
      throw const StaleIdentity();
    }
    return IdentityLease(identity, state.generation);
  }

  Future<void> require(IdentityLease lease) async {
    final state = await read();
    if (state.targetOwner != null ||
        state.owner != lease.identity.owner ||
        state.generation != lease.generation) {
      throw const StaleIdentity();
    }
  }

  Future<StoredIdentityState> begin(SyncIdentity target) =>
      db.transaction(() async {
        final state = await read();
        if (state.targetOwner != null) {
          if (state.targetOwner != target.owner) {
            throw const StaleIdentity();
          }
          return state;
        }
        if (state.owner == target.owner) return state;
        await db
            .update(db.identityStates)
            .write(
              IdentityStatesCompanion(
                targetOwner: Value(target.owner),
                generation: Value(state.generation + 1),
              ),
            );
        return read();
      });

  Future<IdentityLease> finish(StoredIdentityState intent) =>
      db.transaction(() async {
        final current = await read();
        if (current != intent || current.targetOwner == null) {
          throw const StaleIdentity();
        }
        final target = SyncIdentity.tryParse(current.targetOwner!);
        if (target == null) throw const StaleIdentity();
        await db
            .update(db.identityStates)
            .write(
              IdentityStatesCompanion(
                owner: Value(target.owner),
                targetOwner: const Value(null),
              ),
            );
        return IdentityLease(target, current.generation);
      });
}
