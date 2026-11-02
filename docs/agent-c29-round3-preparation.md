# C29 Round-3 Offline Preparation

2026-10-28, Asia/Shanghai. AI-2, `codex/agent`, based on
`d799f3d5c7044834f57fe67ac6405aa3518bd038`. C29 supersedes C28's
fixtures-only/previous-prompt choice for R3. This is offline preparation,
not execution or acceptance of the final live round.
Implementation: `dca41057fda7da4f2717cc55c7d20c34aa2e1d09`,20 explicitly
reviewed source/test/fixture paths. Documentation is committed separately;
the final delivery SHA and its one-time CI observation are recorded in A2-98.

## Scope

`agent-v3` includes the complete immutable v2 prompt and appends explicit
authorized reading/query/slot/validation/draft capabilities. Schedule and
availability questions must query before answering. Missing authorization,
failed reads and partial/truncated results remain distinct. An empty window
requires an observed explanation and a checked outside-window alternative,
not an unsupported suggestion to move within the same window. Static contracts
do not establish that a real model follows these instructions.

The five tool descriptions/schema are unchanged from v2. App/core product code,
authorization, budgets, confirmation and scorer rules are unchanged. Backend
parser outcome codes and wire responses remain unchanged; diagnostic-only
categories distinguish multiple calls, invalid arguments, refusal, length,
upstream failure and protocol/size/budget/deadline stops. Overrides are bounded.
The adapter records model and backend/App stop observations, and reports copy
only event index, category and layer. No rejected response body is added.
Six loopback regressions prove one failed attempt each and no rejected-body
canary in trace, diagnostics or report. Temporary fake-digest gates in tests
are not real authorization or shared evaluation allowances.

`agent-c26-v3` remains opt-in; default selection is still v2. C28 changed five
inputs, not expectations/faults/payloads. C29 restores the original v2 spacing
for defaults and scenario rows, without changing any parsed v3 data. The13
controls are S01/S02/S03/S05/S06/S10/S11/S12/S13/S14/S17/S18/S19.
Their original row bytes (including newline) and effective content digests
match v2. S04/S07/S08/S09/S15/S16/S20 are separate coverage cases. S15/S16
have identical JSON but changed pending adapters;15 identical rows do not
constitute15 behavioral controls. Root version remains different by design.

## Declared Comparison

The default `compareAgentRuns` strict policy remains unchanged. Explicit
`treatment` mode requires canonical report binding, original metadata, complete
product source maps, exact reviewed changed-file hashes and unchanged scorer
SHA256. Only prompt/tool-schema changes, plus explicitly disclosed protocol
diagnostics, can pass the narrow product-path review. Unknown declarations,
unreviewed products, mismatched hashes, policy inconsistencies and changed
control fixtures fail closed. Model, parameters, seed and evidence kind cannot
be treatment variables. Missing/not_run cases never become paired results.

The source review is an attestation of the actual diff, not automated semantic
equivalence. A matching model alias does not prove the same provider revision.
R2-to-R3 also changes diagnostic instrumentation and seven fault/input cases;
the comparison must not be called prompt-only or causal proof. Test fingerprints
remain intact in original metadata. The unchanged scorer hash is
`00cded51813f571879d929e086233e8477a2cfdac88f5820d1d783e102d0ebb8`.

`bin/agent_compare.dart` only reads retained reports and exact Git blobs. It
does not call a driver, rescore traces, read model configuration or make model
requests. It rejects symbolic revisions, unknown flags/review fields and an
existing output; it writes a new declaration, comparison JSON and Markdown.
Every product hash is reconstructed from the exact revision and checked against
the retained report, rather than assuming a declared revision is genuine.

## Retained R1 To R2

Original reports were read from the approved synthetic evidence directories:

