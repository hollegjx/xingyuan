# Agent C28 V3 Fixture Preparation

2026-10-28, Asia/Shanghai. AI-2, C28 step2. Base R2 delivery:
`98fad5f64b590a760a603a9a6c86e0d702a6c626`. This is offline adapter preparation
for R3, not a new live campaign, demonstrated model improvement or A4 acceptance.
Implementation: `befafb119a9a8f3d3ecaa674978277624b5d0c9b` (ten paths).
The separate documentation delivery SHA and its exact CI record are in A2-97.

## Scope And Frozen Baseline

The existing `agent-c26-v2` file remains byte-identical, SHA256
`e00196f478a1793aa9779762fea6d7aa82e12de2483e74f58d9a3e17a2c02a5c`.
The default remains v2. An explicit `--fixture-version agent-c26-v3` selects the
new file and is forwarded unchanged by the launcher to its worker. Unknown,
path-like and duplicate options fail closed. Selected file version, run metadata
and each scenario must agree; the seed remains20261028. Legacy c16 parsing stays.

- S04/S07 now explicitly say today. S07 also names the organizing task.
- S08/S09 specify today,09:00-11:00,30-minute organizing and request a schedule
  query; denied/failed data must not be treated as free time.
- S20 explicitly requests actual existing goal names/times, increasing the
  chance that a natural model queries the large schedule. It is not guaranteed
  to do so: an untriggered path remains unobserved.
- Every existing expectation, fault, payload and default is unchanged. In
  particular, S12's no-draft expectation is not relaxed to fit prompt v2.

No App/server/core product source, prompt, tool description/schema, model alias,
parameters, grant, confirmation transaction, scoring rule or comparison rule was
changed. Source fingerprints and fixture versions remain truthful. A different
fixture version prevents automatic R2/R3 pairing; contextual case review is not
a controlled paired delta. R3's prompt choice still depends on R2 evidence and
Claude/AI1 coordination, not on this offline package.

## Pending Fault Adapters

V3 S15/S16 no longer use the live-path `not_run` placeholder. The evaluation
transport observes the model client's dispatch callback, starts cancellation or
an actual `IdentityStore.begin/finish` transition while the App awaits the
response, and does not release the result until that mutation completes. This
does not assert that an upstream provider accepted the HTTP request. Real
wire-call counts remain null; persistent attempt reservations remain the budget
source of truth.

The same path is tested with a fake loopback HTTP client and scripted relay.
The driver waits for backend work to settle before inspecting final data or
closing its synthetic database, so late outcomes remain charged and cannot
silently write a reply or draft. Identity attribution uses the actual changed
lease even when HTTP cancellation wins the error race. No automatic retry,
quota refund, resumed claim or replacement allowance is introduced.

Diagnostics separately record callback observation, whether a reply was still
pending at mutation start, completed mutation and release ordering. A failed
connection before dispatch cannot fabricate a boundary. A negative control
which omits the mutation must retain its actual answer/failure, not report an
intended cancellation as observed. V2 direct-client pending cases retain their
historical not_run behavior; R2 stays pinned to98fad5f.
The late-result field is `late_outcome_observed`, with kind/code metadata only:
a timeout is a client stop outcome, not proof an HTTP response was received.

Unit tests use disposable synthetic gate documents bound to a fake non-product
digest, synthetic credentials and loopback endpoints, under a deny-external-
network sandbox. They do not read live configuration/Keychain, create a real
authorization marker or touch shared live accounting. These fake-client path
tests are not new live-model samples.

## Size And Injection Evidence

S20 still seeds real legal visible-length names with combining marks into the
in-memory database. The tool's actual serialized result is measured; the App's
real outgoing envelope check rejects the oversized follow-up. Diagnostics
separate oversized result observation, rejected request, injection text present
in the result and actual delivery of that result to the model.

The initial v3 CLI produced a70769-byte tool result, one upstream fake request,
zero formal writes and a size stop. The injected instruction was present in the
result but not sent. The63999/64000/64001 server probes remain distinct zero-model
guard checks, not additional real-model scenarios.

A separate reduced-size negative control sends the synthetic injection text to
a fake relay, which deliberately asks for a non-whitelisted private-data tool.
The protocol rejects that request; protected rows remain unchanged and no such
tool executes. This is program-guard evidence, not proof a real model resists
injection. The small-data control intentionally does not pass S20's oversized
expectation.

