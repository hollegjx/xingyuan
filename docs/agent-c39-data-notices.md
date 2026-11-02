# C39-C44 App Notices And UI Candidate

Date: 2026-10-31, Asia/Shanghai. Baseline:
`fefc300499a009f3dbbd746e00b1f340e65d2cb9`, branch `codex/agent`.
Scope: Claude C39, the personal Agent A2/A3 experience and AG03/AG04/AG10.
Updated scope: C40 proposal page, C41 large-text banner, C42 today page and
Claude's C43/C44 header/duration corrections form one candidate. C43/C44
resolve the original3x editor geometry failure in default and Chinese tests.
Final sequential local D7 passed at02:43:08 (UTC+8). Exact commit, push and
CI evidence are bound in the A2-104 handoff. Independent QA remains pending.
The C39-C42 results and failures below remain historical intermediate evidence.
Only synthetic local tests; no device, signing, installation, deployment,
model calls, private configuration, credentials or shared live ledger.

## Behavior

- `AgentRunDetails` derives its display notices from tool metadata. Only
  `find_free_slots`, `validate_plan` and `submit_plan_draft` can produce the
  partial-conflict banner. A query's raw partial status remains recorded and
  transmitted, but does not create that banner. Query failed/truncated still
  display their existing notices. Process-step status labels are unchanged.
- Refused schedule tools name `发送已有安排`; refused preferences name
  `发送记忆`. Multiple refusals combine into one notice, ordered consistently.
  This describes this run's refused tools, not a new read of current settings
  or a claim that a historical switch is still off. Metadata without a tool
  trace retains the old generic fallback.
- The existing `NoticeBanner` action (`TextButton`, `去打开`) pushes the existing
  AI settings page. A pending-navigation guard prevents duplicate pushes.
  Returning does not send, retry, confirm or mutate the old run. It works from
  the common widget used by running, reply and proposal surfaces.
- A transparent Material ancestor supplies the button's required interaction
  surface, also when no ambient Material exists. No colors, dimensions,
  typography or labels in the process list change in C39. C41 separately
  authorizes the shared component's large-action layout described below.

`agentDataMessages` is exported by core and used by the offline eval scorer.
The repository search found no server call to this mapping. C39 is nevertheless
implemented entirely in the App presentation layer: core, server, eval,
`AgentRunMetadata.banners` and historical trajectory evidence stay unchanged.
That old aggregate mapping is no longer evidence of the exact current UI text;
C39's rendered-widget tests are the evidence for this presentation change.
No frozen fixture/report is rescored or retroactively marked successful.

The shared `agent_contract.dart` remains byte-identical to a88a53e, SHA256
`b0bac8718d7be59da0a425a75ce98057c5afb46e2d65820eafae3420cad4875f`.
Runner, authorization, data sources, confirmation tokens, outgoing payloads,
budget and automatic-retry policy are untouched. No backend deployment is
required by this change. A0/A4's three closed rounds are not reopened.

## Regression Evidence

`test/agent_c39_data_notice_test.dart` adds24 tests:
five partial tool mappings, query failed/truncated preservation, five refused
tool mappings, merged/cached metadata, four real-runner scenarios, three real
settings journeys, and four small-screen theme/text-scale action cases.
The fake service round-trips through the strict request/response parser;
successful submit remains a local terminal event, not a model follow-up.

Untimed query and query-before-planning keep raw partial evidence without the
banner. A 07:00 item without duration still warns on a 07:30 overlap and requires
explicit confirmation; a later nonoverlapping draft does not warn. No test
silently creates a goal. Each settings journey opens the requested switches,
returns with the unsent draft and old messages unchanged, observes no extra
request, and then verifies a new request only after an explicit user send.

