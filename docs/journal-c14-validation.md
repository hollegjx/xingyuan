# C14 Independent Validation

Recorded October 25, 2026, Asia/Shanghai. This is AI-1 evidence, separate from
AI-2's J014 results. C14 is not accepted for installation.

## Exact Sources

- Runtime candidate: `4c17f83bfde5baa9093c7fe6752448dc7ca7fad8`.
- Native entry gate: `94f334925e4cc20e777c07d3b8a4927e6085ae49`.
- Between those commits, production paths are identical; additions are the
  formal-upgrade checklist, the entry gate, and its development documentation.
- Compared with installed B `25471f7a42716a02ae92f876ede06c7ce8e57739`, the only
  application runtime change is `journal_editor_page.dart`. C13 additionally
  changes test/diagnostic infrastructure, not the deployed server runtime.

## Results

| Layer | Result |
| --- | --- |
| Independent focused App suites | 161/161 passed at the exact C14 source |
| Independent full App suite | 1201/1201 passed on 94f3349, exit0, 236.443 seconds |
| Analyzer | Initial unused import in the new gate failed; removed it, then analyzer passed |
| Gate formatting | Formatted; final check unchanged, staged diff check passed |
| Native entry attempt 1 | Interrupted after 300 seconds at startup discovery; exit1, no tests ran |
| Native entry attempt 2 | 14 passed, 2 failed; exit1; release acceptance blocked |
| Source CI40113842642 | Exact 4c17f83 still in_progress when independently checked at 01:18 |
| Checklist CI40112820338 | Exact 8ded7aeb02ee8cc9c407b5282e05031a6d68aba4 completed/success, independently checked at 01:12 |
| Phone or owner acceptance | Not performed; B and formal app unchanged |

The native gate covers four states (expired consent, unconfigured service,
non-today diary, normal invitation and preview), in light/dark and 1x/3.5x.
It uses native iOS fonts/rendering with injected 320x568 viewport, text scale,
safe area, insets, synthetic services, in-memory data and fake text input.
These are not actual maximum-system-font, OS-keyboard, VoiceOver or live-model
checks. No private content, credentials or phone data are used.

## Blocking Finding

Both unconfigured-service cases at 3.5x fail with
`Floating SnackBar presented off screen`. The first error identifies the
underlying `lib/app/home_page.dart:38` Scaffold; the triggering action is the
new journal editor's long connection explanation. The editor and underlying
page share a messenger. This is a rendering failure, not merely duplicate
text matches. Root cause and correction remain for AI-2 to establish.

Preserve the gate's exception, zero-request, explicit-consent, unchanged-draft
and no-save assertions. Do not hide the error, reduce text scaling or isolate
only the editor in the test to manufacture success. A1-46 hands off the exact
gate and failure. Later native release checks await a corrected source.

The failed run's partial capture directory is not a successful screenshot
package. Fourteen passing cases do not cancel the two failures. The first
startup attempt remains independently failed: Runner had a listening loopback
VM service, while Flutter had no TCP connection and no test had started.
The verbose second attempt connected; this is not a proven startup fix.

## Evidence and Boundaries

Private artifacts: `~/.config/xingyuan/journal-c14-20261025/`, including
`focused`, `analyze`, `analyze-fixed`, `native-entry`, `native-entry-r2`,
`app` logs/results, and `observations.md`. First native render trace is at
`native-entry-r2.log:6676`; the second failed scenario is at line 7020.
Failures are retained, not overwritten by a retry.

The isolated simulator's normal entry was restored using the existing ordinary
`lib/main.dart` package from the recorded C11 restore-build/restore-install,
runtime source 25471f7. No rebuild or uninstall was needed. Full package
comparison after installation returned zero. Its Today page visibly retained
both C8 synthetic records; after stopping only that simulator app, all three
original Documents files (database and two photos) remained byte-identical,
with no additions. Appearance stayed light and content size stayed large.
The wrapper's source field records the invoking QA checkout, not the restored
binary's source; those two provenance values must not be confused.

