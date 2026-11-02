# C36 Schedule Uncertainty

Date: 2026-10-30, Asia/Shanghai. Base:
`3bab9fa34addd49c8d9bfdfd655c7d826d04698a`. Source: Claude C36 relaying the
owner's product decision, supplemented by C37 deployed-wire compatibility
and C38's explicit Chinese-font capture contract. Final delivery evidence is
recorded below; independent QA, comprehensive visual/native and owner
acceptance remain separate.

## Rule

This deliberately supersedes the old day-wide unknown-schedule rule, rather
than reclassifying historical failures as successes. It serves personal
planning and Agent AG05/AG07 (final validation and fresh confirmation).

- No start: flexible work, including overdue work projected onto today. It
  occupies no interval and causes no unknown date or conflict warning. Known
  minutes still count toward daily capacity. Same-title duplicate checks remain.
- Start but no duration: reserve `[start, start + 60)` on that calendar date.
  Free-slot search avoids the interval without producing unknown dates. Only
  candidates actually overlapping it receive `unknown_schedule`, as a warning,
  not a hard error. A reservation extending past midnight blocks the rest of
  that date and does not carry into the next date.
- Complete timing: existing half-open conflict rules remain unchanged.

The 60-minute reservation is not an invented known duration for daily-cap
accounting. Capacity still sums explicit minutes. Conflict, duplicate,
daily-cap, invalid-field and date-range priority remain unchanged.

One issue per candidate is retained. An unknown issue has optional
`with: {title, start_minute}` naming the earliest overlapping unknown-duration
record, deterministically ordered by the existing schedule comparator. The
confirmation token binds all overlapping unknown-duration records, including
ones not selected for that label. Nonoverlapping/untimed records are excluded
from that token component; fresh validation still catches hard errors and caps.

Per C37, `query_schedule` retains `partial` when either start or duration is
missing, including untimed/overdue rows. Its
existing D5 data-status banner is not silently cleared by a later valid plan.
Free-slot/validation status and per-item confirmation warnings follow C36.

## Presentation And Compatibility

Only the requested copy changes. The common message formatter is shared by
proposal issues and the exhausted-invalid-plan message. Time uses the existing
card's zero-padded `formatMinute`, e.g. `可能和「跑步」07:00 冲突`.
The checkbox reads `我已了解可能的冲突`. A legacy issue without `with` keeps
`无法完整判断此项的冲突`. `agentStatusLabels`, D5 messages and styles are unchanged.

The App-local wire projection accepts a reference only for `unknown_schedule`,
strictly checks its two fields, title bound and minute range, rejects extra
fields, then strips it before validating against the unchanged shared parser.
Local results and caches retain their reference; outgoing history, including
duplicate wrappers and invalid submits, contains index/code issues only.
Existing no-reference results remain valid. No SQLite schema change is needed:
proposal inspection reconstructs issues from current local data, and stored
Agent metadata remains indexes/status/trace/caps without private titles.

**发往后端的格式未变。** C37 supersedes the initial candidate's shared parser
extension: `agent_contract.dart` is restored to the local a88a53e Git version.
The old online revision is Claude's report, not independently queried. New
six-turn scripted runner tests exercise all five tools for untimed, timed with
unknown duration and complete timing, including an invalid submit sent back for
repair. Every actual outgoing request is strictly parsed, every validation
issue is exactly index/code, and local-only titles are absent from those results.
A fourth test covers cached partial results in nested history. Valid terminal
submits are consumed locally and not falsely described as transmitted.
No backend deployment dependency remains. No server or device was contacted.

## C36/C37 Verification History

All runs use synthetic data and the localhost-only sandbox documented below.
Failures remain under exclusive log names; subsequent passes do not overwrite
them.

| Gate | Result |
| --- | --- |
| New C36 rule tests, original product | 1 passed / 14 failed |
| Same 15 test-source bytes after implementation | 15 passed |
| First selected behavior set | 141 passed / 3 failed |
| Chinese-font C36 UI plus confirmation store after fixture correction | 30 passed |
| First old v2/v3 adapter tests | 13 passed / 2 failed |
| Adapted assertions preserving frozen scores | 15 passed |
| Initial C36 server/core/eval | 462 / 128 / 186 passed |
| Initial C36 four analyses / format | Clean / 546 files, 0 changes |
| C37 first new regression | Load error, LocalDate/CalendarDate test mismatch |
| C37 corrected tests against initial C36 | 1 passed / 3 failed |
| Same four C37 tests after compatibility fix | 4 passed |
| C37 rules/runner/executor/store | 90 passed |
| C37 remaining affected behavior/adapters | 84 passed |
| C37 Chinese-font confirmation flows | 17 passed / 4 PNGs inspected |
| C37 server/core/eval | 462 / 128 / 186 passed |
| C37 four analyses / format | Clean / 546 files, 0 changes |
| Final focused/full App | Not run while default-font failures remain known |

