part of 'protocol.dart';

enum SharingCommandKind { enable, stop, publish, remove, reply, deleteReply }

const sharingCommandRoutes = {
  '/v1/companion/sharing/enable': SharingCommandKind.enable,
  '/v1/companion/sharing/stop': SharingCommandKind.stop,
  '/v1/companion/records/publish': SharingCommandKind.publish,
  '/v1/companion/records/remove': SharingCommandKind.remove,
  '/v1/companion/replies/send': SharingCommandKind.reply,
  '/v1/companion/replies/remove': SharingCommandKind.deleteReply,
};
const sharingGrantsRoute = '/v1/companion/sharing/list';
const sharedFeedRoute = '/v1/companion/records/list';
const sharedRecordRoute = '/v1/companion/records/get';
const sharedRepliesRoute = '/v1/companion/replies/list';
const sharingReadRoutes = {
  sharingGrantsRoute,
  sharedFeedRoute,
  sharedRecordRoute,
  sharedRepliesRoute,
};
const companionPageSize = 20;
const _maxSequence = 0x1fffffffffffff;

class SharingCommand {
  SharingCommand._({
    required this.kind,
    required this.operationId,
    required this.groupId,
    this.goalId,
    this.grantId,
    this.recordId,
    this.replyId,
    this.sourceId,
    this.baseRevision,
    this.title,
    this.occurredAt,
    this.completedAt,
    this.shareDetails,
    this.text,
    this.photoIds = const [],
  });

  factory SharingCommand.fromJson(SharingCommandKind kind, Object? value) {
    _bodySize(value);
    final fields = switch (kind) {
      SharingCommandKind.enable => {'goal_id'},
      SharingCommandKind.stop => {'grant_id'},
      SharingCommandKind.publish => {
        'grant_id',
        'source_id',
        'base_revision',
        'title',
        'occurred_at',
        'completed_at',
        'share_details',
        'text',
        'photo_ids',
      },
      SharingCommandKind.remove => {'record_id'},
      SharingCommandKind.reply => {'record_id', 'text'},
      SharingCommandKind.deleteReply => {'reply_id'},
    };
    final map = _object(value, {
      'protocol',
      'operation_id',
      'group_id',
      ...fields,
    });
    _checkCompanionProtocol(map['protocol']);
    final publish = kind == SharingCommandKind.publish;
    final photos = publish ? _photoIds(map['photo_ids'], 3) : const <String>[];
    final text = publish || kind == SharingCommandKind.reply
        ? _text(map['text'], publish ? 500 : 300, empty: publish)
        : null;
    final details = publish ? _boolean(map['share_details']) : null;
    final completed = publish && map['completed_at'] != null
        ? _companionInstant(map['completed_at'])
        : null;
    final occurred = publish ? _companionInstant(map['occurred_at']) : null;
    if (publish) {
      if (!details! && (text!.isNotEmpty || photos.isNotEmpty)) {
        _invalid('unconsented record details');
      }
      if (completed == null && text!.trim().isEmpty && photos.isEmpty) {
        _invalid('absent progress');
      }
      if (completed != null && completed.isAfter(occurred!)) {
        _invalid('completion after event');
      }
    }
    return SharingCommand._(
      kind: kind,
      operationId: _companionId(map['operation_id']),
      groupId: _companionId(map['group_id']),
      goalId: fields.contains('goal_id') ? _companionId(map['goal_id']) : null,
      grantId: fields.contains('grant_id')
          ? _companionId(map['grant_id'])
          : null,
      recordId: fields.contains('record_id')
          ? _companionId(map['record_id'])
          : null,
      replyId: fields.contains('reply_id')
          ? _companionId(map['reply_id'])
          : null,
      sourceId: publish ? _companionId(map['source_id']) : null,
      baseRevision: publish
          ? _integer(map['base_revision'], 0, _maxSequence)
          : null,
      title: publish ? _text(map['title'], 100) : null,
      occurredAt: occurred,
      completedAt: completed,
      shareDetails: details,
      text: text,
      photoIds: photos,
    );
  }

  final SharingCommandKind kind;
  final String operationId;
  final String groupId;
  final String? goalId;
  final String? grantId;
  final String? recordId;
  final String? replyId;
  final String? sourceId;
  final int? baseRevision;
  final String? title;
  final DateTime? occurredAt;
  final DateTime? completedAt;
  final bool? shareDetails;
  final String? text;
  final List<String> photoIds;

  String get fingerprintInput => jsonEncode({'kind': kind.name, ...toJson()});

