# R8 Assistant Boundary Lifetime

October 26, 2026, Asia/Shanghai. CO-9 / A1-95, existing J12/J13 reliability.
This is a scoped development candidate, not release or owner acceptance.

## Source And Mechanism

- Baseline: `7ddc3f933ef92fded776aceecd4443e8b7bb9c7e`.
- Immutable product/final tests: `a4879d3fb582d4d2173bc36cca6191ea3eafce39`.
- Original independent red test: `973adc5342cb5c4933e3287af50fc54e2a042941`.
  Imported unchanged in `8e6336619ed06ac7982c6b624fdb340ce1117aab`;
  its SHA-256 is `02936bcf980a6f682659dc13a616c1b74782805d92665d51398272f1c285d1de`.
- AI1 local report: `3b087173e8a61a153df1a3ea6f5209168c6ea3e3`.
  Its GitHub push/verification encountered TLS/EOF at handoff; local immutable
  evidence was used, not an assumed remote or CI result. AI1 owns its sync retry.
  A1-96 subsequently reports exact remote sync completed and CI40255326760
  failed before starting due to billing. Accepted from AI1, not queried again.
- Candidate branch: `codex/assistant-boundary-lifetime`; final delivery and
  exact-head sync/CI are recorded in the AI2 outbox, not inferred here.

AI1's isolated normal-discovery regression recorded two passing controls and
one failing same-Future rebuild. The assistant wrapper previously created a
fresh store.then mapping on every build, while LocalIdentityBoundary correctly
keeps its first repository stream and route lease. Later failed mappings had
no subscriber. Both files were unchanged from pre-R7 source9ddef; this was not
introduced by R7's local proposal SELECT retry. AI2 did not replay the before
suite or modify the controls to consume unexpected errors.

Only `assistant_identity_boundary.dart` changes product: 13 additions/4 deletions.
It becomes stateful and retains one late-final mapped Future. The unchanged
LocalIdentityBoundary still handles loading, genuine errors, identity generation,
pending switch, sticky invalidation, hidden children and modal dismissal. The
wrapper still passes the latest child/onReopen; explicit keyed remount may obtain
a new lease, but an ordinary rebuild cannot replace the old route's lease.
No blanket catch, provider invalidation, data reset, implicit write or model call.

## Caller Review

All seven assistant-wrapper call sites were inspected before editing:

- ChatDiaryPage: fixed initial conversation Future; its loaded edits/read retry
  and original store are unchanged.
- AssistantProposalPage: fixed initial store; load/error/confirmation remains.
- AssistantMemoryPage and AssistantMemoryEditPage: fixed store; provider-driven
  rebuilds and editor/confirmation/date-picker privacy remain guarded.
- AssistantSettingsPage: fixed store; settings and synthetic credential updates
  rebuild child UI without replacing its original lease.
- AssistantConsentBody: fixed store; current onReopen remains honored.
- AssistantSessionsPage: supplies a fresh Future.value(controller.store) on each
  build; the first lease remains fixed, while the current child still updates.

Direct LocalIdentityBoundary callers were inventoried, but non-assistant wrappers
are outside this correction and not claimed fixed. No other product file changed.

## Verification

Final execution at the immutable product/test source above: **27/27, 7s,
pipefail exit0**. The selection is 3 original/control cases, 6 new lifetime
cases, 1 full-page provider case, 13 assistant caller identity cases, 2 diary
pending-read/identity cases, 1 diary confirmation case and 1 edited-preview case.

```sh
flutter test test/assistant_initial_boundary_rebuild_test.dart test/assistant_boundary_lifetime_test.dart test/chat_diary_initial_provider_failure_test.dart test/assistant_identity_ui_test.dart test/chat_diary_initial_read_guard_test.dart test/assistant_diary_ui_test.dart test/journal_diary_edit_test.dart --name '^AI1 unavailable|^R8 |^R7 provider|^identity change|^pending identity|^inline consent|^R7 original lease|^chat-diary protects edits against identity' --no-pub --reporter expanded
flutter analyze --no-pub
dart format --output=none --set-exit-if-changed lib test
```

Analysis clean3.7s; format289 files/zero changes. `git diff --check` passes.
The original imported regression is byte-identical to973adc. The former explicit
probe was first run at its old path on the fix, then moved into normal discovery;
its entire `void main()` body/expectations are byte-identical, only header/imports
changed. No skip, swallowed test-zone exception or hidden red probe remains for
this diagnosed failure. This does not mean every possible initialization error
or the complete application has been tested.

New cases verify one identical mapped Future during four pending/six failed
rebuilds, six successful rebuilds with fresh Future.value input and updated child,
late success/failure after disposal, pending identity change before first success,
away/back remaining invalid even when given a new store, and explicit keyed
reopen using the latest callback. No private child builds while pending/failed.
Eight-table all-row/all-column snapshots stay equal, except explicit synthetic
identity transitions get a new comparison baseline. Existing caller tests retain
modal dismissal, no implicit data changes and synthetic service/credential guards.
No real credential, personal database or network/model service is used.

## Preserved Intermediate Results

All logs have prefix `/tmp/xingyuan-ai2-r8-` and suffix `-20261026.log`:

- `fixed-001`: original3 + old explicit full-page probe1, **4/4, 34s, exit0**.
- `lifetime-callers-001`: 17 completed passes and one new fixture cleanup failure;
  all13 existing caller cases completed, but this combined run was not green.
  The success case left a zero-delay Drift query-cache timer after unmount.
  Its teardown then waited for that timer; the final two new cases did not run.
  Only the verified own test runner PID72133 was interrupted; runner summary
  4:14 includes shutdown sink/stream errors. Shell exit0 is not a pass.
- `lifetime-002`: failure/unfinished selection only; plain pump() did not advance
  the fake clock, so the same cleanup assertion failed (0 pass/1 failure at4s).
  Own runner PID73069 was interrupted at1:57; shutdown errors/exit0 remain failed.
- The local Flutter binding confirms null-duration pump flushes microtasks but
  does not elapse fake time; Drift's markAsClosed uses Timer.run. Explicit
  pump(Duration.zero) after unmount completes that fixture cleanup without
  weakening the timer invariant, authorization or data assertions.
- `lifetime-003`: only the failed/previously unrun three cases, **3/3, 4s, exit0**.
- `final`: the complete scoped selection above, **27/27, 7s, exit0** at a4879d3.
- `analyze` and `format`: results above. Two exploratory missing-file paths,
  one documentation patch-context mismatch (no partial writes), and one
  overbroad process-output truncation were corrected by narrow lookups;
  these are not product failures. No unrelated process was interrupted.

Before candidate publication, the first remote branch lookup and push failed
with TLS SSL_ERROR_SYSCALL. A subsequent read-only lookup succeeded with no
matching remote ref, so the ordinary candidate push may be retried without
rewriting or duplicating a known remote delivery. The outbox records its result.

## Limits

No visual markup changed and no new screenshots/native run were produced; R7
images remain historical R7 evidence, not R8 screenshots. No old R6/native/model/
restoration matrix, whole-App/server/core tests or schema regeneration was run.
LocalIdentityBoundary, journal product, server/packages/ios/assets/.github/tool
and dependencies remain byte-identical to the baseline. Only CO-9's appended
review section (72 lines) is included with delivery after exact diff review.
Independent R8 verification, exact-head CI, native/real IME/VoiceOver and owner/J13
gates stay separate. No PR1 change, backlog push, phone/B/backend/formal App,
deployment, network-setting change, payment or closed-CI replay is authorized.
