import 'dart:io';

import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:habit_checkin/app/providers.dart';
import 'package:habit_checkin/data/local/local_goal_repository.dart';
import 'package:habit_checkin/features/assistant/assistant_providers.dart';
import 'package:habit_checkin/features/assistant/data/device_credential_store.dart';
import 'package:habit_checkin/features/records/record_providers.dart';

class _ProbeCredential extends DeviceCredentialStore {
  const _ProbeCredential(this.token);
  final String? token;

  @override
  Future<String?> read() async => token;

  @override
  Future<void> save(String input) async =>
      throw StateError('Personal probes cannot change ordinary credentials');

  @override
  Future<void> clear() async =>
      throw StateError('Personal probes cannot change ordinary credentials');
}

List<Override> isolatedGoalProbeOverrides({
  required LocalGoalRepository goals,
  required Directory workspace,
  String? credential,
}) => [
  databaseProvider.overrideWith((ref) => goals.db),
  goalRepositoryProvider.overrideWith((ref) => goals),
  recordPhotoRootProvider.overrideWith(
    (ref) => Directory('${workspace.path}/record_photos'),
  ),
  assistantCredentialProvider.overrideWithValue(_ProbeCredential(credential)),
];
