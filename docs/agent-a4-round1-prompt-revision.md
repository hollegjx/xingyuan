# Agent A4 Round-1 Prompt Revision

2026-10-28, Asia/Shanghai. AI-2, responding to AI-1 A1-147/A1-148 and Claude C28.
Base: `397392c044da7c0334eaca58a92b261d35b8e82d`.
Initial implementation: `3b8f5db1f8347b570cc58dea62874c1cc8a5b292` (four paths).
C28 final implementation: `957254283b330b68e84e67c6a1ee2181a068935b`, adding
five static contracts and prompt clauses in two of those paths.
This is a prompt candidate, not a demonstrated model-quality
improvement or complete A4/AG acceptance. AI-2 made no live requests.

## Independent Intake

AI-1's complete reports were read without editing or merging their QA sources:

- `idea-ai1/docs/agent-a4-live-round1-independent-validation.md`, SHA256
  `86e5cbac29acd356e102ab92c35ba1cb9ddfa0f7057d3093f59e9aa2c9e1fd36`.
- `idea-ai1/docs/agent-c21-authorized-capture-attempt.md`, SHA256
  `5b4a1cbd0e7ac3e03c970df96e7d6222848f5a15303e2408eb89c5a83a55d4e7`.

The following live facts are AI-1's evidence, not a second run or an AI-2 ledger
inspection: round1 closed with25 attempts, CLI exit1;20 base cases,18 executed,
7 pass/8 fail/3 incomplete/2 not_run. Known actual tokens31800. The single
validated candidate1/1 does not conceal required scheduling completion0/2.
Wire-call count is unobserved, not independently measured as25. Retain the
original report, traces, claim and closed ledger, including unused275 capacity.
One of the shared maximum3 rounds is consumed; no per-thread fresh allowance.

The original v1 prompt and model reports stay unchanged. AI-1's semantic review
is AI review, not human acceptance; machine manual_review stays needs_human.
S04/S07 omitted-date questions were defensible. S08/S09 did not reach their
denied/failed tools, S13/S14 did not produce the injected duplicate/budget
sequence, and S20 never exposed its large payload to the model. Those results
are not proof of broken guards or successful fault coverage. S15/S16 live
pending-fault adapters remain unimplemented. No score or fixture was changed.

C21 stopped at an AI-1 QA analyzer error (`HttpOverrides.global` getter), before
build/install/native execution:0 native runs,0 PNGs. Restoration is reported by
AI-1, not rechecked against private backups here. No QA repair/retry or new
device action was performed. Native, visual and owner acceptance remain open.

## Candidate Changes

`agent-v1` remains immutable; the active server imports `agent-v2`.

- S10/S18: explicitly allow preparing a locally validated reviewable draft.
  Saving still requires explicit App confirmation; do not replace a requested
  actionable draft with prose or deny draft capability because saving is gated.
- S03/S17: choose the earliest fitting tool-supported slot within the supplied
  window, then validate and submit. An omitted exact time/window alone is not
  grounds for clarification: search that day, respecting the supplied local
  clock, known preferences and cap. Ask all missing task/duration/day details
  together only when supplied context or authorized preferences cannot fill
  them. Do not re-confirm known information or invent an omitted date.
- S12: the server appends the authoritative inclusive local-date endpoints,
  calculated with `CalendarDate.addDays(14)`. Explain an out-of-range request
  before asking its time; offer the nearest in-range date explicitly and check
  feasibility with tools. Tests cover month, year and leap-day boundaries,
  independent of the host's real date. Every concrete arrangement, including an
  alternative, must use `submit_plan_draft`, not just prose.
- S05: explain remaining daily capacity based on reliable results, counting
  existing load and the entire requested batch. A different time on the same
  day does not restore capacity. State known used/cap/remaining minutes and offer
  another date, shorter durations or fewer items. A validated alternative draft
  must disclose every change in its note for explicit App confirmation. Never
  silently drop tasks, shorten durations or raise the cap. Partial totals remain
  unknown.