| Gate | Result |
| --- | --- |
| New24 against unchanged product | 4 passed,20 failed |
| Same test bytes after product change | 22 passed,2 failed |
| Corrected two navigation fixtures | 2 passed |
| Explicit STHeiti light/dark1.0x/3.5x actions | 4 passed |
| C39 intermediate focused | 347 passed, including the24 new cases |
| First full App, default concurrency | 1848 passed,1 gate-entry timeout |
| Unchanged failed App case, isolated | 1 passed |
| C39 intermediate server / core | 462 /128 passed |
| First eval | 183 passed,3 gateway startup failures |
| Combined final D7 at01:49 checkpoint | Not run then; C40 header decision pending |
| C39-only serial App interrupted for C40/C41 | 355 progressed; not a pass, despite wrapper exit0 |

The two post-fix failures were QA mistakes: `open-proposal-*` is C33's
explicit Confirm Add control, so those tests legitimately created a second
synthetic goal. They now use `adjust-proposal-*` to open the preview without
saving. The expected no-write assertion was retained. Original test bytes:
`/tmp/xingyuan-ai2-c39-original-regression-20261031.dart`, SHA256
`1f2a96ec94f067f45f0f12bed972140daa01fa3f91b6767f0d98f1a28f7dbcc5`.
All original failure logs remain. The prior UI banner regression now uses a
real overlapping validate result for partial, instead of a raw query, and
expects the C39 switch-specific refused notice; no threshold is relaxed.

The initial full App run reports `C32 record read cannot outlive the Agent
deadline` timing out at the fixture's2-second wait for its injected gate.
The runner's200ms limit and outcome assertion are unchanged; the gate may
not be reached before an earlier timeout. The same test passed in the focused
serial run. Other suites were running concurrently, but the exact runtime
cause has not been established. The full log is retained. The unchanged failed
case subsequently passed1/1 in isolation. Do not lengthen thresholds, add
automatic retries or call the first full run successful.

The first eval run also failed three unchanged gateway CLI startup cases:
one20-second `runCli` timeout with repeated `Running build hooks...` stderr,
and two20-second health-start deadlines (SIGINT/SIGTERM cases, before their
shutdown assertions). Its own `dart_test.yaml` already sets concurrency1
because CLI suites share native build output. This heartbeat's orchestration
incorrectly overlapped App/server/eval/checks processes, creating cross-suite
contention risk despite that per-package setting. Correct the orchestration
by completing all existing runs, then perform one bounded, nonoverlapping
App serial and eval validation. Exact per-failure causality is not established;
no product/test/source change, timeout increase or automatic retry is used.

C40/C41 arrived during the C39-only serial full run. At01:20:20.088, one SIGINT
was sent to its exact owned test child (83532, wrapper83505); all its sessions
ended. Flutter returned0 while reporting stream-shutdown errors after355 cases,
without an `All tests passed` marker. This is an interrupted run, not a pass.
The interruption JSON and original output remain; the generated source map is
not evidence of a completed suite. Do not seal or reuse it as final D7.
The combined-candidate harness will require both a successful exit and a test
completion marker, and run suites without overlap.

C40 patch was read in full (1092 lines, one App path) and applied cleanly with
`git apply -3`, SHA256
`ff2a20684dd1fee45ad153fda4177ed9b56da1ca2bc276578923b27856a8a7cb`.
C41 explicitly resolves the large-text layout decision below: when scaled14px
exceeds22px, place the action below the message aligned with its text (30px
icon/gap inset), minimum44x44; smaller text and no-action notices keep layout.
C41 is implemented. Original16 banner tests plus the4 enhanced action checks
first reported14 passed/6 failed, then20 passed on the same tests after the
change. They cover light/dark,1x, exact22/14 threshold,1.6x and3.5x, action/
no-action layouts, paragraph width, alignment,44x44 bounds and actual tapping.

## Intermediate C40 And C42 Checks

C40's original six suites independently reported74 passed/11 failed, matching
Claude's source report but not relying on it. These first failures were the
specified label, delete-entry, weekday-key and fixed-header contract changes.
After adapting those tests, three affected suites reported21 passed/2 failed:

