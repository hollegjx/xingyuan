part of 'companion_store.dart';

extension SharingStore on CompanionStore {
  String _requireGroup(String device, String group) {
    final member = _member(device, _time);
    if (_group(member)?['id'] != group) {
      throw const CompanionFailure(403, 'pair_unavailable');
    }
    return member;
  }

  int _revision(String group) =>
      _db.select('SELECT content_revision FROM companion_groups WHERE id=?', [
            group,
          ]).single['content_revision']
          as int;

  void _changed(String group) => _db.execute(
    'UPDATE companion_groups SET content_revision=content_revision+1 WHERE id=?',
    [group],
  );

  int _pageRevision(SharedPageRequest request) {
    final revision = _revision(request.groupId);
    if (request.revision != null && request.revision != revision) {
      throw const CompanionFailure(409, 'snapshot_changed');
    }
    return revision;
  }

  SharingGrants sharingGrants(String device, SharedPageRequest request) =>
      _transaction(() {
        final member = _requireGroup(device, request.groupId);
        final revision = _pageRevision(request);
        final rows = _db.select(
          '''
      SELECT * FROM sharing_grants WHERE group_id=? AND member_id=? AND stopped_at IS NULL
      AND (? IS NULL OR sequence<?) ORDER BY sequence DESC LIMIT ?
    ''',
          [
            request.groupId,
            member,
            request.beforeSequence,
            request.beforeSequence,
            companionPageSize + 1,
          ],
        );
        final grants = rows
            .take(companionPageSize)
            .map(
              (row) => {
                'id': row['id'],
                'goal_id': row['goal_id'],
                'enabled_at': _iso(row['enabled_at'] as int),
                'sequence': row['sequence'],
              },
            )
            .toList();
        return SharingGrants.fromJson({
          'protocol': companionProtocol,
          'group_id': request.groupId,
          'revision': revision,
          'grants': grants,
          'next_before': rows.length > companionPageSize
              ? grants.last['sequence']
              : null,
        }, request: request);
      });

  Row _grant(String group, String id, {String? author, bool active = true}) {
    final row = _db.select(
      'SELECT * FROM sharing_grants WHERE id=? AND group_id=?',
      [id, group],
    ).singleOrNull;
    if (row == null ||
        (author != null && row['member_id'] != author) ||
        (active && row['stopped_at'] != null)) {
      throw const CompanionFailure(403, 'sharing_unavailable');
    }
    return row;
  }

  Row _record(String group, String id, {String? author}) {
    final row = _db
        .select(
          '''
      SELECT r.* FROM shared_records r JOIN sharing_grants g ON g.id=r.grant_id
      WHERE r.id=? AND g.group_id=? AND g.stopped_at IS NULL
    ''',
          [id, group],
        )
        .singleOrNull;
    if (row == null || (author != null && row['author_id'] != author)) {
      throw const CompanionFailure(403, 'record_unavailable');
    }
    return row;
  }

  SharedRecord _recordValue(Row row) => SharedRecord.fromJson({
    'id': row['id'],
    'author_id': row['author_id'],
    'grant_id': row['grant_id'],
    'sequence': row['sequence'],
    'revision': row['revision'],
    'title': row['title'],
    'occurred_at': _iso(row['occurred_at'] as int),
    'completed_at': row['completed_at'] == null
        ? null
        : _iso(row['completed_at'] as int),
    'text': row['text'],
    'photo_ids': jsonDecode(row['photo_ids'] as String),
  });

  SharedRecord sharedRecord(String device, String group, String id) =>
      _transaction(() {
        _requireGroup(device, group);
        return _recordValue(_record(group, id));
      });

  SharedFeedPage sharedFeed(String device, SharedPageRequest request) =>
      _transaction(() {
        _requireGroup(device, request.groupId);
        final revision = _pageRevision(request);
        final rows = _db.select(
          '''
      SELECT r.* FROM shared_records r JOIN sharing_grants g ON g.id=r.grant_id
      WHERE g.group_id=? AND g.stopped_at IS NULL AND (? IS NULL OR r.sequence<?)
      ORDER BY r.sequence DESC LIMIT ?
    ''',
          [
            request.groupId,
            request.beforeSequence,
            request.beforeSequence,
            companionPageSize + 1,
          ],
        );
        final records = rows.map((r) => _recordValue(r).toJson()).toList();
        return SharedFeedPage.fromJson(
          _boundedPage(request, revision, 'records', records),
          request: request,
        );
      });

