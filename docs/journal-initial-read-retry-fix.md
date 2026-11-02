# R7 Local Suggestion Read Retry

October 26, 2026, Asia/Shanghai. CO-8 / A1-94, existing J12/J13 journey.
This is a bounded candidate, not release or full provider/identity acceptance.

Follow-up: CO-9/A1-95 isolated the shared initialization mapping/rebuild failure.
[R8](assistant-boundary-lifetime-fix.md) repairs it and moves the unchanged full
probe assertions into normal test discovery. The R7 failures below remain the
historical record; R8's new source/evidence does not retroactively make them pass.

## Source And Scope

- Baseline: `9ddef237c9294ad6d012d97d795a09e735be5717`.
- Product: `801bc0914be842cc7ca4c53bccabff0808bcf568`.
- Final source/tests: `267fcc5b017a0bc0d726ea62d46992309dc2baf2`.
- Candidate branch: `codex/journal-initial-read-retry`. Final delivery/CI are
  recorded in the AI2 outbox; no journal backlog or PR1 change.
- Only ChatDiaryPage changes product, 14 insertions/4 deletions. Its original
  store future and identity lease remain fixed. Initial read is a guarded
  local operation reused by StatusPanel.retry, with one error instead of two,
  a local-document icon and existing loading feedback. Busy calls coalesce.
- Initial text is assigned only until the first successful row load. A retained
  old callback cannot reread or overwrite corrected preview text. When _row is
  still null, Back can leave while a read waits; late completion checks mounted.
  Existing loaded-preview save/cancel/discard/R5 guards are unchanged.
- No global provider invalidation, identity rebinding, model call, data reset,
  automatic save/cancel/retry loop, schema/server/persistence or shared UI change.

## Failure And Verification

AI1's final reproduction is `3f169b7e34267db804df132762af505eee29592c`,
reported in `ba02bf44d8203673971b4a854a6f67453619769d`: 0/4, each failing only
the missing same-route retry assertion after exercising safe Back/reopen.
This is a recoverable UI gap, not data corruption or permanent inaccessibility.
The exact 383-line regression was imported as `29377863ffaf1b0d1cff4b42aaf79e3f15a8d321`;
SHA-256 remains `a7698feb6bfa0e9eefd081bf24b7cecf1dc00ece72c0ecc99cb6d098bdcf118c`.
No before suite was replayed and no QA report/backlog was imported.

Executed results, kept separate:

- Original four normal/narrow, light/dark cases: **4/4, 3s**, Flutter's success
  summary. This first command used tee without pipefail; its shell exit0 is
  tee's exit, not a separately captured Flutter exit. The full log is retained.
- Additional guards001: **11 pass/3 fail, 9s, pipefail exit1**. Retry target,
  full label/semantics, repeated failure, duplicate callbacks, busy state,
  first-load/retry Back, edit retention, pending/cancelled/missing and identity
  switch-away/back checks passed. Two receipt fixtures omitted required schema
  fields; the third failure was the separate provider diagnostic below.
- Guards002: only the three failed names, **2 pass/1 fail, 7s, exit1**.
  Applied/undone fixtures now include all required receipt fields and pass.
  The provider case timed out because its delayed completion had mistakenly
  been inserted into the identity test block; the patch was corrected, leaving
  the previously passing identity body intact. No assertion was weakened.
- Thirteen healthy-store guard cases have passing evidence across those runs,
  not a new full thirteen-case run. Provider failures are not included in them.
- Queued cancellation/deletion before the local read: **2/2, 4s, exit0** at
  `155a3cdc45da1c5829924458bb1d8a0f17ab5923`; final source only removes an unused
  import. The query is held before opening its transaction, the fixture changes
  the row, and releasing the read reflects that state without resurrecting it.
- Related date/mode/edit/discard/save/undo/identity selection: **11/11, 9s,
  exit0**, not the full R5 or R6 suites. One selected existing editor identity
  check is included in this count; these are not eleven new R7 cases.
- App analysis clean, 4.1s. lib/test format: 287 files, zero changes. Earlier
  unused-import analysis warnings are retained, not reported as clean runs.

