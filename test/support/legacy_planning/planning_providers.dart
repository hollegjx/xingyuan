import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:habit_checkin/app/providers.dart';
import 'package:habit_checkin/features/planning/data/local_planning_store.dart';

import 'planning_service.dart';

final planningStoreProvider = FutureProvider<LocalPlanningStore>((ref) async {
  return LocalPlanningStore(await ref.watch(goalRepositoryProvider.future));
}, retry: (count, error) => null);

// Historical UI fixtures cannot activate the retired live gateway.
final planningServiceProvider = Provider<PlanningService>(
  (ref) => UnconfiguredPlanningService(),
);
