import 'dart:convert';
import 'dart:typed_data';

import 'package:characters/characters.dart';

import 'calendar_date.dart';

part 'day_analysis.dart';
part 'journal_ai.dart';
part 'pairing.dart';
part 'sharing.dart';
part 'publication_resolution.dart';
part 'companion_media.dart';
part 'companion_chat.dart';

const assistantProtocol = 'xingyuan.assistant.v1';
const assistantBodyLimit = 64 * 1024;
const memoryCategories = ['作息', '偏好', '目标与背景', '近期约束', '其他'];

Never _invalid(String rule) => throw FormatException('Invalid assistant $rule');
Map<String, dynamic> _object(
  Object? value,
  Set<String> required, [
  Set<String> optional = const {},
]) {
  if (value is! Map<String, dynamic> ||
      !required.every(value.containsKey) ||
      !value.keys.every(
        (key) => required.contains(key) || optional.contains(key),
      )) {
    _invalid('fields');
  }
  return value;
}

String _text(Object? value, int max, {bool empty = false}) {
  if (value is! String ||
      (!empty && value.trim().isEmpty) ||
      value.characters.length > max) {
    _invalid('text');
  }
  return value;
}

String _id(Object? value) {
  final result = _text(value, 128);
  if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(result)) _invalid('id');
  return result;
}

int _integer(Object? value, int min, int max) {
  if (value is! int || value < min || value > max) _invalid('integer');
  return value;
}

bool _boolean(Object? value) {
  if (value is! bool) _invalid('boolean');
  return value;
}

List<dynamic> _list(Object? value, int max) {
  if (value is! List || value.length > max) _invalid('list');
  return value;
}

String _category(Object? value) {
  if (!memoryCategories.contains(value)) _invalid('memory category');
  return value as String;
}

CalendarDate _date(Object? value) => CalendarDate.parse(_text(value, 10));
CalendarDate? _optionalDate(Object? value) =>
    value == null ? null : _date(value);
String? _summary(Object? value) => value == null ? null : _text(value, 1500);
void _protocol(Object? value) {
  if (value != assistantProtocol) _invalid('protocol');
}

void _bodySize(Object? value) {
  if (utf8.encode(jsonEncode(value)).length > assistantBodyLimit) {
    _invalid('body size');
  }
}

Object? decodeAssistantJson(String source) {
  if (utf8.encode(source).length > assistantBodyLimit) _invalid('body size');
  try {
    return jsonDecode(source);
  } on FormatException {
    // JSON decoder errors otherwise echo potentially private request content.
    _invalid('JSON');
  }
}

int parseMinute(String value) {
  if (!RegExp(r'^([01][0-9]|2[0-3]):[0-5][0-9]$').hasMatch(value)) {
    _invalid('time');
  }
  return int.parse(value.substring(0, 2)) * 60 + int.parse(value.substring(3));
}

String formatMinute(int minute) {
  _integer(minute, 0, 1439);
  return '${(minute ~/ 60).toString().padLeft(2, '0')}:'
      '${(minute % 60).toString().padLeft(2, '0')}';
}

class AssistantNow {
  AssistantNow._(this.date, this.time, this.timeZone);
  factory AssistantNow.fromJson(Object? value) {
    final map = _object(value, {'date', 'time', 'weekday', 'time_zone'});
    final date = _date(map['date']);
    date.addDays(13);
    if (_integer(map['weekday'], 1, 7) != date.weekday) _invalid('weekday');
    final time = _text(map['time'], 5);
    parseMinute(time);
    final zone = _text(map['time_zone'], 100);
    if (!RegExp(r'^(UTC|[A-Za-z_+-]+(?:/[A-Za-z0-9_+\-]+)+)$').hasMatch(zone)) {
      _invalid('time zone');
    }
    return AssistantNow._(date, time, zone);
  }
  final CalendarDate date;
  final String time;
  final String timeZone;
  Map<String, Object> toJson() => {
    'date': date.key,
    'time': time,
    'weekday': date.weekday,
    'time_zone': timeZone,
  };
}

