import '../../data/local/local_goal_repository.dart';
import '../../data/sync/identity_store.dart';
import '../../data/sync/local_sync_store.dart';
import '../../data/sync/sync_identity.dart';
import '../../shared/app_clock.dart';
import '../reminders/notification_permissions.dart';
import '../reminders/reminder_coordinator.dart';
import '../reminders/reminder_notifications.dart';

class IdentityActivation {
  const IdentityActivation(this.lease, {required this.remindersNeedRetry});
  final IdentityLease lease;
  final bool remindersNeedRetry;
}

class IdentityCoordinator {
  IdentityCoordinator({
    required this.store,
    required this.clock,
    required this.work,
    required this.permissions,
    required this.notifications,
  });

  final IdentityStore store;
  final AppClock clock;
  final SerialWork work;
  final NotificationPermissions permissions;
  final ReminderNotifications notifications;

  Future<IdentityActivation> switchTo(SyncIdentity target) =>
      work.run(() async {
        final intent = await store.begin(target);
        final IdentityLease lease;
        if (intent.targetOwner != null) {
          await _reminders(intent.owner).suspendIdentity();
          lease = await store.finish(intent);
        } else {
          lease = await store.active();
        }
        return _reconcile(lease);
      });

  Future<IdentityActivation> resume() => work.run(() async {
    final state = await store.read();
    final IdentityLease lease;
    if (state.targetOwner != null) {
      await _reminders(state.owner).suspendIdentity();
      lease = await store.finish(state);
    } else {
      lease = await store.active();
    }
    return _reconcile(lease);
  });

  Future<IdentityActivation> importGuest({
    required IdentityLease lease,
    required String transferId,
  }) => work.run(() async {
    await store.require(lease);
    if (lease.identity.isGuest) throw const StaleIdentity();
    await _reminders('guest').suspendIdentity();
    await LocalSyncStore(
      store.db,
      clock,
    ).transferGuest(lease: lease, transferId: transferId);
    return _reconcile(lease);
  });

  ReminderCoordinator _reminders(String owner, {IdentityLease? lease}) =>
      ReminderCoordinator(
        repository: LocalGoalRepository(
          store.db,
          clock,
          owner: owner,
          identityLease: lease,
        ),
        clock: clock,
        permissions: permissions,
        notifications: notifications,
      );

  Future<IdentityActivation> _reconcile(IdentityLease lease) async {
    try {
      await _reminders(lease.identity.owner, lease: lease).reconcile();
      return IdentityActivation(lease, remindersNeedRetry: false);
    } catch (_) {
      // Old reminders were already confirmed absent. New scheduling can retry
      // independently; do not misreport a committed switch as rolled back.
      return IdentityActivation(lease, remindersNeedRetry: true);
    }
  }
}
