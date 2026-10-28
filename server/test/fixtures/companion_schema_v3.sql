-- Frozen schema from 1e58d09; schema only, no row data.
CREATE TABLE members (
  id TEXT PRIMARY KEY,
  device_label TEXT NOT NULL UNIQUE,
  created_at INTEGER NOT NULL
) STRICT;
CREATE TABLE companion_groups (
  id TEXT PRIMARY KEY,
  created_at INTEGER NOT NULL,
  closed_at INTEGER
, content_revision INTEGER NOT NULL DEFAULT 0) STRICT;
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