The owner's diary issue remains unconfirmed. Code proves the v1-to-v2 consent
gate can disable the installed entry, but no phone observation establishes
that as the owner's cause. The new C14 failure is in an uninstalled candidate
and must not be described as the installed phone's failure.

C8's upgrade checklist is prepared, not executed. Actual PHPicker cancellation,
synthetic text save and selected built-in photo reopen worked on the prior
runtime, but no whole-library denied/allowed/limited prompt appeared. Actual
VoiceOver traversal could not be started on the available simulators; AX labels
do not substitute for spoken traversal. Those acceptance limits remain open.

No phone launch/stop/backup/install, mirroring retry, deployment, credential
read or model request occurred in this validation. The existing formal upgrade
approval gate and J1/J2/J07/J11/K14 remain open.

Separately, A2-35's diagnostic/checklist integration
`b698a0f6d6f14c398ca705d323a0ec3bed7f78fb` was inspected without checking it
out or executing the diagnostic. Relative to C14, only documentation and
`tool/assistant_eval` diagnostic/test files changed; the integrated checklist
matches 8ded7ae byte-for-byte. Its own CI40115378040 was independently observed
in_progress at 01:21. This is not a new application or deployment candidate,
and neither its reported diagnostic results nor CI replace C14 native evidence.

## Notice-Fix Follow-Up

Independent validation of runtime `a14eb4db7e705c17a3891c206dc86bed3ed4b363`
uses QA commit `84a45980931db7a4d9d0fcc8d169e8a5c027097c`. The QA delta contains
only two native gates and development instructions; production paths are
identical. AI-2's integration of the prior entry gate and report was also
checked byte-for-byte against their original commits.

- Focused App regression: 177/177, exit0, 55.624 seconds on a14eb4d.
- Analyzer: the new test import alias initially failed its naming lint; after
  correction, analyze passed and both gate files formatted with zero changes.
- Native entry: 16/16, exit0, 107.619 seconds on 84a4598. Both previously failing
  large-text connection explanations now remain in bounds. The assertions also
  preserve the original text scale, require one notice across the whole tree,
  keep Back hit-testable, scroll overflowing text to its end and dismiss through
  the standard close control. Privacy, no-save and exception assertions remain.
- Capture export: 34 PNGs, each 320x568, minimum 561 distinct RGB colors. Source,
  all 16 completion records, dimensions and exit0 were checked before export;
  PNG hashes are retained. All four theme/scale contact sheets were inspected.
- Merged native AI/UI: 78 passed, 2 failed, exit1, 498.021 seconds on 84a4598;
  details below. Actual system text, real keyboard and independent full App
  follow-up are deferred pending correction. AI-2's reported 1217 App passes
  are not substituted for an independent full run or native acceptance.

Private evidence uses `notice-*` names under the same evidence root. The entry
run token is `c14-notice-entry-20261025`; `notice-entry-export.json` indexes
`notice-entry-frames/`. The two extra frames show the ends of the large-text
connection messages. These remain native renderer captures, not OS screenshots
or actual system-text settings.

### Visual Finding A1-48

The dark notice's close glyph is difficult to distinguish from its background
at both normal and large text sizes. In
`3x-dark-disconnected-explanation-end.png`, the glyph's solid pixels are
`#111114` on `#2C2C2E`, a computed luminance contrast of approximately 1.35:1.
The normal-size disconnected and non-today captures show the same issue;
light-theme captures have a visible light glyph. Hit-test and dismissal
success do not establish visual legibility.

The journal notice enables `showCloseIcon` without a local foreground override,
while the app theme supplies a dark snackbar background in both themes.
A1-48 asks AI-2 to correct only the journal notice foreground and add light/dark
coverage. This visual finding remains open; it does not invalidate the 16
functional passes, and those passes do not close visual acceptance. It is not
evidence of the owner's installed-phone failure.

### Native Finding A1-49