class AssistantMessage {
  AssistantMessage._(this.role, this.text);
  factory AssistantMessage.fromJson(Object? value) {
    final map = _object(value, {'role', 'text'});
    if (!['user', 'assistant'].contains(map['role'])) _invalid('message role');
    return AssistantMessage._(map['role'] as String, _text(map['text'], 12000));
  }
  final String role;
  final String text;
  Map<String, Object> toJson() => {'role': role, 'text': text};
}

class AssistantMemory {
  AssistantMemory._(this.id, this.category, this.text, this.expiresOn);
  factory AssistantMemory.fromJson(Object? value) {
    final map = _object(value, {'id', 'category', 'text', 'expires_on'});
    // Lossless legacy splits can contain a whitespace-only segment. This is
    // existing context, not permission to create blank memories via operations.
    final text = _text(map['text'], 200, empty: true);
    if (text.isEmpty) _invalid('memory text');
    return AssistantMemory._(
      _id(map['id']),
      _category(map['category']),
      text,
      _optionalDate(map['expires_on']),
    );
  }
  final String id;
  final String category;
  final String text;
  final CalendarDate? expiresOn;
  Map<String, Object?> toJson() => {
    'id': id,
    'category': category,
    'text': text,
    'expires_on': expiresOn?.key,
  };
}

class PlanTask {
  PlanTask._(this.title, this.date, this.weekdays, this.time, this.minutes);
  factory PlanTask.fromJson(Object? value, {required bool habit}) {
    final map = _object(value, {
      'title',
      'time',
      'minutes',
      if (habit) 'start_date' else 'date',
      if (habit) 'weekdays',
    });
    final title = _text(map['title'], 60);
    final date = _date(map[habit ? 'start_date' : 'date']);
    final time = map['time'] == null ? null : _text(map['time'], 5);
    final minute = time == null ? null : parseMinute(time);
    final minutes = map['minutes'] == null
        ? null
        : _integer(map['minutes'], 5, 480);
    if (minute != null && minutes != null && minute + minutes > 1440) {
      _invalid('midnight overrun');
    }
    final weekdays = habit
        ? _list(map['weekdays'], 7).map((day) => _integer(day, 1, 7)).toList()
        : null;
    if (weekdays != null &&
        (weekdays.isEmpty || weekdays.toSet().length != weekdays.length)) {
      _invalid('habit weekdays');
    }
    weekdays?.sort();
    return PlanTask._(
      title,
      date,
      weekdays == null ? null : List.unmodifiable(weekdays),
      time,
      minutes,
    );
  }
  final String title;
  final CalendarDate date;
  final List<int>? weekdays;
  final String? time;
  final int? minutes;
  bool get isHabit => weekdays != null;
  bool occursOn(CalendarDate day) => isHabit
      ? !day.isBefore(date) && weekdays!.contains(day.weekday)
      : date == day;
  Map<String, Object?> toJson() => {
    'title': title,
    if (isHabit) 'start_date': date.key else 'date': date.key,
    if (isHabit) 'weekdays': weekdays,
    'time': time,
    'minutes': minutes,
  };
}

class PlanProposal {
  PlanProposal._(this.tasks, this.habits);
  factory PlanProposal.fromJson(Object? value, {required CalendarDate today}) {
    final map = _object(value, {'tasks', 'habits'});
    final tasks = _list(
      map['tasks'],
      40,
    ).map((row) => PlanTask.fromJson(row, habit: false)).toList();
    final habits = _list(
      map['habits'],
      5,
    ).map((row) => PlanTask.fromJson(row, habit: true)).toList();
    if (tasks.isEmpty && habits.isEmpty) _invalid('empty plan');
    final last = today.addDays(13);
    for (final task in [...tasks, ...habits]) {
      if (task.date.isBefore(today) || task.date.isAfter(last)) {
        _invalid('date range');
      }
      if (task.isHabit && task.date != today) _invalid('habit start date');
    }
    for (var offset = 0; offset < 14; offset++) {
      final day = today.addDays(offset);
      if ([...tasks, ...habits].where((task) => task.occursOn(day)).length >
          12) {
        _invalid('daily capacity');
      }
    }
    return PlanProposal._(List.unmodifiable(tasks), List.unmodifiable(habits));
  }
  final List<PlanTask> tasks;
  final List<PlanTask> habits;
  Map<String, Object> toJson() => {
    'tasks': tasks.map((task) => task.toJson()).toList(),
    'habits': habits.map((task) => task.toJson()).toList(),
  };
}

