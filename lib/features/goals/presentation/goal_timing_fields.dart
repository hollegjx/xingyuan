import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

import '../../../app/theme.dart';
import '../../../shared/presentation.dart';
import '../domain/goal_timing.dart';
import 'goal_time_picker.dart';

class GoalTimingFields extends StatefulWidget {
  const GoalTimingFields({
    required this.startMinute,
    required this.durationMinutes,
    required this.onStartChanged,
    required this.onDurationChanged,
    this.enabled = true,
    super.key,
  });
  final int? startMinute;
  final int? durationMinutes;
  final ValueChanged<int?> onStartChanged;
  final ValueChanged<int?> onDurationChanged;
  final bool enabled;

  @override
  State<GoalTimingFields> createState() => _GoalTimingFieldsState();
}

class _GoalTimingFieldsState extends State<GoalTimingFields> {
  late final TextEditingController _minutes;
  @override
  void initState() {
    super.initState();
    _minutes = TextEditingController(
      text: widget.durationMinutes?.toString() ?? '',
    );
  }

  @override
  void didUpdateWidget(GoalTimingFields oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (int.tryParse(_minutes.text) != widget.durationMinutes) {
      _minutes.text = widget.durationMinutes?.toString() ?? '';
    }
  }

  @override
  void dispose() {
    _minutes.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final minute = widget.startMinute ?? 1170;
    final initialTime = TimeOfDay(hour: minute ~/ 60, minute: minute % 60);
    final result = await showGoalTimePicker(context, initialTime: initialTime);
    if (mounted && result != null) {
      widget.onStartChanged(result.hour * 60 + result.minute);
    }
  }

  void _step(int direction) {
    final value = int.tryParse(_minutes.text);
    final next = value == null ? 30 : (value + direction * 5).clamp(5, 480);
    _minutes.text = '$next';
    widget.onDurationChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final xy = context.xy;
    final theme = Theme.of(context);
    final hasMinutes = _minutes.text.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        XyValueRow(
          label: const Text('开始时间（可选）'),
          value: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton(
                key: const ValueKey('start-time'),
                onPressed: widget.enabled ? _pick : null,
                style: widget.startMinute == null
                    ? OutlinedButton.styleFrom(
                        foregroundColor: xy.muted,
                        backgroundColor: xy.fill,
                      )
                    : null,
                child: Text(
                  widget.startMinute == null
                      ? '未设置'
                      : formatMinute(widget.startMinute!),
                  style: const TextStyle(
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              IconButton(
                key: const ValueKey('clear-start-time'),
                tooltip: '清除开始时间',
                color: xy.faint,
                onPressed: widget.enabled && widget.startMinute != null
                    ? () => widget.onStartChanged(null)
                    : null,
                icon: const Icon(CupertinoIcons.xmark_circle_fill, size: 20),
              ),
            ],
          ),
        ),
        const Divider(indent: 16),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          child: Text('预计分钟（可选）', style: theme.textTheme.bodyLarge),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 6, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              IconButton(
                tooltip: '减少 5 分钟',
                color: theme.colorScheme.primary,
                onPressed: widget.enabled ? () => _step(-1) : null,
                icon: const Icon(CupertinoIcons.minus_circle),
              ),
              Expanded(
                child: TextFormField(
                  key: const ValueKey('duration-minutes'),
                  controller: _minutes,
                  enabled: widget.enabled,
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.center,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                  decoration: InputDecoration(
                    hintText: '未设置',
                    errorMaxLines: 6,
                    fillColor: xy.fill,
                    isDense: true,
                    suffixText: hasMinutes ? '分钟' : null,
                  ),
                  onChanged: (value) {
                    setState(() {});
                    widget.onDurationChanged(int.tryParse(value));
                  },
                  validator: (value) {
                    final input = value ?? '';
                    final duration = int.tryParse(input);
                    if (input.isNotEmpty && duration == null) {
                      return '请输入有效分钟数';
                    }
                    try {
                      GoalTiming(
                        startMinute: widget.startMinute,
                        durationMinutes: duration,
                      );
                      return null;
                    } on FormatException catch (error) {
                      return error.message;
                    }
                  },
                ),
              ),
              IconButton(
                tooltip: '增加 5 分钟',
                color: theme.colorScheme.primary,
                onPressed: widget.enabled ? () => _step(1) : null,
                icon: const Icon(CupertinoIcons.plus_circle),
              ),
              IconButton(
                tooltip: '清除预计分钟',
                color: xy.faint,
                onPressed: widget.enabled && hasMinutes
                    ? () {
                        _minutes.clear();
                        setState(() {});
                        widget.onDurationChanged(null);
                      }
                    : null,
                icon: const Icon(CupertinoIcons.xmark_circle_fill, size: 20),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
