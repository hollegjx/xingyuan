import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

import '../../../data/local/app_database.dart';
import '../../../shared/local_identity_boundary.dart';
import '../../../app/theme.dart';
import '../../../shared/presentation.dart';
import '../../../shared/ui/sky.dart';
import '../../assistant/presentation/assistant_settings_page.dart';
import '../analysis_providers.dart';
import '../data/local_day_analysis_store.dart';
import 'day_analysis_controller.dart';

class DayAnalysisPage extends ConsumerStatefulWidget {
  const DayAnalysisPage({super.key});
  @override
  ConsumerState<DayAnalysisPage> createState() => _DayAnalysisPageState();
}

class _DayAnalysisPageState extends ConsumerState<DayAnalysisPage> {
  late final _store = ref.read(dayAnalysisStoreProvider.future);
  bool _dialog = false;

  Future<void> _analyze(
    DayAnalysisController controller, {
    String? retryOf,
  }) async {
    if (_dialog || controller.busy) return;
    if (controller.settings?.consentVersion != dayAnalysisConsentVersion) {
      setState(() => _dialog = true);
      final consent = await confirmAction(
        context,
        title: '分析发送范围',
        message: '将把你当天的目标名称、计划时间和分钟数、完成状态和时间、已保存的文字记录发送到星愿后端和模型服务。照片、未保存草稿、聊天、记忆和其他日期不发送。分析结果仅保存在本机，不分享给他人。',
        confirm: '同意并分析',
        confirmKey: const ValueKey('consent-day-analysis'),
      );
      if (!mounted) return;
      if (consent != true) {
        setState(() => _dialog = false);
        return;
      }
      try {
        await controller.consent();
        ref.invalidate(dayAnalysisSettingsProvider);
      } catch (_) {
        if (mounted) {
          setState(() => _dialog = false);
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('授权未保存，请重试。')));
        }
        return;
      }
      if (!mounted) return;
      setState(() => _dialog = false);
    }
    await controller.analyze(retryOf: retryOf);
  }

  Future<void> _delete(
    DayAnalysisController controller,
    StoredDayAnalysis row,
  ) async {
    if (_dialog) return;
    setState(() => _dialog = true);
    final approved = await confirmAction(
      context,
      title: '删除这次分析？',
      message: '将删除本机的分析结果和发送快照，不改变目标、打卡或文字记录。',
      confirm: '删除',
      confirmKey: const ValueKey('confirm-delete-analysis'),
      destructive: true,
    );
    if (!mounted) return;
    try {
      if (approved == true) await controller.remove(row.id);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('未能删除分析，请重试。')));
      }
    } finally {
      if (mounted) setState(() => _dialog = false);
    }
  }

  void _payload(StoredDayAnalysis row) => Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => DayAnalysisPayloadPage(row: row)),
  );

  @override
  Widget build(BuildContext context) {
    final xy = context.xy;
    final theme = Theme.of(context);
    return LocalIdentityBoundary(
      repository: _store.then((store) => store.goals),
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: Scaffold(
          backgroundColor: xy.sky,
          extendBodyBehindAppBar: true,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            foregroundColor: xy.onSky,
            systemOverlayStyle: SystemUiOverlayStyle.light,
            actions: [
              IconButton(
                tooltip: 'AI 设置',
                icon: const Icon(CupertinoIcons.slider_horizontal_3),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const AssistantSettingsPage(),
                  ),
                ),
              ),
            ],
          ),
          body: SkyPanel(
            seed: 42,
            radius: BorderRadius.zero,
            padding: EdgeInsets.zero,
            child: SafeArea(
              child: ref
                  .watch(dayAnalysisControllerProvider)
                  .when(
                    loading: () => const PageScroll(
                      children: [StatusPanel(message: '正在读取分析', loading: true)],
                    ),
                    error: (_, _) => PageScroll(
                      children: [
                        StatusPanel(
                          message: '无法读取分析',
                          retry: () =>
                              ref.invalidate(dayAnalysisControllerProvider),
                        ),
                      ],
                    ),
                    data: (controller) => ListenableBuilder(
                      listenable: controller,
                      builder: (context, _) => DefaultTextStyle.merge(
                        style: TextStyle(color: xy.onSky),
                        child: PageScroll(
                          padding: const EdgeInsets.fromLTRB(20, 4, 20, 40),
                          children: [
                            Row(
                              children: [
                                Icon(
                                  CupertinoIcons.moon_stars_fill,
                                  size: 26,
                                  color: xy.star,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    '今日星语',
                                    style: theme.textTheme.displaySmall
                                        ?.copyWith(color: xy.onSky),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '读一读你今天写下的话，给你写几句。只用当天的目标、完成情况和已保存的文字，不发送照片和聊天。',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: xy.onSkyMuted,
                              ),
                            ),
                            const SizedBox(height: 24),
                            if (controller.settings?.enabled != true)
                              const StatusPanel(message: '今日分析已关闭')
                            else
                              FilledButton(
                                key: const ValueKey('analyze-today'),
                                style: ButtonStyle(
                                  backgroundColor:
                                      WidgetStateProperty.resolveWith(
                                        (states) => xy.onSky.withValues(
                                          alpha:
                                              states.contains(
                                                WidgetState.disabled,
                                              )
                                              ? 0.4
                                              : states.contains(
                                                  WidgetState.pressed,
                                                )
                                              ? 0.8
                                              : 1,
                                        ),
                                      ),
                                  foregroundColor: WidgetStatePropertyAll(
                                    xy.sky,
                                  ),
                                ),
                                onPressed: controller.busy || _dialog
                                    ? null
                                    : () => _analyze(controller),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (controller.busy) ...[
                                      XyActivity(radius: 8, color: xy.sky),
                                      const SizedBox(width: 8),
                                    ],
                                    Text(controller.busy ? '正在分析' : '分析今天'),
                                  ],
                                ),
                              ),
                            if (controller.busy)
                              TextButton(
                                key: const ValueKey('cancel-analysis'),
                                style: TextButton.styleFrom(
                                  foregroundColor: xy.onSkyMuted,
                                ),
                                onPressed: () => controller.cancel(),
                                child: const Text('取消等待'),
                              ),
                            if (controller.error case final error?) ...[
                              const SizedBox(height: 12),
                              NoticeBanner(
                                tone: NoticeTone.error,
                                message: error,
                              ),
                            ],
                            if (controller.results.isEmpty) ...[
                              const SizedBox(height: 32),
                              Text(
                                '暂无分析',
                                textAlign: TextAlign.center,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: xy.onSkyMuted,
                                ),
                              ),
                            ],
                            for (final row in controller.results) ...[
                              const SizedBox(height: 20),
                              _Letter(
                                row: row,
                                onPayload: () => _payload(row),
                                onDelete: _dialog
                                    ? null
                                    : () => _delete(controller, row),
                                onRetry:
                                    [
                                          'failed',
                                          'cancelled',
                                        ].contains(row.status) &&
                                        controller.settings?.enabled == true
                                    ? () =>
                                          _analyze(controller, retryOf: row.id)
                                    : null,
                                retryEnabled: !controller.busy && !_dialog,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
            ),
          ),
        ),
      ),
    );
  }
}

