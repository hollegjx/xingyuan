import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/local/app_database.dart';
import '../../data/local/local_goal_repository.dart';
import '../../data/sync/identity_store.dart';
import 'data/assistant_service.dart';
import 'data/device_credential_store.dart';
import 'data/local_conversation_store.dart';
import 'presentation/assistant_conversation_controller.dart';

final assistantCredentialProvider = Provider(
  (ref) => const DeviceCredentialStore(),
);

final assistantServiceProvider = Provider<AssistantService>((ref) {
  final credentials = ref.watch(assistantCredentialProvider);
  const address = String.fromEnvironment('ASSISTANT_BASE_URL');
  try {
    return HttpAssistantService(
      endpoint: address.isEmpty ? null : Uri.parse(address),
      readCredential: credentials.read,
      allowInsecureLoopback: const bool.fromEnvironment(
        'ASSISTANT_ALLOW_LOOPBACK',
      ),
    );
  } on FormatException {
    return HttpAssistantService(
      endpoint: null,
      readCredential: credentials.read,
    );
  } on AssistantFailure {
    return HttpAssistantService(
      endpoint: null,
      readCredential: credentials.read,
    );
  }
});

final assistantStoreProvider = FutureProvider<LocalConversationStore>((
  ref,
) async {
  final goals = await ref.watch(goalRepositoryProvider.future);
  final lease = await IdentityStore(goals.db).active();
  if (lease.identity.owner != goals.owner) throw const StaleIdentity();
  return LocalConversationStore(
    LocalGoalRepository(
      goals.db,
      goals.clock,
      owner: goals.owner,
      identityLease: lease,
    ),
  );
}, retry: (retryCount, error) => null);

final assistantSettingsProvider = FutureProvider<StoredAssistantSettings>(
  (ref) async =>
      (await ref.watch(assistantStoreProvider.future)).memories.settings(),
  retry: (retryCount, error) => null,
);

final assistantMemoriesProvider = FutureProvider<List<StoredAssistantMemory>>(
  (ref) async =>
      (await ref.watch(assistantStoreProvider.future)).memories.list(),
  retry: (retryCount, error) => null,
);

final assistantSessionsProvider = FutureProvider<List<StoredAssistantSession>>(
  (ref) async => (await ref.watch(assistantStoreProvider.future)).sessions(),
  retry: (retryCount, error) => null,
);

final assistantCredentialRevisionProvider =
    NotifierProvider<AssistantCredentialRevision, int>(
      AssistantCredentialRevision.new,
    );

class AssistantCredentialRevision extends Notifier<int> {
  bool _changing = false;
  bool get changing => _changing;
  @override
  int build() => 0;
  void changed() => state++;

  Future<void> change(Future<void> Function() mutation) async {
    if (changing) {
      throw const DeviceCredentialFailure('设备凭证正在更改，请稍后重试。');
    }
    _changing = true;
    changed();
    try {
      await mutation();
    } finally {
      _changing = false;
      if (ref.mounted) changed();
    }
  }
}

final assistantCredentialReadyProvider = FutureProvider<bool>((ref) async {
  ref.watch(assistantCredentialRevisionProvider);
  return await ref.watch(assistantCredentialProvider).read() != null;
}, retry: (retryCount, error) => null);

final assistantConversationProvider =
    FutureProvider<AssistantConversationController>((ref) async {
      final service = ref.watch(assistantServiceProvider);
      final store = await ref.watch(assistantStoreProvider.future);
      if (!ref.mounted) throw const StaleIdentity();
      final controller = AssistantConversationController(
        store: store,
        service: service,
      );
      ref.onDispose(controller.dispose);
      ref.listen(assistantCredentialRevisionProvider, (_, _) {
        controller.cancel(configurationChanged: true).ignore();
      });
      await controller.initialize();
      return controller;
    }, retry: (retryCount, error) => null);