class ScheduleDay {
  ScheduleDay._(this.date, this.items);
  factory ScheduleDay.fromJson(Object? value, CalendarDate today) {
    final map = _object(value, {'date', 'items'});
    final date = _date(map['date']);
    if (date.isBefore(today) || date.isAfter(today.addDays(13))) {
      _invalid('schedule date');
    }
    final items = _list(map['items'], assistantBodyLimit).map((value) {
      final item = _object(value, {'title', 'kind', 'time', 'minutes', 'done'});
      _text(item['title'], 60);
      if (!['habit', 'single'].contains(item['kind'])) {
        _invalid('schedule kind');
      }
      _boolean(item['done']);
      PlanTask.fromJson({
        'title': item['title'],
        'date': date.key,
        'time': item['time'],
        'minutes': item['minutes'],
      }, habit: false);
      return Map<String, Object?>.unmodifiable(item);
    }).toList();
    return ScheduleDay._(date, List.unmodifiable(items));
  }
  final CalendarDate date;
  final List<Map<String, Object?>> items;
  Map<String, Object> toJson() => {'date': date.key, 'items': items};
}

class GoalStats {
  GoalStats._(this.title, this.kind, this.scheduled, this.done);
  factory GoalStats.fromJson(Object? value) {
    final map = _object(value, {'title', 'kind', 'scheduled_14d', 'done_14d'});
    final title = _text(map['title'], 60);
    if (!['single', 'habit'].contains(map['kind'])) _invalid('stats kind');
    final scheduled = _integer(map['scheduled_14d'], 0, 14);
    final done = _integer(map['done_14d'], 0, 14);
    // Overdue single tasks can be completed outside their original window.
    if (map['kind'] == 'habit' && done > scheduled) _invalid('stats counts');
    return GoalStats._(title, map['kind'] as String, scheduled, done);
  }
  final String title;
  final String kind;
  final int scheduled;
  final int done;
  Map<String, Object> toJson() => {
    'title': title,
    'kind': kind,
    'scheduled_14d': scheduled,
    'done_14d': done,
  };
}