  SharedRepliesPage sharedReplies(String device, SharedPageRequest request) =>
      _transaction(() {
        _requireGroup(device, request.groupId);
        if (request.recordId == null) {
          throw const FormatException('Missing record');
        }
        _record(request.groupId, request.recordId!);
        final revision = _pageRevision(request);
        final rows = _db.select(
          '''
      SELECT * FROM shared_replies WHERE record_id=? AND (? IS NULL OR sequence<?)
      ORDER BY sequence DESC LIMIT ?
    ''',
          [
            request.recordId,
            request.beforeSequence,
            request.beforeSequence,
            companionPageSize + 1,
          ],
        );
        final replies = rows
            .map(
              (r) => {
                'id': r['id'],
                'record_id': r['record_id'],
                'author_id': r['author_id'],
                'sequence': r['sequence'],
                'text': r['text'],
                'created_at': _iso(r['created_at'] as int),
              },
            )
            .toList();
        return SharedRepliesPage.fromJson(
          _boundedPage(request, revision, 'replies', replies),
          request: request,
        );
      });

  Map<String, Object?> _boundedPage(
    SharedPageRequest request,
    int revision,
    String field,
    List<Map<String, Object?>> rows,
  ) {
    var count = min(rows.length, companionPageSize);
    while (true) {
      final body = <String, Object?>{
        'protocol': companionProtocol,
        'group_id': request.groupId,
        'revision': revision,
        if (request.recordId != null) 'record_id': request.recordId,
        field: rows.take(count).toList(),
        'next_before': count < rows.length && count > 0
            ? rows[count - 1]['sequence']
            : null,
      };
      if (utf8.encode(jsonEncode(body)).length <= assistantBodyLimit) {
        return body;
      }
      if (count <= 1) throw const FormatException('Record response size');
      count--;
    }
  }

  SharingReceipt executeSharing(String device, SharingCommand command) {
    final outcome = _transaction(() {
      final member = _requireGroup(device, command.groupId);
      final fingerprint = _hash(command.fingerprintInput);
      if (_db.select(
            'SELECT 1 FROM pairing_operations WHERE member_id=? AND operation_id=?',
            [member, command.operationId],
          ).isNotEmpty ||
          _db.select(
            'SELECT 1 FROM media_operations WHERE member_id=? AND operation_id=?',
            [member, command.operationId],
          ).isNotEmpty ||
          _db.select(
            'SELECT 1 FROM chat_operations WHERE member_id=? AND operation_id=?',
            [member, command.operationId],
          ).isNotEmpty) {
        throw const CompanionFailure(409, 'operation_conflict');
      }
      final old = _db.select(
        'SELECT * FROM sharing_operations WHERE member_id=? AND operation_id=?',
        [member, command.operationId],
      ).singleOrNull;
      if (old != null) {
        if (old['fingerprint'] != fingerprint) {
          throw const CompanionFailure(409, 'operation_conflict');
        }
        if (old['error_code'] != null) {
          return _SharingOutcome.failure(
            old['status'] as int,
            old['error_code'] as String,
          );
        }
        final resource = old['resource_id'] as String;
        _validateSharingReplay(command, member, resource);
        return _SharingOutcome.success(resource, old['revision'] as int);
      }
      late _SharingOutcome result;
      // Keep rejected commands payload-bound without committing partial mutations.
      _db.execute('SAVEPOINT sharing_command');
      try {
        final (resource, revision) = switch (command.kind) {
          SharingCommandKind.enable => _enableSharing(member, command),
          SharingCommandKind.stop => _stopSharing(member, command),
          SharingCommandKind.publish => _publishRecord(member, command),
          SharingCommandKind.remove => _removeRecord(member, command),
          SharingCommandKind.reply => _sendReply(member, command),
          SharingCommandKind.deleteReply => _removeReply(member, command),
        };
        result = _SharingOutcome.success(resource, revision);
      } on CompanionFailure catch (error) {
        _db.execute('ROLLBACK TO sharing_command');
        result = _SharingOutcome.failure(error.status, error.code);
      } finally {
        _db.execute('RELEASE sharing_command');
      }
      _db.execute(
        '''INSERT INTO sharing_operations
        (member_id,operation_id,group_id,fingerprint,kind,resource_id,revision,status,error_code,created_at)
        VALUES (?,?,?,?,?,?,?,?,?,?)''',
        [
          member,
          command.operationId,
          command.groupId,
          fingerprint,
          command.kind.name,
          result.resource,
          result.revision,
          result.status,
          result.error,
          _time,
        ],
      );
      return result;
    });
    if (outcome.error != null) {
      throw CompanionFailure(outcome.status, outcome.error!);
    }
    return _sharingReceipt(command, outcome.resource!, outcome.revision!);
  }

