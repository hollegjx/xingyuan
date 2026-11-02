# Supabase Development Setup

Recorded on October 10, 2026 (Asia/Shanghai).

This records environment preparation authorized by the owner in the setup
conversation. It does not start the phase-two implementation, accept M1, or pass
G3. The owner signed in to the Supabase dashboard in Edge; the assistant then
prepared and created the development project with the owner's confirmation.

## Created Resources

| Item | Observed value |
| --- | --- |
| Organization | Habit Checkin |
| Plan | Free; no card or paid upgrade submitted |
| Project | habit-checkin-dev |
| Region | Southeast Asia (Singapore), ap-southeast-1 |
| Database | Standard PostgreSQL, not the OrioleDB beta |
| Dashboard status after provisioning | Healthy |
| Data API | Enabled |
| Automatically expose new tables | Disabled at creation |
| Automatic RLS | Enabled at creation |
| GitHub deployment integration | Not connected |
| Custom SMTP | Off; not configured |

Singapore is the initial development location, not a network-performance
guarantee or approval to migrate real personal data. The console's
`main / PRODUCTION` label denotes the project's primary branch; this project
is reserved for development.

No application tables, policies, functions, test users or business records were
created in this setup. New-table protection does not implement the future
application's authorization: versioned grants, RLS policies and negative-access
tests are still required before client data access is enabled.

## Credential Handling

- A generated strong database password was saved in this Mac's **login**
  keychain, not the iCloud keychain. The item is named
  `habit-checkin-dev / Supabase PostgreSQL`, with account `postgres`.
- The keychain entry was verified by its label, account and location. Password
  retrieval and a direct database login were not tested.
- The password is not stored in repository files, the App, command arguments or
  GitHub. Its temporary clipboard content was replaced after saving.
- The dashboard's default secret API key was not revealed, copied or exported.
  No additional API keys or personal access tokens were created.
- Changing or losing this Mac requires a separate credential-recovery or
  migration plan. This setup did not create a password backup.

## Client Configuration

`config/supabase.local.json` contains only `SUPABASE_URL` and
`SUPABASE_PUBLISHABLE_KEY`. It is ignored by Git and has owner-only `0600`
permissions; the committed `config/supabase.example.json` contains placeholders
only.

The local file is intended for the future
`--dart-define-from-file=config/supabase.local.json` configuration. The current
App does not read these settings, initialize Supabase, or upload records.
No runtime dependency or application code was changed.

A publishable key identifies the project, not the user, and is suitable for
client distribution only with correctly configured server authorization.
Never add a database password, `server-secret-key-` key, `service_role` key, SMTP
password or user token to a Dart-define file. Ignoring a file in Git does not
keep its values secret after they are compiled into an App.

## Verification Scope

The dashboard showed `Healthy` after creation. These checks were then executed
from this Mac's current network, without changing network settings:

| Check | Observed result |
| --- | --- |
| Local JSON and example | Valid JSON; exactly the two client-configuration keys |
| Local file permissions | `0600` |
| Git exclusion | `git check-ignore -v` matched `/config/*.local.json` |
| Data API root without API key | HTTP 401 |
| Data API OpenAPI root with publishable key | HTTP 401, `Secret API key required` |
| GET of nonexistent `habit_checkin_setup_probe` table with publishable key | HTTP 404, `PGRST205` |
| Auth public settings with publishable key | HTTP 200; email provider enabled |

The first connectivity probe expected HTTP 200 for the OpenAPI root and failed
that assumption. The returned error was inspected, and a follow-up check
verified the explicit secret-key restriction. No permissions were relaxed or
secret key exported to access schema metadata. The missing-table probe issued
only a GET with `limit=0`; it did not create the named table.

These results establish basic reachability and observed API responses, not
successful user login, business-data access, RLS correctness or phone-network
reliability. No emails were sent and no user sessions were created.

No application tests, iOS builds or physical-device tests were run for this
configuration-only change.

## Still Required

CLI preparation on October 11, 2026: Goal D07 explicitly permits installation.
`env HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1 brew install
supabase/tap/supabase` exited 0; `supabase --version` returned `2.120.0`.
The CLI is outside the repository. Homebrew automatically cleaned its old
cache/temp entries; no project files were intentionally removed. Future installs
should also set `HOMEBREW_NO_INSTALL_CLEANUP=1`.
No CLI login, project link, remote migration, Docker installation or local
Supabase stack was performed. Installation alone does not satisfy G3.

The later G3 preparation adds migration/role-test files and a client
configuration checker, not deployed objects. Current gate status and the
owner-authorized CLI sequence are in [G3 Gate](cloud-gate.md).

1. Select an authorized email sender, configure custom SMTP and verify delivery
   to two separate test inboxes. Do not reuse the database password for SMTP.
2. Implement versioned schema changes, grants and RLS, then test allowed and
   denied requests directly with distinct user identities.
3. Test the actual iPhone Wi-Fi and mobile networks, expired sessions, offline
   recovery and retry behavior.
4. Implement optional account login and personal synchronization under the
   agreed next milestone. Never upload existing guest records without the
   owner's explicit in-App choice.
5. Confirm any future paid service, quota upgrade, additional integration or
   access grant before enabling it.

References:

- [Supabase API keys](https://supabase.com/docs/guides/api/api-keys)
- [Custom SMTP](https://supabase.com/docs/guides/auth/auth-smtp)
- [Row Level Security](https://supabase.com/docs/guides/database/postgres/row-level-security)
