# C49-C53 Structure Candidate

Date: 2026-10-31, Asia/Shanghai. Author workspace: `idea`, branch `codex/agent`.
Baseline: `47c9d0f1572348137f7174ac615190675d566e11`. This is the final-D7,
pre-delivery report. Exact delivered SHA, source/index/HEAD/remote binding and
new CI status are recorded separately in the delivery evidence and A2-108;
this report does not claim a commit, push or CI outcome before those operations.

## C53 Correction And Combined Verification

Claude C53 explicitly supplies the narrow photo-count fix and requests combined
C49-C53 D7 and handoff. The patch was read in full and hash/path reviewed:
`.ai-bus/patches/C53-photo-count-wrap.patch`, SHA256
`17e0bb2297b8dc6abaac3b6b57f76f988eeec515e001217b15f8a50ec0c6d688`.
`git apply -3` applied cleanly to the exact working/index sharing-page blob
`2c2c0f37c25c847c884092c879fa9e8c687f7d22`, producing
`2ac7a6ac81a6e48baef473c26e022b01e8fa15fa`. Only the `showPhotos:false`
photo-count Text is wrapped in Flexible, with a comment explaining the indent.
No text-scale clamp, wording/icon change, access rule, photo branch or reply
control change was added. All seven product files match the five named patches.

The original four default-font 3.5x failures passed4/4 from20:24:12.425 to
20:24:31.615 Beijing, exit0 and a complete success marker. Log SHA256 is
`2d39ab93932590ea32b824f075382aebf4abd305629cf2be555ae6db4bfe37f2`.
The sixteen-test source remains byte-identical to the saved C52 original source,
SHA256 `c3e0fad6512e2ed441bc798cd684456e4a8dbfef2784d71ff2013840f068d3a1`.
This preserves every original assertion and the earlier failure history.

The combined Chinese selection passed39/39 from20:24:48.817 to20:25:36.537,
log SHA256 `593cc103a29bccc7b6a183bd685b297124990757996a5e8c6ecfbe646b0ea902`.
The final556-source canonical hash before/after both gates is
`145153ff0528780e55f78a151697c9ec2ebca8f302b5ed3a78f035881c8b2968`.
Full combined D7 ran from20:26:13.309 to20:58:53.703, with the guard interruption
and source-bound resumption described below. All ten final gates completed exit0
with their success markers. The previous C49-only partial matrix is not reused.
The45-file related selection completed496/496 at20:36:16.413, exit0 with its
success marker; full App started at20:36:16.710 in the same sequential harness.
Full App completed1942/1942 at20:54:57.746, exit0 with its success marker and
identical source hashes. Its log SHA256 is
`20408452035e2a0bb5619b7d1708f8ce21d8111861da142bfb827b07c2e545d4`.

Immediately afterward the unrelated-file guard stopped the outer harness with
exit1: `.stversions/.claude/scheduled_tasks~20261030-205059.lock` no longer existed.
At20:55:43.432 the only drift among61 original unrelated inputs was that missing
historical sync lock; the other60 hashes, all39 protected hashes and all556 source
hashes were unchanged. No AI-2 action deleted, restored or recreated the lock, and
its disappearance cause is not established. The original baseline remains intact;
its former SHA256 was `9e62a5562ad928f30ffdabf6ca3bcbccc5265d0c998549dd09108e076d99f748`.
`/tmp/xingyuan-ai2-c49-guard-interruption-20261031.json` records this exception and
the outer failure separately. The revised guard requires exactly this absence and
all other60 original hashes, rather than silently replacing the baseline or
claiming all61 remain identical. The completed App gate is not a product failure,
but this first outer invocation did not complete D7. A bound `matrix-rest` resumed
the remaining eight gates at20:56:43.923 without rerunning focused/App or weakening
any test assertion. The source/log hashes of those two completed gates were checked
before resuming. This interruption is distinct from the two earlier incomplete
child-exit0 runs, which still lack success markers and remain non-passes.