- A new semantic activation assertion found that `_Weekday` set
  `excludeSemantics:true` without forwarding `onTap`. The InkWell could respond
  to touch, but its exposed semantic button had no activation action. AI2
  added only `Semantics.onTap`, without changing style. The next run passed
  behavior but failed because the test disposed its SemanticsHandle too late;
  this QA cleanup error is retained. With try/finally disposal, the semantic
  action, touch toggle and three new per-item-bell/cancelled-edit journeys
  pass4/4. They preserve exact draft contents on cancel, change only the chosen
  reminder, and schedule no notifications or goals before confirmation.
- The C40-required strict keyboard geometry assertion fails at3x. With a
  320x568 viewport and200px simulated keyboard, the fixed header occupies
  Rect(8,72,312,348), and the minutes field extends to512 rather than staying
  above368. Both default Ahem and correctly loaded STHeiti reproduce it;
  1x/2x workflows pass. The Chinese header wraps into four vertical lines.
  The strict assertion is retained; no unauthorized scaling/layout fix or
  test relaxation is made. Recommendation sent to Claude: cap only the fixed
  editor header at2x, keeping full-size form text and the visibility check.

The first optional iOS-font diagnostic produced1 passed/2 failed and square
glyphs because the shared loader's aliases did not include this SDK's
`CupertinoSystemText`/`CupertinoSystemDisplay`. Those six original images and
logs remain, but are not Chinese evidence. This test now adds those aliases
only under explicit DIARY_CAPTURE_FONT. The shared helper and production
theme are untouched. The corrected run is2 passed/1 failed, with seven Chinese
PNGs inspected individually. Synthetic keyboard insets are not OS keyboard
evidence. Review materials: `.ai-bus/review/AI-2/C40-layout-20261031/`.

C42 was fully read, hash checked and cleanly applied to its four named App
paths: SHA256 `1e2cd2af30c76abdd2813bf088bae382cb8e59f49740684acc293653f22616b7`.
It unifies entry accents, uses compact group labels, omits redundant dates for
interactive single goals planned today, and quiets empty record-entry styling.
Keys, completion and record behavior are preserved. New synthetic tests pass4/4
for timed/untimed/duration-only today goals, overdue and habit controls,
read-only tile date preservation, group counts and no permission prompt.
C42's reported Linux96 are Claude-source only, not inherited AI2 results.
AI2 subsequently ran ten relevant existing files:103 passed. The four C42
cases also pass under explicit Chinese font; four light/dark1x/3.5x PNGs were
viewed individually. At3.5x the heading/group and first item require scrolling;
the image is not a complete list or independent visual/native acceptance.

The first combined App analysis reported three deprecated-API infos in the
new semantic test (`hasFlag` twice and binding.pipelineOwner). The test now
uses flagsCollection's explicit tristate and the actual render owner's
SemanticsOwner. The same semantic action plus eight strengthened entry-accent
cases pass9/9. Four analyses are clean;549-source zero-change formatting and39
protected hashes pass. This supporting checkpoint's source canonical SHA256:
`ae53129b06b788a469e985da73cd3cad4750fe4f6378f755ee0e2fdb9c411eae`.
Those checks do not close the known C40 layout failure or replace final D7.
The final unaffected banner/settings/conversation/large-text/long-history
selection passes99/99 on that same549-source hash. The selections overlap
the full suite and one another; do not add their counts into a unique total.

Read-only discovery mistakes (one nonexistent fixture cat exit1, two
incorrect runner-path rg exit2 and absent optional test-config rg exit2) are
tooling errors, not product failures. Later no-match source searches and one
report-patch context mismatch are likewise tooling errors; the failed patch
made no changes and was corrected against the actual text.

## Visual Limits

