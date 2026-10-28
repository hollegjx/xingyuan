import 'dart:convert';

import 'package:characters/characters.dart';

import '../../../shared/local_date.dart';

class PlanningException implements Exception {
  const PlanningException(this.message);
  final String message;
  @override
  String toString() => message;
}

String planningText(Object? value, {required int max, bool empty = false}) {
  if (value is! String ||
      value.characters.length > max ||
      (!empty && value.trim().isEmpty) ||
      RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f]').hasMatch(value)) {
    throw const PlanningException('内容格式不正确，请检查后重试。');
  }
  return value.trim();
}

Map<String, dynamic> planningObject(Object? value, Set<String> keys) {
  if (value is! Map<String, dynamic> ||
      value.length != keys.length ||
      !keys.every(value.containsKey)) {
    throw const PlanningException('计划格式不正确，未创建任何目标。');
  }
  return value;
}

class PlanningRequest {
  PlanningRequest({
    required this.day,
    required String zone,
    required String intent,
    required String preferences,
    required this.availableMinutes,
  }) : zone = planningText(zone, max: 80),
       intent = planningText(intent, max: 1000),
       preferences = planningText(preferences, max: 500, empty: true) {
    if (availableMinutes < 5 || availableMinutes > 240) {
      throw const PlanningException('可用时间需为 5 至 240 分钟。');
    }
  }

  factory PlanningRequest.fromJson(Object? json) {
    final map = planningObject(json, {
      'day',
      'zone',
      'intent',
      'preferences',
      'available_minutes',
    });
    if (map['available_minutes'] is! int) {
      throw const PlanningException('可用时间格式不正确。');
    }
    try {
      return PlanningRequest(
        day: LocalDate.parse(planningText(map['day'], max: 10)),
        zone: planningText(map['zone'], max: 80),
        intent: planningText(map['intent'], max: 1000),
        preferences: planningText(map['preferences'], max: 500, empty: true),
        availableMinutes: map['available_minutes'] as int,
      );
    } on FormatException {
      throw const PlanningException('日期格式不正确。');
    } on ArgumentError {
      throw const PlanningException('日期格式不正确。');
    }
  }

  final LocalDate day;
  final String zone;
  final String intent;
  final String preferences;
  final int availableMinutes;

  Map<String, Object> toJson() => {
    'day': day.key,
    'zone': zone,
    'intent': intent,
    'preferences': preferences,
    'available_minutes': availableMinutes,
  };
}

class PlanTask {
  PlanTask({required String title, required this.minutes})
    : title = planningText(title, max: 60) {
    if (minutes < 1 || minutes > 240) {
      throw const PlanningException('每项任务的预计时间需为 1 至 240 分钟。');
    }
  }

  factory PlanTask.fromJson(Object? json) {
    final map = planningObject(json, {'title', 'minutes'});
    if (map['minutes'] is! int) {
      throw const PlanningException('任务时间格式不正确。');
    }
    return PlanTask(
      title: planningText(map['title'], max: 60),
      minutes: map['minutes'] as int,
    );
  }

  final String title;
  final int minutes;
  Map<String, Object> toJson() => {'title': title, 'minutes': minutes};
}

List<PlanTask> validatePlanTasks(List<PlanTask> tasks, int budget) {
  if (tasks.isEmpty || tasks.length > 6) {
    throw const PlanningException('每份计划需包含 1 至 6 项任务。');
  }
  final titles = <String>{};
  var total = 0;
  for (final task in tasks) {
    if (!titles.add(task.title.toLowerCase())) {
      throw const PlanningException('计划中有重名任务，请修改后再确认。');
    }
    total += task.minutes;
  }
  if (total > budget) {
    throw const PlanningException('预计总时长超过可用时间，请调整后再确认。');
  }
  return List.unmodifiable(tasks);
}

List<PlanTask> parsePlanTasks(Object? json, int budget) {
  final map = planningObject(json, {'tasks'});
  if (map['tasks'] is! List) {
    throw const PlanningException('计划缺少任务列表。');
  }
  return validatePlanTasks(
    (map['tasks'] as List).map(PlanTask.fromJson).toList(),
    budget,
  );
}

String encodePlanTasks(List<PlanTask> tasks) =>
    jsonEncode({'tasks': tasks.map((task) => task.toJson()).toList()});

class DailyPlan {
  DailyPlan({
    required this.id,
    required this.day,
    required this.budget,
    required List<PlanTask> tasks,
    List<int>? appliedGoalIds,
  }) : tasks = validatePlanTasks(tasks, budget),
       appliedGoalIds = appliedGoalIds == null
           ? null
           : List.unmodifiable(appliedGoalIds);

  final String id;
  final LocalDate day;
  final int budget;
  final List<PlanTask> tasks;
  final List<int>? appliedGoalIds;
  int get totalMinutes => tasks.fold(0, (sum, task) => sum + task.minutes);
}