| Final gate | Result |
| --- | --- |
| Related selection,45 files | 496/496 |
| Full App | 1942/1942 |
| Server | 462/462 |
| Shared core | 128/128 |
| Offline eval | 186/186 |
| App/server/core/eval analysis | Four clean results |
| Whole-source format | 556 files,0 changed |

The26 new tests are included in496 and1942. The four repaired-case reruns and
Chinese39 overlap those suites and are not added to the full App count. All final
gate intervals are nonoverlapping, on the same556-source hash. The complete27
child-command ledger retains7 exit1,2 incomplete child-exit0 and18 complete exit0
records, including earlier stages; it is not27 passing final gates. The extra
post-App outer guard exit1 is recorded separately. Command JSONL SHA256 is
`4412e11f7e3480dd0f67df3c47e161f508bd17a907c646fb8f45edc14a6289f5`;
guard incident SHA256 is `e508adcec33a23b9c4ae4ba116511da92228ef775f44fd231c175f1fa00e7155`.
No first-attempt-green claim is made. All sessions ended and the lock was released.

Measured final-matrix wall time was1960.394 seconds; child execution totaled
1853.226 seconds, with the remaining time including guard diagnosis/resumption.
This replaces any assumption based on the smaller C49-only selection, but is
not owner labor time, a future runtime guarantee or a release-date promise.
The39 protected files remain identical;60 of61 original unrelated files remain
identical and the one historical sync lock stays absent, without AI-2 alteration.

The new capture directory is `/tmp/xingyuan-ai2-c49-combined-capture-20261031`.
Its44 PNGs are all320x568 with44 distinct hashes. Twenty-five differing frames
were individually viewed at original size; nineteen match previously viewed
originals byte-for-byte, without claiming a second visual inspection. The new
review manifest is `/tmp/xingyuan-ai2-c49-combined-visual-review-20261031.json`,
SHA256 `eb1af4245195af8287a316fab4bf62f56e490fd0fd8fda05142aae6c2988b8d5`.
Today note/diary rows also reflect the shared icon fills. At2x/3.5x, targeted
scrolling places preceding content above the frame and later content below the
navigation bar. C51 images are standalone compact cards, not photographs of the
earlier Companion-home failure; the test separately checks home exceptions before
navigation. In completed3.5x frames, the top author/date line has scrolled above
the frame and completion text wraps below the photo count. No entire-card-in-one-
frame claim is made. The unchanged C50 privacy scrolling and C52 isolated title
wrapping/debug-ribbon limitations below remain for Claude's visual judgment.

## Historical C49-C52 Blocker

Claude C50/C51 explicitly expanded the in-flight C49 candidate, and C52 adds
center alignment for SectionLabel. All four named patches were read in full and
applied cleanly; seven product files are now changed. C50 changes My-page
grouping/privacy placement and shared icon fills, C51 changes shared-record
card hierarchy, and C52 aligns section titles and trailing actions. None changes
privacy defaults, sharing authorization, controllers, storage or network logic.

| Additional patch | SHA256 |
| --- | --- |
| C50-my-page.patch | 24ea1355b5fc1de7d78a746d30e33223f58fd6f8496420bcd2b874b7c6ae7cf1 |
| C51-feed-card.patch | 01eff0e947c296d0af8ac11d3699e967fc1f7b320a51b37cc47a9f21fd60a116 |
| C52-section-label.patch | 549c019aa1f58ab5a6528a6aa0c26fb0c66cb8a6e4e18104516ddfb2a9ef154c |

The resulting additional blobs are MyView `f9a6ee60410916750b064d648d1688987ebb2ee1`,
sharing page `2c2c0f37c25c847c884092c879fa9e8c687f7d22`, shared presentation after C52
`5b4caf3c86a8b3da1fa16a9aa9bb638b6d496cac`. No extra product styling was added.

