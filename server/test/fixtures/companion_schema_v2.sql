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
