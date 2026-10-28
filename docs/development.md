# Development

## Toolchain And Local Use

Use Flutter 3.47.6 with its Dart 3.13.5 SDK. Keep the committed lockfiles.
Run `flutter pub get --enforce-lockfile` in the repository root. Run
`dart pub get --enforce-lockfile` in `packages/xingyuan_core`, `server` and
`tool/assistant_eval` before running repository-wide analysis or testing those
packages. Resolving only the root package does not install each subpackage's
test and lint dependencies.

The iOS project uses an example bundle identifier and includes no signing
credentials. For a physical device, select your own signing team and unique
bundle identifier in Xcode. Do not uninstall or overwrite an installation
containing personal data to try this source distribution.

## Offline Checks

From the repository root:

```sh
flutter analyze
flutter test
dart format --output=none --set-exit-if-changed lib test integration_test tool
```

From each of `packages/xingyuan_core`, `server`, and `tool/assistant_eval`:

```sh
dart analyze --fatal-infos
dart test
```

Tests use synthetic fixtures. Model calls, hosted services, notifications on
real devices, and native iOS interactions are separate opt-in activities. Never
attach real credentials or production data to CI. The existing Flutter workflow
also checks schema generation, server builds and synthetic subprocess probes.

After schema changes:

```sh
dart run build_runner build
dart run drift_dev make-migrations --no-test
dart run drift_dev schema generate drift_schemas/app_database test/drift/generated
```

Review generated diffs and run migration tests; do not regenerate historic
schemas to conceal compatibility failures.

## Optional Services

The local application does not require an account or a backend. To enable the
assistant or companion, deploy your own server. Example domains ending in
`.invalid` are deliberately unusable. No original host or credential is supplied.

`config/assistant-server.example.json` documents the configuration shape. Keep
the real configuration outside Git with owner-only permissions (mode 0600).
`base_url` must be your HTTPS model endpoint. The current adapter explicitly
accepts the `gpt-6-luna` model identifier; it is not a general promise of support
for arbitrary providers. Model availability and service costs are your own
deployment responsibility. A model key may be supplied through the private
`model_api_key` field, or the existing macOS Keychain integration. Never put it
in client defines, an example file, CI, screenshots or logs.

Configure `devices_file` to a private registry path. The server command below
requires that registry and valid model configuration. Issue distinct device
credentials using `server/bin/devices.dart`; its `issue` command prints a secret,
so run it only in a private terminal and never retain that output in CI logs.
Optional `companion_database` and `companion_objects` paths hold private data.
The Agent endpoint stays disabled unless a separate `agent_ledger_database`
is configured. Back up these stores under your own operational policy.

From `server/`:

```sh
dart run bin/server.dart --config /absolute/private/assistant-server.json
```

The server binds to loopback. The files in `server/deploy/` are templates, not an
installed service. Review HTTPS, reverse-proxy limits, permissions, backups and
authentication before exposing a deployment. Do not point a template at someone
else's service or reuse another person's credential.

Client configuration is provided using a local, ignored JSON file containing
your `ASSISTANT_BASE_URL`, passed with `--dart-define-from-file`. Device access
credentials are entered in the app and stored through its secure-storage flow.
Keep cloud/sync settings separate; the Supabase example is only an optional
development configuration, not a guarantee that hosted authorization gates pass.

## Evaluation And Release Safety

Run the package tests for offline evaluation. Live evaluation utilities require
explicit flags, private configuration and budget controls; publishing their
source grants no access to any model endpoint and no authorization to spend
someone else's quota. Some live guards retain deliberately invalid example
endpoints and must be reviewed for a self-hosted environment before use.

Before a public push, stage only intended files, inspect `git diff --cached`, run
`dart run tool/check_public_release.dart`, and run a redacting secret scanner
such as Gitleaks. Scan history as well as the current tree if adding any commits
from another repository. Do not merge private history into this distribution.
The public-release checks do not prove that a file contains no personal data;
manual review remains required.