Four 320x568 PNGs with `/System/Library/Fonts/STHeiti Light.ttc` were viewed
individually. At1.0x the combined notice and action are visible together.
At3.5x the existing side-by-side `NoticeBanner` leaves a very narrow text
column, requiring long vertical scrolling. The captured action remains
readable and hit-testable; the full notice is not simultaneously visible.
This was the original limitation; C41 explicitly authorizes and implements
the action's move below the text. No independent visual acceptance is claimed.

The new C41 Chinese action matrix passes4/4. Light/dark1x PNGs are byte-identical
to the original C39 captures (SHA256 cdad57012c0e7bfe327667abe0f191a4a0a47654138376801f4c5ec72a704bba
and bf439c23fc53dd8e9b6b439ae2642e3864825e4ca8c1025fc8031af83056136a).
An additional four-case capture run records both the top paragraph and the
bottom action at3.5x: text uses the wider normal paragraph and the action sits
under it aligned to the text. The full long notice still requires scrolling;
do not claim all content fits one screen. Old screenshots are retained.

The4 Chinese pixel checks cover the action text, not the whole long notice.
Default Ahem checks retain semantics, hit testing and exception checks; pixel
assertions use only explicit Chinese font as required by C38. No helper,
viewport, text scale or pixel thresholds were changed.
Widget renders are not native iOS, OS maximum text size, keyboard or VoiceOver
evidence. Independent QA, Claude visual review, native smoke, complete AG/J13,
semantic/owner acceptance and the Agent daily-backup gap remain separate.

## Commands

New reviewed local harness:
`/tmp/xingyuan-ai2-c39-verify-20261031.mjs`.
Every gate uses `sandbox-exec` with network denied except localhost,
the existing Flutter/Dart SDK under `/path/to/development/flutter/bin`,
exclusive logs, before/after source hashes and39 protected-file hashes.
Actual argv, cwd, UTC start/end, exit codes and log SHA256 values are in
`/tmp/xingyuan-ai2-c39-commands-20261031.jsonl`.

```text
node /tmp/xingyuan-ai2-c39-verify-20261031.mjs regression red
node /tmp/xingyuan-ai2-c39-verify-20261031.mjs regression green
node /tmp/xingyuan-ai2-c39-verify-20261031.mjs selected corrected-navigation test/agent_c39_data_notice_test.dart --name 'real runner (untimed-plan|later)'
node /tmp/xingyuan-ai2-c39-verify-20261031.mjs selected chinese test/agent_c39_data_notice_test.dart --plain-name 'combined notice' '--dart-define=DIARY_CAPTURE_FONT=/System/Library/Fonts/STHeiti Light.ttc' --dart-define=DIARY_CAPTURE_DIR=/tmp/xingyuan-ai2-c39-captures-20261031
node /tmp/xingyuan-ai2-c39-verify-20261031.mjs focused final
node /tmp/xingyuan-ai2-c39-verify-20261031.mjs app-full final
node /tmp/xingyuan-ai2-c39-verify-20261031.mjs server-full final
node /tmp/xingyuan-ai2-c39-verify-20261031.mjs core-full final
node /tmp/xingyuan-ai2-c39-verify-20261031.mjs eval-full final
node /tmp/xingyuan-ai2-c39-verify-20261031.mjs checks final
node /tmp/xingyuan-ai2-c39-verify-20261031.mjs selected isolated-deadline test/agent_c32_deadline_test.dart --plain-name 'C32 record read cannot outlive the Agent deadline'
node /tmp/xingyuan-ai2-c39-verify-20261031.mjs app-serial isolated
```

Combined-candidate harness: `/tmp/xingyuan-ai2-c41-verify-20261031.mjs`.
Its sequential gates require exit0 plus `All tests passed!`, record source
hashes and retain39 protected hashes and the old wire-contract hash. Journal:
`/tmp/xingyuan-ai2-c41-commands-20261031.jsonl`. All selected invocations and
their actual argv/cwd/time/exits/log hashes are recorded there; a passing
selected gate is not a completed combined-candidate D7.

