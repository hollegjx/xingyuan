import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local/app_database.dart';
import '../assistant/assistant_providers.dart';
import '../assistant/data/assistant_service.dart';
import '../records/record_providers.dart';
import 'data/local_day_analysis_store.dart';
import 'presentation/day_analysis_controller.dart';

final dayAnalysisStoreProvider = FutureProvider<LocalDayAnalysisStore>((
  ref,
) async {
  final records = await ref.watch(dayRecordStoreProvider.future);
  return LocalDayAnalysisStore(records.goals);
}, retry: (count, error) => null);

final dayAnalysisServiceProvider = Provider<DayAnalysisService>((ref) {
  final service = ref.watch(assistantServiceProvider);
  if (service case final DayAnalysisService analysis) return analysis;
  throw const AssistantFailure(AssistantFailureKind.unconfigured);
});

final dayAnalysisSettingsProvider = FutureProvider<StoredDayAnalysisSettings>(
  (ref) async => (await ref.watch(dayAnalysisStoreProvider.future)).settings(),
  retry: (count, error) => null,
);

final dayAnalysisControllerProvider = FutureProvider<DayAnalysisController>((
  ref,
) async {
  final service = ref.watch(dayAnalysisServiceProvider);
  final store = await ref.watch(dayAnalysisStoreProvider.future);
  final controller = DayAnalysisController(store: store, service: service);
  ref.onDispose(controller.dispose);
  ref.listen(assistantCredentialRevisionProvider, (_, _) {
    controller.cancel(configurationChanged: true).ignore();
  });
  await controller.initialize();
  return controller;
}, retry: (count, error) => null);