class TurnRequest {
  TurnRequest._(
    this.requestId,
    this.now,
    this.summary,
    this.messages,
    this.memories,
    this.schedule,
    this.stats,
    this.scheduleTruncated,
    this.autoMemory,
    this.diaryProposals,
  );
  factory TurnRequest.fromJson(Object? value) {
    _bodySize(value);
    final map = _object(
      value,
      {'protocol', 'request_id', 'now', 'summary', 'messages', 'settings'},
      {
        'memories',
        'schedule',
        'stats',
        'schedule_truncated',
        'diary_proposals',
      },
    );
    _protocol(map['protocol']);
    final id = _id(map['request_id']);
    final now = AssistantNow.fromJson(map['now']);
    final summary = _summary(map['summary']);
    final messages = _list(
      map['messages'],
      20,
    ).map(AssistantMessage.fromJson).toList();
    if (messages.isEmpty ||
        messages.last.role != 'user' ||
        messages.last.text.characters.length > 2000 ||
        messages.fold(0, (n, message) => n + message.text.characters.length) >
            12000) {
      _invalid('message budget');
    }
    final settings = _object(map['settings'], {'auto_memory'});
    final memories = map.containsKey('memories')
        ? _list(map['memories'], 200).map(AssistantMemory.fromJson).toList()
        : null;
    if (memories != null) {
      if (memories.map((memory) => memory.id).toSet().length !=
          memories.length) {
        _invalid('duplicate memory');
      }
      if (memories.any(
        (memory) => memory.expiresOn?.isBefore(now.date) ?? false,
      )) {
        _invalid('expired memory');
      }
    }
    final schedule = map.containsKey('schedule')
        ? _list(
            map['schedule'],
            14,
          ).map((row) => ScheduleDay.fromJson(row, now.date)).toList()
        : null;
    if (schedule != null &&
        (jsonEncode(map['schedule']).characters.length > 3000 ||
            schedule.map((day) => day.date).toSet().length !=
                schedule.length)) {
      _invalid('schedule budget');
    }
    final scheduleTruncated = map.containsKey('schedule_truncated')
        ? _boolean(map['schedule_truncated'])
        : false;
    if (map.containsKey('schedule_truncated') && schedule == null) {
      _invalid('schedule truncation without schedule');
    }
    final stats = map.containsKey('stats')
        ? _list(
            map['stats'],
            assistantBodyLimit,
          ).map(GoalStats.fromJson).toList()
        : null;
    return TurnRequest._(
      id,
      now,
      summary,
      List.unmodifiable(messages),
      memories == null ? null : List.unmodifiable(memories),
      schedule == null ? null : List.unmodifiable(schedule),
      stats == null ? null : List.unmodifiable(stats),
      scheduleTruncated,
      _boolean(settings['auto_memory']),
      map.containsKey('diary_proposals')
          ? _boolean(map['diary_proposals'])
          : false,
    );
  }
  final String requestId;
  final AssistantNow now;
  final String? summary;
  final List<AssistantMessage> messages;
  final List<AssistantMemory>? memories;
  final List<ScheduleDay>? schedule;
  final List<GoalStats>? stats;
  final bool scheduleTruncated;
  final bool autoMemory;
  final bool diaryProposals;
  Map<String, Object?> toJson() => {
    'protocol': assistantProtocol,
    'request_id': requestId,
    'now': now.toJson(),
    'summary': summary,
    'messages': messages.map((row) => row.toJson()).toList(),
    if (memories != null)
      'memories': memories!.map((row) => row.toJson()).toList(),
    if (schedule != null)
      'schedule': schedule!.map((row) => row.toJson()).toList(),
    if (stats != null) 'stats': stats!.map((row) => row.toJson()).toList(),
    if (scheduleTruncated) 'schedule_truncated': true,
    'settings': {'auto_memory': autoMemory},
    if (diaryProposals) 'diary_proposals': true,
  };
}

class MemoryOperation {
  MemoryOperation._(this.op, this.id, this.category, this.text, this.expiresOn);
  factory MemoryOperation.fromJson(Object? value, Set<String> sentIds) {
    final map = _object(value, {'op', 'id', 'category', 'text', 'expires_on'});
    if (!['add', 'update', 'delete'].contains(map['op'])) {
      _invalid('memory operation');
    }
    final op = map['op'] as String;
    final id = map['id'] == null ? null : _id(map['id']);
    if (op == 'add' ? id != null : id == null || !sentIds.contains(id)) {
      _invalid('memory reference');
    }
    if (op == 'delete') {
      if (map['category'] != null ||
          map['text'] != null ||
          map['expires_on'] != null) {
        _invalid('delete payload');
      }
      return MemoryOperation._(op, id, null, null, null);
    }
    final text = _text(map['text'], 200);
    if (RegExp(
      r'密码|口令|证件号|身份证|银行卡|信用卡|密钥|password|credential|api[ _-]?key|secret|Bearer\s|sk-[A-Za-z0-9]',
      caseSensitive: false,
    ).hasMatch(text)) {
      _invalid('sensitive memory');
    }
    return MemoryOperation._(
      op,
      id,
      _category(map['category']),
      text,
      _optionalDate(map['expires_on']),
    );
  }
  final String op;
  final String? id;
  final String? category;
  final String? text;
  final CalendarDate? expiresOn;
  Map<String, Object?> toJson() => {
    'op': op,
    'id': id,
    'category': category,
    'text': text,
    'expires_on': expiresOn?.key,
  };
}

class DiaryProposal {
  DiaryProposal._(this.date, this.content);

  factory DiaryProposal.fromJson(Object? value, {required CalendarDate today}) {
    final map = _object(value, {'date', 'content'});
    final date = map['date'] == null
        ? null
        : CalendarDate.parse(_text(map['date'], 10));
    if (date != null && date.isAfter(today)) _invalid('future diary date');
    return DiaryProposal._(date, _text(map['content'], 5000));
  }

