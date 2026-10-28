part of 'companion_store.dart';

class CompanionPhotoReservation {
  CompanionPhotoReservation._(
    this.photoId,
    this.memberId,
    this.request,
    this.fingerprint,
    this.ready,
  );
  final String photoId;
  final String memberId;
  final CompanionPhotoUpload request;
  final String fingerprint;
  final CompanionPhotoMetadata? ready;
}

extension CompanionMediaStore on CompanionStore {
  bool get requiresPhotoStore =>
      _db.select('SELECT 1 FROM companion_photos LIMIT 1').isNotEmpty ||
      _db.select('SELECT 1 FROM photo_deletions LIMIT 1').isNotEmpty;

  void _mediaOperationAvailable(String member, String operation) {
    for (final table in [
      'pairing_operations',
      'sharing_operations',
      'chat_operations',
    ]) {
      if (_db.select(
        'SELECT 1 FROM $table WHERE member_id=? AND operation_id=?',
        [member, operation],
      ).isNotEmpty) {
        throw const CompanionFailure(409, 'operation_conflict');
      }
    }
  }

  void _uploadPermission(String member, CompanionPhotoUpload request) {
    if (request.purpose == CompanionPhotoPurpose.record) {
      _grant(request.groupId, request.grantId!, author: member);
    }
  }

  CompanionPhotoMetadata _photoValue(Row row) =>
      CompanionPhotoMetadata.fromJson({
        'id': row['id'],
        'group_id': row['group_id'],
        'author_id': row['author_id'],
        'purpose': row['purpose'],
        'grant_id': row['grant_id'],
        'width': row['width'],
        'height': row['height'],
        'byte_count': row['byte_count'],
        'sha256': row['sha256'],
      });

  CompanionPhotoReservation reservePhoto(
    String device,
    CompanionPhotoUpload request,
  ) {
    final result = _transaction<Object>(() {
      final member = _requireGroup(device, request.groupId);
      _mediaOperationAvailable(member, request.operationId);
      final fingerprint = _hash(
        jsonEncode({
          'kind': 'upload',
          'group_id': request.groupId,
          'purpose': request.purpose.name,
          'grant_id': request.grantId,
          'source_sha256': sha256.convert(request.bytes).toString(),
        }),
      );
      final old = _db.select(
        'SELECT * FROM media_operations WHERE member_id=? AND operation_id=?',
        [member, request.operationId],
      ).singleOrNull;
      if (old != null) {
        if (old['fingerprint'] != fingerprint) {
          throw const CompanionFailure(409, 'operation_conflict');
        }
        if (old['status'] == 'failed') {
          return CompanionFailure(
            old['status_code'] as int,
            old['error_code'] as String,
          );
        }
        _uploadPermission(member, request);
        final photo = _db.select('SELECT * FROM companion_photos WHERE id=?', [
          old['resource_id'],
        ]).singleOrNull;
        if (photo == null) {
          throw const CompanionFailure(403, 'photo_unavailable');
        }
        return CompanionPhotoReservation._(
          photo['id'] as String,
          member,
          request,
          fingerprint,
          photo['status'] == 'ready' ? _photoValue(photo) : null,
        );
      }
      final id = _id();
      try {
        _uploadPermission(member, request);
      } on CompanionFailure catch (failure) {
        _db.execute(
          '''INSERT INTO media_operations
        (member_id,operation_id,group_id,kind,fingerprint,resource_id,status,status_code,error_code,created_at)
        VALUES (?,?,?,'upload',?,?,'failed',?,?,?)''',
          [
            member,
            request.operationId,
            request.groupId,
            fingerprint,
            id,
            failure.status,
            failure.code,
            _time,
          ],
        );
        return failure;
      }
      _db.execute(
        '''INSERT INTO companion_photos (id,group_id,author_id,purpose,grant_id,status,created_at)
      VALUES (?,?,?,?,?,'uploading',?)''',
        [
          id,
          request.groupId,
          member,
          request.purpose.name,
          request.grantId,
          _time,
        ],
      );
      _db.execute(
        '''INSERT INTO media_operations
      (member_id,operation_id,group_id,kind,fingerprint,resource_id,status,created_at)
      VALUES (?,?,?,'upload',?,?,'uploading',?)''',
        [member, request.operationId, request.groupId, fingerprint, id, _time],
      );
      return CompanionPhotoReservation._(
        id,
        member,
        request,
        fingerprint,
        null,
      );
    });
    if (result is CompanionFailure) throw result;
    return result as CompanionPhotoReservation;
  }