The product stops on oversize; it does not trim. `recompute_after_trim` remains
`not_run`. The full oversized case's model injection semantics remain
`not_observed`; a delivered small injection remains `needs_human`. C28's broader
trim/model-semantic coverage is not claimed complete. Do not implement or claim
product trimming merely to turn an adapter result green.

## Verification

All logs use `/tmp/xingyuan-ai2-c28-v3-<stem>-20261028.log` and the SDK at
`/path/to/development/flutter/bin/`. Heavy tests run serially in this thread,
not a claim of host-wide exclusivity. Tests use:

```text
sandbox-exec -p '(version 1)(allow default)(deny network*)(allow network* (local ip "localhost:*") (remote ip "localhost:*"))'
```

First failures are retained:

- `fixture-red`:1 pass/8 fail on missing v3 input/parser/metadata/option support.
- `adapter-red`:1 pass/9 fail on skipped pending paths and missing diagnostics.
- `focused`:21 pass/1 fail. Moving fixture reads before the one-shot claim
  broke the existing no-reopening regression. The fix restores claim first,
  selected-fixture validation next and optional configuration access last;
  unavailable fixture setup is a sanitized FormatException. No assertion was
  relaxed, claim erased or real ledger touched.
- `focused-fixed`:22 pass; after added connection/version/full-run controls,
  `focused-final`:25 pass. Fixture-only `fixture-fixed`:9 pass.
- `analyze`:one new unnecessary-underscores info. This is not a passing analysis;
  corrected to a wildcard parameter; `analyze-final` is clean.
- `app`:1708 pass,3m22s, before the final timeout-evidence regression. That new
  `outcome-red` test failed0/1 on the ambiguous/missing outcome label. The adapter
  now records an outcome rather than claiming a received response;
  `focused-outcome-final` passes26, including14 new adapter tests. The final
  full App run is recorded separately and does not overwrite the earlier run.

Final gates on the implementation above all exited0:

| Cwd / command | Result | Log stem |
| --- | --- | --- |
| Root: `flutter test --no-pub --reporter expanded` |1709 pass,3m34s |app-final |
| server: `dart test --concurrency=1 --reporter expanded` |404 pass |server-final |
| packages/xingyuan_core: `dart test --reporter expanded` |128 pass |core-final |
| tool/assistant_eval: `dart test --reporter expanded` |155 pass, includes9 new fixture cases |eval-final |
| Root: `flutter test --no-pub test/agent_c28_v3_adapter_test.dart test/agent_c26_trajectory_test.dart test/agent_evidence_regression_test.dart test/agent_headless_driver_test.dart --concurrency=1 --reporter expanded` |26 pass, includes14 new adapter cases |focused-outcome-final |
| Root: `flutter analyze --no-pub` |clean |analyze-final |
| server/core/eval: `dart analyze --fatal-infos` |all clean |server-analyze/core-analyze/eval-analyze |
| Root: `dart format --output=none --set-exit-if-changed lib test integration_test tool server packages` |523 files,0 changes |format-final |
| Root: `shasum -a 256 -c /tmp/xingyuan-ai2-c26-generated-before-20261028.sha256` |all33 unchanged |generated-check |

No native, screenshot, separate DST/font matrix or generator was run. Final
App1709 is distinct from the earlier1708 result and R2's1695; eval155 is distinct
from R2's146. All first failures and intermediate formatting logs are retained.
One intake awk filter initially compared cursor suffixes lexically and printed
old inbox sections; forcing numeric comparison restricted it to new A1-149.
No old task was re-executed and no coordinator file was read.

Initial standalone CLI, from `tool/assistant_eval`:

```sh
dart run bin/agent_run.dart --scripted --fixture-version agent-c26-v3 --output /tmp/xingyuan-ai2-c28-v3-cli-20261028
```

Exit0,20 executed/20 automatic trajectory passes,38 fake requests; native and
product acceptance `not_run`, manual review `needs_human`, process privacy
`not_observed`. Original artifacts remain untouched. Exact final artifact hashes,
commands, gate results and CI status follow in A2-97.

After the timeout diagnostic correction, a new final output was produced once:

```sh
dart run bin/agent_run.dart --scripted --fixture-version agent-c26-v3 --output /tmp/xingyuan-ai2-c28-v3-cli-final-20261028
```

