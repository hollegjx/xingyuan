import 'package:xingyuan_core/xingyuan_core.dart';

class GoalTiming {
  GoalTiming({this.startMinute, this.durationMinutes}) {
    final start = startMinute;
    final duration = durationMinutes;
    if (start != null && (start < 0 || start > 1439)) {
      throw const FormatException('开始时间需在当天 00:00 至 23:59 之间');
    }
    if (duration != null && (duration < 5 || duration > 480)) {
      throw const FormatException('预计分钟需为 5 至 480');
    }
    if (start != null && duration != null && start + duration > 1440) {
      throw const FormatException('开始时间与预计分钟不能跨过当天 24:00');
    }
  }

  final int? startMinute;
  final int? durationMinutes;

  String get label => [
    if (startMinute != null) formatMinute(startMinute!),
    if (durationMinutes != null) '$durationMinutes 分钟',
  ].join(' · ');

  bool overlaps(GoalTiming other) {
    final start = startMinute;
    final otherStart = other.startMinute;
    if (start == null || otherStart == null) return false;
    // A missing duration is a point, not an invented time interval.
    if (start == otherStart) return true;
    if (start < otherStart) {
      return durationMinutes != null && start + durationMinutes! > otherStart;
    }
    return other.durationMinutes != null &&
        otherStart + other.durationMinutes! > start;
  }
}