The selected set's failures were two 320x568/3.5x Ahem capture assertions and
one test-only call to a nonexistent `rename` API. The API fixture now uses
`edit`; no product workaround was made. Default Ahem selection boxes extend
to x=326 on a 320px viewport. With the existing STHeiti test aliases, the same
full-text clipping/opacity/contrast checks pass in both themes and both scales.
All four Chinese PNGs were inspected. At 3.5x the warning wraps and is readable
after scrolling; the whole item and acknowledgement are not simultaneously
visible. These are widget captures, not native or OS accessibility evidence.

At the C37 checkpoint, the Ahem failures remained unresolved pending Claude's
test-font contract decision. No style change, threshold reduction or
failed-assertion deletion had been made. That Chinese pass was not a
default-font pass or D7.
The C37 four PNGs were also individually inspected after the wire fix; they
retain those same scroll and accessibility limitations. The last numeric inbox
check at20:43:14 found no C38 or A1-173. At that checkpoint the candidate was
blocked on Claude's font decision, with no new owner action, commit or handoff.
This historical state is superseded only by the C38 section below.

The old v2/v3 scripted fixtures S06/S07 assert day-wide partial for an untimed
row or a nonoverlapping unknown-duration row. Under C36 each frozen report is
18 passed / 2 failed, not 20 passed. Tests now assert the exact failed case IDs,
`unknown_schedule_not_ok=fail`, and current final-validation `ok`. The fixtures,
scorer, prompt, historical reports and model comparisons are not changed or
rescored. New C36 tests separately cover actual overlapping warnings. These
are fresh synthetic adapter runs, not a fourth live round.

## Commands And Evidence

Harness: `/tmp/xingyuan-ai2-c36-verify-20261030.mjs`.
Actual argv/cwd/start/end/exit, source and test hashes, and exclusive log hashes:
`/tmp/xingyuan-ai2-c36-commands-20261030.jsonl`.

```text
node /tmp/xingyuan-ai2-c36-verify-20261030.mjs regression red
node /tmp/xingyuan-ai2-c36-verify-20261030.mjs regression green
node /tmp/xingyuan-ai2-c36-verify-20261030.mjs selected behavior test/agent_c36_confirmation_test.dart test/agent_confirmation_store_test.dart test/agent_conversation_runner_test.dart test/agent_planning_test.dart test/agent_tool_executor_test.dart test/agent_confirmation_ui_test.dart test/agent_ui_test.dart test/agent_c33_inline_confirmation_test.dart
node /tmp/xingyuan-ai2-c36-verify-20261030.mjs selected chinese test/agent_c36_confirmation_test.dart test/agent_confirmation_store_test.dart --dart-define=DIARY_CAPTURE_FONT=/System/Library/Fonts/STHeiti\ Light.ttc --dart-define=DIARY_CAPTURE_DIR=/tmp/xingyuan-ai2-c36-captures-20261030
node /tmp/xingyuan-ai2-c36-verify-20261030.mjs selected adapters test/agent_headless_driver_test.dart test/agent_c28_v3_adapter_test.dart
node /tmp/xingyuan-ai2-c36-verify-20261030.mjs selected adapters-c36 test/agent_headless_driver_test.dart test/agent_c28_v3_adapter_test.dart
node /tmp/xingyuan-ai2-c36-verify-20261030.mjs checks review
node /tmp/xingyuan-ai2-c36-verify-20261030.mjs selected c37-red test/agent_conversation_runner_test.dart --plain-name C37
node /tmp/xingyuan-ai2-c36-verify-20261030.mjs selected c37-red-fixed test/agent_conversation_runner_test.dart --plain-name C37
node /tmp/xingyuan-ai2-c36-verify-20261030.mjs selected c37-green test/agent_conversation_runner_test.dart --plain-name C37
node /tmp/xingyuan-ai2-c36-verify-20261030.mjs selected c37-rules test/agent_c36_schedule_test.dart test/agent_conversation_runner_test.dart test/agent_tool_executor_test.dart test/agent_confirmation_store_test.dart
node /tmp/xingyuan-ai2-c36-verify-20261030.mjs checks c37
node /tmp/xingyuan-ai2-c36-verify-20261030.mjs server-full c37
node /tmp/xingyuan-ai2-c36-verify-20261030.mjs core-full c37
node /tmp/xingyuan-ai2-c36-verify-20261030.mjs eval-full c37
node /tmp/xingyuan-ai2-c36-verify-20261030.mjs selected c37-remaining test/agent_c28_v3_adapter_test.dart test/agent_headless_driver_test.dart test/agent_planning_test.dart test/agent_confirmation_ui_test.dart test/agent_ui_test.dart test/agent_c33_inline_confirmation_test.dart
node /tmp/xingyuan-ai2-c36-verify-20261030.mjs selected c37-chinese test/agent_c36_confirmation_test.dart --dart-define=DIARY_CAPTURE_FONT=/System/Library/Fonts/STHeiti\ Light.ttc --dart-define=DIARY_CAPTURE_DIR=/tmp/xingyuan-ai2-c37-captures-20261030
```