  CompanionPhotoMetadata finishPhoto(
    String device,
    CompanionPhotoReservation reservation,
    SanitizedCompanionPhoto sanitized,
  ) => _transaction(() {
    final member = _requireGroup(device, reservation.request.groupId);
    if (member != reservation.memberId) {
      throw const CompanionFailure(403, 'photo_unavailable');
    }
    _uploadPermission(member, reservation.request);
    final row = _db.select(
      'SELECT * FROM companion_photos WHERE id=? AND author_id=?',
      [reservation.photoId, member],
    ).singleOrNull;
    final operation = _db.select(
      'SELECT * FROM media_operations WHERE member_id=? AND operation_id=?',
      [member, reservation.request.operationId],
    ).singleOrNull;
    if (row == null ||
        operation == null ||
        operation['fingerprint'] != reservation.fingerprint ||
        operation['status'] == 'failed') {
      throw const CompanionFailure(403, 'photo_unavailable');
    }
    if (row['status'] == 'ready') {
      if (row['sha256'] != sanitized.sha256) {
        throw const CompanionFailure(409, 'operation_conflict');
      }
      return _photoValue(row);
    }
    _db.execute(
      '''UPDATE companion_photos SET status='ready',width=?,height=?,byte_count=?,sha256=? WHERE id=?''',
      [
        sanitized.width,
        sanitized.height,
        sanitized.bytes.length,
        sanitized.sha256,
        reservation.photoId,
      ],
    );
    _db.execute(
      "UPDATE media_operations SET status='succeeded',status_code=200 WHERE member_id=? AND operation_id=?",
      [member, reservation.request.operationId],
    );
    return _photoValue(
      _db.select('SELECT * FROM companion_photos WHERE id=?', [
        reservation.photoId,
      ]).single,
    );
  });

  void abortPhoto(
    CompanionPhotoReservation reservation,
    CompanionFailure failure,
  ) => _transaction(() {
    final operation = _db.select(
      'SELECT * FROM media_operations WHERE member_id=? AND operation_id=?',
      [reservation.memberId, reservation.request.operationId],
    ).singleOrNull;
    if (operation == null ||
        operation['fingerprint'] != reservation.fingerprint) {
      return;
    }
    // A leave/stop may already have drained the original deletion before a
    // delayed write finishes. Re-enqueue even when the photo row is gone.
    final row = _db.select('SELECT status FROM companion_photos WHERE id=?', [
      reservation.photoId,
    ]).singleOrNull;
    if (row == null) {
      _enqueuePhotoDeletion(reservation.photoId);
    } else if (operation['status'] != 'uploading') {
      return;
    }
    _db.execute('DELETE FROM companion_photos WHERE id=?', [
      reservation.photoId,
    ]);
    _db.execute(
      "UPDATE media_operations SET status='failed',status_code=?,error_code=? WHERE member_id=? AND operation_id=?",
      [
        failure.status,
        failure.code,
        reservation.memberId,
        reservation.request.operationId,
      ],
    );
  });

  void _enqueuePhotoDeletion(String key) => _db.execute(
    '''
    INSERT INTO photo_deletions (object_key,created_at) VALUES (?,?)
    ON CONFLICT(object_key) DO UPDATE SET generation=lower(hex(randomblob(16))),attempts=0
  ''',
    [key, _time],
  );

  CompanionPhotoMetadata photoFor(
    String device,
    CompanionPhotoRequest request,
  ) => _transaction(() {
    final member = _requireGroup(device, request.groupId);
    final row = _db.select(
      "SELECT * FROM companion_photos WHERE id=? AND group_id=? AND status='ready'",
      [request.photoId, request.groupId],
    ).singleOrNull;
    if (row == null) throw const CompanionFailure(403, 'photo_unavailable');
    if (row['grant_id'] != null) {
      _grant(request.groupId, row['grant_id'] as String);
    }
    if (row['author_id'] != member) {
      final shared =
          (row['purpose'] == 'record' &&
              _db
                  .select(
                    '''
        SELECT 1 FROM shared_record_photos p JOIN shared_records r ON r.id=p.record_id
        JOIN sharing_grants g ON g.id=r.grant_id
        WHERE p.photo_id=? AND g.group_id=? AND g.stopped_at IS NULL
      ''',
                    [request.photoId, request.groupId],
                  )
                  .isNotEmpty) ||
          (row['purpose'] == 'chat' &&
              _db.select(
                'SELECT 1 FROM chat_messages WHERE group_id=? AND photo_id=?',
                [request.groupId, request.photoId],
              ).isNotEmpty);
      if (!shared) throw const CompanionFailure(403, 'photo_unavailable');
    }
    return _photoValue(row);
  });

