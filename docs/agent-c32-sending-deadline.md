# C32 Sending Deadline Recovery

October 29, 2026. Base: `a88a53e92766a9f022a69e2b389b1167c519d5af`.
Scope: C32 and A1-159, offline functional logic only. Implementation:
`bdb61e7a818e476469e34b3a30924cd9d01c0936`; delivery SHA is recorded in A2-100.
No style, layout, copy, prompt,
schema, tool, budget, server, scoring or automatic model-retry change.

## Evidence Boundary

The owner-reported B waiting screen and absence of Agent requests in server logs
were relayed by Claude. A1-159 independently read the old candidate's source,
not the device or server. Neither that report nor these synthetic tests proves
the cause of the installed B incident. AI1's separately requested read-only
diagnostic permission does not authorize AI2 to access the phone, credentials,
server, private evidence or any model endpoint.

`HttpAssistantService._send` already bounds the entire `perform()` operation:
access checks, credential read, `openUrl`, headers and body reads. It was not
changed. Eight local controls cover four access boundaries, a pending credential,
a raw loopback TLS handshake that never responds, response headers and body.
No real credential is read and no model is contacted. The 250ms transport faults
prove those synthetic paths, not a physical iOS transport observation.

## Reproduced Gaps And Fix

Eight regression cases fail on the original source:

- Initial identity check, input construction and request recording had no
  runner deadline. A successful service call's final identity check also ran
  outside `bounded()`'s timeout. These reads now share the remaining 60-second
  run limit and cancellation race. After an awaited identity check, the runner
  checks cancellation/end state again; late completion cannot advance the run.
- `AssistantConversationRunner` awaited `store.fail()` before rethrowing. A
  stalled transaction prevented failure delivery; a thrown cleanup error hid
  the original failure. Failure recording now has five seconds, cancels the
  turn first, and preserves the original typed error. A pending durable row is
  not represented as successfully updated; recovery remains request-ID scoped.
- The controller cleared `busy` and `stage` but only notified after its final
  database refresh. It now notifies first, then allows five seconds for refresh.
  A separate 90-second send limit also covers preparation, and prevents late
  preparation or callbacks from starting/updating an ended operation.

With failure persistence deliberately stalled, the original view predicate
also hid the existing retry button. A separate failing widget regression proves
that case. The predicate now recognizes a current in-memory failure for a
pending message. Existing controls, styles, labels, error messages and retry
confirmation remain unchanged. Explicit retry first resolves that exact failed
turn's pending row before beginning a new request ID. Failed persistence never
permits a model request before that local recovery succeeds.

Six widget cases cover a stalled model, stalled/throwing failure persistence,
stalled final refresh, delayed begin and delayed initial refresh. They check
existing failure UI and enabled retry, no implicit request, explicit confirmation
before a second request, a new request ID, rejected late text, and zero goals or
proposals. The default 60/90-second timers use Flutter's test clock; they do not
prove native scheduling, OS suspension, UI-thread starvation or full UI acceptance.
The eight lower-level deadline regressions use real bounded waits.

## Verification

The final D7 matrix completed on October 29 at 03:19:19 Beijing. Every gate
below exited 0; these are local synthetic results, not CI or native acceptance.

| Gate | Final result |
| --- | --- |
| Related Agent/controller/runner/network/UI tests | 296 passed |
| Full App | 1749 passed |
| Full server | 460 passed |
| Full core | 128 passed |
| Full eval | 186 passed |
| App/server/core/eval analysis | All four clean |
| Whole-source format | 542 files, zero changes |
| Generated/schema/dependency/unrelated-review guard | All 37 hashes unchanged |

The three new files add 22 cases: eight deadline regressions, eight unchanged
HTTP transport controls and six widget cases. Initial fixed deadline/commit/
subscription checks passed 15; the separate final UI suite passed 6. They are
included in the final 296/App1749, not additional independent acceptance counts.
All final gates used the same 542-source snapshot. Its canonical content hash is
`3443b8fbe9f4d9fe841a2d3365e7aadaa8888e9d78ffc3bac45b7323176064a4`.

The authored verifier `/tmp/xingyuan-ai2-c32-verify-20261029.mjs` records exact
argv, cwd, UTC timestamps, real exits, output SHA256 and before/after source hashes
in `/tmp/xingyuan-ai2-c32-commands-20261029.jsonl`. All commands run through:

