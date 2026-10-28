part of 'protocol.dart';

class DayAnalysisEntry {
  DayAnalysisEntry._(
    this.id,
    this.title,
    this.plannedTime,
    this.plannedMinutes,
    this.completed,
    this.completedAt,
    this.text,
  );

  factory DayAnalysisEntry.fromJson(Object? value) {
    final map = _object(value, {
      'id',
      'title',
      'planned_time',
      'planned_minutes',
      'completed',
      'completed_at',
      'text',
    });
    final id = _text(map['id'], 5);
    if (!RegExp(r'^e[1-9][0-9]{0,3}$').hasMatch(id)) _invalid('analysis entry');
    final time = map['planned_time'] == null
        ? null
        : _text(map['planned_time'], 5);
    if (time != null) parseMinute(time);
    final minutes = map['planned_minutes'] == null
        ? null
        : _integer(map['planned_minutes'], 5, 480);
    final completed = _boolean(map['completed']);
    final completedAt = map['completed_at'] == null
        ? null
        : _text(map['completed_at'], 32);
    if (completed != (completedAt != null)) _invalid('analysis completion');
    if (completedAt != null) {
      final instant = DateTime.tryParse(completedAt);
      if (instant == null ||
          !instant.isUtc ||
          instant.toIso8601String() != completedAt) {
        _invalid('analysis completion time');
      }
    }
    return DayAnalysisEntry._(
      id,
      _text(map['title'], 60),
      time,
      minutes,
      completed,
      completedAt,
      _text(map['text'], 500, empty: true),
    );
  }

  final String id;
  final String title;
  final String? plannedTime;
  final int? plannedMinutes;
  final bool completed;
  final String? completedAt;
  final String text;

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'planned_time': plannedTime,
    'planned_minutes': plannedMinutes,
    'completed': completed,
    'completed_at': completedAt,
    'text': text,
  };
}

class DayAnalysisRequest {
  DayAnalysisRequest._(this.requestId, this.now, this.entries);

  factory DayAnalysisRequest.fromJson(Object? value) {
    _bodySize(value);
    final map = _object(value, {'protocol', 'request_id', 'now', 'entries'});
    _protocol(map['protocol']);
    final entries = _list(
      map['entries'],
      1000,
    ).map(DayAnalysisEntry.fromJson).toList();
    if (entries.map((entry) => entry.id).toSet().length != entries.length) {
      _invalid('duplicate analysis entry');
    }
    return DayAnalysisRequest._(
      _id(map['request_id']),
      AssistantNow.fromJson(map['now']),
      List.unmodifiable(entries),
    );
  }

  final String requestId;
  final AssistantNow now;
  final List<DayAnalysisEntry> entries;
  bool get hasNotes => entries.any((entry) => entry.text.trim().isNotEmpty);

  Map<String, Object?> toJson() => {
    'protocol': assistantProtocol,
    'request_id': requestId,
    'now': now.toJson(),
    'entries': entries.map((entry) => entry.toJson()).toList(),
  };
}

class DayAnalysisResponse {
  DayAnalysisResponse._(this.requestId, this.summary, this.suggestions);

  factory DayAnalysisResponse.fromJson(
    Object? value, {
    required DayAnalysisRequest request,
  }) {
    _bodySize(value);
    final map = _object(value, {
      'protocol',
      'request_id',
      'summary',
      'suggestions',
    });
    _protocol(map['protocol']);
    if (_id(map['request_id']) != request.requestId) _invalid('request id');
    final suggestions = _list(
      map['suggestions'],
      2,
    ).map((item) => _text(item, 100)).toList();
    if (request.hasNotes && suggestions.isEmpty) _invalid('missing suggestion');
    if (suggestions.toSet().length != suggestions.length) {
      _invalid('duplicate suggestion');
    }
    return DayAnalysisResponse._(
      request.requestId,
      _text(map['summary'], 180),
      List.unmodifiable(suggestions),
    );
  }

  final String requestId;
  final String summary;
  final List<String> suggestions;

  Map<String, Object?> toJson() => {
    'protocol': assistantProtocol,
    'request_id': requestId,
    'summary': summary,
    'suggestions': suggestions,
  };
}