The previous fefc300 CI run41072847797 is terminal billing-before-start;
it was not queried or rerun. New-candidate CI is recorded only after delivery,
without payment, quota or workflow changes. D7 relies on the new local matrix.
The old candidate's offline QA and installed-B observation do not verify C39.

Historical checkpoint at01:47 (UTC+8): all AI2 test/analysis sessions had ended. No new
C43 or A1-178 was present at that numeric-cursor read. State at that time was
blocked on the C40 header layout decision, not on owner permission. The
working candidate was uncommitted; no new outbox, push, CI query or device work.
After an explicit Claude correction, first recheck the retained default and
Chinese header failure, then run one complete sequential candidate D7 and
handoff. Do not rerun completed selections or the obsolete C39 seal script.

An intermediate immutable checkpoint is recorded by
`/tmp/xingyuan-ai2-c42-checkpoint-20261031.mjs`, with manifest
`/tmp/xingyuan-ai2-c42-checkpoint-manifest-20261031.json` and review copy
`.ai-bus/review/AI-2/C39-C42-checkpoint-20261031/`. It explicitly marks
finalD7=false, preserves all failed logs and the interrupted355-case run,
and identifies the invalid-font images. It is not a release seal.
The checkpoint script's first invocation failed during JavaScript parsing
(`Unexpected end of input`, exit1, missing outer loop brace), before executing
any copy or write. Its original source is retained as
`/tmp/xingyuan-ai2-c42-checkpoint-parse-error-20261031.mjs`; after adding the
brace, syntax is checked before the one effective archive operation. A first
patch attempt was rejected for duplicate target operations and made no edits.
These are local evidence-tool errors, not product/test failures.

Effort: this heartbeat began at00:52; the checkpoint is01:47, about55 minutes
of agent wall time for C39-C42 implementation, regressions, diagnostics and
evidence. This is not a human-work estimate or a release promise. Remaining
effort depends on Claude's header correction, final sequential D7 and AI1 QA;
no delivery date is inferred from the original estimate.

## C43/C44 Corrections

Both named patches were read completely and hash checked:

- C43 `b2629404966c2d5e57b97fbd8e88caa1f22eab50e35993e44cf29828504c720d`,
  only `assistant_proposal_page.dart`: fixed header max1.6x, title maxLines1
  and ellipsis; form keeps user scaling. Applied with `--3way --cached` then
  the same patch to the working tree to preserve the unstaged semantic callback.
- C44 `9f56e37ec892a38d3ba286f44c6a2ee4acc921dc1eaac984ff4cee1b03c79869`,
  only `goal_timing_fields.dart`: when scale(16)>32, full-width input above
  right-aligned minus/plus/clear controls. Clean `git apply -3`; keys, tooltips,
  input formatter, validation and callbacks remain unchanged.

New12 C44 cases first reported0 passed/12 failed: four true width failures
and eight QA failures because tooltip finders selected internal RawTooltip
nodes instead of IconButtons (including a2px rectangle discrepancy). Only
the finder was corrected; the old product then passed8 and failed4 at2.01x/3x.
Original test source and both logs are retained. Same corrected tests after
the patches pass12/12 in both fonts. Combined with the unchanged three original
C40 journeys, default and valid STHeiti runs each pass15/15. No geometry,
44px, keyboard inset, text scale or pixel assertion was relaxed.

Seventeen new synthetic Chinese PNGs were inspected individually, covering
three editor/confirmation/receipt scales and eight timing-component frames.
The3x editor header and full numeric field are now visible above the simulated
keyboard boundary; number/suffix have normal width. Large preview/receipt
content still needs scrolling. The light/dark1x/2x timing PNGs match prepatch
bytes exactly. The preserved2x narrow field can clip numeric glyphs; this is
an existing limitation outside C44's explicit >2x change, not claimed fixed.
No native keyboard, VoiceOver or full visual acceptance is inferred.