Working-tree executions above bind to the unchanged product bytes in801bc09;
the early evolving test sources were not immutable commits. The final source
and the original immutable AI1 regression are explicitly distinguished.
Snapshots compare all columns/rows of eight synthetic tables. Controlled state
changes have their own post-change baseline. Retry performs no writes; turn and
summary requests stay zero and service health calls do not increase.

```sh
flutter test test/chat_diary_initial_read_recovery_test.dart --no-pub --reporter expanded '--dart-define=DIARY_CAPTURE_FONT=/System/Library/Fonts/STHeiti Light.ttc' --dart-define=DIARY_CAPTURE_DIR=/tmp/xingyuan-ai2-r7-initial-fixed-001-20261026
flutter test test/chat_diary_initial_read_guard_test.dart --no-pub --reporter expanded '--dart-define=DIARY_CAPTURE_FONT=/System/Library/Fonts/STHeiti Light.ttc' --dart-define=DIARY_CAPTURE_DIR=/tmp/xingyuan-ai2-r7-guard-001-20261026
flutter test test/chat_diary_initial_read_queued_test.dart --no-pub --reporter expanded
flutter test test/assistant_diary_ui_test.dart test/journal_diary_edit_test.dart --name 'chat-diary|chat |identity|date change' --no-pub --reporter expanded
flutter analyze
dart format --output=none --set-exit-if-changed lib test
```

Logs use `/tmp/xingyuan-ai2-r7-` plus `initial-fixed-001`, `guard-001`,
`guard-002`, `guard-003`, `queued-001`, `focused`, `provider-probe`,
`analyze-001`, `analyze-final`, `analyze-clean`, `format`, then `-20261026.log`.
Except the first original-regression command, test pipelines used pipefail.
Two exploratory file lookups missed their filenames, and a broad process
listing was truncated; neither is a product finding or stopped any process.

## Separate Unresolved Provider Diagnostic

An unavailable assistantStoreProvider is not the assigned healthy-store read
failure. Both the initial synchronous fake and the corrected asynchronous
completion emit `StateError('R7 separate provider failure')` into the test zone.
Guards003 remains **0/1 failed, 4s**. This is not dismissed as a passing boundary
check or attributed to a confirmed product root cause without further analysis.

The full assertion body is preserved as an explicitly runnable diagnostic,
`test/support/r7_initial_provider_failure_probe.dart`. It intentionally does
not use the normal `_test.dart` discovery suffix: it is a disclosed unresolved
probe outside the healthy-store regression suite, not a skipped/green test.
Explicit execution at final source267fcc5 remains **0/1 failed, 2s, exit1**:

```sh
flutter test test/support/r7_initial_provider_failure_probe.dart --no-pub --reporter expanded
```

No error swallowing, provider reset or shared identity-boundary fix is included.
Coordinator/AI1 should triage this separately; do not claim all initial-provider
failure handling or all candidate checks are green. No baseline replay was made
to establish whether this diagnostic is pre-existing.

## Images And Remaining Gates

The original regression's after directory has12 PNGs/10 hashes; guard001 has8/8.
Combined: **20 filenames/16 distinct hashes**. The names `failed-initial` and
`failed-status` depict the recovered design's intentional read-error state;
`retried-proposal` follows its actual button, not the old Back/reopen workaround.
AI1 before12/10 remain untouched. AI2 viewed five after frames and two AI1
before frames, not every image. At4x the long error still scrolls; the full
two-character retry label, >=44px target and Flutter tap semantics were checked.
Loading captures retain a visible spinner and reading message. This is not
native, OCR, real Chinese IME, VoiceOver or whole-screen text acceptance.

Audit `/tmp/xingyuan-ai2-r7-initial-audit-20261026.json` binds final product/test/
helper hashes, source provenance, four exact observation JSONs, all image sizes
and hashes. The ignored audit script is under `build/assistant-eval/`.
Only CO-8's two approved review sections (103 added lines) accompany delivery.
No old R6/model/native/restoration run, phone/B/backend/formal App operation,
credential/private-data access, deployment or terminal-CI query was performed.
AI1 independent verification, scoped visual review and owner/J13 acceptance
remain open; the known billing restriction is not bypassed or re-notified.