  Map<String, Object?> removePhoto(
    String device,
    CompanionPhotoRequest request,
  ) {
    if (request.operationId == null) {
      throw const FormatException('Photo operation');
    }
    final failure = _transaction<CompanionFailure?>(() {
      final member = _requireGroup(device, request.groupId);
      _mediaOperationAvailable(member, request.operationId!);
      final fingerprint = _hash(
        jsonEncode({'kind': 'remove', ...request.toJson()}),
      );
      final old = _db.select(
        'SELECT * FROM media_operations WHERE member_id=? AND operation_id=?',
        [member, request.operationId],
      ).singleOrNull;
      if (old != null) {
        if (old['fingerprint'] != fingerprint) {
          throw const CompanionFailure(409, 'operation_conflict');
        }
        if (old['status'] == 'failed') {
          return CompanionFailure(
            old['status_code'] as int,
            old['error_code'] as String,
          );
        }
        return null;
      }
      final row = _db.select(
        'SELECT * FROM companion_photos WHERE id=? AND group_id=? AND author_id=?',
        [request.photoId, request.groupId, member],
      ).singleOrNull;
      CompanionFailure? failure;
      if (row == null) {
        failure = const CompanionFailure(403, 'photo_unavailable');
      } else if (_db.select(
            'SELECT 1 FROM shared_record_photos WHERE photo_id=?',
            [request.photoId],
          ).isNotEmpty ||
          _db.select('SELECT 1 FROM chat_messages WHERE photo_id=?', [
            request.photoId,
          ]).isNotEmpty) {
        failure = const CompanionFailure(409, 'photo_attached');
      } else {
        _db.execute('DELETE FROM companion_photos WHERE id=?', [
          request.photoId,
        ]);
      }
      _db.execute(
        '''INSERT INTO media_operations
      (member_id,operation_id,group_id,kind,fingerprint,resource_id,status,status_code,error_code,created_at)
      VALUES (?,?,?,'remove',?,?,?,?,?,?)''',
        [
          member,
          request.operationId,
          request.groupId,
          fingerprint,
          request.photoId,
          failure == null ? 'succeeded' : 'failed',
          failure?.status ?? 200,
          failure?.code,
          _time,
        ],
      );
      return failure;
    });
    if (failure != null) throw failure;
    return request.toJson();
  }

  void _bindRecordPhotos(String member, SharingCommand command, String record) {
    for (final id in command.photoIds) {
      final row = _db.select(
        "SELECT * FROM companion_photos WHERE id=? AND status='ready'",
        [id],
      ).singleOrNull;
      final link = _db.select(
        'SELECT record_id FROM shared_record_photos WHERE photo_id=?',
        [id],
      ).singleOrNull;
      if (row == null ||
          row['group_id'] != command.groupId ||
          row['author_id'] != member ||
          row['purpose'] != 'record' ||
          row['grant_id'] != command.grantId ||
          (link != null && link['record_id'] != record)) {
        throw const CompanionFailure(403, 'photo_unavailable');
      }
    }
    final old = _db.select(
      'SELECT photo_id FROM shared_record_photos WHERE record_id=?',
      [record],
    );
    for (final row in old) {
      if (!command.photoIds.contains(row['photo_id'])) {
        _db.execute('DELETE FROM companion_photos WHERE id=?', [
          row['photo_id'],
        ]);
      }
    }
    _db.execute('DELETE FROM shared_record_photos WHERE record_id=?', [record]);
    for (var position = 0; position < command.photoIds.length; position++) {
      _db.execute(
        'INSERT INTO shared_record_photos (record_id,photo_id,position) VALUES (?,?,?)',
        [record, command.photoIds[position], position],
      );
    }
  }