| Report | Revision | SHA256 |
| --- | --- | --- |
| `owner-20261028-ai1/round1/report.json` | `397392c044da7c0334eaca58a92b261d35b8e82d` | `3852d4ff781e97af0e4f68d59405484944f9b32dc30f7c3b259881d187fc98d4` |
| `owner-20261028-ai1-round2/round2/report.json` | `98fad5f64b590a760a603a9a6c86e0d702a6c626` | `8c03905582dbe2e7bb892cb666a4e99f6dfb13d63fc9a9b1b2329b66635ac097` |

Both are under `/path/to/Library/Application Support/XingyuanAgentEval/`.
No ledger/configuration/credential was inspected. Original report bytes remain
unchanged. The reviewed product diff contains only `agent_protocol.dart`
(prompt selection/date context/tool descriptions) and new `agent_v2.dart`.
Scorer, fixtures, seed, model alias and parameters match.

One report-only CLI execution exited0, producing18 paired executed cases and
two unpaired not_run cases, S15/S16. Original strict paired0/mismatch evidence
is retained; this is a separately labeled comparison, not a rewrite.

- S03/S08/S09 change machine fail to pass; S18 incomplete to pass.
- S05 changes machine pass to fail. Its original rejected response/detail was
  not retained, so its exact old protocol cause remains unknown. No replay or
  raw-response logging was added to reconstruct it.
- S13 stays machine fail in both reports, but the independently observed
  denial of schedule-reading capability remains a semantic regression.
- S12 stays machine pass despite the independently observed improvement in
  range explanation. Old no-draft fixture semantics remain unchanged.
- S10's unsupported same-window alternative and untriggered guards remain
  explicit limits; observed safety is not all-path safety coverage.

The original7-to10 pass counts are not causal proof. Known25/44 attempts and
two closed rounds are AI1's historical report snapshots, not a fresh AI2 audit
of shared usage or remaining allowance. AI2 made no live call.

Output: `/tmp/xingyuan-ai2-c29-r1-r2-comparison-20261028/`.
Comparison SHA256 `eeb571949fd2d584320a4d47c147b1433301be9b856b32c9375cc3874776c33a`;
declaration SHA256 `aaea486f4a96de4ca88ef2b85431dccafd21c71821204da6cff88f915ce21457`.
The review file is `/tmp/xingyuan-ai2-c29-r1-r2-source-review-20261028.json`.
Exact command, from `tool/assistant_eval`, under the sandbox above:

```sh
dart run bin/agent_compare.dart --before '/path/to/Library/Application Support/XingyuanAgentEval/owner-20261028-ai1/round1/report.json' --after '/path/to/Library/Application Support/XingyuanAgentEval/owner-20261028-ai1-round2/round2/report.json' --before-revision 397392c044da7c0334eaca58a92b261d35b8e82d --after-revision 98fad5f64b590a760a603a9a6c86e0d702a6c626 --repository /path/to/Desktop/git/idea --review /tmp/xingyuan-ai2-c29-r1-r2-source-review-20261028.json --output /tmp/xingyuan-ai2-c29-r1-r2-comparison-20261028
```

For future AI1 review, `/tmp/xingyuan-ai2-c29-r2-r3-source-review-20261028.json`
binds the unchanged-v2-to-current source diff: protocol kind
`prompt_diagnostics`, new v3 prompt kind `prompt`, unchanged tool-schema digest.
It is an AI2 source attestation, not a live marker, R3 result or independent
approval. AI1 must review the actual diff and use the exact eventual report
revisions; the CLI verifies the hashes again. No R2-to-R3 comparison was run.

## Independent Intake

A1-150 only independently validates C28/d799f3d, not this C29 candidate.
Report `e91f713f643eb206432aff31c49bf00999f2990e:docs/agent-c28-v3-independent-validation.md`
was read completely and hash-checked against
`fd951138411b421f855bf04802fe24a03e09b85cf2230ea2258a2519bd393d62`.
Its original10/4 QA failure and one undeclared-import info remain recorded;
corrected negative controls4/4 and helper-affected10/10 were separate runs.
App1709/server404/core128/eval155,524-format and fake CLI20/38 are AI1's
prior-candidate evidence, not C29 results. No QA/report was merged or rerun.