  SharingReceipt _sharingReceipt(
    SharingCommand command,
    String resource,
    int revision,
  ) => SharingReceipt.fromJson({
    'protocol': companionProtocol,
    'operation_id': command.operationId,
    'group_id': command.groupId,
    'resource_id': resource,
    'revision': revision,
  }, command: command);

  PublicationResolution resolvePublication(
    String device,
    PublicationResolveRequest request,
  ) => _transaction(() {
    final member = _requireGroup(device, request.groupId);
    if (_db.select(
          'SELECT 1 FROM pairing_operations WHERE member_id=? AND operation_id=?',
          [member, request.operationId],
        ).isNotEmpty ||
        _db.select(
          'SELECT 1 FROM media_operations WHERE member_id=? AND operation_id=?',
          [member, request.operationId],
        ).isNotEmpty ||
        _db.select(
          'SELECT 1 FROM chat_operations WHERE member_id=? AND operation_id=?',
          [member, request.operationId],
        ).isNotEmpty) {
      throw const CompanionFailure(409, 'operation_conflict');
    }
    var row = _db.select(
      'SELECT * FROM sharing_operations WHERE member_id=? AND operation_id=?',
      [member, request.operationId],
    ).singleOrNull;
    if (row != null &&
        (row['kind'] != 'publish' ||
            row['group_id'] != request.groupId ||
            row['fingerprint'] != request.fingerprint)) {
      throw const CompanionFailure(409, 'operation_conflict');
    }
    if (row == null) {
      // The rejection and the lookup share one transaction. A delayed original
      // body can only observe this tombstone, never publish after cancellation.
      _db.execute(
        '''INSERT INTO sharing_operations
        (member_id,operation_id,group_id,fingerprint,kind,resource_id,revision,status,error_code,created_at)
        VALUES (?,?,?,?,'publish',NULL,NULL,409,'publication_cancelled',?)''',
        [
          member,
          request.operationId,
          request.groupId,
          request.fingerprint,
          _time,
        ],
      );
      row = _db.select(
        'SELECT * FROM sharing_operations WHERE member_id=? AND operation_id=?',
        [member, request.operationId],
      ).single;
    }
    return PublicationResolution.fromJson({
      ...request.toJson(),
      'receipt': row['status'] == 200
          ? {
              'protocol': companionProtocol,
              'operation_id': request.operationId,
              'group_id': request.groupId,
              'resource_id': row['resource_id'],
              'revision': row['revision'],
            }
          : null,
      'error_code': row['error_code'],
    }, request: request);
  });

  void _validateSharingReplay(
    SharingCommand command,
    String member,
    String resource,
  ) {
    switch (command.kind) {
      case SharingCommandKind.enable:
        _grant(command.groupId, resource, author: member);
      case SharingCommandKind.publish:
        _record(command.groupId, resource, author: member);
      case SharingCommandKind.reply:
        _reply(command.groupId, resource, author: member);
      case SharingCommandKind.stop:
      case SharingCommandKind.remove:
      case SharingCommandKind.deleteReply:
        break;
    }
  }

  (String, int) _enableSharing(String member, SharingCommand command) {
    final current = _db
        .select(
          '''SELECT id FROM sharing_grants
      WHERE group_id=? AND member_id=? AND goal_id=? AND stopped_at IS NULL''',
          [command.groupId, member, command.goalId],
        )
        .singleOrNull;
    if (current != null) return (current['id'] as String, 0);
    final id = _id();
    _db.execute(
      '''INSERT INTO sharing_grants (id,group_id,member_id,goal_id,enabled_at)
      VALUES (?,?,?,?,?)''',
      [id, command.groupId, member, command.goalId, _time],
    );
    _changed(command.groupId);
    return (id, 0);
  }