The merged gate includes the existing journal UI suite alongside AI and notice
coverage. Its two failures are `diary at 320px 3.5 dark/light with keyboard`,
at `test/journal_ui_test.dart:334`: `journal-add-photo.hitTestable()` finds zero
widgets instead of one. These are test assertion failures, not observed
RenderFlex/FlutterError exceptions. Subsequent camera/delete/AI hit checks and
save assertions in those two cases were not reached and are not counted passed.

The suite has four quick-note keyboard cases, two ordinary-size diary keyboard
passes and two large-text diary failures. The separate notice suite's 16 cases
passed, including eight quick-note cases. Four final AI capture journeys also
completed, but do not override overall exit1. The failed capture manifest is
archived with an explicit failed result; its 28 frames were not exported as a
successful screenshot package.

The root cause is not established. The reused UI cases override physical size,
DPR and keyboard inset but do not specify padding/viewPadding, unlike the entry
and notice gates. A native-device safe area mixed with synthetic dimensions is
therefore a fixture hypothesis to investigate, not proof of a product defect.
Keep the first failure and all hit/text-scale/save assertions. Any fixture
correction needs measured metrics/constraints, plus later real-geometry and
actual-keyboard validation. A1-49 requests that distinction from AI-2.

Evidence: `notice-native-ai.{json,log}`, first failures at log lines 6738 and
6768, final summary 78 passed/2 failed; `notice-ai-failed-capture-report.json`
preserves the partial capture manifest and process exit1 explicitly.

### Restoration

The existing ordinary C11 package, runtime 25471f7, was reinstalled in place on
the isolated simulator without uninstalling or rebuilding. Full installed
package comparison returned zero. CUA showed both C8 synthetic records and one
photo on each; `notice-restored-simulator.png` records that ordinary screen.
Only this simulator app was then stopped. `documents-after-notice.json` matches
the fresh `documents-before-notice.json`: all three files byte-identical, no
additions. Appearance and content size stayed light/large. No test/native
process remains; the old simulator package was only read, and phones were not
operated. Wrapper source metadata denotes the QA caller, not the restored binary.

### CI Reconciliation

The earlier source CI40113842642 / 4c17f83 subsequently reached success,
independently confirmed at 01:26. Diagnostic CI40115378040 / b698a0f6 and prior
QA CI40115849774 / 7b54f89 were also independently confirmed completed/success
this round, with updates at 01:35:40 and 01:42:52 Beijing respectively.
The earlier GitHub API EOF observations remain query failures, not CI failures.
Those terminal runs are not polled again.

New source CI40117055011 / a14eb4d was in_progress at 01:52 and independently
confirmed completed/success at 02:05 (updated 02:02:38 Beijing). It does not
override the new native failures. Diagnostic CI40118502018 /
`de445a8722e41d91c20dec7200e32c96723e2158` was independently in_progress at 02:06.
That commit changes only the existing port probe and three documents; it was
reviewed read-only, not executed or checked out. Its reported macOS source-port
observation does not identify the historical errno98 cause. No CI was rerun or
cancelled, and no network settings were changed.

## Contrast And Geometry Follow-Up

The October 25, 02:10-02:19 Beijing follow-up independently reviewed contrast
source `f47c28a60170a307e29e352e162da8883eb95beb` and unified handoff
`bbeb094761ab6a4abffa60583b9d8cc1e32bc48e`. Relative to the preceding notice
runtime, the only product change sets the local close-icon foreground to the
existing notice text foreground. Global theme, layout, text scaling, AI guards
and persistence are unchanged.

Contrast validation used QA `5b811cdd69cb78102971bac1e645414f4611c855`, which
adds the unchanged native gates and prior report. Its lib/test/ios/assets and
pubspec files match f47. The handoff's product runtime also matches f47; its
two gates match original `84a45980931db7a4d9d0fcc8d169e8a5c027097c` and its
report matches `0577476a7cf13e1d14932af365b3b9a781e2c4b3` byte-for-byte.
Those integration checks permit reuse only of the unchanged tested scope,
not a claim of a new complete App or native pass.

### A1-48 Verified

- Focused notice regression: 16/16, exit0, 15.937 seconds on QA5b811cd.
- Native entry: 16/16, exit0, 100.963 seconds on QA5b811cd. The four states,
  both themes, 1x/3.5x scaling and all privacy/no-save/error assertions remain.
