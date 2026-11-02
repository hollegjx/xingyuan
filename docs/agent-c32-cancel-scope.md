# C32 Cancellation Completion Scope

October 29, 2026. Follow-up to A1-160/A1-161.
Base: `2915f695637864f4240356f327dca404b747679f`.
Implementation: `3924b5ab4596570dea6e61ed5bef0ada3044f6d9`.
The final documentation delivery SHA is recorded in A2-101.

## Independent Finding

AI1's local QA commit `1e3d38c7814b8558ff9384cc283126043ac0ea0b` has the exact
base above as parent and adds only its test and report. AI2 read both in full
and compared their commit bytes with the corresponding `idea-ai1` files:

- `docs/agent-c32-independent-validation.md`: SHA256
  `1db95417a8f0b4982b33d8bddf7cbe8ee1c284b0b445f5bd3368f0343060d3dc`.
- `test/agent_c32_independent_test.dart`: SHA256
  `42912b168606da06efb3d08418cd0feb5c12be04688a1b2ad8548cb62faac573`.

Neither file nor the QA commit was merged. AI1's 1749/460/128/186 candidate
matrix and 29 focused passes are source-attributed, not AI2 reruns. Its additional
suite was 11 passed / 1 failed, exit 1. Those original results remain unchanged.

The open P2 is a late `cancel()` cleanup exception replacing a newer send's
error state. The old cancellation catch already existed before C32; this is
new coverage of an existing gap, not a demonstrated C32-introduced regression.
It is not a diagnosis of the installed B waiting incident.

## Change

Only `assistant_conversation_controller.dart` changes product behavior:

- Cancellation captures its operation number. The exact old request's durable
  cancellation still runs, but its subsequent refresh and error notification
  are ignored if a newer operation, identity invalidation or disposal intervened.
- Refresh captures both the operation and read sequence. Successful snapshots,
  identity errors and other failures may update the controller only while both
  are current. This also protects the interval where a new send has begun but
  its preflight has not yet requested a new refresh.
- Current-operation cleanup and refresh errors still surface. The fix does
  not swallow every storage error or claim that a pending write succeeded.

No style, layout, copy, model request, retry policy, timeout, consent, budget,
schema, protocol, prompt, backend, ledger, scoring or save-confirmation change.
The existing exact request-ID persistence and atomic commit checks remain.

## Regression Evidence

New author file: `test/agent_c32_cancel_scope_test.dart`, eight real-time tests
using synthetic in-memory SQLite and `ScriptedAgentService`, never a live model.
The first case follows A1-160's old/new model and first-failure-write ordering;
the original independent test itself was not rerun or altered by AI2.

On the unchanged base controller, the corrected new suite was **2 passed /
6 failed, exit 1**:

- Old cleanup failure overwrote the active new send's null error.
- Old successful cleanup started an unnecessary refresh for the new send.
- Cleanup errors replaced identity-invalidated or disposed controller state.
- Old refresh success/error published after a new send started but before its
  delayed preflight could start a competing read.
- The two negative controls, current cleanup and current refresh failure,
  already passed and must continue exposing their errors.

After the product-only fix, all eight passed. The corrected-red and fixed test
source SHA256 is identical:
`6eec81f89b79c36bf583d57beff4975e3f4234e0256c12be25e9c3d4d1d8bdf4`.
Checks include busy/stage/error, notification count, no stale snapshot replacement,
fresh request IDs, successful new response and zero formal goals/proposals.

Retained logs use `/tmp/xingyuan-ai2-c32-cancel-` and `-20261029.log`:

| Stem | Result | SHA256 |
| --- | --- | --- |
| regression-red | Test load failure, missing stage-enum import; not product reproduction | `d323b64c9aa19d192cdcfb844958c6ef9c51090e6e3e0ab28d3b884bf5e471c3` |
| regression-red-corrected | 2 passed / 6 failed, exit 1 | `ca56fc3d41760feebe3cebeb0ba479cb9265e69aa43045e3c7b38a0f826e4bed` |
| regression-fixed | 8 passed, exit 0 | `fdb4db275d82be1edd74b4ac0c9ec0c0c127eed69b6522bab977d97a59c9ea50` |

The import mistake was corrected before touching product code. Assertions were
not weakened. Original C32 and independent first failures remain retained.

## Final Verification

The final D7 matrix finished at 04:16:13 Beijing. All final gates exited 0.

