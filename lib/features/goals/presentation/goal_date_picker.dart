import 'dart:math' as math;

import 'package:flutter/material.dart';

Future<DateTime?> showGoalDatePicker(
  BuildContext context, {
  required DateTime initialDate,
  required DateTime firstDate,
}) {
  final media = MediaQuery.of(context);
  final theme = Theme.of(context);
  final localizations = MaterialLocalizations.of(context);
  final style = theme.datePickerTheme.dayStyle ?? theme.textTheme.bodyLarge!;
  final painter = TextPainter(
    textDirection: Directionality.of(context),
    textScaler: media.textScaler,
  );
  // The existing portrait calendar has seven cells inside its side padding.
  final calendarWidth = math.min(
    328.0,
    media.size.width - media.padding.horizontal - 16,
  );
  final cellWidth = (calendarWidth - 48) / 7;
  var calendarFits = true;
  for (var day = 1; day <= 31; day++) {
    painter.text = TextSpan(
      text: localizations.formatDecimal(day),
      style: style,
    );
    painter.layout();
    if (painter.width + 8 > cellWidth || painter.height > 40) {
      calendarFits = false;
      break;
    }
  }
  painter.dispose();
  FocusScope.of(context).unfocus();
  return showDialog<DateTime>(
    context: context,
    builder: (context) => calendarFits
        ? DatePickerDialog(
            initialDate: initialDate,
            currentDate: firstDate,
            firstDate: firstDate,
            lastDate: DateTime(9999, 12, 31),
            insetPadding: const EdgeInsets.all(8),
            helpText: '计划日期',
          )
        : _GoalDateInput(initialDate: initialDate, firstDate: firstDate),
  );
}

class _GoalDateInput extends StatefulWidget {
  const _GoalDateInput({required this.initialDate, required this.firstDate});

  final DateTime initialDate;
  final DateTime firstDate;

  @override
  State<_GoalDateInput> createState() => _GoalDateInputState();
}

class _GoalDateInputState extends State<_GoalDateInput> {
  final _form = GlobalKey<FormState>();
  late DateTime? _candidate = widget.initialDate;
  bool _submitted = false;

  void _readCandidate() {
    _candidate = null;
    // Standard date parsing and range validation are owned by the input field.
    _form.currentState!.save();
    setState(() {});
  }

  void _confirm() {
    setState(() => _submitted = true);
    if (!_form.currentState!.validate()) return;
    _form.currentState!.save();
    Navigator.of(context).pop(_candidate);
  }

  String _unit(BuildContext context, int number, String suffix, double width) {
    final text = '$number$suffix';
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: Theme.of(context).textTheme.titleMedium,
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final fits = painter.width <= width;
    painter.dispose();
    return fits ? text : '$number\n$suffix';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final candidate = _candidate;
    return Dialog.fullscreen(
      child: Scaffold(
        appBar: AppBar(leading: const BackButton()),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            child: Form(
              key: _form,
              onChanged: _readCandidate,
              autovalidateMode: _submitted
                  ? AutovalidateMode.onUserInteraction
                  : AutovalidateMode.disabled,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('计划日期', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 16),
                  InputDecorationTheme(
                    data: theme.inputDecorationTheme.copyWith(
                      errorMaxLines: 20,
                    ),
                    child: InputDatePickerFormField(
                      key: const ValueKey('goal-date-input'),
                      initialDate: widget.initialDate,
                      firstDate: widget.firstDate,
                      lastDate: DateTime(9999, 12, 31),
                      fieldLabelText: '日期',
                      errorFormatText: '请输入有效日期（年/月/日）',
                      errorInvalidText: '日期需从今天起，最晚为9999年12月31日',
                      onDateSaved: (value) => _candidate = value,
                    ),
                  ),
                  if (candidate != null) ...[
                    const SizedBox(height: 16),
                    LayoutBuilder(
                      builder: (context, constraints) => Semantics(
                        liveRegion: true,
                        child: Wrap(
                          key: const ValueKey('goal-date-candidate'),
                          spacing: 8,
                          runSpacing: 4,
                          children: [
                            for (final (number, suffix) in [
                              (candidate.year, '年'),
                              (candidate.month, '月'),
                              (candidate.day, '日'),
                            ])
                              Text(
                                _unit(
                                  context,
                                  number,
                                  suffix,
                                  constraints.maxWidth,
                                ),
                                semanticsLabel: '$number$suffix',
                                style: theme.textTheme.titleMedium,
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  TextButton(
                    key: const ValueKey('goal-date-cancel'),
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                  const SizedBox(height: 8),
                  FilledButton(
                    key: const ValueKey('goal-date-confirm'),
                    onPressed: _confirm,
                    child: const Text('确定'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
