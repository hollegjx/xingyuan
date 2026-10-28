import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../shared/local_date.dart';
import '../../../app/theme.dart';
import '../../../shared/presentation.dart';
import '../domain/goal.dart';
import 'goal_date_picker.dart';
import 'goal_time_picker.dart';
import 'goal_timing_fields.dart';

class GoalFormPage extends ConsumerStatefulWidget {
  const GoalFormPage({this.goal, super.key});

  final Goal? goal;

  @override
  ConsumerState<GoalFormPage> createState() => _GoalFormPageState();
}

class _GoalFormPageState extends ConsumerState<GoalFormPage> {
  final _form = GlobalKey<FormState>();
  final _scroll = ScrollController();
  late final TextEditingController _title;
  late final GoalDraft _initial;
  late GoalKind _kind;
  late int _weekdays;
  late bool _daily;
  late LocalDate _plannedDay;
  late bool _reminder;
  late int _reminderMinute;
  int? _startMinute;
  int? _durationMinutes;
  bool _reminderTimeEdited = false;
  bool _saving = false;
  bool _allowExit = false;
  bool _confirming = false;
  bool _validateTitle = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final today = ref.read(clockProvider).read().day;
    final goal = widget.goal;
    _kind = goal?.kind ?? GoalKind.habit;
    _weekdays = _kind == GoalKind.habit && goal != null
        ? goal.scheduleOn(today.addDays(1)).weekdays
        : 127;
    _daily = _weekdays == 127;
    _plannedDay = goal?.scheduleOn(today).plannedDay ?? today;
    _reminder = goal?.reminder.enabled ?? false;
    _reminderMinute = goal?.reminder.minuteOfDay ?? 1200;
    _reminderTimeEdited = goal?.reminder.enabled ?? false;
    final timing = goal?.scheduleOn(
      _kind == GoalKind.habit ? today.addDays(1) : today,
    );
    _startMinute = timing?.startMinute;
    _durationMinutes = timing?.durationMinutes;
    _title = TextEditingController(text: goal?.titleOn(today) ?? '');
    _initial = _draft;
  }

  GoalDraft get _draft => GoalDraft(
    title: _title.text,
    kind: _kind,
    weekdays: _daily ? 127 : _weekdays,
    plannedDay: _kind == GoalKind.single ? _plannedDay : null,
    startMinute: _startMinute,
    durationMinutes: _durationMinutes,
    reminderEnabled: _reminder,
    reminderMinute: _reminderMinute,
  );

  bool get _dirty {
    final draft = _draft;
    return draft.title != _initial.title ||
        draft.kind != _initial.kind ||
        draft.weekdays != _initial.weekdays ||
        draft.plannedDay != _initial.plannedDay ||
        draft.startMinute != _initial.startMinute ||
        draft.durationMinutes != _initial.durationMinutes ||
        draft.reminderEnabled != _initial.reminderEnabled ||
        draft.reminderMinute != _initial.reminderMinute;
  }

  @override
  void dispose() {
    _title.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _leave() async {
    if (_saving || _confirming) return;
    if (!_dirty) {
      Navigator.of(context).pop();
      return;
    }
    _confirming = true;
    final discard = await confirmAction(
      context,
      title: '放弃更改？',
      message: '尚未保存的内容将丢失。',
      confirm: '放弃更改',
      confirmKey: const ValueKey('discard-goal-changes'),
      cancel: '继续编辑',
      cancelKey: const ValueKey('continue-editing-goal'),
      destructive: true,
    );
    _confirming = false;
    if (mounted && discard == true) {
      setState(() => _allowExit = true);
      Navigator.of(context).pop();
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _validateTitle = true);
    if (!_form.currentState!.validate()) {
      await _scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
      return;
    }
    if (_kind == GoalKind.habit && !_daily && _weekdays == 0) {
      setState(() => _error = '至少选择一周中的一天');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final commands = ref.read(goalCommandsProvider.notifier);
      final int id;
      if (widget.goal case final original?) {
        await commands.edit(original, _draft);
        id = original.id;
      } else {
        id = await commands.create(_draft);
      }
      if (mounted) {
        setState(() => _allowExit = true);
        Navigator.of(context).pop(id);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = error is GoalRuleException
              ? error.message
              : '未能保存，请重试。原有记录未被清空。';
        });
      }
    }
  }

  Future<void> _pickDay() async {
    final today = ref.read(clockProvider).read().day;
    final initial = _plannedDay.isBefore(today) ? today : _plannedDay;
    final selected = await showGoalDatePicker(
      context,
      initialDate: DateTime(initial.year, initial.month, initial.day),
      firstDate: DateTime(today.year, today.month, today.day),
    );
    if (mounted && selected != null) {
      setState(() => _plannedDay = LocalDate.fromDateTime(selected));
    }
  }

  Future<void> _pickTime() async {
    final selected = await showGoalTimePicker(
      context,
      initialTime: TimeOfDay(
        hour: _reminderMinute ~/ 60,
        minute: _reminderMinute % 60,
      ),
      title: '提醒时间',
    );
    if (mounted && selected != null) {
      setState(() {
        _reminderMinute = selected.hour * 60 + selected.minute;
        _reminderTimeEdited = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final today =
        ref.watch(environmentProvider).value?.day ??
        ref.read(clockProvider).read().day;
    final time = TimeOfDay(
      hour: _reminderMinute ~/ 60,
      minute: _reminderMinute % 60,
    );
    final scheduleChanges =
        widget.goal != null &&
        _kind == GoalKind.habit &&
        _draft.weekdays != widget.goal!.scheduleOn(today).weekdays;
    final timingChanges =
        widget.goal != null &&
        _kind == GoalKind.habit &&
        (_startMinute != widget.goal!.scheduleOn(today).startMinute ||
            _durationMinutes != widget.goal!.scheduleOn(today).durationMinutes);
    return PopScope<int>(
      canPop: _allowExit || (!_dirty && !_saving),
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _leave();
      },
      child: Scaffold(
        appBar: pageAppBar(context, widget.goal == null ? '新建目标' : '编辑目标'),
        body: SafeArea(
          child: Form(
            key: _form,
            child: PageScroll(
              controller: _scroll,
              children: [
                XyGroup(
                  margin: const EdgeInsets.only(top: 12),
                  children: [
                    TextFormField(
                      key: const ValueKey('goal-title'),
                      controller: _title,
                      enabled: !_saving,
                      maxLength: 60,
                      maxLengthEnforcement: MaxLengthEnforcement.none,
                      maxLines: null,
                      textInputAction: TextInputAction.done,
                      style: Theme.of(context).textTheme.titleMedium,
                      decoration: const InputDecoration(
                        hintText: '目标名称',
                        counterText: '',
                      ),
                      onChanged: (_) => setState(() {}),
                      autovalidateMode: _validateTitle
                          ? AutovalidateMode.onUserInteraction
                          : AutovalidateMode.disabled,
                      errorBuilder: (context, message) => Text(
                        message,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                      validator: (value) {
                        final text = (value ?? '').trim();
                        if (text.isEmpty || text.characters.length > 60) {
                          return '名称需要 1 至 60 个字符';
                        }
                        return null;
                      },
                    ),
                  ],
                ),
                XyGroup(
                  footer: scheduleChanges
                      ? '频率从 ${dateLabel(today.addDays(1))} 起生效，今天不变。'
                      : widget.goal?.singleCompletion != null
                      ? '已完成任务不可直接改期'
                      : null,
                  children: [
                    _ChoiceRow<GoalKind>(
                      key: const ValueKey('goal-kind'),
                      label: '类型',
                      value: _kind,
                      options: const [
                        (GoalKind.habit, '重复习惯'),
                        (GoalKind.single, '单次任务'),
                      ],
                      onChanged: widget.goal != null || _saving
                          ? null
                          : (kind) => setState(() => _kind = kind),
                    ),
                    if (_kind == GoalKind.habit) ...[
                      _ChoiceRow<bool>(
                        key: const ValueKey('goal-frequency'),
                        label: '频率',
                        value: _daily,
                        options: const [(true, '每天'), (false, '指定星期')],
                        onChanged: _saving
                            ? null
                            : (daily) => setState(() => _daily = daily),
                      ),
                      if (!_daily)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                          child: Wrap(
                            spacing: 6,
                            runSpacing: 8,
                            alignment: WrapAlignment.center,
                            children: [
                              for (var i = 0; i < 7; i++)
                                FilterChip(
                                  key: ValueKey('weekday-${i + 1}'),
                                  selected: (_weekdays & (1 << i)) != 0,
                                  showCheckmark: false,
                                  label: Text(
                                    weekdayLabels[i],
                                    style: TextStyle(
                                      color: (_weekdays & (1 << i)) != 0
                                          ? Colors.white
                                          : null,
                                    ),
                                  ),
                                  onSelected: _saving
                                      ? null
                                      : (selected) => setState(() {
                                          _weekdays = selected
                                              ? _weekdays | (1 << i)
                                              : _weekdays & ~(1 << i);
                                        }),
                                ),
                            ],
                          ),
                        ),
                    ] else
                      XyValueRow(
                        label: const Text('计划日期'),
                        value: OutlinedButton(
                          key: const ValueKey('planned-day'),
                          onPressed:
                              _saving || widget.goal?.singleCompletion != null
                              ? null
                              : _pickDay,
                          child: Text(dateLabel(_plannedDay)),
                        ),
                      ),
                  ],
                ),
                XyGroup(
                  footer: timingChanges
                      ? '时间与分钟从 ${dateLabel(today.addDays(1))} 起生效，今天不变。'
                      : null,
                  children: [
                    GoalTimingFields(
                      startMinute: _startMinute,
                      durationMinutes: _durationMinutes,
                      enabled: !_saving,
                      onStartChanged: (value) => setState(() {
                        _startMinute = value;
                        if (!_reminderTimeEdited) {
                          _reminderMinute = value ?? 1200;
                        }
                      }),
                      onDurationChanged: (value) =>
                          setState(() => _durationMinutes = value),
                    ),
                  ],
                ),
                XyGroup(
                  footer: _reminder ? '提醒按最近日期预排，打开 App 时补充；长期不打开可能耗尽。' : null,
                  children: [
                    SwitchListTile.adaptive(
                      key: const ValueKey('reminder-toggle'),
                      secondary: const XyIconTile(
                        CupertinoIcons.bell_fill,
                        color: Color(0xFFFF3B30),
                      ),
                      title: const Text('提醒'),
                      value: _reminder,
                      onChanged: _saving
                          ? null
                          : (value) => setState(() {
                              _reminder = value;
                              if (value &&
                                  !_reminderTimeEdited &&
                                  _startMinute != null) {
                                _reminderMinute = _startMinute!;
                              }
                            }),
                    ),
                    if (_reminder)
                      XyValueRow(
                        label: const Text('提醒时间'),
                        value: OutlinedButton(
                          key: const ValueKey('reminder-time'),
                          onPressed: _saving ? null : _pickTime,
                          child: Text(time.format(context)),
                        ),
                      ),
                  ],
                ),
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Semantics(
                    liveRegion: true,
                    child: NoticeBanner(
                      tone: NoticeTone.error,
                      message: _error!,
                    ),
                  ),
                ],
                const SizedBox(height: 28),
                FilledButton(
                  key: const ValueKey('save-goal'),
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            XyActivity(radius: 8),
                            SizedBox(width: 8),
                            Text('保存中'),
                          ],
                        )
                      : const Text('保存'),
                ),
                const SizedBox(height: 6),
                TextButton(
                  onPressed: _saving ? null : _leave,
                  child: const Text('取消'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A row whose value is chosen from an iOS action sheet.
class _ChoiceRow<T> extends StatelessWidget {
  const _ChoiceRow({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    super.key,
  });

  final String label;
  final T value;
  final List<(T, String)> options;
  final ValueChanged<T>? onChanged;

  Future<void> _choose(BuildContext context) async {
    final picked = await showCupertinoModalPopup<T>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(label),
        actions: [
          for (final (option, text) in options)
            CupertinoActionSheetAction(
              isDefaultAction: option == value,
              onPressed: () => Navigator.pop(context, option),
              child: Text(text),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
      ),
    );
    if (picked != null && picked != value) onChanged?.call(picked);
  }

  @override
  Widget build(BuildContext context) {
    final xy = context.xy;
    final current = options.firstWhere((option) => option.$1 == value).$2;
    final enabled = onChanged != null;
    final largeText = MediaQuery.textScalerOf(context).scale(17) > 25.5;
    return ListTile(
      enabled: enabled,
      onTap: () => _choose(context),
      title: Text(label),
      subtitle: largeText ? Text(current) : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!largeText) Text(current, style: TextStyle(color: xy.muted)),
          if (enabled) ...[
            const SizedBox(width: 6),
            Icon(
              CupertinoIcons.chevron_up_chevron_down,
              size: 15,
              color: xy.faint,
            ),
          ],
        ],
      ),
    );
  }
}