New `ui_c50_c51_test.dart` initially had twelve contracts, all failing before
C50/C51. With the exact patches, the combined C49 ten plus those twelve yielded
18 passed / 4 failed. The four failures are light/dark 320x568, 3.5x, completed
and uncompleted records with a photo. Diagnosis locates the error in the actual
Companion home before opening the full sharing page: the `showPhotos:false`
photo-count Row at `sharing_page.dart:645` has width226 and overflows by26px
with the default test font. The detailed original failure is preserved in
`/tmp/xingyuan-ai2-c49-selected-c51-row-diagnostic-20261031.log`, SHA256
`d5582ce659b9f1aae35f8433ddbc44da67b292ec135fa92de32656ca1d591134`.

The same dark/uncompleted 3.5x case passes once with the explicitly loaded Chinese
font; log SHA256 `32446105111db277f55141aec919bb1c03506fa2791cdeacb8ddc8cf5ff1f061`.
That does not erase the default-font failure, prove a native problem, or establish
that all fonts fit. The test adds earlier exception checks and delegated error
diagnostics without removing any original assertions. Initial twelve-test source
is retained separately; do not claim it is byte-identical to the augmented file.

Claude owns layout changes. The recommendation in AI-2 status is a narrowly scoped
Flexible/wrapping photo-count label, preserving text scale, icon, both photo
branches, reply controls and access rules. That fix was not applied until the named
C53 patch above. C52 does not alter this Row. Its four new 1x/3.5x light/dark center/
44px/action contracts failed before C52 and passed afterward with unchanged source.

The C49-only focused gate finished383/383 at19:24:52.193. Scope expansion stopped
the immediately following App run during loading, using one SIGINT to its verified
child21943. Child exit0 lacked a completion marker, wrapper exit1; it is not App
success or a product failure. At that checkpoint no combined D7 had passed. All interrupted
sessions have ended. The 556-source checkpoint after C52 is
`2e664b36345ea0e0fb77b41f13fa192cc1a063e9b6d0e80faa3de2644eac2851`.
Historical C49-only results and24 images below retain their earlier source binding;
they do not establish C50-C52 rendering or final combined acceptance.

## C50-C52 Chinese And Visual Checks

The separately selected C50 four and C52 four explicit-Chinese cases passed8/8
from19:35:37.595 to19:36:00.760 Beijing, exit0 with the success marker. The log is
`/tmp/xingyuan-ai2-c49-selected-c50-c52-chinese-20261031.log`, SHA256
`899fd325e0147e3f260f600cdbc3c10a237404f4420cfba45159228beb615865`.
Its before/after source checkpoint is the556-input hash above. This selection
does not include the four failing C51 default-font cases or replace combined D7.

All twelve320x568 captures from that run and the one earlier Chinese C51
diagnostic capture were viewed individually at original size. The twelve show
My-page groups/privacy at1x and3.5x in both themes, plus four isolated SectionLabel
fixtures. At3.5x, My entries wrap; the privacy paragraph extends below the captured
viewport, so its full wording is not visible in one frame. In the isolated C52
fixture, the title wraps one character per line while the action is vertically
centered beside it. The fixture's debug ribbon remains visible. This passes the
narrow alignment/action contract, not full-page visual acceptance or a claim of
comfortable large-text composition. Claude should review that visual tradeoff.

The C51 diagnostic frame shows the standalone dark, uncompleted compact card with
Chinese text and the photo-count label fitting. The default-font failure is from
the earlier real Companion-home step, not this standalone screenshot. These are
different rendered contexts; the successful frame is not an image of the failure.
All screenshots contain synthetic data, not device/OS keyboard/IME/VoiceOver or
private-content evidence. No full UI, independent QA or owner acceptance is claimed.