- Export: 34 nonblank 320x568 PNGs, minimum 552 distinct colors; source,
  all 16 completion records, dimensions and PNG hashes were checked.
- Pixel comparison with the preceding a14/QA84a captures: 24 images are
  identical. The remaining ten differ only within the close glyph: 118 pixels
  per dark image and 94 per light image. Both theme contact sheets were
  inspected, covering all ten changed notices; the dark close control is now
  visible, with no additional text, position or scroll-end differences.

This closes A1-48's candidate notice-contrast finding, not the owner's
installed-phone issue. Evidence is `contrast-focused.{json,log}`,
`contrast-native-entry.{json,log}`, `contrast-entry-export.json`,
`contrast-entry-pixel-comparison.json`, `contrast-entry-frames/` and
`contrast-{dark,light}-notices.png` under the existing private evidence root.
The native run token is `c14-contrast-entry-20261025`. These are native renderer
captures with synthetic metrics/data, not OS screenshots or live model evidence.

### A1-49 Geometry, Still Failing

Only the two original `diary at 320px 3.5` native cases were rerun on the full
bbeb094 handoff, using the existing AI gate, `--no-uninstall` and run token
`c14-geometry-two-20261025`. Result: zero passed, two failed, exit1,
59.388 seconds. Both first fail at `journal-add-photo.hitTestable()`;
subsequent action and save assertions remain unreached. No fixture, product
threshold, text scale, assertion or timeout was changed for this diagnostic.

The two themes produced the same measured geometry:

| Measurement | Value |
| --- | --- |
| Before override: physical size / DPR | 1242x2688 / 3 |
| At assertion: physical size / DPR | 320x568 / 1 |
| Editor padding (left, top, right, bottom) | 0, 132, 0, 0 |
| Editor viewPadding | 0, 132, 0, 102 |
| Editor viewInsets | 0, 0, 0, 200 |
| Text-ancestor maximum constraints / size | 320x137.7 / 320x137.7 |
| Action rectangles | Empty |

The 137.7px available height is below the existing 160px threshold, so the
toolbar is not created. This establishes the immediate trigger and supports
the mixed synthetic-dimensions/native-safe-area fixture explanation. It does
not establish a corrected-fixture pass or real-keyboard acceptance. The raw
view padding/viewPadding/insets diagnostic uses `.toString()` and yielded only
`Instance of 'FakeViewPadding'`; pre-override numeric edge values were not
captured. Any further metric diagnostic must serialize the four edges directly.

Evidence: `geometry-native-two.{json,log}`, first failures at lines 6665/6705,
wrapped geometry JSON at 6672-6681/6712-6721. A1-51 handed these synthetic
measurements to AI-2. Preserve the prior 78/2 and original 14/2 failures and all
hit/text-scale/save checks. A consistent-fixture correction, actual system
maximum text, real keyboard and independent full App verification remain open.

### Restoration And CI Boundaries

After both runs the existing ordinary C11 package, runtime25471f7, was restored
in place without uninstalling or rebuilding. Full installed-package comparison
returned zero. The ordinary Today screen retained both C8 synthetic records,
one photo each; `contrast-restored-simulator.png` records that check. Only the
isolated simulator app was stopped. `documents-after-contrast.json` matches the
fresh `documents-before-contrast.json`: three files byte-identical, no additions
or changes. Light/large settings were retained and no test/native process
remained. `contrast-restore-*` records the restoration; wrapper source metadata
denotes the QA caller, not the restored binary's source. Restoration is complete
and must not be repeated merely to refresh documentation.

The following exact runs were independently observed in_progress this round;
none was rerun or cancelled, and earlier terminal runs were not rechecked:

| Scope | CI run | Exact commit |
| --- | --- | --- |
| C13 diagnostic | 40118502018 | de445a8722e41d91c20dec7200e32c96723e2158 |
| Prior QA/report | 40119247630 | 0577476a7cf13e1d14932af365b3b9a781e2c4b3 |
| Contrast source | 40119167352 | f47c28a60170a307e29e352e162da8883eb95beb |
| Geometry diagnostic | 40119497902 | 3c28e6876b159a60d98b0c090a0f6481d400e8b7 |
| Unified handoff | 40119613053 | bbeb094761ab6a4abffa60583b9d8cc1e32bc48e |

CI status is separate from native results and is not an installation gate pass.
No phone, mirroring, credential, live-model, backend or network operation was
performed. B25471f7, formal86b48ad and backendbb6b2cf remain unchanged. The
owner's diary-failure cause, C8 acceptance limits and J1/J2/J07/J11/K14 remain
open; do not repeat the owner's pending question or production health checks.

## Consistent Fixture And Native Keyboard

On October 25, starting at 02:39 Beijing, AI-1 independently reviewed and
checked out `7735a868da4b91ec6013c7e7d264d6a83fa222eb`. Relative to fa5575c,
only four test/documentation files changed. Product code, dependencies, native
gates and the integrated prior QA report were unchanged. The fixture specifies
consistent 320x568/DPR1 safe areas and initial insets; it does not alter the
product's 160px toolbar threshold or remove hit, text-scale, save or error checks.

All runs used isolated simulator `6C8800D5-FB35-4B7D-A487-7BB9BD2F3AC3`,
`--no-uninstall`, synthetic input/services and in-memory test storage. Evidence
remains under the existing private `journal-c14-20261025` root.

| Run on 7735a868 | Result | Seconds | Evidence prefix |
| --- | --- | --- | --- |
| Original `diary at 320px 3.5` native pair | 2/2, exit0 | 76.674 | fixture-native-two |
| Mutually exclusive remaining changed UI cases | 8/8, exit0 | 116.252 | fixture-native-remaining |
| Actual system maximum text, both themes | 2/2, exit0 | 80.539 | fixture-system-text |
| Actual light keyboard, both record kinds | 1 test, 2 PASS markers, exit0 | 271.659 | fixture-keyboard-light |
| Actual dark keyboard, both record kinds | 1 test, 2 PASS markers, exit0 | 362.116 | fixture-keyboard-dark |

The remaining UI filter was
`inherited safe areas|quickNote at 320px|diary at 320px 1.0`; it includes the
two new inherited-safe-area regressions without repeating the original pair.
These ten affected native cases support closure of A1-49 as a mixed-metrics
fixture failure. They are not a new full 82/82 run, and the prior 78/2 and
diagnostic 0/2 results remain historical failures.

The system-text run used the actual accessibility-extra-extra-extra-large
setting, without synthetic viewport or scale overrides. Both themes reported
effective scale `3.1176470588235294`; the original `large` setting was restored.
The keyboard runs used CUA pointer/keyboard input and the Simulator software
keyboard toggle after host typing hid it. Light used rapid focus/input; dark
diary used separate focus and input. The native keyboard reached physical
bottom inset 1035 (345 logical at DPR3), returning to zero on dismissal. Both
kinds checked exact original text, preview, explicit use/append, no automatic
save, refocus, blank-header dismissal, undo and one saved revision.

There were no `JOURNAL_AI_KEYBOARD_ERROR` markers in either run. Light had no
INVALID markers. Dark retained two genuine negative native inset observations:
`-1090949.9654444142` during quick-note typing (log line 6407) and
`-888.040084113013` during diary typing (line 6422). Those events did not cause
a Flutter error or break the tested flow, but the negative-inset origin and
historical 34px issue are not closed. Appearance was restored to light after
the dark run. These results are not VoiceOver, physical-device or live-model
evidence and do not identify the owner's installed-phone failure.

### C15 Scope

At the safe point after the dark run exited, AI-1 independently reviewed and
checked out `157244eb1f51e382ba68361ba038d659e421376c` on
`codex/journal-c15-toolbar-qa`. Its entire diff from 7735a868 is
`test/journal_ui_test.dart` plus two documents; runtime, dependencies and native
gates are byte-identical. The preceding actual-text/keyboard evidence is reused
only for that unchanged scope, retaining its original SHA.

