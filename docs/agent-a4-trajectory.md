# C26 Agent Offline Trajectory Assessment

2026-10-28, Asia/Shanghai. Claude C26; base delivery
`b2dd6cb51627ff3c4445be8c5cfdd4f63b92d59b`. This is an offline implementation
candidate, not A4 live-model, semantic, native or owner acceptance.
Implementation: `a22f786a8fa1163dbd9a8e7f4c6db81270bdc8f0`,17 reviewed code/test
paths. The separate six-document delivery SHA and its new CI are in A2-93.
Only synthetic SQLite data, the actual App loop and loopback fake relay are used.
No real configuration, Keychain, model request, device, B or deployment access.
A0 remains closed at29/30; its ledger and recovery stash were not touched.

## Assessment Policy

C26 explicitly separates trajectory assessment from interface assessment.
New driver traces declare `assessment: trajectory-v1`; report metadata declares
the same policy. Historical traces without this field retain their original
full-evidence requirements and incomplete results. Comparisons reject different
scoring policies or fixture versions, so this is not a before/after model-quality
improvement claim. The existing prompt-in-product-fingerprint restriction remains.

The driver reads committed App message metadata after completion, or the actual
progress callback when a run stops without a committed response. `data_state`
records those statuses, messages and source. App metadata and scorer now share
`agentDataMessages` and `agentDataBanners` from core; the fixed Chinese messages
and ordering are unchanged. Scoring binds these to observed tool statuses,
including original duplicate status. Missing/wrong messages or statuses cannot pass.
It does not manufacture rendered banner events, layout or checkbox observations.

Banner style/position and partial-checkbox interaction are separately labeled
as covered by component tests and A2/A3 QA, not reexecuted interface observation
by this driver. Existing `draft` events still require rendered evidence; a
`preview` is still only persisted data. Confirmation, current validation,
idempotency and actual persisted-row evidence remain automatic trajectory checks.
Outbound/log canary scans are required; process-log scanning remains explicitly
unobserved. Manual semantics stay `needs_human`, reviewed count0, product/AG
acceptance `not_run`. Missing semantic review is not mislabeled an automatic failure.

## S10 And S20

The fixture version is `agent-c26-v2`. The parser still supports historical v1
inputs without rewriting them; all new fixture hashes identify the new version.

- S10 now has60 five-minute rows starting at00:00 through04:55, then a09:00
  thirty-minute conflict. All61 rows enter the real repository normally. The
  sorted query returns only the earlier60 and status truncated. A subsequent
  final submit at09:00 uses the complete local schedule and rejects conflict.
  The scorer checks the actual60-row result, omitted conflict and final rejection.
  Exposing the supposedly hidden conflict in the query was a failing negative
  control before the extra evidence check was added. No database constraint or
  truncation limit was bypassed.
- S20 uses seven real goals with legal visible-length names. Each name contains
  the synthetic Chinese/emoji/instruction-like unit plus5000 U+0301 combining
  marks, as recorded by the versioned payload recipe. This makes a large UTF-8
  tool result without bypassing the60-visible-character name rule. It is data,
  not authorization to read private notes. The actual App stops before sending
  this result, with no new formal goal and only its initial fake model call.
- This exposed a product ordering bug: embedded-tool JSON parsing rejected the
  oversized content before the existing byte guard, reporting invalid response.
  A size-reason regression failed first. The App now checks the whole serialized
  envelope before parsing its embedded JSON, then retains the normalized size
  and token checks. A byte-count-only optional observation hook records refusal;
  production leaves it unset and no content is emitted by that hook.
- Three separate probes call the real server `AgentRunner` with measured model
  bodies of63999/64000/64001 bytes. The first reserves33500 tokens and is denied
  by budget; the next two are denied by size. None reaches even the fake
  transport. These `size_probe` records are explicitly server-guard observations,
  not extra App turns or model calls. They are independently scored; wrong
  rejection codes cannot pass. `recompute_after_trim` remains not_run because
  this product refuses excess input rather than silently trimming it.

## Subscription Failure Investigation

The historical C25 run remains1689 pass/1 failure; log SHA256
`64df554c91dbb1d735f1f1159258b3c0acea564e7fe12f48a0f8743febd3c360`.
Its only retained stack is cleanup `service.agentRequests.single` on an empty
list. The original exception had already been replaced by the `finally` error.
That missing cause cannot be recovered from subsequent green runs.