The original red/green 15-test source SHA256 is
`385a8047343f5eae6bb8a2d588ca09102148bd17c79a68c022df6b512c9560de`.
Red log: `e57ad4c9e0dbaec8e5b16169c03a4221d1d29b678a1aa4f0ab566f8cb2c55d48`.
Green log: `8c493436aa5aa401b0a9cf039752280a66918cab9c70b46c20276dda9bd9b26f`.
Later formatting changes that test's bytes; the final source will be bound
separately. Existing 39-file protection checks have remained unchanged.

The corrected C37 red/green runner source is preserved at
`/tmp/xingyuan-ai2-c37-wire-red-source-20261030.dart`, SHA256
`61ca8164e556588247e8772047a823c0f10a8bd4eb15dc559a178260c5961b0c`,
equal to the successful gate's per-file snapshot. Its first fixture type-loading
failure remains a QA failure, not a reproduced product defect. The corrected
1/3 red shows query status and ordinary/cached reference leakage; the unchanged
four tests pass after the compatibility fix.

Final C37 checked 546-source canonical SHA256:
`2bf07490ec92105ee25e8fcc5fb1a2f5c13f4f69facf066cd8173bf087c42997`.
The restored contract and local a88a53e Git blob have identical SHA256
`b0bac8718d7be59da0a425a75ce98057c5afb46e2d65820eafae3420cad4875f`;
the comparison is in `/tmp/xingyuan-ai2-c37-contract-20261030.json`.
The command ledger has28 gates with5 recorded failures, all retained, and no
pending command records. All tool sessions finished. `git diff --check` passed.
Four new C37 tests are included in90; do not add those counts together. The
Chinese17 and earlier Chinese30 overlap. No whole-App total is claimed.

Intermediate review evidence is sealed once at
`/tmp/xingyuan-ai2-c36-c37-review-manifest-20261030.json`, with report, logs,
contract/source bindings and all8 Chinese screenshots copied to
`.ai-bus/review/AI-2/C36-C37-20261030`. This is not a delivery manifest or D7
approval. Existing historical evidence is not overwritten.

## C38 Font Contract And Final Verification

C38 explicitly assigns Chinese pixel and selection-bound checks to the
existing `DIARY_CAPTURE_FONT` gate. Ahem/FlutterTest keeps all interaction,
state and semantic assertions, including an explicit `takeException() == null`
at the former capture call and the existing final exception check. Only this
test's capture is conditional; the shared capture helper, opacity/contrast
thresholds, 320x568 viewport, 1.0/3.5 scales and product styles are unchanged.
The old two Ahem failures remain failures of the earlier test contract.

The original two 3.5x overlap cases pass under the new default-font contract.
The explicit Chinese-font gate passes all four cases: dark1.0, dark3.5,
light1.0 and light3.5. All four new PNGs were inspected individually.
The exact command includes the actual font path:

```sh
node /tmp/xingyuan-ai2-c38-verify-20261030.mjs selected original-failures test/agent_c36_confirmation_test.dart --name 'C36 overlap (light|dark) 3.5x explicit confirmation'
node /tmp/xingyuan-ai2-c38-verify-20261030.mjs selected chinese-matrix test/agent_c36_confirmation_test.dart --plain-name 'C36 overlap' '--dart-define=DIARY_CAPTURE_FONT=/System/Library/Fonts/STHeiti Light.ttc' --dart-define=DIARY_CAPTURE_DIR=/tmp/xingyuan-ai2-c38-captures-20261030
```

C38 accepts that the full item and acknowledgement do not share the first
screen at3.5x for this iteration; redesign remains Claude's responsibility.
These captures show the scrolled warning, not native UI, VoiceOver or owner
acceptance. The confirmation test SHA256 is
`3562650ee7b1d9a8ee5b2163fcb8740bf582450e34caf3c8e4d3d0d7c9a8aa3c`.

