# Agent Assessment Policy Binding

2026-10-28, Asia/Shanghai. AI-1 A1-143/A1-144; base candidate
`200fdeb55ca7d3b3d37fd86dd92a61130e4e83f8`. This is an offline evidence-integrity
fix, not an App authorization fix or a live-model quality improvement.
Implementation: `572ee92cef442e98e1ebb77a942c25586361826a` (three paths).
The separate documentation delivery commit and new CI are recorded in A2-94.

## Finding And Fix

Previously the scorer used each trace's `assessment`, while the report declared
the policy from run metadata. Removing only the metadata policy let a trajectory
case pass inside a report labeled full-evidence. Comparison checked only outer
metadata, so inconsistent reports could produce a false quality improvement.

Three boundaries now reject mismatches rather than relabeling evidence:

- `ScriptedTrajectoryDriver` validates every parsed trace against its declared
  run policy, including traces not subsequently selected for scoring.
- `evaluateAgentRun` snapshots validated metadata before awaiting the adapter,
  then checks each returned trace before scoring. A non-scripted driver cannot
  bypass the same binding. No report is returned for a mixed-policy run.
- `compareAgentRuns` validates each report's metadata, top-level policy and
  case assessments before pairing. Missing, null, unknown or contradictory
  trajectory declarations cannot yield comparisons or numeric deltas.

Absent legacy declarations still mean `full-evidence-v1`; its requirements are
unchanged. Historical full-evidence reports without the newer top-level/case
fields remain comparable. Consistent reports with different policies are
explicitly unpaired. A `not_run` row may omit assessment, but an explicit
contradiction is invalid and no unexecuted row is paired.
The existing CLI catches invalid input, returns64 and creates no output report;
it never prints input text or parser details. There are no model requests.

Only two evaluator source files and one evaluator test file change. App,
server/core, actual App driver, fixture data, prompt, schema/locks and workflows
are unchanged from the base. Other agents' tests/reports are neither merged nor
edited; the unrelated diary review and synchronization metadata remain intact.

## Red Evidence

Logs below use `/tmp/xingyuan-ai2-a1-143-` plus the stem and `-20261028.log`.

- `red`: initial19 regressions,1 pass/18 failures, exit1. The S08 reproduction
  emits full-evidence-v1/passed1 while its case is trajectory-v1. Missing,
  contradictory, null and unknown comparison labels were also accepted; both
  malformed CLI paths returned3 and created reports instead of rejecting.
- `fixed`: the initial19 regressions pass after evaluation/comparison binding.
- `ingestion-red`: two direct parser cases both fail before the ingestion guard.
- `focused-final`: all21 regressions pass with all three guards. The evaluator
  cases use a separate adapter, so parser rejection does not hide a missing
  evaluator check. Existing assertions and timeouts are not relaxed.

The first local full App run passed1695; evaluator144, server387/core128,
four analyses and519-file format also passed before the final parser guard.
Those intermediate logs remain; final App/evaluator checks follow the last code
change and do not silently replace that earlier evidence.

## Independent Intake

A1-144's immutable report was read and hash-checked at QA commit
`8f3a7ec1daa4119b91daa1f2ab679c405c743a04`; report SHA256
`2f2dc267828501411bf78bb5bc7829dc276c3ff834210d0963d3eefeb9f2b739`.
Its1695/387/128/125/13/39, normal CLI20/38 and generation results are for the
old200fdeb candidate only. Independent new QA is18 pass/1 failure, not all green.
The unchanged negative-control source/log and original comparison remain in
AI1's evidence directory. This fix still needs its own independent review.

AI1's stock CLI reproduction used two retained synthetic inputs, without
changing events or measurements. The old version exited0 and paired20 cases:
before20 incomplete -> after20 pass, despite a full-evidence report label and
trajectory cases. That result is a reproduced defect, not a model improvement.
The original input hashes are:

- after: `79a36500e54af4ec0d07cf8e8bb64a3f119f5c0f73aac2104016e8092f0f0798`
- before: `50f48c54cca5de0f7f2f5e52093818026f450fbd81f5134972865d278a43a1d2`

Only the reviewed repository CLI is executed against those JSON files. That
reproduction does not launch an App journey or replay a model attempt/budget.
Full unit/widget tests still use their ordinary isolated synthetic services.
Outputs go to a new AI2 directory, never into AI1's evidence. The independent
helper scripts were not run.

## Final Verification