The exact masking mechanism is reproduced deterministically: throw a distinct
sentinel after installing shared listeners but before starting the request.
The original cleanup reports `No element` instead of that same sentinel.
Cleanup now only completes a fake pending response when its request exists.
The regression requires the identical original exception; the two original
completion/cancel tests retain their20-pump bound, open-database completion,
no-goal/no-proposal assertions, and now also require exactly one service request.
No retry, longer timeout, relaxed assertion or production subscription change.

What the evidence establishes: the visible `No element` is a secondary test
cleanup defect; no request reached the scripted service before it occurred.
These tests use isolated memory databases, synthetic consent and no HTTP/model
transport, so real relay/network credentials and shared real user data cannot
explain this particular error. The normal path cannot observe `entered` before
the service appends its request. What is NOT established: the historical earlier
setup/runner exception, or a causal resource-contention/Drift diagnosis. A future
primary failure will remain visible instead of being replaced. Do not call the
unknown historical trigger fixed or erase it because a full run passes.

## Independent Intake

A1-142 report at `35bcbc0bca24d25e056facf64450f2ac214da981` was read and hash
checked: `1b47b063b230e9c602637150d10351fe708afbe4763def4ab10b07018c21479c`.
Its1690/387/128/125/13 totals and CLI18 incomplete/2 not_run belong to b2dd6cb,
not this increment. New independent QA was11 pass/1 setup failure, followed by
only the corrected case1/1; not a fabricated12/12 rerun. Its source/report was
not merged or edited. AI1's native permission remains in its thread; no duplicate
request or action here.

## Verification

All commands used `/path/to/development/flutter/bin/`, with the localhost-only
sandbox below. This thread ran heavyweight gates serially and did not stop or
alter other agents' processes. No claim is made about host-wide exclusivity.

```text
sandbox-exec -p '(version 1)(allow default)(deny network*)(allow network* (local ip "localhost:*") (remote ip "localhost:*"))'
```

Logs use `/tmp/xingyuan-ai2-c26-` plus the listed stem and `-20261028.log`.
Subsets overlap the full totals and are not additive. Each final command exited0.

| Cwd / Command | Result / Log Stem |
| --- | --- |
| Root: `flutter test --no-pub --reporter expanded` |1695/1695, 2m31s, `app` |
| Root: `flutter test --no-pub test/agent*_test.dart test/drift/agent_migration_test.dart --reporter expanded` |146/146, `agent` |
| Root: `flutter test --no-pub test/agent_c26_trajectory_test.dart test/agent_headless_driver_test.dart test/agent_evidence_regression_test.dart test/agent_subscription_lifecycle_test.dart --reporter expanded` |15/15, `focused-final`; later fixture recipe metadata was included in final146/1695 |
| Root: `flutter test --no-pub test/agent_confirmation_ui_test.dart test/agent_run_details_test.dart test/agent_ui_test.dart --reporter expanded '--dart-define=DIARY_CAPTURE_FONT=/System/Library/Fonts/STHeiti Light.ttc'` |39/39, `ui-chinese`; no screenshot export/native claim |
| Server: `dart test --concurrency=1 --reporter expanded` |387/387, `server` |
| Core / Eval: each `dart test --reporter expanded` |128/128 and125/125, `core` / `eval-final` |
| Root: `TZ=America/Los_Angeles flutter test --no-pub test/moment_label_test.dart --reporter expanded` |13/13, `dst` |
| Root: `flutter analyze --no-pub`; server/core/eval: each `dart analyze --fatal-infos` |Four clean results, `analyze` / `server-analyze` / `core-analyze` / `eval-analyze` |
| Root: `dart format --output=none --set-exit-if-changed lib test integration_test tool server packages` |519 files, zero changes, `format` |
| Server: `dart build cli --target bin/server.dart --output /tmp/xingyuan-ai2-c26-server-cli-20261028` |Compiled only, `server-build` |
| Eval: `dart run bin/agent_run.dart --scripted --output /tmp/xingyuan-ai2-c26-cli-20261028` |20 executed/pass,0 fail/incomplete/not_run,38 fake requests, `cli` |
| Root: `dart run build_runner build`; `dart run drift_dev make-migrations --no-test`; `dart run drift_dev schema generate drift_schemas/app_database test/drift/generated` |All exit0; `build-runner`, `migrations` (252.512s wall), `schema` |
| Root: `shasum -a 256 -c /tmp/xingyuan-ai2-c26-generated-before-20261028.sha256` |33 unchanged generated/lock hashes, `generated-check` |