The first final focused run was302 passed /1 failed: an overlooked C26 S06
trajectory test still expected the frozen overall score to pass. Its
unchanged scorer correctly reports `unknown_schedule_not_ok=fail` for the
superseded rule. The test now requires that exact sole failed check and
`validation=ok`, while the actual `data_banners` check must pass. Missing,
incorrect-text and incorrect-status mutations explicitly check their own
banner result, so the already-failed S06 total cannot hide a broken negative
control. No fixture, scorer, prompt or historical report was changed.

The first strengthened negative-control run failed because this test expected
`fail` rather than the scorer's existing `not_observed` for a missing event.
That QA error is retained. Corrected S06/S08 run2/2 passes: missing events are
`not_observed`, wrong values are `fail`; S08's missing-event total is
`incomplete`, while S06 remains `fail` due to its frozen unknown-schedule check.

```sh
node /tmp/xingyuan-ai2-c38-verify-20261030.mjs matrix final
node /tmp/xingyuan-ai2-c38-verify-20261030.mjs selected trajectory-fix test/agent_c26_trajectory_test.dart --plain-name 'S06 trajectory'
node /tmp/xingyuan-ai2-c38-verify-20261030.mjs selected trajectory-exact test/agent_c26_trajectory_test.dart --name '(S06|S08) trajectory'
node /tmp/xingyuan-ai2-c38-verify-20261030.mjs matrix final-exact
node /tmp/xingyuan-ai2-c38-verify-20261030.mjs checks final
```

The first `matrix final` stopped after its focused failure and did not run
the other suites. The final corrected matrix passed focused303, App1825,
server462, core128 and eval186. The selected cases and font runs overlap with
focused/App and are not additional unique tests. Focused303 selects current
`test/agent*_test.dart`, both assistant-proposal suites and Agent migration;
it is not the same selection as C35's384.
The final four analyses are clean; formatting checked546 files with0 changes.
All39 protected hashes match, and all execution sessions have ended. This is
the author's local D7 result, not independent, native or owner acceptance.

Final 546-source canonical SHA256:
`40ef19a26ae06407a7560c8c276f4d7f77d04e8b0094f01080d061994a5f4ff6`.
Compared with C37, only the confirmation font gate and C26 trajectory test
changed; all product sources are byte-identical. The final C26 test SHA256 is
`2e8587a1840a68f81936bafef074197f3faf4430189b6c0840307e00bf48c273`.
The Chinese/default confirmation runs precede the C26-only adjustment; their
test, helper and product bytes are unchanged. Old C37 evidence has97/98 entries
unchanged: only this working report was updated, not its sealed review copy.

New argv/cwd/times/exits/hashes are stored separately
in `/tmp/xingyuan-ai2-c38-commands-20261030.jsonl`; C36/C37 logs, command ledger
and sealed review copies remain unchanged. Exploratory `rg` returned no match
for an optional font-reference search and exit2 for a nonexistent driver path;
these are discovery results, not product failures. An early attempt to read
the not-yet-created full-App log also returned exit1, without running a test.

The C38 ledger contains15 completed gates, including the two retained failures
above; it is not a claim of15 first-pass successes. Final review material is
sealed once at `/tmp/xingyuan-ai2-c38-manifest-20261030.json` and copied to
`.ai-bus/review/AI-2/C38-20261030`. The manifest and report SHA256 values,
exact delivery commit/source binding and that commit's new CI status are in
A2-103. No old terminal CI result is inherited or queried again.

SDK: `/path/to/development/flutter/bin/{flutter,dart}`. Sandbox:

```text
(version 1)(allow default)(deny network*)(allow network* (local ip "localhost:*") (remote ip "localhost:*"))
```

Other retained tool mistakes: initial nonexistent companion/test/time paths,
unmatched exploratory shell globs, and one rejected apply_patch with duplicate
target operations. These were local discovery/edit-tool failures, not product
test results. No unknown scripts or private evidence were executed/read.

## Boundaries

No device, native/simulator, server/SSH, build/sign/install/deploy, real model,
real configuration, Keychain, shared live ledger or marker operations. A0 and
all three A4 rounds remain closed. All old terminal CI runs remain unqueried.
No generation, separate CLI20 run or historical comparison was repeated.
The unrelated diary review and synchronization files are preserved.

C36's report of an owner B planning success at19:46 is Claude-source context,
not AI2 firsthand execution or comprehensive UI/native/semantic acceptance.
