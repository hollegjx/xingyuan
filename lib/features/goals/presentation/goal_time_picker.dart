import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../../app/theme.dart';

/// Picks a time of day: iOS wheels in a bottom sheet on Apple devices (and
/// at large text sizes, where the Material dial would overlap), the Material
/// dialog elsewhere.
Future<TimeOfDay?> showGoalTimePicker(
  BuildContext context, {
  required TimeOfDay initialTime,
  String title = '开始时间',
}) {
  final large = MediaQuery.textScalerOf(context).scale(14) > 21;
  if (!context.isCupertino && !large) {
    return showTimePicker(
      context: context,
      initialTime: initialTime,
      helpText: title,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
  }

  FocusScope.of(context).unfocus();
  var selected = initialTime;
  return showCupertinoModalPopup<TimeOfDay>(
    context: context,
    builder: (context) {
      final theme = Theme.of(context);
      final xy = context.xy;
      return Material(
        color: xy.card,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
        clipBehavior: Clip.antiAlias,
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: xy.line, width: 0.5),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(
                    children: [
                      TextButton(
                        key: const ValueKey('time-picker-cancel'),
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('取消'),
                      ),
                      Expanded(
                        child: Text(
                          title,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.titleMedium,
                        ),
                      ),
                      TextButton(
                        key: const ValueKey('time-picker-confirm'),
                        onPressed: () => Navigator.of(context).pop(selected),
                        child: const Text(
                          '确定',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SizedBox(
                height: 216,
                child: CupertinoTheme(
                  data: CupertinoThemeData(
                    brightness: theme.brightness,
                    textTheme: CupertinoTextThemeData(
                      dateTimePickerTextStyle: TextStyle(
                        fontSize: 22,
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                  ),
                  child: CupertinoDatePicker(
                    mode: CupertinoDatePickerMode.time,
                    initialDateTime: DateTime(
                      2000,
                      1,
                      1,
                      initialTime.hour,
                      initialTime.minute,
                    ),
                    use24hFormat: true,
                    showTimeSeparator: true,
                    onDateTimeChanged: (value) =>
                        selected = TimeOfDay.fromDateTime(value),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