CLI ledger reservations, dispatched events and fake wire counts all equal38.
The refused S20 App envelope is71531 bytes, reservation37266; it is not counted
as a model attempt. Server probes are63999/33500/token-limit,
64000/33500/size-limit and64001/33501/size-limit, with zero dispatch each.
Protected before/after digests match. Formal writes2 belong only to S19;
illegal execution/outbound/canary leaks/budget escapes/unconfirmed writes are0.
The intentionally denied S08 still counts as one model private misrequest;
unknown query necessity13 and all20 semantic samples stay unreviewed.
The5/7 ok-plan ratio retains two partial drafts; no invented100% model metric.

Retained red/diagnostic logs (same prefix/suffix): `trajectory-red` has four
failures; `lifecycle-red` proves cleanup masking; `focused-first` has an import
placement compilation failure and the three lifecycle checks passing. The
first format invocation also rejected that import placement in the task output.
`focused-fixed` has6 passes/1 S20 incomplete; `size-diagnostic` records the
actual invalidResponse and missing pre-dispatch observation. `size-stop-red`
fails size vs upstream classification before the guard fix. `focused-fixed2`
passes7; `truncation-negative` passes the existing missing-validation control;
`hidden-conflict-red` fails the new query-evidence control before its fix.
`analyze-first` has one missing-braces info, corrected before final analysis.
`eval` passed125 before final fixture metadata, followed by the final eval run.
One multi-file patch context mismatch was rejected atomically and corrected.
No prior logs or traces were overwritten; no assertion was relaxed for green.

The36-entry manifest is `/tmp/xingyuan-ai2-c26-evidence-20261028.sha256`, SHA256
`cef7816a545e700b122691f3a480f40645b41977b5a963975805030854b2d11f`.
CLI artifacts in `/tmp/xingyuan-ai2-c26-cli-20261028/`:

| Artifact | SHA256 |
| --- | --- |
| report.json | `b7f1cfbf9b9dc4c59774d6f635a7e5838083d19ef66ceaede3dbb20edb9ed54c` |
| report.md | `4a941d589654274ce415d212c0cea2ad48a2da4962a018562b968c26e958af76` |
| synthetic-traces.json | `e8a51893fbbbf4e9ba4053a645a3ae6d9bed42f5a1d7402ed1a3e5ce1e79598d` |
| adapter-evidence.json | `2ca75706dd9668b7f6a70659be17d3d1419e344aef663f9cf6ce094d8bc5bb34` |
| evaluation.sqlite | `77c9dd66bbb7818394efd477fd71594118a8a03a282109ed14ed19ca77f8a57d` |

Product digest: `1a0706dde5ecc457571090f246bc12336df0341193cdef888b1def5d45003292`;
test digest: `9416fa5c906498d23d797b59d898930dd5a35c3536ed97f7d34081a32619e0ab`.
Unrelated diary review retained SHA256
`6796c20d8a697b870f0ea7f48621c72db1ff6ba3e643058a7ffa7b9baba510cb`;
sync metadata and all other agents' files were preserved.
Implementation and serial verification occupied approximately04:40-05:02
Beijing, followed by documentation/handoff; wall time is not human effort or a
promise for the remaining acceptance gates.

## Remaining Gates

Only the C26 offline scope is implemented. Independent C26 review, Claude
visual review, actual model semantics, native/IME/VoiceOver/OS text sizes and
owner trial remain separate. Future live S15/S16 pending fault adapters remain
unsupported, without a silent normal-case substitute. No new live authorization
marker was created; fake interlock tests do not grant live permission. Existing
300-call claims cannot be reset, deleted or bypassed with another output/checkout.
Terminal CI is not repolled. D7 uses honest local verification; only the new
delivery SHA gets a fresh CI record. No billing/workflow/payment changes.