```text
sandbox-exec -p '(version 1)(allow default)(deny network*)(allow network* (local ip "localhost:*") (remote ip "localhost:*"))'
```

SDK: `/path/to/development/flutter/bin/{flutter,dart}`. Gates:

```text
root: flutter test --no-pub <all test/agent*_test.dart plus assistant controller/runner/network/conversation UI> --concurrency=1 --reporter expanded
root: flutter test --no-pub --reporter expanded
server: dart test --concurrency=1 --reporter expanded
packages/xingyuan_core: dart test --reporter expanded
tool/assistant_eval: dart test --reporter expanded
root: flutter analyze --no-pub
server, packages/xingyuan_core, tool/assistant_eval: dart analyze
root: dart format --output=none --set-exit-if-changed <542 exact source paths>
```

The exact invocations used to run those groups were:

```text
node /tmp/xingyuan-ai2-c32-verify-20261029.mjs checks first
node /tmp/xingyuan-ai2-c32-verify-20261029.mjs matrix final
```

The command ledger expands both file lists and records each real gate exit.
Final log SHA256 values (prefix `/tmp/xingyuan-ai2-c32-`, suffix `-20261029.log`):

| Stem | SHA256 |
| --- | --- |
| focused-final | `59c4b02c5dce26d6271076e28daaff6ba2db7c3bb9b29d740b1f8755af7e7c23` |
| app-full-final | `01bb1df932d115c38ae6dd1cb391721d3feae4fa9789ec4ec8f3a157e3fa3577` |
| server-full-final | `fccf306953aa1397c95eff69738b8b95b6c768e3ffa9f16072fdfb9043554700` |
| core-full-final | `04c80a8cc18d7c240ed754d202e71c3c6762c0cf84de89325ed976e6dbb7c2b7` |
| eval-full-final | `0850d842a87f8e2fd5e01fdabafc327199df6be92c19f95030070f4532b54f15` |

The final manifest `/tmp/xingyuan-ai2-c32-manifest-20261029.json` indexes the
retained logs, command ledger, verifier, source snapshots and handoff documents;
its SHA256 and the report SHA256 are recorded in A2-100, avoiding self-reference.
A 37-file guard covers generated code, schema fixtures, dependency manifests/
locks and the pre-existing unrelated
review document. No generators, dependency resolution, standalone live/20-scenario
CLI, historical rescoring, separate DST/Chinese/native or device gate is rerun.

## Retained Failures

Logs are `/tmp/xingyuan-ai2-c32-<stem>-20261029.log`:

- `deadline-red`: four product failures, then an author-created mixed widget
  fixture waited indefinitely. Interrupted deliberately; its wrapper returned0,
  not a passing suite. `deadline-red-corrected`: all eight assertions failed,
  exit1, using bounded real-time fixtures. No assertions were weakened.
- `focused-first`: seven unchanged transport controls passed; three test-file
  loads failed because a newly added import was mistakenly appended below the
  runner declaration. The format command also exited65. Fixed the import error;
  `focused-fixed` then passed15 deadline/commit/subscription cases. This was an
  author edit error, not the original B failure.
- `ui-first`: missing database-type import, load failure. `ui-retry-red`: the
  constant overridden store did not refresh the consent provider, so the input
  was absent. The fixture now establishes synthetic consent before mounting.
- `ui-retry-red-corrected`: true behavior failure, retry button absent while
  persistence is pending, with the original view predicate restored temporarily.
- `ui-fixed`: two passed, then a QA expectation wrongly required `busy=true`
  after an immediate failure; a bare-controller initialization fixture stalled.
  Interrupted deliberately (wrapper exit0, not success). Use the normal mounted
  harness and only expect waiting while the fault is actually pending.
  `ui-final`: all six passed, including the additional persistence-error recovery.

Exploratory missing paths and truncated document reads are not product failures.
Original failures, historical schema12/Security/Locked observations, C21 stop and
C30 protocol findings remain intact. No root cause is retroactively assigned.

## Handoff

AI1 should independently validate the exact new candidate's failure notification,
deadline, explicit retry and late-work protection. Native/owner diagnosis and UI
visual design remain separate; Claude owns visual patches. No deployment, signing,
rebuild/install, phone or production operation is authorized by this report.
A0 and all three A4 rounds remain closed at the previously reported119 attempts;
no fourth round, credential/config read, real marker or ledger reset occurred.
