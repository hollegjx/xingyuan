import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../assistant/assistant_providers.dart';
import '../../assistant/data/assistant_service.dart';

final journalAiServiceProvider = Provider<JournalAiService>((ref) {
  final service = ref.watch(assistantServiceProvider);
  if (service case final JournalAiService journal) return journal;
  return HttpAssistantService(endpoint: null, readCredential: () async => null);
});