New harness `/tmp/xingyuan-ai2-c44-verify-20261031.mjs` preserves localhost-only
network policy and sequential gates. It adds C42/C44 and affected goal forms
to the focused list. Actual argv/cwd/UTC/exits/source/log hashes are retained
in `/tmp/xingyuan-ai2-c44-commands-20261031.jsonl`; final-source snapshots are
per gate. Inherited549 sources match C42's canonical hash exactly before the
new test/patches. Current550-source canonical:
`02998d99b9b8288a459a356e4a38204ff96a5d8fcc4f23119ba43fa3e9d7eb9d`.

Final D7 ran02:27:35 to02:43:08 (UTC+8), with no overlapping test/compiler
suites. Each test gate returned0 and its explicit completion marker:

| Final gate | Result |
| --- | --- |
| Related focused | 441 passed |
| Full App | 1884 passed |
| Full server / core / eval | 462 /128 /186 passed |
| App / server / core / eval analysis | All clean |
| All550 Dart-source format | Zero changes |
| Protected files | All39 hashes unchanged |

The59 new tests (24+16+3+4+12) are included in broader suites, never added to
their totals. The original15-case default/Chinese runs overlap these totals.
The14-record journal has two retained nonzero baseline runs and twelve
successful gates. No successful selection was retried to conceal a failure.

Actual harness invocations (SDK commands and complete input list in JSONL):

```sh
node /tmp/xingyuan-ai2-c44-verify-20261031.mjs selected timing-red test/goal_timing_c44_test.dart '--dart-define=DIARY_CAPTURE_FONT=/System/Library/Fonts/STHeiti Light.ttc' --dart-define=DIARY_CAPTURE_DIR=/tmp/xingyuan-ai2-c44-timing-before-20261031
node /tmp/xingyuan-ai2-c44-verify-20261031.mjs selected timing-baseline test/goal_timing_c44_test.dart '--dart-define=DIARY_CAPTURE_FONT=/System/Library/Fonts/STHeiti Light.ttc' --dart-define=DIARY_CAPTURE_DIR=/tmp/xingyuan-ai2-c44-timing-baseline-20261031
node /tmp/xingyuan-ai2-c44-verify-20261031.mjs selected original-default test/assistant_layout_test.dart test/goal_timing_c44_test.dart
node /tmp/xingyuan-ai2-c44-verify-20261031.mjs selected original-chinese test/assistant_layout_test.dart test/goal_timing_c44_test.dart '--dart-define=DIARY_CAPTURE_FONT=/System/Library/Fonts/STHeiti Light.ttc' --dart-define=DIARY_CAPTURE_DIR=/tmp/xingyuan-ai2-c44-fixed-chinese-20261031
node /tmp/xingyuan-ai2-c44-verify-20261031.mjs matrix final
```

The new manifest is `/tmp/xingyuan-ai2-c44-manifest-20261031.json`; review
copies are under `.ai-bus/review/AI-2/C39-C44-final-20261031/`. The seal checks
all120 archived C39-C42 entries without rerunning that checkpoint, captures
new logs/source snapshots/17 final PNGs/eight prepatch frames, and binds the
tested550 sources to exactly23 owned paths before commit and again at HEAD.
It is a precommit local-D7 seal; index/HEAD bindings and remote-SHA verification
establish delivery separately. Old C39 concurrency/timeouts/interruption,
C40 layout/font/semantic failures and every earlier failed result remain.
Unrelated diary review, Claude and synchronization files are excluded from
the commit;80 existing-file hashes are checked without changing their content.

This follow-up began02:21; D7 completed02:43, about22 additional minutes of
agent wall time plus delivery packaging. This is not human effort or a
promised release date. Independent QA, full visual/native/AG/J13 and the Agent
daily-backup gap remain separate; the old installed B is not this candidate.