  (String, int) _stopSharing(String member, SharingCommand command) {
    final grant = _grant(
      command.groupId,
      command.grantId!,
      author: member,
      active: false,
    );
    if (grant['stopped_at'] == null) {
      _db.execute('DELETE FROM companion_photos WHERE grant_id=?', [
        command.grantId,
      ]);
      _db.execute('DELETE FROM shared_records WHERE grant_id=?', [
        command.grantId,
      ]);
      _db.execute('UPDATE sharing_grants SET stopped_at=? WHERE id=?', [
        _time,
        command.grantId,
      ]);
      _changed(command.groupId);
    }
    return (command.grantId!, 0);
  }

  (String, int) _publishRecord(String member, SharingCommand command) {
    final grant = _grant(command.groupId, command.grantId!, author: member);
    final occurred = command.occurredAt!.millisecondsSinceEpoch;
    final completed = command.completedAt?.millisecondsSinceEpoch;
    if (occurred < (grant['enabled_at'] as int) ||
        occurred > _time ||
        (completed != null && completed < (grant['enabled_at'] as int))) {
      throw const CompanionFailure(409, 'history_not_shareable');
    }
    final old = _db.select(
      'SELECT * FROM shared_records WHERE grant_id=? AND source_id=?',
      [command.grantId, command.sourceId],
    ).singleOrNull;
    if ((old == null && command.baseRevision != 0) ||
        (old != null && command.baseRevision != old['revision'])) {
      throw const CompanionFailure(409, 'revision_conflict');
    }
    final id = old?['id'] as String? ?? _id();
    final revision = (old?['revision'] as int? ?? 0) + 1;
    if (old == null) {
      _db.execute(
        '''INSERT INTO shared_records
        (id,grant_id,source_id,author_id,revision,title,occurred_at,completed_at,text,photo_ids)
        VALUES (?,?,?,?,?,?,?,?,?,?)''',
        [
          id,
          command.grantId,
          command.sourceId,
          member,
          revision,
          command.title,
          occurred,
          completed,
          command.text,
          jsonEncode(command.photoIds),
        ],
      );
    } else {
      if (occurred < (old['occurred_at'] as int)) {
        throw const CompanionFailure(409, 'revision_conflict');
      }
      _db.execute(
        '''UPDATE shared_records SET revision=?,title=?,occurred_at=?,completed_at=?,text=?,photo_ids=?
        WHERE id=?''',
        [
          revision,
          command.title,
          occurred,
          completed,
          command.text,
          jsonEncode(command.photoIds),
          id,
        ],
      );
    }
    _bindRecordPhotos(member, command, id);
    final published = _recordValue(_record(command.groupId, id));
    _boundedPage(
      SharedPageRequest.fromJson({
        'protocol': companionProtocol,
        'group_id': command.groupId,
        'before_sequence': null,
        'revision': null,
      }),
      _revision(command.groupId),
      'records',
      [published.toJson()],
    );
    _changed(command.groupId);
    return (id, revision);
  }

  (String, int) _removeRecord(String member, SharingCommand command) {
    _record(command.groupId, command.recordId!, author: member);
    _db.execute(
      'DELETE FROM companion_photos WHERE id IN (SELECT photo_id FROM shared_record_photos WHERE record_id=?)',
      [command.recordId],
    );
    _db.execute('DELETE FROM shared_records WHERE id=?', [command.recordId]);
    _changed(command.groupId);
    return (command.recordId!, 0);
  }

  (String, int) _sendReply(String member, SharingCommand command) {
    _record(command.groupId, command.recordId!);
    final id = _id();
    _db.execute(
      '''INSERT INTO shared_replies (id,record_id,author_id,text,created_at)
      VALUES (?,?,?,?,?)''',
      [id, command.recordId, member, command.text, _time],
    );
    final row = _reply(command.groupId, id);
    final request = SharedPageRequest.fromJson({
      'protocol': companionProtocol,
      'group_id': command.groupId,
      'record_id': command.recordId,
      'before_sequence': null,
      'revision': null,
    }, replies: true);
    _boundedPage(request, _revision(command.groupId), 'replies', [
      {
        'id': id,
        'record_id': command.recordId,
        'author_id': member,
        'text': command.text,
        'created_at': _iso(row['created_at'] as int),
        'sequence': row['sequence'],
      },
    ]);
    _changed(command.groupId);
    return (id, 1);
  }