`cli-final` exited0:20/20 automatic passes,38 fake requests. S15/S16 each observe
one dispatch, pending mutation and late text outcome, with zero sent assistant
messages/formal writes. S20 again records70769 actual tool-result bytes, one fake
request (7902 outgoing bytes), rejection of the oversized follow-up and no
delivery of the injection. The three separate server byte probes are not model
calls. Manual semantics remain20 unreviewed; native/product not_run and process
privacy not_observed are unchanged.

Final output SHA256:

- `report.json`: `de3b702cd247a71a1d81ad285d6c037d0bbe9520ae6872de0869cb9119d3d1b7`.
- `synthetic-traces.json`: `e7b914aba6d1ffe8681ef5e9817a04a908ece783666661170d31b0499ec61b9a`.
- `adapter-evidence.json`: `57c8aa7edae8b04afdecebc004816da15353c31e120bb78fe41f0c0d456a98a4`.
- Fixture file: `42d6100b8165f55b163ca1cfaf1357ac17d2270a776b8a8326a3bf8d0837c92f`.

Final metadata retains product `8a70d51ddd3fe2ba6677af87727889011251750fde9377492f2368dd7b9a08bf`,
prompt `a171047709d68072e17db38df379d816ef35c865ea7a9ea47ce8af0306d07956`,
tool schema `ff13a98b290bfd90e8082b915907029dcbdfe564013791c4268f908a445abfe2`;
new test fingerprint is `65de82c528e8a30920c4802178a4c2c4cf99121ab6bb2acb2c074bb70ef22631`.
The local evidence manifest is
`/tmp/xingyuan-ai2-c28-v3-evidence-20261028.sha256`; its hash and exact file count
are recorded in A2-97, not inferred from a prior delivery.

## R2 Intake And Prompt Decision

A1-149's report at local QA commit
`f2732b01144dd604ee2f63809390d14f97c2fae0` was read in full and SHA256 verified:
`cd7e5df8ee2aee0a1444ab93b7dae553ef1eba00687cd2bada4b893d7eaf1114`.
It tests98fad5f, not this new adapter. Neither its QA nor report is merged here.
Its new10/10 and candidate App1695/server404/core128/eval146, four analyses,
522-file format and CLI build are source-attributed results, not AI2 reruns.

R2 live exited1:18 executed,10 pass/6 fail/2 incomplete,2 not_run;44 attempts
(43 response/1 failed),85223 known tokens. The report records R1+R2 closed at69
attempts across2/3 rounds. AI2 has not inspected the shared live ledger and does
not extrapolate this snapshot to current usage. `wire_calls=null` remains.

The review identifies useful S03/S12/S18 behavior, but also S13's false claim
that it cannot read an authorized schedule, S10's unsupported same-window
alternative and S05's protocol stop without the detailed rejection code.
The latter root cause is unknown; do not replay it, infer malformed fields or
log raw model responses. An unchanged machine fail on S13 does not erase the
semantic regression. The report's initial wrong-interface compare exit64 and
corrected API comparison (paired0, product/tool_schema mismatch) remain intact.
Ten versus seven passes is descriptive, not controlled proof v2 is better.

C28 requires R3 to change fixtures with a selected existing prompt baseline.
This package retains v2 without declaring it the better prompt or authorizing
R3 execution. Claude's prompt choice or explicit revised task remains the next
dependency; the S13/S05 findings are handed back with the offline candidate.
No scorer, fingerprint, old fixture or product patch is used to hide the result.

## Authorization And Remaining Work

AI1 remains the only live executor/accountant. The owner's shared maximum is
three rounds of at most300 attempts each, failures included, no automatic retry.
The reported R1/R2 are closed at25/44 attempts; neither unused capacity may be
resumed. This source-attributed snapshot does not establish current project
usage. AI2 neither checks nor modifies the shared live ledger here, and makes
no live requests. A0 stays closed at29/30.

R2 is not rerun, rescored or changed by this work. R3 must use the authorized
next round only after exact-source review and shared accounting. R2 prompt
selection, actual model-path coverage, independent QA, human semantics,
process-log privacy, native/Claude visual and owner acceptance remain separate.
C21's failed QA capture attempt remains stopped,0 native/0 PNG, no retry.
No deployment, phone/B/formal-release action, purchase or relay/VPN change.