  Map<String, Object?> toJson() => {
    'protocol': companionProtocol,
    'operation_id': operationId,
    'group_id': groupId,
    if (goalId != null) 'goal_id': goalId,
    if (grantId != null) 'grant_id': grantId,
    if (recordId != null) 'record_id': recordId,
    if (replyId != null) 'reply_id': replyId,
    if (kind == SharingCommandKind.publish) ...{
      'source_id': sourceId,
      'base_revision': baseRevision,
      'title': title,
      'occurred_at': occurredAt!.toIso8601String(),
      'completed_at': completedAt?.toIso8601String(),
      'share_details': shareDetails,
      'photo_ids': photoIds,
    },
    if (text != null) 'text': text,
  };
}

List<String> _photoIds(Object? value, int maximum) {
  final result = _list(value, maximum).map(_companionId).toList();
  if (result.toSet().length != result.length) _invalid('duplicate photo');
  return List.unmodifiable(result);
}

class SharingGrant {
  SharingGrant._(this.id, this.goalId, this.enabledAt, this.sequence);
  factory SharingGrant.fromJson(Object? value) {
    final map = _object(value, {'id', 'goal_id', 'enabled_at', 'sequence'});
    return SharingGrant._(
      _companionId(map['id']),
      _companionId(map['goal_id']),
      _companionInstant(map['enabled_at']),
      _integer(map['sequence'], 1, _maxSequence),
    );
  }
  final String id;
  final String goalId;
  final DateTime enabledAt;
  final int sequence;
  Map<String, Object?> toJson() => {
    'id': id,
    'goal_id': goalId,
    'enabled_at': enabledAt.toIso8601String(),
    'sequence': sequence,
  };
}

class SharingGrants {
  SharingGrants._(this.groupId, this.grants, this.revision, this.nextBefore);
  factory SharingGrants.fromJson(
    Object? value, {
    required SharedPageRequest request,
  }) {
    _bodySize(value);
    final map = _object(value, {
      'protocol',
      'group_id',
      'grants',
      'revision',
      'next_before',
    });
    _checkCompanionProtocol(map['protocol']);
    if (_companionId(map['group_id']) != request.groupId ||
        request.recordId != null) {
      _invalid('group');
    }
    final grants = _list(
      map['grants'],
      companionPageSize,
    ).map(SharingGrant.fromJson).toList();
    if (grants.map((g) => g.id).toSet().length != grants.length ||
        grants.map((g) => g.goalId).toSet().length != grants.length) {
      _invalid('duplicate grant');
    }
    final revision = _integer(map['revision'], 0, _maxSequence);
    final next = map['next_before'] == null
        ? null
        : _integer(map['next_before'], 1, _maxSequence);
    _checkPage(
      request,
      revision,
      grants.map((g) => g.id).toList(),
      grants.map((g) => g.sequence).toList(),
      next,
    );
    return SharingGrants._(
      request.groupId,
      List.unmodifiable(grants),
      revision,
      next,
    );
  }
  final String groupId;
  final List<SharingGrant> grants;
  final int revision;
  final int? nextBefore;
  Map<String, Object?> toJson() => {
    'protocol': companionProtocol,
    'group_id': groupId,
    'grants': grants.map((g) => g.toJson()).toList(),
    'revision': revision,
    'next_before': nextBefore,
  };
}

class SharingReceipt {
  SharingReceipt._(
    this.operationId,
    this.groupId,
    this.resourceId,
    this.revision,
  );
  factory SharingReceipt.fromJson(
    Object? value, {
    required SharingCommand command,
  }) {
    final map = _object(value, {
      'protocol',
      'operation_id',
      'group_id',
      'resource_id',
      'revision',
    });
    _checkCompanionProtocol(map['protocol']);
    if (_companionId(map['operation_id']) != command.operationId ||
        _companionId(map['group_id']) != command.groupId) {
      _invalid('receipt');
    }
    final resource = _companionId(map['resource_id']);
    final revision = _integer(map['revision'], 0, _maxSequence);
    final expectedResource = switch (command.kind) {
      SharingCommandKind.stop => command.grantId,
      SharingCommandKind.remove => command.recordId,
      SharingCommandKind.deleteReply => command.replyId,
      _ => null,
    };
    final expectedRevision = switch (command.kind) {
      SharingCommandKind.publish => command.baseRevision! + 1,
      SharingCommandKind.reply => 1,
      _ => 0,
    };
    if ((expectedResource != null && resource != expectedResource) ||
        revision != expectedRevision) {
      _invalid('receipt result');
    }
    return SharingReceipt._(
      command.operationId,
      command.groupId,
      resource,
      revision,
    );
  }
  final String operationId;
  final String groupId;
  final String resourceId;
  final int revision;
  Map<String, Object?> toJson() => {
    'protocol': companionProtocol,
    'operation_id': operationId,
    'group_id': groupId,
    'resource_id': resourceId,
    'revision': revision,
  };
}

