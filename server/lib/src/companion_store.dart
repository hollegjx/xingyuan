import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

import 'companion_photo.dart';
import 'object_store.dart';

part 'sharing_store.dart';
part 'companion_media_store.dart';
part 'chat_store.dart';

class CompanionFailure implements Exception {
  const CompanionFailure(this.status, this.code, {this.retryAfter});
  final int status;
  final String code;
  final int? retryAfter;
}

class CompanionStore {
  CompanionStore._(this._db, this._now);

  factory CompanionStore.open(String path, {DateTime Function()? now}) {
    if (!File(path).isAbsolute || !File(path).parent.existsSync()) {
      throw const FormatException('Companion database path');
    }
    if (FileSystemEntity.typeSync(path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const FormatException('Companion database link');
    }
    final db = sqlite3.open(path);
    try {
      final version = db.userVersion;
      if (version < 0 || version > 4) {
        throw const FormatException('Unsupported companion database');
      }
      if (version > 0 &&
          db.select('PRAGMA application_id').single.values.single !=
              1481065296) {
        throw const FormatException('Companion database identity');
      }
      if (version == 0 &&
          db
              .select("SELECT name FROM sqlite_schema WHERE type='table'")
              .isNotEmpty) {
        throw const FormatException('Unexpected companion database tables');
      }
      db.execute('PRAGMA foreign_keys=ON');
      db.execute('PRAGMA busy_timeout=5000');
      _validateCompanionDatabase(db);
      if (version < 4) {
        db.execute('BEGIN IMMEDIATE');
        try {
          if (version == 0) {
            db.execute(_schema);
            db.execute('PRAGMA application_id=1481065296');
          }
          if (version < 2) db.execute(_sharingSchema);
          if (version < 3) db.execute(_mediaSchema);
          db.execute(_chatSchema);
          db.userVersion = 4;
          _validateCompanionDatabase(db);
          db.execute('COMMIT');
        } catch (_) {
          db.execute('ROLLBACK');
          rethrow;
        }
      }
      db.execute('PRAGMA journal_mode=WAL');
      db.execute('PRAGMA synchronous=FULL');
      db.execute('PRAGMA secure_delete=ON');
      return CompanionStore._(db, now ?? DateTime.now);
    } catch (_) {
      db.close();
      rethrow;
    }
  }

  final Database _db;
  final DateTime Function() _now;
  bool _closed = false;
  static const _window = Duration(minutes: 10);
  String _id() => const Uuid().v4();
  int get _time => _now().toUtc().millisecondsSinceEpoch;
  String _iso(int instant) => DateTime.fromMillisecondsSinceEpoch(
    instant,
    isUtc: true,
  ).toIso8601String();
  String _hash(String value) => sha256.convert(utf8.encode(value)).toString();

  T _transaction<T>(T Function() action) {
    _db.execute('BEGIN IMMEDIATE');
    try {
      final result = action();
      _db.execute('COMMIT');
      return result;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  String _member(String device, int now) {
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,64}$').hasMatch(device)) {
      throw const FormatException('Device identity');
    }
    final found = _db.select('SELECT id FROM members WHERE device_label=?', [
      device,
    ]);
    if (found.isNotEmpty) return found.single['id'] as String;
    final id = _id();
    _db.execute(
      'INSERT INTO members (id,device_label,created_at) VALUES (?,?,?)',
      [id, device, now],
    );
    return id;
  }

  PairingState state(String device) => _transaction(() {
    final now = _time;
    return _state(_member(device, now), now);
  });

  Row? _group(String member) => _db
      .select(
        '''
    SELECT g.id,g.created_at,other.member_id AS partner_id
    FROM group_members own
    JOIN companion_groups g ON g.id=own.group_id AND g.closed_at IS NULL
    JOIN group_members other ON other.group_id=g.id AND other.member_id<>own.member_id AND other.left_at IS NULL
    WHERE own.member_id=? AND own.left_at IS NULL
  ''',
        [member],
      )
      .singleOrNull;

  Row? _activeInvite(String member, int now) => _db
      .select(
        '''
    SELECT * FROM invitations WHERE creator_id=? AND status='active' AND expires_at>?
  ''',
        [member, now],
      )
      .singleOrNull;

  PairingState _state(String member, int now) {
    final group = _group(member);
    final invite = group == null ? _activeInvite(member, now) : null;
    return PairingState.fromJson({
      'protocol': companionProtocol,
      'member_id': member,
      'group': group == null
          ? null
          : {
              'id': group['id'],
              'partner_id': group['partner_id'],
              'paired_at': _iso(group['created_at'] as int),
            },
      'invitation': invite == null
          ? null
          : {
              'id': invite['id'],
              'code': invite['code'],
              'expires_at': _iso(invite['expires_at'] as int),
            },
    });
  }

  PairingReceipt execute(String device, PairingCommand command) {
    final outcome = _transaction(() {
      final now = _time;
      final member = _member(device, now);
      if (_db.select(
            'SELECT 1 FROM sharing_operations WHERE member_id=? AND operation_id=?',
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
        return const _Outcome.failure(409, 'operation_conflict');
      }
      final fingerprint = _hash(
        jsonEncode({'kind': command.kind.name, ...command.toJson()}),
      );
      final old = _db.select(
        'SELECT * FROM pairing_operations WHERE member_id=? AND operation_id=?',
        [member, command.operationId],
      ).singleOrNull;
      if (old != null) {
        if (old['fingerprint'] != fingerprint) {
          return const _Outcome.failure(409, 'operation_conflict');
        }
        if (old['error_code'] != null) {
          return _Outcome.failure(
            old['status'] as int,
            old['error_code'] as String,
            retryUntil: old['retry_until'] as int?,
          );
        }
        final denied = _validateReplay(
          member,
          command.kind,
          old['resource_id'] as String,
          now,
        );
        if (denied != null) return denied;
        return _Outcome.success(
          old['resource_id'] as String,
          state: _state(member, now),
        );
      }
      final result = switch (command.kind) {
        PairingCommandKind.createInvite => _createInvite(member, now),
        PairingCommandKind.cancelInvite => _cancelInvite(
          member,
          command.invitationId!,
        ),
        PairingCommandKind.join => _join(member, command, now),
        PairingCommandKind.leave => _leave(member, command.groupId!, now),
      };
      _db.execute(
        '''
        INSERT INTO pairing_operations (member_id,operation_id,fingerprint,kind,resource_id,status,error_code,retry_until,created_at)
        VALUES (?,?,?,?,?,?,?,?,?)
      ''',
        [
          member,
          command.operationId,
          fingerprint,
          command.kind.name,
          result.resource,
          result.status,
          result.error,
          result.retryUntil,
          now,
        ],
      );
      return result.error == null
          ? _Outcome.success(result.resource!, state: _state(member, now))
          : result;
    });
    if (outcome.error != null) {
      throw CompanionFailure(
        outcome.status,
        outcome.error!,
        retryAfter: outcome.retryUntil == null
            ? null
            : max(0, ((outcome.retryUntil! - _time) / 1000).ceil()),
      );
    }
    return PairingReceipt.fromJson({
      'protocol': companionProtocol,
      'operation_id': command.operationId,
      'state': outcome.state!.toJson(),
    }, operationId: command.operationId);
  }

  _Outcome? _validateReplay(
    String member,
    PairingCommandKind kind,
    String resource,
    int now,
  ) {
    if (kind == PairingCommandKind.createInvite) {
      final invite = _db.select(
        'SELECT * FROM invitations WHERE id=? AND creator_id=?',
        [resource, member],
      ).singleOrNull;
      if (invite == null) {
        return const _Outcome.failure(410, 'invite_cancelled');
      }
      return _inviteFailure(invite, now);
    }
    if (kind == PairingCommandKind.join && _group(member)?['id'] != resource) {
      return const _Outcome.failure(410, 'pair_gone');
    }
    return null;
  }

  _Outcome? _inviteFailure(Row invite, int now) {
    final status = invite['status'] as String;
    if (status == 'used') return const _Outcome.failure(409, 'invite_used');
    if (status == 'cancelled') {
      return const _Outcome.failure(410, 'invite_cancelled');
    }
    if (status == 'expired' || (invite['expires_at'] as int) <= now) {
      return const _Outcome.failure(410, 'invite_expired');
    }
    return null;
  }

  _Outcome _createInvite(String member, int now) {
    if (_group(member) != null) {
      return const _Outcome.failure(409, 'already_paired');
    }
    _db.execute(
      "UPDATE invitations SET status='expired',code=NULL WHERE status='active' AND expires_at<=?",
      [now],
    );
    final existing = _activeInvite(member, now);
    if (existing != null) return _Outcome.success(existing['id'] as String);
    final random = Random.secure();
    for (var attempt = 0; attempt < 16; attempt++) {
      final code = List.generate(
        8,
        (_) => invitationAlphabet[random.nextInt(invitationAlphabet.length)],
      ).join();
      final hash = _hash(code);
      if (_db.select('SELECT 1 FROM invitations WHERE code_hash=?', [
        hash,
      ]).isNotEmpty) {
        continue;
      }
      final id = _id();
      _db.execute(
        '''INSERT INTO invitations (id,creator_id,code,code_hash,status,created_at,expires_at)
        VALUES (?,?,?,?,'active',?,?)''',
        [
          id,
          member,
          code,
          hash,
          now,
          now + const Duration(hours: 24).inMilliseconds,
        ],
      );
      return _Outcome.success(id);
    }
    throw StateError('Invitation generation unavailable');
  }

  _Outcome _cancelInvite(String member, String invitation) {
    final invite = _db.select(
      'SELECT * FROM invitations WHERE id=? AND creator_id=?',
      [invitation, member],
    ).singleOrNull;
    if (invite == null) return const _Outcome.failure(403, 'forbidden');
    if (invite['status'] == 'active') {
      _db.execute(
        "UPDATE invitations SET status='cancelled',code=NULL WHERE id=?",
        [invitation],
      );
    }
    return _Outcome.success(invitation);
  }

  _Outcome _join(String member, PairingCommand command, int now) {
    if (_group(member) != null) {
      return const _Outcome.failure(409, 'already_paired');
    }
    _db.execute('DELETE FROM join_failures WHERE attempted_at<=?', [
      now - _window.inMilliseconds,
    ]);
    final failures = _db.select(
      'SELECT attempted_at FROM join_failures WHERE member_id=? ORDER BY attempted_at',
      [member],
    );
    if (failures.length >= 5) {
      return _Outcome.failure(
        429,
        'invite_rate_limited',
        retryUntil:
            (failures.first['attempted_at'] as int) + _window.inMilliseconds,
      );
    }
    final code = command.code!.trim().toUpperCase();
    final invite = RegExp('^[$invitationAlphabet]{8}\$').hasMatch(code)
        ? _db.select('SELECT * FROM invitations WHERE code_hash=?', [
            _hash(code),
          ]).singleOrNull
        : null;
    final invalid = invite == null
        ? const _Outcome.failure(404, 'invite_invalid')
        : _inviteFailure(invite, now) ??
              (invite['creator_id'] == member
                  ? const _Outcome.failure(409, 'invite_self')
                  : _group(invite['creator_id'] as String) != null
                  ? const _Outcome.failure(409, 'invite_owner_paired')
                  : null);
    if (invalid != null) {
      _db.execute(
        'INSERT INTO join_failures (member_id,operation_id,attempted_at) VALUES (?,?,?)',
        [member, command.operationId, now],
      );
      if (failures.length == 4) {
        return _Outcome.failure(
          429,
          'invite_rate_limited',
          retryUntil:
              (failures.first['attempted_at'] as int) + _window.inMilliseconds,
        );
      }
      return invalid;
    }
    final group = _id();
    _db.execute('INSERT INTO companion_groups (id,created_at) VALUES (?,?)', [
      group,
      now,
    ]);
    for (final id in [invite!['creator_id'] as String, member]) {
      _db.execute(
        'INSERT INTO group_members (group_id,member_id,joined_at) VALUES (?,?,?)',
        [group, id, now],
      );
    }
    _db.execute(
      "UPDATE invitations SET status='used',code=NULL,used_by=? WHERE id=?",
      [member, invite['id']],
    );
    _db.execute(
      "UPDATE invitations SET status='cancelled',code=NULL WHERE creator_id IN (?,?) AND status='active'",
      [member, invite['creator_id']],
    );
    return _Outcome.success(group);
  }

  _Outcome _leave(String member, String group, int now) {
    final membership = _db.select(
      'SELECT 1 FROM group_members WHERE member_id=? AND group_id=?',
      [member, group],
    );
    if (membership.isEmpty) return const _Outcome.failure(403, 'forbidden');
    _purgeChat(group);
    _purgeSharing(group);
    _db.execute(
      'UPDATE companion_groups SET closed_at=? WHERE id=? AND closed_at IS NULL',
      [now, group],
    );
    _db.execute(
      'UPDATE group_members SET left_at=? WHERE group_id=? AND left_at IS NULL',
      [now, group],
    );
    return _Outcome.success(group);
  }

  Future<void> backupTo(String destination) async {
    final file = File(destination);
    if (!file.isAbsolute ||
        !file.parent.existsSync() ||
        FileSystemEntity.typeSync(destination, followLinks: false) !=
            FileSystemEntityType.notFound) {
      throw const FileSystemException(
        'Backup requires a new absolute destination',
      );
    }
    final backup = sqlite3.open(destination);
    try {
      await _db.backup(backup).drain<void>();
      if (backup.select('PRAGMA integrity_check').single.values.single !=
              'ok' ||
          backup.select('PRAGMA foreign_key_check').isNotEmpty) {
        throw const FormatException('Backup validation');
      }
    } finally {
      backup.close();
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _db.close();
  }
}

void _validateCompanionDatabase(Database db) {
  if (db.select('PRAGMA integrity_check').single.values.single != 'ok' ||
      db.select('PRAGMA foreign_key_check').isNotEmpty) {
    throw const FormatException('Companion database integrity');
  }
}

class _Outcome {
  const _Outcome.success(this.resource, {this.state})
    : status = 200,
      error = null,
      retryUntil = null;
  const _Outcome.failure(this.status, this.error, {this.retryUntil})
    : resource = null,
      state = null;
  final int status;
  final String? resource;
  final String? error;
  final int? retryUntil;
  final PairingState? state;
}

const _schema = '''
CREATE TABLE members (
  id TEXT PRIMARY KEY,
  device_label TEXT NOT NULL UNIQUE,
  created_at INTEGER NOT NULL
) STRICT;
CREATE TABLE companion_groups (
  id TEXT PRIMARY KEY,
  created_at INTEGER NOT NULL,
  closed_at INTEGER
) STRICT;
CREATE TABLE group_members (
  group_id TEXT NOT NULL REFERENCES companion_groups(id),
  member_id TEXT NOT NULL REFERENCES members(id),
  joined_at INTEGER NOT NULL,
  left_at INTEGER,
  PRIMARY KEY (group_id,member_id)
) STRICT;
CREATE UNIQUE INDEX one_active_group ON group_members(member_id) WHERE left_at IS NULL;
CREATE TRIGGER max_two_members BEFORE INSERT ON group_members
WHEN (SELECT count(*) FROM group_members WHERE group_id=NEW.group_id)>=2
BEGIN SELECT RAISE(ABORT,'Group is full'); END;
CREATE TABLE invitations (
  id TEXT PRIMARY KEY,
  creator_id TEXT NOT NULL REFERENCES members(id),
  code TEXT,
  code_hash TEXT NOT NULL UNIQUE,
  status TEXT NOT NULL CHECK (status IN ('active','used','cancelled','expired')),
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  used_by TEXT REFERENCES members(id),
  CHECK ((status='active')=(code IS NOT NULL))
) STRICT;
CREATE UNIQUE INDEX one_active_invitation ON invitations(creator_id) WHERE status='active';
CREATE TABLE pairing_operations (
  member_id TEXT NOT NULL REFERENCES members(id),
  operation_id TEXT NOT NULL,
  fingerprint TEXT NOT NULL,
  kind TEXT NOT NULL,
  resource_id TEXT,
  status INTEGER NOT NULL,
  error_code TEXT,
  retry_until INTEGER,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (member_id,operation_id),
  CHECK ((status=200)=(error_code IS NULL)),
  CHECK ((status=200)=(resource_id IS NOT NULL))
) STRICT;
CREATE TABLE join_failures (
  member_id TEXT NOT NULL REFERENCES members(id),
  operation_id TEXT NOT NULL,
  attempted_at INTEGER NOT NULL,
  PRIMARY KEY (member_id,operation_id)
) STRICT;
CREATE INDEX failures_by_member ON join_failures(member_id,attempted_at);
''';