  void expireUnattachedPhotos() => _transaction(() {
    _db.execute(
      '''DELETE FROM companion_photos WHERE created_at<=?
      AND id NOT IN (SELECT photo_id FROM shared_record_photos)
      AND id NOT IN (SELECT photo_id FROM chat_messages WHERE photo_id IS NOT NULL)''',
      [_time - const Duration(hours: 24).inMilliseconds],
    );
  });

  Future<void> reconcilePhotoObjects(ObjectStore objects) async {
    final keys = await objects.keys(includePending: true);
    _transaction(() {
      for (final key in keys) {
        if (_db.select('SELECT 1 FROM companion_photos WHERE id=?', [
          key,
        ]).isEmpty) {
          _enqueuePhotoDeletion(key);
        }
      }
    });
    await drainPhotoDeletions(objects);
  }

  Future<void> drainPhotoDeletions(ObjectStore objects) async {
    while (true) {
      final jobs = _db.select(
        'SELECT object_key,generation FROM photo_deletions ORDER BY created_at LIMIT 100',
      );
      if (jobs.isEmpty) return;
      for (final row in jobs) {
        final key = row['object_key'] as String;
        try {
          await objects.delete(key);
        } catch (_) {
          _db.execute(
            'UPDATE photo_deletions SET attempts=attempts+1 WHERE object_key=?',
            [key],
          );
          throw const CompanionFailure(503, 'photo_cleanup_pending');
        }
        _db.execute(
          'DELETE FROM photo_deletions WHERE object_key=? AND generation=?',
          [key, row['generation']],
        );
      }
    }
  }
}

const _mediaSchema = '''
CREATE TABLE companion_photos (
  id TEXT PRIMARY KEY,
  group_id TEXT NOT NULL REFERENCES companion_groups(id),
  author_id TEXT NOT NULL REFERENCES members(id),
  purpose TEXT NOT NULL CHECK (purpose IN ('record','chat')),
  grant_id TEXT REFERENCES sharing_grants(id) ON DELETE CASCADE,
  status TEXT NOT NULL CHECK (status IN ('uploading','ready')),
  width INTEGER, height INTEGER, byte_count INTEGER, sha256 TEXT,
  created_at INTEGER NOT NULL,
  CHECK ((purpose='record')=(grant_id IS NOT NULL)),
  CHECK ((status='ready')=(width IS NOT NULL AND height IS NOT NULL AND byte_count IS NOT NULL AND sha256 IS NOT NULL)),
  CHECK (width BETWEEN 1 AND 1600 AND height BETWEEN 1 AND 1600),
  CHECK (byte_count BETWEEN 1 AND 2097152)
) STRICT;
CREATE TABLE shared_record_photos (
  record_id TEXT NOT NULL REFERENCES shared_records(id) ON DELETE CASCADE,
  photo_id TEXT NOT NULL UNIQUE REFERENCES companion_photos(id) ON DELETE CASCADE,
  position INTEGER NOT NULL CHECK (position BETWEEN 0 AND 2),
  PRIMARY KEY(record_id,position)
) STRICT;
CREATE TABLE media_operations (
  member_id TEXT NOT NULL REFERENCES members(id),
  operation_id TEXT NOT NULL,
  group_id TEXT NOT NULL REFERENCES companion_groups(id),
  kind TEXT NOT NULL CHECK (kind IN ('upload','remove')),
  fingerprint TEXT NOT NULL,
  resource_id TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('uploading','succeeded','failed')),
  status_code INTEGER,
  error_code TEXT,
  created_at INTEGER NOT NULL,
  PRIMARY KEY(member_id,operation_id),
  CHECK ((status='failed')=(error_code IS NOT NULL)),
  CHECK ((status='uploading')=(status_code IS NULL))
) STRICT;
CREATE TABLE photo_deletions (
  object_key TEXT PRIMARY KEY,
  created_at INTEGER NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0,
  generation TEXT NOT NULL DEFAULT (lower(hex(randomblob(16))))
) STRICT;
CREATE TRIGGER enqueue_photo_deletion AFTER DELETE ON companion_photos BEGIN
  INSERT INTO photo_deletions (object_key,created_at)
  VALUES (OLD.id,CAST(strftime('%s','now') AS INTEGER)*1000)
  ON CONFLICT(object_key) DO UPDATE SET generation=lower(hex(randomblob(16))),attempts=0;
END;
''';