  Row _reply(String group, String id, {String? author}) {
    final reply = _db
        .select(
          '''SELECT p.* FROM shared_replies p
      JOIN shared_records r ON r.id=p.record_id JOIN sharing_grants g ON g.id=r.grant_id
      WHERE p.id=? AND g.group_id=? AND g.stopped_at IS NULL''',
          [id, group],
        )
        .singleOrNull;
    if (reply == null || (author != null && reply['author_id'] != author)) {
      throw const CompanionFailure(403, 'reply_unavailable');
    }
    return reply;
  }

  (String, int) _removeReply(String member, SharingCommand command) {
    _reply(command.groupId, command.replyId!, author: member);
    _db.execute('DELETE FROM shared_replies WHERE id=?', [command.replyId]);
    _changed(command.groupId);
    return (command.replyId!, 0);
  }

  void _purgeSharing(String group) {
    // Cascades erase content, while operation receipts retain only opaque metadata.
    _db.execute('DELETE FROM companion_photos WHERE group_id=?', [group]);
    _db.execute('DELETE FROM sharing_grants WHERE group_id=?', [group]);
  }
}

class _SharingOutcome {
  const _SharingOutcome.success(this.resource, this.revision)
    : status = 200,
      error = null;
  const _SharingOutcome.failure(this.status, this.error)
    : resource = null,
      revision = null;
  final String? resource;
  final int? revision;
  final int status;
  final String? error;
}

const _sharingSchema = '''
ALTER TABLE companion_groups ADD COLUMN content_revision INTEGER NOT NULL DEFAULT 0;
CREATE TABLE sharing_grants (
  sequence INTEGER PRIMARY KEY AUTOINCREMENT,
  id TEXT NOT NULL UNIQUE,
  group_id TEXT NOT NULL REFERENCES companion_groups(id),
  member_id TEXT NOT NULL REFERENCES members(id),
  goal_id TEXT NOT NULL,
  enabled_at INTEGER NOT NULL,
  stopped_at INTEGER
) STRICT;
CREATE UNIQUE INDEX one_active_share ON sharing_grants(group_id,member_id,goal_id) WHERE stopped_at IS NULL;
CREATE TABLE shared_records (
  sequence INTEGER PRIMARY KEY AUTOINCREMENT,
  id TEXT NOT NULL UNIQUE,
  grant_id TEXT NOT NULL REFERENCES sharing_grants(id) ON DELETE CASCADE,
  source_id TEXT NOT NULL,
  author_id TEXT NOT NULL REFERENCES members(id),
  revision INTEGER NOT NULL CHECK (revision>0),
  title TEXT NOT NULL,
  occurred_at INTEGER NOT NULL,
  completed_at INTEGER,
  text TEXT NOT NULL,
  photo_ids TEXT NOT NULL,
  UNIQUE(grant_id,source_id)
) STRICT;
CREATE TABLE shared_replies (
  sequence INTEGER PRIMARY KEY AUTOINCREMENT,
  id TEXT NOT NULL UNIQUE,
  record_id TEXT NOT NULL REFERENCES shared_records(id) ON DELETE CASCADE,
  author_id TEXT NOT NULL REFERENCES members(id),
  text TEXT NOT NULL,
  created_at INTEGER NOT NULL
) STRICT;
CREATE INDEX replies_by_record ON shared_replies(record_id,sequence);
CREATE TABLE sharing_operations (
  member_id TEXT NOT NULL REFERENCES members(id),
  operation_id TEXT NOT NULL,
  group_id TEXT NOT NULL REFERENCES companion_groups(id),
  fingerprint TEXT NOT NULL,
  kind TEXT NOT NULL,
  resource_id TEXT,
  revision INTEGER,
  status INTEGER NOT NULL,
  error_code TEXT,
  created_at INTEGER NOT NULL,
  PRIMARY KEY(member_id,operation_id),
  CHECK ((status=200)=(error_code IS NULL)),
  CHECK ((status=200)=(resource_id IS NOT NULL)),
  CHECK ((status=200)=(revision IS NOT NULL))
) STRICT;
''';