String _letterDate(String day) {
  final parts = day.split('-');
  if (parts.length != 3) return day;
  final month = int.tryParse(parts[1]);
  final date = int.tryParse(parts[2]);
  if (month == null || date == null) return day;
  return '$month月$date日';
}

/// One analysis, written as a short letter.
class _Letter extends StatelessWidget {
  const _Letter({
    required this.row,
    required this.onPayload,
    required this.onDelete,
    required this.onRetry,
    required this.retryEnabled,
  });

  final StoredDayAnalysis row;
  final VoidCallback onPayload;
  final VoidCallback? onDelete;
  final VoidCallback? onRetry;
  final bool retryEnabled;

  @override
  Widget build(BuildContext context) {
    final xy = context.xy;
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: xy.onSky.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: xy.onSky.withValues(alpha: 0.10)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 14, 8, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '写给 ${_letterDate(row.day)} 的你',
                  style: theme.textTheme.titleMedium?.copyWith(color: xy.onSky),
                ),
              ),
              IconButton(
                key: ValueKey('analysis-payload-${row.id}'),
                tooltip: '查看实际发送内容',
                color: xy.onSkyMuted,
                onPressed: onPayload,
                icon: const Icon(CupertinoIcons.doc_text_search),
              ),
              IconButton(
                key: ValueKey('delete-analysis-${row.id}'),
                tooltip: '删除分析',
                color: xy.onSkyMuted,
                onPressed: onDelete,
                icon: const Icon(CupertinoIcons.trash),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12, top: 6),
            child: _AnalysisResult(row: row),
          ),
          if (onRetry != null)
            Padding(
              padding: const EdgeInsets.only(top: 12, right: 12),
              child: OutlinedButton(
                key: ValueKey('retry-analysis-${row.id}'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: xy.onSky,
                  backgroundColor: xy.onSky.withValues(alpha: 0.10),
                ),
                onPressed: retryEnabled ? onRetry : null,
                child: const Text('重试这次分析'),
              ),
            ),
        ],
      ),
    );
  }
}