Diagnostic review copies are under
`.ai-bus/review/AI-2/C49-C52-blocked-20261031/`. This is a blocked-candidate review
package, not A2-108, a passing delivery manifest or a successful D7 seal. Earlier
raw logs, failures, C49 images and source snapshots remain unchanged.

## Scope

Claude C49 supplies the UI decisions under the confirmed delegation. This is
M1 personal tracking and J03/J11 Today navigation refinement, not a new platform,
sharing policy or completed product milestone. Independent QA, full UI/native
and owner acceptance remain separate.

The named patch `.ai-bus/patches/C49-today-restructure.patch` was read in full,
SHA256 `3c63c9ab6ca301a7c8c1ff3e20d3dc9b1168f39e8f8f058d3210776db581483d`, and applied
cleanly with `git apply -3`. Only four product paths change:

- `entry_bubbles.dart`: flat shortcut card at normal size; existing adaptive
  tiles, callbacks, keys, semantics, hints, haptics and reduced-motion handling remain.
- `today_view.dart`: remove the redundant completion ring; keep count and star
  progress; slightly reduce summary padding.
- `day_record_preview.dart`: optional `showSaved` and `iconOnly`; defaults retain
  existing consumers. Icon-only empty entry has the same key and a write tooltip;
  the body preview owns read-error retry.
- `goal_tile.dart`: interactive nonarchived empty record entry moves before the
  detail arrow; saved records and drafts retain the body preview. Only one
  `record-<goal>-<date>` key is present for the visible tile.

The product files match the patch's four resulting blobs exactly:

| Path suffix | Git blob |
| --- | --- |
| goals/presentation/goal_tile.dart | de948f349ef5da364f54b6eaddef208d14ec2ad8 |
| goals/presentation/today_view.dart | 41d85e4d7bbf97297cea596459311283aa58fc71 |
| records/presentation/day_record_preview.dart | 0d0ca275c3ff0a140457dfddf954581f25e75c01 |
| shared/ui/entry_bubbles.dart | 8da62c3f24745db3e3fa67929e1a9b668f855d18 |

No additional product styling, controller, storage, schema, reminder, privacy,
sharing, model, budget or wire changes. No new backend deployment dependency.
The unchanged wire SHA256 is `b0bac8718d7be59da0a425a75ce98057c5afb46e2d65820eafae3420cad4875f`.

## Regression Evidence

New `test/today_c49_test.dart` contains ten tests. Six cover both themes at
320x568 and 1x/2x/3.5x: unique inline empty entry, tooltip/color/44px bounds,
draft return, save, independent completion/undo, cancelled and confirmed record
deletion, retained goal and no notification permission requests. Two check flat
shortcut decoration, 24px marks, ring removal and empty check-in navigation.
Two exercise loading, exactly one read-error retry and recovery without writes.

All data are synthetic, in-memory SQLite; record photo storage is a memory
substitute. This is not actual iOS keyboard, IME, VoiceOver or device evidence.

| Execution | Result |
| --- | --- |
| First fixture compilation | exit 1: missing snapshot import and incorrect Goal.title getter; not product evidence |
| Corrected original suite, interrupted | first five contract assertions failed; fake-clock teardown awaited stream.close and stalled; exact own child15899 interrupted once; child exit0 without completion marker, wrapper exit1, not a pass |
| Original code, corrected teardown | 0 passed / 10 failed, exit1, complete suite |
| Exact patch, unchanged assertions/source | 10/10 passed, exit0 |
| Explicit Chinese run | C49 ten + C42 four + entrance nine = 23/23 passed, exit0 |
| C49-only serial D7 | Focused383 passed; following App stopped for scope expansion; no complete matrix |

The fixture teardown now closes its synthetic stream without awaiting a
fake-clock event. No product code or assertions changed for this correction.
The complete original-red test source and final test are byte-identical,
SHA256 `f1fcad3f9638b70ecba4cf0c323eb5a652944044f5ffcdea7c6ae839ea416530`.
Compilation, interrupted-run and complete original-red sources/logs remain
separate. Historical failures are never retroactively marked green.