SDK `/path/to/development/flutter/bin/`. Each executable below runs under:

```text
sandbox-exec -p '(version 1)(allow default)(deny network*)(allow network* (local ip "localhost:*") (remote ip "localhost:*"))'
```

Heavy gates are serial in this thread, not claimed host-wide exclusive.
Log stems use the prefix/suffix described above; all sessions ended.

| Cwd / Command | Result | Log stem |
| --- | --- | --- |
| Root: `flutter test --no-pub --reporter expanded` |1695/1695, exit0,2m32s after final parser change |app-final |
| Eval: `dart test --reporter expanded` |146/146, exit0 |eval-final |
| Eval: `dart test test/agent_eval_test.dart --name 'assessment policy binding' --reporter expanded` |21/21, exit0; included in146, not additive |focused-final |
| Server: `dart test --concurrency=1 --reporter expanded` |387/387, exit0; server tree unchanged by final parser change |server |
| Core: `dart test --reporter expanded` |128/128, exit0; core tree unchanged |core |
| Root: `flutter analyze --no-pub` |clean exit0 |analyze-final |
| Server/core/eval: each `dart analyze --fatal-infos` |three clean exit0 |server-analyze/core-analyze/eval-analyze-final |
| Root: `dart format --output=none --set-exit-if-changed lib test integration_test tool server packages` |519 files,0 changes, exit0 |format-final |

All33 generated/schema/lock hashes still match the C26 baseline. No generators,
server build, separate DST/font-specific UI matrix, native or screenshot export
were repeated for this evaluator-only change. App tests include ordinary
Agent/lifecycle cases; there is no new146-case Agent-only run to add to totals.

The report-only CLI uses retained C26 synthetic events, not a new20-scenario
App-driver evaluation. A generated copy changes only `evidence_kind` to
`scripted_trace` for the scorer CLI; trace bodies and source fingerprints are
unchanged. Source `synthetic-traces.json` SHA256 remains
`e8a51893fbbbf4e9ba4053a645a3ae6d9bed42f5a1d7402ed1a3e5ce1e79598d`.
Paths below are within `/tmp/xingyuan-ai2-a1-143-cli-20261028/`:

- `dart run bin/agent_report.dart --scripted valid.json --compare valid.json
  --output valid-final-out` returns0:20 trajectory passes,20 self-comparison
  pairs,0 regressions, product_acceptance not_run. Fingerprints refer to the
  retained source evaluation, not a newly run product/model sample.
- `--scripted missing-policy.json --output missing-final-out` returns64.
- `--scripted valid.json --compare missing-policy.json --output
  compare-final-out` returns64.
- Exact AI1 `policy-after-mismatched.json` plus `--compare
  policy-before-full.json` from `/tmp/xingyuan-ai1-c26-20261028-1llEqr/`, with
  output `ai1-exact-final-out`, returns64.

These commands run in `tool/assistant_eval/` with absolute input/output paths.
Their logs are `cli-valid-final`, `cli-missing-final`, `cli-compare-final` and
`cli-ai1-exact-final`. None of the three rejected outputs exists. The earlier
pre-parser-guard CLI logs/output are also retained, not overwritten.

Final report SHA256:
`31b85cf6b8b78fefa039ad2258287feeee3e2069c8a3e52cf0c0a7ea7b434868`.
Final comparison SHA256:
`21728c936158f667fdb31af037450c84e2c3178d475060468c441f27df19ecc5`.
The33-entry log/artifact manifest
`/tmp/xingyuan-ai2-a1-143-evidence-20261028.sha256` has SHA256
`b4ed23a60e36c6c69ae1e3c1550fac6cecad94f550618c3cc364326775d4197d`.
Implementation/verification occupied approximately05:24-05:38 Beijing;
wall time is not human effort or a promise for independent acceptance.

## Remaining Scope

Native/Claude visual/owner acceptance and all20 live-model semantic scenarios
remain unverified. The report rescore references C26's original38 fake requests;
it does not count those as new calls. Unit-test fake requests are not model samples.
Old subscription primary cause remains unknown; preserving its exception does
not recover it. Process-log observation, future live S15/S16 fault adapters,
prompt-only comparison restrictions and trim/recompute limitations remain.
A0 stays closed at29/30; no configuration, credential, live marker, device,
B/formal installation or deployment access. D7 uses local evidence; only the
new delivery SHA receives a CI record and no old terminal CI is queried.