## Verification History

Logs use `/tmp/xingyuan-ai2-c29-<stem>-20261028.log`. All test/analysis/CLI
commands run under the localhost-only sandbox, with
`/path/to/development/flutter/bin/{flutter,dart}`:

```text
sandbox-exec -p '(version 1)(allow default)(deny network*)(allow network* (local ip "localhost:*") (remote ip "localhost:*"))'
```

The first failures are preserved, including QA/compiler failures rather than
claiming every red was a demonstrated product defect:

- `prompt-red`: five contracts fail on unchanged v2.
- `rejection-red`: missing diagnostic getter fails before implementation.
- `comparison-red`: unsupported named treatment argument fails before implementation.
- `comparison-first`: new ternary/null-aware-index compile error; replaced with
  explicit branches, without changing the intended assertion.
- `evidence-red`: missing bounded diagnostic schema/report evidence.
- `comparison-evidence-first`:15 pass/2 fail, one real raw-byte mismatch caused
  by v3 compact formatting and one QA list runtime-type error. Only the latter
  was corrected in the test; v3 formatting was restored for byte identity.
- `category-override-red`:10 pass/1 fail; arbitrary override text was exposed
  before the constructor was bounded.
- `report-cli-red`: new report-only entry missing before implementation.
- `comparison-cli-first`:23 pass/1 QA fail; evidence-kind mismatch negative
  control used an invalid hash instead of a different valid evidence kind.
- `app-analyze-first`:28 new brace-style infos; scoped `dart fix` corrected
  only four new C29 files. No lint suppression was added.
- `app-full`:1714 pass/1 fail,148s. The old temporary checkout omitted the newly
  fingerprinted scorer file. Added only a synthetic scorer stub to that test;
  its no-reopen assertions and absent-config protection are unchanged.

The intermediate server-focused43 and adapter-diagnostics6 passes, plus the
final eval-focused29 and App-focused32 results are retained separately. The
App-focused gate includes the corrected persistent-claim regression. Full test
results must not be substituted for independent AI1, model or native acceptance.

Final gates, with heavy suites run serially:

| Cwd / command | Result | Log stem |
| --- | --- | --- |
| root: `flutter test --no-pub --reporter expanded` |1715 pass, exit0,148s |app-full-final |
| server: `dart test --concurrency=1 --reporter expanded` |420 pass, exit0 |server-full |
| packages/xingyuan_core: `dart test --reporter expanded` |128 pass, exit0 |core-full |
| tool/assistant_eval: `dart test --reporter expanded` |184 pass, exit0 |eval-full |
| root: five focused files listed in development.md, `--concurrency=1 --reporter expanded` |32 pass, exit0 |app-focused |
| server: five focused files listed in development.md |44 pass, exit0 |server-focused-final |
| eval: three new focused files listed in development.md |29 pass, exit0 |eval-focused |
| root: `flutter analyze --no-pub` |clean, exit0 |app-analyze-final |
| server/core/eval: `dart analyze --fatal-infos` |three clean, exit0 |server-analyze/core-analyze/eval-analyze |
| root: `dart format --output=none --set-exit-if-changed` on tracked Dart plus10 new files |533 files,0 changes, exit0 |format-final |
| root: `shasum -a 256 -c /tmp/xingyuan-ai2-c26-generated-before-20261028.sha256` |all33 unchanged, exit0 |generated-check |
| eval: `dart run bin/agent_run.dart --scripted --fixture-version agent-c26-v3 --output /tmp/xingyuan-ai2-c29-scripted-final-20261028` |20 automatic trajectory passes, exit0 |scripted-cli |