The C49-only 555 Dart inputs had canonical source SHA256
`958f6c6cddc04a5a1d667e6e79b62a28d118581fdb349c22cec007451b097594`.
The harness records hashes before/after each gate, exact argv/cwd/times/exits,
and requires a success marker as well as exit0. An exclusive lock prevents
overlapping author suites. The 39 protected files and 61 unrelated inputs are
checked against preserved baselines. New tests overlap focused/App counts;
Chinese and default suites must not be added to the full App total.

## C49-Only Visual Evidence

Twenty-four new 320x568 PNGs were viewed individually at their original size:
two empty-home frames, eighteen empty/draft/saved target frames across both
themes and three scales, and four C42 Today/date-scope frames. Explicit Chinese
font loading and existing pixel/selection-region assertions were used for C49
and C42 captures. Entrance tests retain their existing font setup.

At normal size, empty records are inline pencils; draft and saved content use
the body preview. At larger sizes, titles and records wrap. Captures scroll to
the asserted text; they do not show the whole target at once. C42 3.5x section
frames show the section and only the start of the first goal; controls are
exercised separately with scrolling. No claim that every goal is one line,
that list height decreased by a measured one-third, or that full UI/native
acceptance has passed. No screenshot is a device capture or private data.

## Reproduction And Handoff

Local author artifacts use `/tmp/xingyuan-ai2-c49-*-20261031.*`. The blocked review
package remains unchanged. Final synthetic evidence is sealed only after D7 under
`.ai-bus/review/AI-2/C49-C53-20261031/`, with a pre-delivery manifest and separate
post-delivery binding; exact manifest hashes are recorded in A2-108.
The command JSONL includes every original failure and final gate. Each command
runs under this localhost-only policy, with analytics suppressed:

```text
(version 1)(allow default)(deny network*)(allow network* (local ip "localhost:*") (remote ip "localhost:*"))
```

The inspected author harness uses `/path/to/development/flutter/bin/flutter`
or the matching `dart`, `--no-pub` for Flutter, test concurrency1 and expanded
reporting. Final matrix order is focused, full App, server, core, eval, four
analyses, then whole-source `dart format --output=none --set-exit-if-changed`.
The final-candidate invocations, run sequentially from the root, are:

```sh
node /tmp/xingyuan-ai2-c49-verify-20261031.mjs selected c53-patched test/ui_c50_c51_test.dart --name 'C51 feed .* 3\.5x'
node /tmp/xingyuan-ai2-c49-verify-20261031.mjs chinese c53-chinese
node /tmp/xingyuan-ai2-c49-verify-20261031.mjs matrix c53-final
node /tmp/xingyuan-ai2-c49-verify-20261031.mjs matrix-rest c53-final
```

Every actual SDK argv, cwd, time, exit, completion marker and source checkpoint
is in `/tmp/xingyuan-ai2-c49-commands-20261031.jsonl`. The report's first manual
patch missed a context line and made no change; an exploratory rg named a missing
settings test path and returned2. Both tool incidents remain in the transcript,
not product failures. The C49-only delivery helper was preserved separately
before being reviewed and updated for the14-path/five-patch combined candidate.
The C49-only focused set contained entry/record/GoalTile/Today/shortcut/preview
tests. The inspected harness now also selects My-page/settings/shared-icon/
sharing/reply consumers for the expanded candidate; that45-file focused gate
passed496. Exact paths are recorded in argv. Neither set is assumed to
match Claude's reported30-file/324 run.

No generation, native tests, model evaluation, device access, installation,
signing, server operation, real configuration, Keychain or shared ledger reads.
A0/A4 closed rounds stay closed. Old terminal CI is not queried or rerun.
Installed B remains baseline47c9d0f solely by A1-186's prior report; no C49
installation is claimed. New exact-candidate independent QA is still required.