- Five tool descriptions distinguish relevant preferences, schedule details,
  one-item candidate slots, whole-batch validation and reviewable submission.
  A free-slot query already considers the schedule; it is not a reservation
  for several tasks. Known caps are passed through the existing slot tool.

No tool name, parameter schema, protocol, model alias, model parameters,
executor, grants, confirmation transaction, budget, retry, scorer, fixture,
legacy/journal prompt, dependency or platform changed. Description changes do
change the tool-schema fingerprint. Ordinary questions still use no private
tools; non-ok results never establish complete availability. Untrusted tool
data, local validation, partial disclosure and one-tool sequencing remain.

Offline snapshot, using the ordinary synthetic request at2026-10-27 08:00:

| Field | Value |
| --- | --- |
| prompt_version | agent-v2 |
| prompt | a171047709d68072e17db38df379d816ef35c865ea7a9ea47ce8af0306d07956 |
| tool_schema | ff13a98b290bfd90e8082b915907029dcbdfe564013791c4268f908a445abfe2 |
| request bytes |7767 |
| existing reservation formula |5384 tokens, an estimate, not measured token usage |
| snapshot model calls |0 |

The v1 digest assertion still matches
`883e542c3ca6df3a18f723e3ed8e43e14ec60ee5e05c3b818ba9d21d025fc174`.
The snapshot does not prove all future requests fit; unchanged byte/token guards
continue to check each actual request before dispatch.

## Red And Final Verification

All log paths use `/tmp/xingyuan-ai2-a4-r1-prompt-` plus the stem below and
`-20261028.log`. SDK: `/path/to/development/flutter/bin/`.

New tests are static instruction/request contracts, not assertions that a real
model now behaves correctly. Round1 is the actual behavior-failure evidence.
Initial `red` is1 pass/11 failures:8 instruction-contract failures plus3 new QA
fixture errors from raw-Map `addAll`. After fixing only that fixture, the
unchanged product rerun `red-corrected` is1 pass/11 genuine contract failures.
Both logs remain. Initial product changes passed all12 new contracts, focused74,
App1695 (4m07s), server399/core128/eval146, four analyses,521-file format and33
generated/lock hashes. Those initial logs remain under `focused`, `app`, `server`,
`core`, `eval`, `analyze`, `server-analyze`, `core-analyze`, `eval-analyze`,
`format-final`, `generated-check`; they describe3b8f5db, not the final C28 prompt.

C28's four additional contracts first produced12 pass/4 fail (`c28-red`), then
focused78 and App1695 passed (`c28-focused`, `c28-app`,3m33s). A final missing-time
contract then produced16 pass/1 fail (`c28-window-red`); after the prompt fix,
`final-focused` passed79, including all17 new static contracts. No assertion was
weakened. The existing version test changes only its expected active version.

`final-app` was interrupted at00:24/+259 with no terminal result; its tool session
was no longer available on resume. A scoped process check found no remaining
test process. Keep that incomplete log, do not count it as passed, and record the
fresh full execution separately as `final-app-resumed`.

Each test executable ran in the existing localhost-only sandbox:

```text
sandbox-exec -p '(version 1)(allow default)(deny network*)(allow network* (local ip "localhost:*") (remote ip "localhost:*"))'
```

Heavy tests ran serially in this thread; this is not a host-wide exclusivity
claim. There was no live configuration read, live marker or model request.

| Cwd / command | Result | Log stem |
| --- | --- | --- |
| Server: `dart test test/agent_prompt_quality_test.dart --reporter expanded` |First1/11 and corrected1/11, exit1 |red / red-corrected |
| Server: `dart test test/agent_prompt_quality_test.dart test/agent_prompt_version_test.dart test/agent_protocol_test.dart test/agent_ledger_test.dart test/agent_service_test.dart --concurrency=1 --reporter expanded` |79/79, exit0 |final-focused |
| Root: `flutter test --no-pub --reporter expanded` |1695/1695, exit0,3m38s |final-app-resumed |
| Server: `dart test --concurrency=1 --reporter expanded` |404/404, exit0 |final-server |
| Core: `dart test --reporter expanded` |128/128, exit0 |final-core |
| Eval: `dart test --reporter expanded` |146/146, exit0 |final-eval |
| Root: `flutter analyze --no-pub` |clean, exit0 |final-analyze |
| Server/core/eval: each `dart analyze --fatal-infos` |all clean, exit0 |final-server-analyze / final-core-analyze / final-eval-analyze |
| Root: `dart format --output=none --set-exit-if-changed lib test integration_test tool server packages` |521 files,0 changes, exit0 |final-format |
| Root: `shasum -a 256 -c /tmp/xingyuan-ai2-c26-generated-before-20261028.sha256` |33 hashes unchanged, exit0 |final-generated-check |