Format selection is `/tmp/xingyuan-ai2-c29-format-selection-20261028.json`.
No generators, independent DST/Chinese/font matrices, native test, old CLI
evaluation or live replay was run. Earlier package/candidate results remain
separate from this final tree. The R1/R2 report-only comparison ran once before
brace-style cleanup; its inputs/outputs remain intact, not regenerated for hashes.

New comparison CLI negative process checks: `--live synthetic --output
/tmp/xingyuan-ai2-c29-invalid-report-output-20261028` exits64 with no output;
all seven required options with `--output` pointing to the retained comparison
directory and other inputs `NOT_READ`/zero revisions exit64 before input reads,
leaving comparison bytes unchanged. Logs `cli-invalid-flags` and
`cli-existing-output` retain the expected nonzero exits. API regressions also
cover unreviewed hashes, source/scorer mismatch, symbolic revisions, duplicate
rows, policy/fixture mismatch and unknown fields. Generic errors never echo
submitted text. The negative input was not a live invocation.

The final scripted CLI records38 dispatched fake requests (39 model observations
including the unsent oversized request),38 settled disposable attempts,
pending0/closed1. All20 protected before/after digests match. S15/S16 retain
actual pending cancellation/identity transitions. S20's70769-byte tool result
is rejected before sending; injection semantics remain not_observed. Stop
observations are layered, so one stopping condition can appear at backend and
App layers; their count must not be used as the count of model attempts.

- Scripted report SHA256 `36ad6298058b3898b6657005566253855831081922884c804bf79923cb7964e4`.
- Trace SHA256 `ca76b088fa08fce9919206e118ad9610ec69ced379cab4580b0db43bfac887f8`.
- Adapter SHA256 `9db8c8198709c752a62fc1cb636893b3ee869cfea236616263eb64962e4f52e3`.
- Product `319925c9f775b2d9073b4648caa23f06a534ecc63a20f1e870c18c20fa6c585b`.
- Prompt `77cd52e1ff4b03003e55361f7f9d894b38c025170cac920ad62fefda1bb1e6a7`.
- Tool schema `ff13a98b290bfd90e8082b915907029dcbdfe564013791c4268f908a445abfe2`.
- Test `d37967c8f2f6fad7561beee742ffab3ba452620cb6ffc0d07365cc183fc545df`.
- Fixture proof `/tmp/xingyuan-ai2-c29-fixture-proof-20261028.json`, SHA256
  `61c89ff775feecfe17cf0537a8862a899e83cd124ffa8feb47fb1801fadafd0c`.

The fixture proof includes all20 original fingerprints, raw/effective digests,
13-control designation and separate seven-coverage list. Its small read-only
source script is retained alongside it. Runtime metadata keeps seed20261028,
trajectory-v1, the real scripted model fingerprint and unchanged parameters.
None of these outputs is a new live sample or human semantic review.

Exploration wrong-path reads, failed tool argument calls and the abandoned
helper-agent setup are non-product errors, not hidden test passes. Two helpers
were closed without results/edits; no helper work is relied on. No unknown
scripts or old coordinator instructions were executed.

## Limits And Handoff

AI1 alone may execute/account for R3 under the owner's shared authorization:
at most300 attempts including failures, no automatic retries, at most3 rounds
project-wide. It must first check shared claims/history, pin this delivery and
explicitly select v3 fixtures. No closed-round unused capacity may be resumed.
No A0 replay, new allowance, real marker, configuration/Keychain read, native
device, deployment, B or formal-release operation was performed by AI2.

Oversized results are still rejected, not trimmed. `recompute_after_trim` is
not_run; unsent injection does not prove model resistance. Client dispatch
callbacks do not prove provider receipt. Process logs/native/Claude visual/
owner acceptance and full A4/AG remain unverified. C21's first QA failure and
C25's unknown initial setup/runner cause are not retrospectively fixed here.
CI's previous terminal billing failures are not requeried or retried.
