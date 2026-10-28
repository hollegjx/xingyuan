import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../analysis_providers.dart';
import 'day_analysis_page.dart';

class DayAnalysisButton extends ConsumerWidget {
  const DayAnalysisButton({this.spacing = EdgeInsets.zero, super.key});

  /// Space around the button, applied only when it is shown.
  final EdgeInsetsGeometry spacing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(dayAnalysisSettingsProvider).value?.enabled != true) {
      return const SizedBox.shrink();
    }
    return Padding(padding: spacing, child: _entry(context));
  }

  Widget _entry(BuildContext context) {
    final xy = context.xy;
    final theme = Theme.of(context);
    return Tooltip(
      message: '分析今天',
      excludeFromSemantics: true,
      child: Material(
        color: xy.onSky.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          key: const ValueKey('open-day-analysis'),
          borderRadius: BorderRadius.circular(12),
          highlightColor: xy.onSky.withValues(alpha: 0.08),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const DayAnalysisPage()),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
            child: Row(
              children: [
                Icon(CupertinoIcons.moon_stars_fill, size: 20, color: xy.star),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '今日星语',
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: xy.onSky,
                        ),
                      ),
                      Text(
                        '让星愿读一读今天，给你写几句话',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: xy.onSkyMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  CupertinoIcons.chevron_right,
                  size: 15,
                  color: xy.onSkyMuted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class DayAnalysisSettingsControl extends ConsumerStatefulWidget {
  const DayAnalysisSettingsControl({super.key});
  @override
  ConsumerState<DayAnalysisSettingsControl> createState() =>
      _DayAnalysisSettingsControlState();
}

class _DayAnalysisSettingsControlState
    extends ConsumerState<DayAnalysisSettingsControl> {
  bool _saving = false;
  Future<void> _set(bool value) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final store = await ref.read(dayAnalysisStoreProvider.future);
      // Disabling is available even when the optional model service is unconfigured.
      await store.setEnabled(value);
      final controller = ref.read(dayAnalysisControllerProvider).value;
      if (controller != null) {
        if (!value) await controller.cancel(configurationChanged: true);
        await controller.refresh();
      }
      ref.invalidate(dayAnalysisSettingsProvider);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('分析设置未保存，请重试。')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => ref
      .watch(dayAnalysisSettingsProvider)
      .when(
        loading: () =>
            const ListTile(title: Text('今日分析'), subtitle: Text('正在读取设置')),
        error: (_, _) => ListTile(
          title: const Text('今日分析设置无法读取'),
          trailing: IconButton(
            tooltip: '重试',
            onPressed: () => ref.invalidate(dayAnalysisSettingsProvider),
            icon: const Icon(CupertinoIcons.arrow_clockwise),
          ),
        ),
        data: (settings) => Column(
          children: [
            SwitchListTile.adaptive(
              key: const ValueKey('enable-day-analysis'),
              title: const Text('今日星语'),
              subtitle: const Text('让 AI 读一读你当天的记录'),
              value: settings.enabled,
              onChanged: _saving ? null : _set,
            ),
            const Divider(indent: 16),
            ListTile(
              title: const Text('分析记录'),
              trailing: Icon(
                CupertinoIcons.chevron_right,
                size: 16,
                color: context.xy.faint,
              ),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const DayAnalysisPage(),
                ),
              ),
            ),
          ],
        ),
      );
}