The source edit formatter changed only the new QA file (`format-edit`); final
format is clean. Exploration also had a nonexistent `assistant*.dart` shell
glob (exit1) and a guessed driver path (exit2); corrected with repository file
search, neither was a test/live failure. No logs or failed results were erased.

The reviewed synthetic snapshot helper is
`/tmp/xingyuan-ai2-a4-r1-prompt-snapshot-20261028.dart`, run from server with
`dart --packages=.dart_tool/package_config.json <helper>` in a deny-network
sandbox, exit0 (`final-snapshot`). It imports the actual active body builder and
prints only synthetic sizes/digests, not configuration or credentials.
The initial manifest `/tmp/xingyuan-ai2-a4-r1-prompt-evidence-20261028.sha256`
is preserved. The final37-entry manifest includes all C28 failures and final gates:
`/tmp/xingyuan-ai2-a4-r1-prompt-final-evidence-20261028.sha256`, SHA256
`1d46ae8ffa36ad81a95c08c509e348df6fafc067e953f2e1de2c750fafc94a96`.

App full tests include the existing fake-relay/headless-driver checks. They do
not count as new live samples. No standalone20-scenario CLI, old-report
rescoring, generator, separate DST/font matrix, screenshot or native run was
performed. Runtime sources were unchanged after the successful tests.

## Round-2 Handoff

AI-1 remains the sole live executor and shared authorization accountant. After
independent candidate review, use at most the next authorized round; failures
count and no automatic retry is allowed. Do not reopen round1, reuse its unused
capacity, alter old claims or manufacture a separate allowance. No deployment,
phone, B, formal release, purchases or relay/VPN changes are authorized.

Per C28 step1, keep `agent-c26-v2`, the same seed and model alias/parameters for a bounded
round2. Prioritize S03/S10/S12/S17/S18 draft/clarification/range quality and S05
cap reasoning, with S01/S02/S11 and the observed S19 confirmation path as
controls. Do not rewrite ambiguous fixture inputs between rounds to improve
the score. Deterministic fault guards and naturally triggered live paths stay
separate; an untriggered path remains unobserved, not a passed safety test.
In particular, the unchanged v2 S12 fixture requires no draft, while C28 permits
an explicitly disclosed in-range alternative draft. If that path occurs, retain
the machine failure and explain the contract mismatch in semantic review; do
not retrospectively change the fixture, score or original result.

C28 step2 is a separate offline work package for R3: `agent-c26-v3` will complete
S04/S07 dates and S08/S09 inputs, implement deterministic pending cancel/identity
adapters for S15/S16, and strengthen real oversized-result/trim/injection coverage
for S20. None of that code is included here or substituted into R2. The R3 prompt
choice depends on R2 evidence; no live request or new round is opened by AI-2.

The existing automatic comparator rejects changed product/tool-schema digests.
This candidate changes both, so raw reports must retain their real metadata and
remain automatically unpaired; a zero-regression count with zero pairs is not
quality evidence. Do not spoof fingerprints, weaken pairing or run the already
closed v1 campaign again. A contextual side-by-side review may explain actual
case outcomes, but must not relabel them as controlled paired numeric deltas.

No fixed upstream model revision was established. Process-log privacy, rendered
UI, independent v2/model semantics, human/owner acceptance, S15/S16 live faults
and `recompute_after_trim` remain unresolved. Historical subscription primary
failure is still unknown. Final D7 local verification is complete for9572542;
only the new delivery's exact CI is recorded in A2-96, not the old terminal runs.
