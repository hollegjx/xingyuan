import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../companion_providers.dart';
import '../data/companion_service.dart';
import '../data/local_publication_outbox.dart';
import '../data/publication_runner.dart';

String publicationStatus(String value) => switch (value) {
  'confirmed' => '记录已分享',
  'pending' => '分享待发送',
  'failed' => '分享未完成',
  _ => '仅保存在本机',
};

class PublicationQueueView extends ConsumerWidget {
  const PublicationQueueView({this.goalId, this.day, super.key});
  final int? goalId;
  final String? day;

  Future<void> _retry(
    BuildContext context,
    WidgetRef ref,
    PublicationRunner runner,
    PublicationAttempt attempt,
  ) async {
    await runner.run(retryOperation: attempt.row.operationId);
    if (!context.mounted || !runner.available) return;
    try {
      final sharing = await ref.read(sharingControllerProvider.future);
      if (sharing.available &&
          sharing.store.sessionId == runner.outbox.sharing.sessionId) {
        await sharing.refresh();
      }
    } catch (_) {
      // A successful send is not undone by a subsequent read/scope failure.
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => ref
      .watch(publicationRunnerProvider)
      .when(
        loading: () => const SizedBox.shrink(),
        error: (_, _) => const SizedBox.shrink(),
        data: (runner) => AnimatedBuilder(
          animation: runner,
          builder: (context, _) {
            if (!runner.available) return const SizedBox.shrink();
            final seen = <String>{};
            final pending = runner.pending.where(
              (item) =>
                  (goalId == null || item.source.goalId == goalId) &&
                  (day == null || item.source.day == day) &&
                  seen.add(item.source.id),
            );
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final attempt in pending)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(attempt.row.title),
                    subtitle: Text(
                      '${attempt.source.day}\n${switch (attempt.row.status) {
                        'sending' => '正在发送分享',
                        'uncertain' => '分享结果尚未确认',
                        'failed' => CompanionServiceFailure(attempt.row.errorCode ?? 'unavailable').message,
                        _ => '分享待发送',
                      }}',
                    ),
                    trailing: runner.canRetry(attempt)
                        ? IconButton(
                            key: ValueKey(
                              'retry-publication-${attempt.row.operationId}',
                            ),
                            tooltip: '重试分享',
                            onPressed: () =>
                                _retry(context, ref, runner, attempt),
                            icon: const Icon(CupertinoIcons.arrow_clockwise),
                          )
                        : attempt.row.status == 'sending'
                        ? IconButton(
                            tooltip: '取消分享等待',
                            onPressed: runner.cancelWaiting,
                            icon: const Icon(CupertinoIcons.xmark),
                          )
                        : null,
                  ),
              ],
            );
          },
        ),
      );
}