| Gate | Result |
| --- | --- |
| Related Agent/controller/runner/network/UI suite | 304 passed |
| Full App | 1757 passed |
| Full server | 460 passed |
| Full core | 128 passed |
| Full eval | 186 passed |
| App/server/core/eval analysis | All four clean |
| Whole-source format | 543 files, zero changes |
| Generated/schema/dependency/earlier-evidence guard | 39 hashes unchanged |

The eight new cases are included in the 304 and 1757 counts, not separate
independent acceptance. All final commands and the fixed regression use the same
543 runtime-source contents. The final source still matches after the code commit.
Runtime-source canonical SHA256:
`2817610c78c2373667d9a82c315e5fbd983db644a84da96626836c8f71c4a177`.

Exact group commands (working directory `/path/to/Desktop/git/idea`):

```text
node /tmp/xingyuan-ai2-c32-cancel-verify-20261029.mjs regression red
node /tmp/xingyuan-ai2-c32-cancel-verify-20261029.mjs regression red-corrected
node /tmp/xingyuan-ai2-c32-cancel-verify-20261029.mjs regression fixed
node /tmp/xingyuan-ai2-c32-cancel-verify-20261029.mjs checks final
node /tmp/xingyuan-ai2-c32-cancel-verify-20261029.mjs matrix final
```

The verifier expands the related Agent/controller/runner/network/UI files,
full App/server/core/eval tests, four analyses and all Dart format paths.
Every test/analysis/format gate uses this localhost-only sandbox and the SDK
`/path/to/development/flutter/bin/{flutter,dart}`:

```text
sandbox-exec -p '(version 1)(allow default)(deny network*)(allow network* (local ip "localhost:*") (remote ip "localhost:*"))'
```

`/tmp/xingyuan-ai2-c32-cancel-commands-20261029.jsonl` records exact argv, cwd,
UTC timestamps, child exits, test hash, before/after source hashes and log hashes.
The new manifest `/tmp/xingyuan-ai2-c32-cancel-manifest-20261029.json` is sealed
once after verification; its hash and this report's hash are recorded in A2-101.
The 39-file guard includes generated/schema/dependency files, the unrelated
review document and the original C32 report/manifest. No old evidence is overwritten.

Final test log hashes, with the same prefix/suffix as above:

| Stem | SHA256 |
| --- | --- |
| focused-final | `d0f7da180a627340e1cd802c96de92f935e34e9cf8ffe5379a2998ba5b8ba2ba` |
| app-full-final | `916d7a51128089be3318a6622a450d4fd6261491109f0d1e85b18d0297941c91` |
| server-full-final | `9bf8819f8477eaaa0ce6823c644ceb4669a6aadee6ea42ab71ce267800a903b8` |
| core-full-final | `295e4c678afcb4c5f4cf6a994da81bf20847fe089d1dfa67ad70722741fa69de` |
| eval-full-final | `93e2cbcc9834970b282ec4ad22e69eef7e85bbd150835703575539b60f989ac5` |

## CI And Remaining Limits

AI2 queried the then-current base run `40754098235` once during the 04:02 Beijing
heartbeat, using `gh run view 40754098235 --json headSha,status,conclusion,jobs,updatedAt`.
It returned exact head `2915f695637864f4240356f327dca404b747679f`, completed/success,
updated at 03:58:41 Beijing; job `123048243614` completed at 03:58:40 and all
15 listed steps succeeded. A tool-result summary, explicitly not a full raw log,
is retained in `/tmp/xingyuan-ai2-c32-cancel-prior-ci-terminal-20261029.json`.
This closes only the base's pending CI. It does not cover AI1's additional P2
or confer CI success on the new fix. Do not requery/rerun that terminal run or
any older terminal CI. New delivery CI is reported separately in A2-101.
A1-162 subsequently reports the same terminal result; no duplicate query was made.

Independent confirmation of the exact follow-up remains AI1's next check.
No native, screenshot, accessibility, full AG/J13, semantic or owner acceptance
is asserted. No generators, standalone 20-scenario CLI, independent DST/Chinese
matrix, historical rescoring/comparison, signing, device or backend operation ran.
The installed B is still the previously reported a88a53e, not this candidate;
its root cause and requested read-only diagnosis remain separate. No repeated
owner authorization request is needed. A0 and all three A4 rounds remain closed;
no live calls, real configuration/credentials/private evidence, shared ledger,
real marker, deployment or data restoration were accessed or performed.
