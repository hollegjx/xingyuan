# Journal Formal-App Upgrade Checklist

Prepared on October 25, 2026 (Asia/Shanghai), for Goal J07 and Claude C8.
This is an execution plan, not an installation, backup, rollback drill, or
acceptance result. No formal upgrade is authorized by this document.

## Release Gate

- [ ] Record the owner's explicit approval in this chat, after trying B, for
  this exact candidate. Approval of an earlier version does not carry forward.
- [ ] Resolve the candidate's full source SHA and successful CI run. Keep
  source CI, documentation CI, simulator evidence, phone evidence, and owner
  acceptance separate. A documentation-only commit does not require redeploying
  the backend or repeating unchanged source tests.
- [ ] Confirm that the B build the owner accepted has the same runtime source
  as the candidate. Record any differences; reuse evidence only for proven
  unchanged paths. An installed or running process is not UI acceptance.
- [ ] Review current AI-1 status and both inboxes. The October 25 diary-entry
  fix is still awaiting handoff at preparation time; it is not implicitly the
  accepted candidate. J1/J2/J11 and old K14 remain separate open items.
- [ ] Confirm current device availability and authorization. A Locked error
  stops device work; preserve it and do not repeatedly relaunch or ask to unlock.

## Prepare Without Touching the Phone

- [ ] Work only in the AI-1 checkout. Preserve unrelated changes and active
  processes; do not build in the AI-2 main checkout or reuse a failed run's path.
- [ ] Verify or prepare the normal Release package from the exact candidate
  before the device maintenance window. Reuse a verified matching artifact;
  do not rebuild merely because a new documentation commit exists.
- [ ] Record package hash, source SHA, entry point, bundle identifier, signing
  team/application identifier, entitlements, registered device, and profile
  expiration. Compare against the formal app, not B. No new team, shared
  Keychain group, embedded database, credential, or production-content fixture.
- [ ] Keep the prior formal package and source outside Git. Check its current
  signature validity and schema compatibility before calling it a rollback
  option. An expired package is not a usable rollback package.
- [ ] Review existing comparison tooling before reuse. It must read snapshots
  only, report failures without content/secrets, and never open a baseline via
  the App or run migrations against it. Preserve all prior failed reports.
- [ ] Allocate a new private run directory outside Git with distinct
  `before`, `installed-not-launched`, and `after-launch` snapshots, manifests,
  comparison reports, install/launch results, and the approval reference.

The last recorded formal source is
`86b48ad82679ccfb6e4873a2a588b1a8e93e600d` (C067), with schema v10 and 41 tables
in the main database plus the separate reminder database. The last installed
B source is `25471f7a42716a02ae92f876ede06c7ce8e57739` (J011/J012). These are
historical baselines, not substitutes for the execution-time inventory. The
recorded formal signing expiry is October 26, 2026 at 17:48:54 Asia/Shanghai;
re-read the candidate's actual signed profile before installation.

## Fresh Baseline

- [ ] Record the exact installed formal bundle/container and its process.
  Stop only that verified process under the current upgrade approval. Never
  reuse an old PID or touch B, other apps, server processes, or VPN/relay state.
- [ ] Copy the complete Documents directory to the fresh `before` location.
  Retain every database, sidecar, photo, draft, and unknown file. Do not use an
  older successful backup as the fresh pre-upgrade baseline.
- [ ] Verify transfer completion, relative file paths, sizes, and hashes.
  Open every database read-only with `query_only=ON`; check schema version,
  application ID, all tables/columns/rows, integrity, and foreign keys. If WAL
  sidecars exist, first establish a consistent complete snapshot. Never bypass
  unreadable data, remove sidecars, or migrate the baseline to make it readable.
- [ ] Record comparison metadata without printing private row values. Include
  saved and draft text/photos, goals/check-ins/history, accounts/ownership,
  pending sync/reminders, AI consent/settings/history, pairing/sharing/chat,
  old probe databases, and non-database files. A Documents backup is not a
  Keychain export; do not read credentials or claim it backs up the Keychain.

## In-Place Install and First Launch

- [ ] Install the verified candidate over the formal bundle without uninstalling.
  A signing conflict that suggests removal is a stop condition, not permission
  to remove the App, replace its identity, or change signing teams.
- [ ] Before first launch, take `installed-not-launched` and compare all original
  files byte-for-byte with `before`. An install success alone proves neither
  data migration nor a launch. Investigate any unexplained difference first.
- [ ] Launch once when authorized and available. Record the result and exact
  process separately from foreground, visible pages, and interaction evidence.
  Do not enable AI, accept new consent, make model calls, add test records,
  change notifications, or operate pairing/sharing as part of this read-only check.
- [ ] Read-only UI checks: Today and existing goal/history/review content remain
  reachable; new journal entries are empty for an untouched formal installation.
  Do not expose private content in shared screenshots or logs. If mirroring
  fails, record UI as unverified; do not equate process presence with acceptance.
- [ ] Stop only the re-resolved formal process, take `after-launch`, and perform
  the schema-aware comparison below. Leave a clear handoff state; if reopening
  is blocked by Locked, do not claim the App was left in the foreground.

## Comparison Gates

| Item | Required result |
| --- | --- |
| Old main-database tables | All original columns and row values retained, with old row counts and relationships intact |
| Journal migration | Only reviewed candidate schema changes; on the v10-to-v11 path the four journal tables initially contain no entries/photos |
| Other databases | Original schema, rows, and values unchanged, including the separate reminder/probe databases |
| Photos and other files | Original file set, lengths, and hashes preserved; any additions explained without deleting originals |
| Drafts and pending work | No loss, unexpected confirmation, duplicate save, cancellation, or cross-owner movement |
| Integrity | All database integrity/foreign-key checks pass using read-only snapshots |
| Runtime metadata | Strict differences remain failures in the original report; an independent, narrowly scoped explanation is recorded separately |

J012's B-only pairing refresh difference is not a blanket allowlist for the
formal app. If the formal app refreshes a revision/timestamp, identify the exact
table/columns, before/after interval, and unchanged remaining values. Do not
silently exempt whole tables, rewrite the failed strict report, or infer success
from equal row counts alone. Keep real values and backups private.

## Stop and Recovery

1. On failed backup/readability, unexpected data change, migration/launch error,
   or signing conflict, stop progression. Keep all artifacts and failed reports;
   do not uninstall, clear storage, reset/stash others' work, or keep retrying.
2. If installation never succeeded and the old installation/data are unchanged,
   retain that state. A normal relaunch still requires the applicable device
   authorization and must not be repeated against a locked phone.
3. If the new binary installed but has not migrated data, recheck schema and
   the prior package's validity. An in-place binary rollback is considered only
   after explicit owner agreement for that recovery action and a fresh snapshot.
4. After migration, do not assume the v10 binary can open a v11 database.
   Preserve the current installation and fresh data; reproduce on copied,
   isolated data and prepare a forward fix. Do not downgrade a migrated live
   database or overwrite it with `before`, which could erase later owner writes.
5. Any data restoration requires a separately reviewed, explicitly approved
   recovery plan. First verify restoration into a new isolated directory, retain
   both versions, and account for all post-upgrade writes. This checklist grants
   no permission to replace live data, restore credentials, or change servers.

## Execution Record

Record approval reference, timezone/timestamps, source/package hashes, CI run,
B acceptance scope, old/new schema, signing expiry, each snapshot/verification
path, strict and explained comparison results, and the final device/UI state.
Separate completed installation, successful launch, UI checks, and owner
acceptance. Update AI-1 status and the delivery ledger only after actual evidence;
the unexecuted checkboxes here do not close J07 or any other Goal item.