class SharedRecord {
  SharedRecord._({
    required this.id,
    required this.authorId,
    required this.grantId,
    required this.sequence,
    required this.revision,
    required this.title,
    required this.occurredAt,
    required this.completedAt,
    required this.text,
    required this.photoIds,
  });
  factory SharedRecord.fromJson(Object? value) {
    _bodySize(value);
    final map = _object(value, {
      'id',
      'author_id',
      'grant_id',
      'sequence',
      'revision',
      'title',
      'occurred_at',
      'completed_at',
      'text',
      'photo_ids',
    });
    final text = _text(map['text'], 500, empty: true);
    final photos = _photoIds(map['photo_ids'], 3);
    final completed = map['completed_at'] == null
        ? null
        : _companionInstant(map['completed_at']);
    final occurred = _companionInstant(map['occurred_at']);
    if ((completed == null && text.trim().isEmpty && photos.isEmpty) ||
        (completed != null && completed.isAfter(occurred))) {
      _invalid('progress');
    }
    return SharedRecord._(
      id: _companionId(map['id']),
      authorId: _companionId(map['author_id']),
      grantId: _companionId(map['grant_id']),
      sequence: _integer(map['sequence'], 1, _maxSequence),
      revision: _integer(map['revision'], 1, _maxSequence),
      title: _text(map['title'], 100),
      occurredAt: occurred,
      completedAt: completed,
      text: text,
      photoIds: photos,
    );
  }
  final String id;
  final String authorId;
  final String grantId;
  final int sequence;
  final int revision;
  final String title;
  final DateTime occurredAt;
  final DateTime? completedAt;
  final String text;
  final List<String> photoIds;
  Map<String, Object?> toJson() => {
    'id': id,
    'author_id': authorId,
    'grant_id': grantId,
    'sequence': sequence,
    'revision': revision,
    'title': title,
    'occurred_at': occurredAt.toIso8601String(),
    'completed_at': completedAt?.toIso8601String(),
    'text': text,
    'photo_ids': photoIds,
  };
}

class SharedReply {
  SharedReply._(
    this.id,
    this.recordId,
    this.authorId,
    this.sequence,
    this.text,
    this.createdAt,
  );
  factory SharedReply.fromJson(Object? value) {
    _bodySize(value);
    final map = _object(value, {
      'id',
      'record_id',
      'author_id',
      'sequence',
      'text',
      'created_at',
    });
    return SharedReply._(
      _companionId(map['id']),
      _companionId(map['record_id']),
      _companionId(map['author_id']),
      _integer(map['sequence'], 1, _maxSequence),
      _text(map['text'], 300),
      _companionInstant(map['created_at']),
    );
  }
  final String id;
  final String recordId;
  final String authorId;
  final int sequence;
  final String text;
  final DateTime createdAt;
  Map<String, Object?> toJson() => {
    'id': id,
    'record_id': recordId,
    'author_id': authorId,
    'sequence': sequence,
    'text': text,
    'created_at': createdAt.toIso8601String(),
  };
}

class SharedPageRequest {
  SharedPageRequest._(
    this.groupId,
    this.recordId,
    this.beforeSequence,
    this.revision,
  );
  factory SharedPageRequest.fromJson(Object? value, {bool replies = false}) {
    _bodySize(value);
    final map = _object(value, {
      'protocol',
      'group_id',
      'before_sequence',
      'revision',
      if (replies) 'record_id',
    });
    _checkCompanionProtocol(map['protocol']);
    final before = map['before_sequence'] == null
        ? null
        : _integer(map['before_sequence'], 1, _maxSequence);
    final revision = map['revision'] == null
        ? null
        : _integer(map['revision'], 0, _maxSequence);
    if ((before == null) != (revision == null)) _invalid('pagination cursor');
    return SharedPageRequest._(
      _companionId(map['group_id']),
      replies ? _companionId(map['record_id']) : null,
      before,
      revision,
    );
  }
  final String groupId;
  final String? recordId;
  final int? beforeSequence;
  final int? revision;
  Map<String, Object?> toJson() => {
    'protocol': companionProtocol,
    'group_id': groupId,
    if (recordId != null) 'record_id': recordId,
    'before_sequence': beforeSequence,
    'revision': revision,
  };
}