The new assertions retain the original two case names and 200px focused-save
path, adding a 350px synthetic stress inset, measured body below160, absent
actions and no exception. Unfocus/zero inset must restore body at least 160px,
all action hit targets, enabled photo action, unchanged text/scale and zero
saves. A later `showKeyboard` restores synthetic focus before the original
200px checks and explicit save. This is not a measured OS keyboard height.

The exact 157244e native pair passed 2/2, exit0, 83.070 seconds, using run token
`c15-157244e-native-two-20261025` and the full SHA as SOURCE. Evidence is
`toolbar-native-two.{json,log}`. This verifies the added hide/restore sequence
in both themes, not a new full native run. AI-2's initial synthetic focus-click
failure remains its reported evidence; this run did not change any test code.

One independent full App run on exact 157244e completed at 03:03 Beijing:
`flutter test --reporter expanded`, 1219/1219, exit0, 269.454 seconds
(`toolbar-app.{json,log}`). It was not repeated on 7735a868. `flutter analyze`
then passed with no issues (`toolbar-analyze`, exit0), and
`dart format --output=none --set-exit-if-changed lib test integration_test tool packages server`
checked 406 files with zero changes (`toolbar-format`, exit0). The only QA
working-tree edit was this report; product, test and dependency paths still
matched 157244e. No test/native/Runner processes remained after completion.

### Ordinary Simulator Restored

At 03:00 Beijing the existing C11 ordinary package, runtime25471f7, was restored
in place on the isolated simulator without rebuilding or uninstalling. The
source package on the old simulator was read-only. Full bundle comparison
returned zero; CUA showed both C8 synthetic records, each with one photo.
`fixture-restored-simulator.png` records that ordinary Today screen. Only the
isolated simulator's app was then stopped. The three files in
`documents-after-fixture.json` exactly match the fresh
`documents-before-fixture.json`, with empty changed/added lists. Final settings
are light/large. `fixture-restore-*`, `fixture-appearance-final` and
`fixture-content-size-final` preserve the operations. Wrapper SOURCE identifies
the QA checkout, not the restored package runtime. This restoration is complete;
documentation or later CI status changes do not require repeating it.

### CI Updates

Only previously nonterminal runs were checked. The following were independently
confirmed completed/success; update times are Beijing on October 25:

| Scope | Exact SHA | Run | Updated |
| --- | --- | --- | --- |
| Prior QA report | 0577476a7cf13e1d14932af365b3b9a781e2c4b3 | 40119247630 | 02:31:37 |
| Contrast source | f47c28a60170a307e29e352e162da8883eb95beb | 40119167352 | 02:27:00 |
| Geometry diagnostic | 3c28e6876b159a60d98b0c090a0f6481d400e8b7 | 40119497902 | 02:28:04 |
| Unified handoff | bbeb094761ab6a4abffa60583b9d8cc1e32bc48e | 40119613053 | 02:29:24 |
| Geometry QA report | fa5575c554a7fabc30e5b6486f144b456f586f88 | 40120384079 | 02:43:47 |
| Consistent fixture | 7735a868da4b91ec6013c7e7d264d6a83fa222eb | 40121202041 | 02:52:40 |

C13 diagnostic de445a8/40118502018 was already independently confirmed success
at 02:22 and was not rechecked. The new C15 test/document source
157244e/40122048566 was still in_progress at 02:58; it is not counted passed.
These CI layers remain separate from native, actual-keyboard and phone results.
No run was rerun or cancelled, and no network configuration was changed.

These completed checks do not authorize a phone installation or close overall
J1/J2/J07/J11/K14 acceptance. Installed B25471f7, formal86b48ad and
backendbb6b2cf were untouched. C8 spoken VoiceOver traversal and the full-library
permission-mode acceptance question remain open; PHPicker and AX evidence are
not substitutes. The owner's diary-failure cause still lacks confirming
entry/error feedback. There were no new credentials, live model calls,
production health polls, phone operations, deployments or owner prompts.
