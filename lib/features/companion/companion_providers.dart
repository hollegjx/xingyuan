import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../app/providers.dart';
import '../assistant/assistant_providers.dart';
import '../records/record_providers.dart';
import 'data/companion_service.dart';
import 'data/chat_photo_files.dart';
import 'data/local_chat_store.dart';
import 'data/local_pairing_store.dart';
import 'data/local_sharing_store.dart';
import 'data/local_publication_outbox.dart';
import 'data/publication_runner.dart';
import 'presentation/companion_foreground.dart';
import 'presentation/chat_controller.dart';
import 'presentation/pairing_controller.dart';
import 'presentation/sharing_controller.dart';

final companionServiceProvider = Provider<CompanionService>((ref) {
  final credentials = ref.watch(assistantCredentialProvider);
  const address = String.fromEnvironment('ASSISTANT_BASE_URL');
  try {
    return HttpCompanionService(
      endpoint: address.isEmpty ? null : Uri.parse(address),
      readCredential: credentials.read,
      allowInsecureLoopback: const bool.fromEnvironment(
        'ASSISTANT_ALLOW_LOOPBACK',
      ),
    );
  } catch (_) {
    return HttpCompanionService(
      endpoint: null,
      readCredential: credentials.read,
    );
  }
});

final companionSharingServiceProvider = Provider<CompanionSharingService>((
  ref,
) {
  final Object service = ref.watch(companionServiceProvider);
  if (service is CompanionSharingService) return service;
  throw const CompanionServiceFailure('unconfigured');
});

final companionMediaServiceProvider = Provider<CompanionMediaService>((ref) {
  final Object service = ref.watch(companionServiceProvider);
  if (service is CompanionMediaService) return service;
  throw const CompanionServiceFailure('unconfigured');
});

final companionChatServiceProvider = Provider<CompanionChatService>((ref) {
  final Object service = ref.watch(companionServiceProvider);
  if (service is CompanionChatService) return service;
  throw const CompanionServiceFailure('unconfigured');
});

final chatPhotoFilesProvider = FutureProvider<ChatPhotoFiles>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  final records = await ref.watch(recordPhotoRootProvider.future);
  if (!ref.mounted) throw const CompanionServiceFailure('discarded');
  final files = ChatPhotoFiles(
    Directory(p.join(p.dirname(records.path), 'chat_photos')),
    db,
  );
  ref.onDispose(() => unawaited(files.dispose()));
  return files;
}, retry: (count, error) => null);

final chatPhotoCleanupProvider = FutureProvider<void>((ref) async {
  final files = await ref.watch(chatPhotoFilesProvider.future);
  if (ref.mounted) await files.startCleanup();
}, retry: (count, error) => null);

final chatControllerProvider = FutureProvider<ChatController>((ref) async {
  final service = ref.watch(companionChatServiceProvider);
  final media = ref.watch(companionMediaServiceProvider);
  final sharing = await ref.watch(sharingControllerProvider.future);
  final files = await ref.watch(chatPhotoFilesProvider.future);
  if (!ref.mounted || !sharing.available) {
    throw const CompanionServiceFailure('discarded');
  }
  final store = await LocalChatStore.open(sharing.store);
  if (!ref.mounted) throw const CompanionServiceFailure('discarded');
  final controller = ChatController(
    store: store,
    service: service,
    media: media,
    files: files,
  );
  ref.onDispose(controller.dispose);
  await controller.initialize();
  return controller;
}, retry: (count, error) => null);

final companionPublicationServiceProvider =
    Provider<CompanionPublicationService>((ref) {
      final Object service = ref.watch(companionServiceProvider);
      if (service is CompanionPublicationService) return service;
      throw const CompanionServiceFailure('unconfigured');
    });

final publicationRunnerProvider = FutureProvider<PublicationRunner>((
  ref,
) async {
  final sharing = await ref.watch(sharingControllerProvider.future);
  final files = await ref.watch(recordPhotoFilesProvider.future);
  if (!ref.mounted || !sharing.available) {
    throw const CompanionServiceFailure('discarded');
  }
  final runner = PublicationRunner(
    outbox: LocalPublicationOutbox(sharing.store),
    sharing: ref.watch(companionSharingServiceProvider),
    media: ref.watch(companionMediaServiceProvider),
    resolution: ref.watch(companionPublicationServiceProvider),
    files: files,
  );
  ref.onDispose(runner.dispose);
  await runner.initialize();
  return runner;
}, retry: (count, error) => null);

final companionForegroundProvider = Provider<CompanionForeground?>((ref) {
  if (!ref.watch(companionServiceProvider).configured) return null;
  final pairing = ref.watch(pairingControllerProvider).asData?.value;
  if (pairing == null) return null;
  final foreground = CompanionForeground(
    pairing: pairing,
    loadSharing: () => ref.read(sharingControllerProvider.future),
    loadRunner: () => ref.read(publicationRunnerProvider.future),
    loadChat: () => ref.read(chatControllerProvider.future),
    groupChanged: () {
      if (ref.mounted) ref.invalidate(sharingControllerProvider);
    },
  );
  ref.onDispose(foreground.dispose);
  return foreground;
});

final pairingControllerProvider = FutureProvider<PairingController>((
  ref,
) async {
  ref.watch(assistantCredentialRevisionProvider);
  final changing = ref
      .read(assistantCredentialRevisionProvider.notifier)
      .changing;
  final credentials = ref.watch(assistantCredentialProvider);
  final service = ref.watch(companionServiceProvider);
  final records = await ref.watch(dayRecordStoreProvider.future);
  if (!ref.mounted) throw const CompanionServiceFailure('discarded');
  final token = changing ? null : await credentials.read();
  if (!ref.mounted) throw const CompanionServiceFailure('discarded');
  if (token == null) {
    await LocalPairingStore.forgetCredential(
      records.goals,
      isCurrent: () => ref.mounted,
    );
    throw const CompanionServiceFailure('credential');
  }
  final store = await LocalPairingStore.open(
    records.goals,
    credentialScope: companionCredentialScope(token),
  );
  if (!ref.mounted) throw const CompanionServiceFailure('discarded');
  final controller = PairingController(store: store, service: service);
  ref.onDispose(controller.dispose);
  await controller.initialize();
  return controller;
}, retry: (count, error) => null);

final sharingControllerProvider = FutureProvider<SharingController>((
  ref,
) async {
  ref.watch(assistantCredentialRevisionProvider);
  final pairing = await ref.watch(pairingControllerProvider.future);
  if (!ref.mounted) throw const CompanionServiceFailure('discarded');
  final store = await LocalSharingStore.open(pairing.store);
  if (!ref.mounted) throw const CompanionServiceFailure('discarded');
  final controller = SharingController(
    store: store,
    service: ref.watch(companionSharingServiceProvider),
  );
  void changed() {
    if (ref.mounted && pairing.snapshot?.state?.group?.id != store.groupId) {
      ref.invalidateSelf();
    }
  }

  pairing.addListener(changed);
  ref.onDispose(() {
    pairing.removeListener(changed);
    controller.dispose();
  });
  await controller.initialize();
  return controller;
}, retry: (count, error) => null);