  final CalendarDate? date;
  final String content;
  Map<String, Object?> toJson() => {'date': date?.key, 'content': content};
}

class TurnResponse {
  TurnResponse._(
    this.requestId,
    this.reply,
    this.plan,
    this.memoryOps,
    this.diary,
  );
  factory TurnResponse.fromJson(Object? value, {required TurnRequest request}) {
    _bodySize(value);
    final map = _object(value, {
      'protocol',
      'request_id',
      'reply',
      'plan',
      'memory_ops',
    }, request.diaryProposals ? {'diary'} : {});
    _protocol(map['protocol']);
    if (map['request_id'] != request.requestId) _invalid('request correlation');
    final reply = _text(map['reply'], assistantBodyLimit);
    final plan = map['plan'] == null
        ? null
        : PlanProposal.fromJson(map['plan'], today: request.now.date);
    final sentIds =
        request.memories?.map((memory) => memory.id).toSet() ?? <String>{};
    final ops = _list(
      map['memory_ops'],
      5,
    ).map((op) => MemoryOperation.fromJson(op, sentIds)).toList();
    final touched = ops
        .where((op) => op.id != null)
        .map((op) => op.id)
        .toList();
    if (touched.toSet().length != touched.length) {
      _invalid('duplicate memory operation');
    }
    if (!request.autoMemory &&
        ops.isNotEmpty &&
        (!RegExp(r'记住|忘掉|忘记|删除.*记忆|更新.*记忆')
                .hasMatch(request.messages.last.text) ||
            RegExp(r'别记|不要记|不许记|不用记').hasMatch(request.messages.last.text))) {
      _invalid('automatic memory disabled');
    }
    return TurnResponse._(
      request.requestId,
      reply,
      plan,
      List.unmodifiable(ops),
      map['diary'] == null
          ? null
          : DiaryProposal.fromJson(map['diary'], today: request.now.date),
    );
  }
  final String requestId;
  final String reply;
  final PlanProposal? plan;
  final List<MemoryOperation> memoryOps;
  final DiaryProposal? diary;
  Map<String, Object?> toJson() => {
    'protocol': assistantProtocol,
    'request_id': requestId,
    'reply': reply,
    'plan': plan?.toJson(),
    'memory_ops': memoryOps.map((op) => op.toJson()).toList(),
    if (diary != null) 'diary': diary!.toJson(),
  };
}

class SummaryRequest {
  SummaryRequest._(this.requestId, this.summary, this.messages);
  factory SummaryRequest.fromJson(Object? value) {
    _bodySize(value);
    final map = _object(value, {
      'protocol',
      'request_id',
      'summary',
      'messages',
    });
    _protocol(map['protocol']);
    final messages = _list(
      map['messages'],
      assistantBodyLimit,
    ).map(AssistantMessage.fromJson).toList();
    if (messages.isEmpty) _invalid('empty summary input');
    return SummaryRequest._(
      _id(map['request_id']),
      _summary(map['summary']),
      List.unmodifiable(messages),
    );
  }
  final String requestId;
  final String? summary;
  final List<AssistantMessage> messages;
  Map<String, Object?> toJson() => {
    'protocol': assistantProtocol,
    'request_id': requestId,
    'summary': summary,
    'messages': messages.map((message) => message.toJson()).toList(),
  };
}

class SummaryResponse {
  SummaryResponse._(this.requestId, this.summary);
  factory SummaryResponse.fromJson(Object? value, {required String requestId}) {
    _bodySize(value);
    final map = _object(value, {'protocol', 'request_id', 'summary'});
    _protocol(map['protocol']);
    if (map['request_id'] != requestId) _invalid('request correlation');
    return SummaryResponse._(requestId, _text(map['summary'], 1500));
  }
  final String requestId;
  final String summary;
  Map<String, Object> toJson() => {
    'protocol': assistantProtocol,
    'request_id': requestId,
    'summary': summary,
  };
}