class SharedFeedPage {
  SharedFeedPage._(this.groupId, this.revision, this.records, this.nextBefore);
  factory SharedFeedPage.fromJson(
    Object? value, {
    required SharedPageRequest request,
  }) {
    _bodySize(value);
    final map = _object(value, {
      'protocol',
      'group_id',
      'revision',
      'records',
      'next_before',
    });
    _checkCompanionProtocol(map['protocol']);
    if (_companionId(map['group_id']) != request.groupId ||
        request.recordId != null) {
      _invalid('feed group');
    }
    final revision = _integer(map['revision'], 0, _maxSequence);
    final rows = _list(
      map['records'],
      companionPageSize,
    ).map(SharedRecord.fromJson).toList();
    final next = map['next_before'] == null
        ? null
        : _integer(map['next_before'], 1, _maxSequence);
    _checkPage(
      request,
      revision,
      rows.map((r) => r.id).toList(),
      rows.map((r) => r.sequence).toList(),
      next,
    );
    return SharedFeedPage._(
      request.groupId,
      revision,
      List.unmodifiable(rows),
      next,
    );
  }
  final String groupId;
  final int revision;
  final List<SharedRecord> records;
  final int? nextBefore;
  Map<String, Object?> toJson() => {
    'protocol': companionProtocol,
    'group_id': groupId,
    'revision': revision,
    'records': records.map((r) => r.toJson()).toList(),
    'next_before': nextBefore,
  };
}

class SharedRepliesPage {
  SharedRepliesPage._(
    this.groupId,
    this.recordId,
    this.revision,
    this.replies,
    this.nextBefore,
  );
  factory SharedRepliesPage.fromJson(
    Object? value, {
    required SharedPageRequest request,
  }) {
    _bodySize(value);
    final map = _object(value, {
      'protocol',
      'group_id',
      'record_id',
      'revision',
      'replies',
      'next_before',
    });
    _checkCompanionProtocol(map['protocol']);
    if (_companionId(map['group_id']) != request.groupId ||
        _companionId(map['record_id']) != request.recordId) {
      _invalid('replies target');
    }
    final revision = _integer(map['revision'], 0, _maxSequence);
    final rows = _list(
      map['replies'],
      companionPageSize,
    ).map(SharedReply.fromJson).toList();
    final next = map['next_before'] == null
        ? null
        : _integer(map['next_before'], 1, _maxSequence);
    if (rows.any((r) => r.recordId != request.recordId)) {
      _invalid('reply record');
    }
    _checkPage(
      request,
      revision,
      rows.map((r) => r.id).toList(),
      rows.map((r) => r.sequence).toList(),
      next,
    );
    return SharedRepliesPage._(
      request.groupId,
      request.recordId!,
      revision,
      List.unmodifiable(rows),
      next,
    );
  }
  final String groupId;
  final String recordId;
  final int revision;
  final List<SharedReply> replies;
  final int? nextBefore;
  Map<String, Object?> toJson() => {
    'protocol': companionProtocol,
    'group_id': groupId,
    'record_id': recordId,
    'revision': revision,
    'replies': replies.map((r) => r.toJson()).toList(),
    'next_before': nextBefore,
  };
}

void _checkPage(
  SharedPageRequest request,
  int revision,
  List<String> ids,
  List<int> sequences,
  int? next,
) {
  if ((request.revision != null && revision != request.revision) ||
      ids.toSet().length != ids.length ||
      (next != null && (sequences.isEmpty || next != sequences.last))) {
    _invalid('page consistency');
  }
  var previous = request.beforeSequence;
  for (final sequence in sequences) {
    if (previous != null && sequence >= previous) _invalid('page order');
    previous = sequence;
  }
}

class SharedResourceRequest {
  SharedResourceRequest._(this.groupId, this.recordId);
  factory SharedResourceRequest.fromJson(Object? value, {bool record = false}) {
    _bodySize(value);
    final map = _object(value, {
      'protocol',
      'group_id',
      if (record) 'record_id',
    });
    _checkCompanionProtocol(map['protocol']);
    return SharedResourceRequest._(
      _companionId(map['group_id']),
      record ? _companionId(map['record_id']) : null,
    );
  }
  final String groupId;
  final String? recordId;
  Map<String, Object?> toJson() => {
    'protocol': companionProtocol,
    'group_id': groupId,
    if (recordId != null) 'record_id': recordId,
  };
}
