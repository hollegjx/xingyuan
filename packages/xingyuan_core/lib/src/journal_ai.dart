part of 'protocol.dart';

class PolishNoteRequest {
  PolishNoteRequest._(this.requestId, this.text);

  factory PolishNoteRequest.fromJson(Object? value) {
    _bodySize(value);
    final map = _object(value, {'protocol', 'request_id', 'text'});
    _protocol(map['protocol']);
    return PolishNoteRequest._(
      _id(map['request_id']),
      _text(map['text'], 1000),
    );
  }

  final String requestId;
  final String text;
  Map<String, Object?> toJson() => {
    'protocol': assistantProtocol,
    'request_id': requestId,
    'text': text,
  };
}

class PolishNoteResponse {
  PolishNoteResponse._(this.requestId, this.rewrite, this.tips);

  factory PolishNoteResponse.fromJson(
    Object? value, {
    required PolishNoteRequest request,
  }) {
    _bodySize(value);
    final map = _object(value, {'protocol', 'request_id', 'rewrite', 'tips'});
    _protocol(map['protocol']);
    if (_id(map['request_id']) != request.requestId) _invalid('request id');
    final tips = _list(map['tips'], 2).map((tip) => _text(tip, 100)).toList();
    if (tips.isEmpty || tips.toSet().length != tips.length) {
      _invalid('journal tips');
    }
    return PolishNoteResponse._(
      request.requestId,
      _text(map['rewrite'], 1000),
      List.unmodifiable(tips),
    );
  }

  final String requestId;
  final String rewrite;
  final List<String> tips;
  Map<String, Object?> toJson() => {
    'protocol': assistantProtocol,
    'request_id': requestId,
    'rewrite': rewrite,
    'tips': tips,
  };
}

class DiarySourceEntry {
  DiarySourceEntry._(this.title, this.completed, this.text);

  factory DiarySourceEntry.fromJson(Object? value) {
    final map = _object(value, {'title', 'completed', 'text'});
    return DiarySourceEntry._(
      _text(map['title'], 60),
      _boolean(map['completed']),
      _text(map['text'], 500, empty: true),
    );
  }

  final String title;
  final bool completed;
  final String text;
  Map<String, Object?> toJson() => {
    'title': title,
    'completed': completed,
    'text': text,
  };
}

class GenerateDiaryRequest {
  GenerateDiaryRequest._(this.requestId, this.day, this.entries, this.notes);

  factory GenerateDiaryRequest.fromJson(Object? value) {
    _bodySize(value);
    final map = _object(value, {
      'protocol',
      'request_id',
      'day',
      'entries',
      'notes',
    });
    _protocol(map['protocol']);
    return GenerateDiaryRequest._(
      _id(map['request_id']),
      _date(map['day']),
      List.unmodifiable(
        _list(map['entries'], 1000).map(DiarySourceEntry.fromJson),
      ),
      List.unmodifiable(
        _list(map['notes'], 1000).map((text) => _text(text, 1000, empty: true)),
      ),
    );
  }

  final String requestId;
  final CalendarDate day;
  final List<DiarySourceEntry> entries;
  final List<String> notes;
  bool get hasMaterial =>
      entries.any((entry) => entry.completed || entry.text.trim().isNotEmpty) ||
      notes.any((text) => text.trim().isNotEmpty);

  Map<String, Object?> toJson() => {
    'protocol': assistantProtocol,
    'request_id': requestId,
    'day': day.key,
    'entries': entries.map((entry) => entry.toJson()).toList(),
    'notes': notes,
  };
}

class GenerateDiaryResponse {
  GenerateDiaryResponse._(
    this.requestId,
    this.draft,
    this.insufficientMaterial,
  );

  factory GenerateDiaryResponse.fromJson(
    Object? value, {
    required GenerateDiaryRequest request,
  }) {
    _bodySize(value);
    final map = _object(value, {'protocol', 'request_id', 'status', 'draft'});
    _protocol(map['protocol']);
    if (_id(map['request_id']) != request.requestId) _invalid('request id');
    if (!['draft', 'insufficient_material'].contains(map['status'])) {
      _invalid('diary status');
    }
    final insufficient = map['status'] == 'insufficient_material';
    final draft = _text(map['draft'], 1500, empty: insufficient);
    if ((insufficient && draft.isNotEmpty) ||
        (!request.hasMaterial && !insufficient)) {
      _invalid('diary material');
    }
    return GenerateDiaryResponse._(request.requestId, draft, insufficient);
  }

  factory GenerateDiaryResponse.insufficient(GenerateDiaryRequest request) =>
      GenerateDiaryResponse._(request.requestId, '', true);

  final String requestId;
  final String draft;
  final bool insufficientMaterial;
  Map<String, Object?> toJson() => {
    'protocol': assistantProtocol,
    'request_id': requestId,
    'status': insufficientMaterial ? 'insufficient_material' : 'draft',
    'draft': draft,
  };
}