class _AnalysisResult extends StatelessWidget {
  const _AnalysisResult({required this.row});
  final StoredDayAnalysis row;
  @override
  Widget build(BuildContext context) {
    final xy = context.xy;
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(color: xy.onSkyMuted);
    if (row.status == 'pending') return Text('正在等待分析结果', style: muted);
    if (row.status != 'succeeded') {
      return Text(dayAnalysisFailureMessage(row.failureCode), style: muted);
    }
    try {
      final request = DayAnalysisRequest.fromJson(jsonDecode(row.requestJson));
      final response = DayAnalysisResponse.fromJson(
        jsonDecode(row.responseJson!),
        request: request,
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SelectableText(
            response.summary,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: xy.onSky,
              height: 1.8,
            ),
          ),
          if (response.suggestions.isNotEmpty) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              decoration: BoxDecoration(
                color: xy.onSky.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '明天可以试试',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: xy.star,
                    ),
                  ),
                  for (final suggestion in response.suggestions) ...[
                    const SizedBox(height: 6),
                    SelectableText(
                      suggestion,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: xy.onSky,
                        height: 1.6,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: Text('—— 星愿', style: muted),
          ),
        ],
      );
    } catch (_) {
      return Text('无法读取这次分析，原记录仍保留。', style: muted);
    }
  }
}

class DayAnalysisPayloadPage extends ConsumerStatefulWidget {
  const DayAnalysisPayloadPage({required this.row, super.key});
  final StoredDayAnalysis row;
  @override
  ConsumerState<DayAnalysisPayloadPage> createState() =>
      _DayAnalysisPayloadPageState();
}

class _DayAnalysisPayloadPageState
    extends ConsumerState<DayAnalysisPayloadPage> {
  late final _store = ref.read(dayAnalysisStoreProvider.future);
  @override
  Widget build(BuildContext context) => LocalIdentityBoundary(
    repository: _store.then((store) {
      if (store.owner != widget.row.owner) {
        throw StateError('Analysis owner changed');
      }
      return store.goals;
    }),
    child: Scaffold(
      appBar: pageAppBar(context, '实际发送内容'),
      body: SafeArea(
        child: PageScroll(
          children: [
            SelectableText(
              const JsonEncoder.withIndent('  ')
                  .convert(jsonDecode(widget.row.requestJson)),
            ),
          ],
        ),
      ),
    ),
  );
}
