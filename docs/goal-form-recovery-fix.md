# R17 Goal Form Recovery

Date: October 27, 2026 (Asia/Shanghai). Scope: CO-26, existing J03/M1
Today -> new single goal. Both assigned product fixes are implemented.
This is producer widget/data/visual evidence. AI1 CO44 completed independently
in A1-129; Claude visual review is separate, not native or owner acceptance.
R16 was accepted within its bounded
local widget/data/shown-visual scope by CO-25; it is no longer awaiting R16 QA.

## Source And Scope

| Role | Commit |
| --- | --- |
| Baseline | `07692f3d89cfcdeff5aea79fc5b2e92280378750` |
| First-red tests | `c2c9e0ca8e83ae5fbc4ce1b9061a623a0f6bbb01` |
| Main product | `e4531c887e10b160f0fa429aec4f2a38e8bf90e3` |
| Final product | `861c76f56bb52c6e0bd20508df0f415d54fc3229` |
| Final tests | `f26e99ad6c9b026594d8bd13964eaebf27b61bde` |

The final documentation/candidate SHA and its exact-head CI result are recorded
after this report commit in bus message A2-85. Only the reviewed incremental
candidate branch `codex/journal-limit-feedback` is delivered; no journal backlog.

Runtime changes are confined to `goal_form_page.dart` and the new local
`goal_date_picker.dart`. The name error now wraps at the original bodySmall
scale; trim and 1..60 grapheme validation remain unchanged. No unsolicited
initial error. After explicit submit, only this field revalidates on edits.
A valid correction removes its stale error without clearing persistence errors.

The date path measures localized 1..31 labels in the actual day style and
MediaQuery text scaler. Its conservative budget uses at most 328px, reserves
48px across seven cells and 8px per label, with a 40px text-height budget.
These are local conservative fit budgets, not exact SDK calendar dimensions.
The measured fit decision is not a 320px/4x fixture special case. The readable
ordinary calendar stays. Otherwise a local fullscreen, SafeArea, scrollable
InputDatePickerFormField uses standard strict parsing and range validation.
No custom calendar/parser, SDK or shared-theme change, or text-scale reduction.

Valid candidate year/month/day units wrap between units; when necessary only
the suffix moves to a new line, keeping numeral tokens intact. Each semantic
label retains its complete unit. Explicit Cancel, Back and Confirm are retained.
Confirm changes only the parent form; persistence still requires parent Save.
Range remains today..9999-12-31; overdue initial value clamps to today and
cancellation leaves the original planned day unchanged. Completed single-goal
date restrictions remain covered by the related old history test.

No dirty-exit dialog redesign, management/detail layout change, dependency,
platform, store/schema, reminder, sync, identity, AI or backend change.
The C2 bubbles and journal 1000/5000 user-visible-character rules are unchanged.
CO43 capture/data helpers were reused with provenance to AI1 QA SHA256
`41425263534911aeb5ad310876f44aacd0859b0914c83947817e0e5390e4b7b4`.
AI1's original failed dirty-dialog audit and report remain separate and unedited.

## Results

All piped Flutter commands used `/bin/bash -o pipefail`; test process exits
were collected. Final runtime/test source bytes match the commits above.

| Run | Result |
| --- | --- |
| red-001, baseline product + first-red QA | 0 passed / 3 failed, 3s, exit 1 |
| final-001, Chinese font | 7/7, 10s, exit 0 |
| default-final, same cases without font/capture defines | 7/7, 14s, exit 0 |
| legacy-fixed-001, selected related old cases | 6/6, 7s, exit 0 |
| analyze-final, whole app | Clean, 4.1s, exit 0 |
| format-final, seven changed Dart files | 0 changes, 0.13s, exit 0 |

Seven unique new cases: three minimal regressions, ordinary and narrow actual
App journeys, one injected-keyboard journey, one measured layout-boundary case.
Two fonts do not mean fourteen unique cases. Ordinary is 390x844/1x/light;
narrow and keyboard are 320x568/4x/dark with iOS target override, not iOS runtime.

The ordinary journey selects day 28 on the actual calendar, cancels/reopens,
switches the standard calendar input and corrects invalid input. Narrow input
rejects nonexistent 2026/02/30, past 2026/10/26 and 10000/01/01 without clearing
them; 9999/12/31 is valid as a candidate, then explicitly cancelled. Back and
Cancel do not change the parent value. Correct 2026/10/28 confirms locally.
The ordinary controlled SQLite insert failure preserves the form; fixing a
name afterward does not clear the unrelated save failure. Explicit final
double-save creates only one goal. The saved goal is retrieved via management
and detail, not by directly replacing state.

At 1.3x Chinese font, measured threshold is 291.40771484375px:
290.40771484375 uses input; 292.40771484375 uses calendar and an intact day 28.
Default Ahem's measured threshold is 429.40008544921875, exceeding the capped
calendar budget; widths 343/345 both use input. This is an intentional font
difference, not evidence that Ahem exercised both branches.

The keyboard test injects 200px inset and uses fake input. The input, complete
candidate, Cancel and Confirm are reachable after explicit ensureVisible.
The Confirm node has button/tap semantics. This does not prove a native
keyboard, zero-scroll use, automatic caret following or VoiceOver interaction.

## Reproduction

Run from the exact candidate. Use a fresh, nonexistent capture directory;
the QA intentionally refuses to overwrite evidence and requires the
`/tmp/xingyuan-ai2-r17-` prefix. Append an independent suffix for AI1.
The producer directory below is existing evidence, not a rerun destination.

```sh
flutter test test/goal_form_recovery_test.dart test/goal_form_recovery_red_test.dart test/goal_date_layout_boundary_test.dart --no-pub --reporter expanded "--dart-define=DIARY_CAPTURE_FONT=/System/Library/Fonts/STHeiti Light.ttc" --dart-define=DIARY_CAPTURE_DIR=/tmp/xingyuan-ai2-r17-independent-new --dart-define=R17_PRODUCT_SOURCE=861c76f56bb52c6e0bd20508df0f415d54fc3229 --dart-define=R17_TEST_SOURCE=f26e99ad6c9b026594d8bd13964eaebf27b61bde
flutter test test/goal_form_recovery_test.dart test/goal_form_recovery_red_test.dart test/goal_date_layout_boundary_test.dart --no-pub --reporter expanded
flutter test test/widget_test.dart test/goal_history_ui_test.dart --name 'new single date and time pickers work at Size\(320.0, 568.0\)|overdue single|invalid names|write failure preserves|form validation and cancel|creates, checks' --no-pub --reporter expanded
flutter analyze --no-pub
dart format --output=none --set-exit-if-changed lib/features/goals/presentation/goal_form_page.dart lib/features/goals/presentation/goal_date_picker.dart test/goal_form_recovery_red_test.dart test/goal_form_recovery_test.dart test/goal_date_layout_boundary_test.dart test/widget_test.dart test/goal_history_ui_test.dart
```

Actual Flutter binary: `/path/to/development/flutter/bin/flutter`; Dart is in
the same bin directory. Final Chinese run used
`/tmp/xingyuan-ai2-r17-final-001-20261027`. First-red command selected only
`test/goal_form_recovery_red_test.dart`, with the same Chinese font and no
capture defines. Legacy changes only adapt actual calendar/input locators;
all pre-existing validation/cancel/save/history assertions remain.

## Data And Evidence

Evidence root: `/tmp/xingyuan-ai2-r17-final-001-20261027`.
There are three JSON reports, 91 observed states, 39 raw PNGs and 32 distinct
frames. The read-only producer audit separately checked all 45 tables at every
state, including nonempty unrelated goal/check-in/journal/photo metadata and
identity rows. Before explicit parent Save every table is unchanged. After
each full journey's double-save, exactly one new goal plus one title, schedule,
reminder and sync-state row exists; all old rows and other tables are unchanged.
New goal: planned2026-10-28, start/duration null, reminder off/1200/disabled
with reminder revision0; sync local_revision1. Narrow overdue picker at
2026-10-29 cancels back to stored28.
The keyboard-only journey never saves.

Memory-photo sets, bytes/hash and metadata remain unchanged; this is not
physical-file preservation evidence. Fake permission requests/settings,
notification scheduling, AI and photo picker calls stay zero in all three
journeys. Assistant, pairing and chat non-instantiation is asserted at the end
of the two full journeys only; the keyboard case returns before those final
assertions. No real data or credentials.

| Report | States | SHA256 |
| --- | --- | --- |
| `keyboard.json` | 17 | `13f2cf51f416b3878ef359b20386b00a13cacb6297ee6c1aed8c58aa88c682e0` |
| `narrow.json` | 45 | `0ad5018d775f44974230dcb59ee9bbf1a79c4ef7f2c95fa3b4d5541b5ea1a6dc` |
| `ordinary.json` | 29 | `7b80074978751be7bad060829e6bc7906dad39c48469149db500c5b3cf2be85e` |

Source bindings:
- Journey QA: `6916f03f326db2a53981a10fbfe7cade97ed8ed4106cc1a38ca4c252850d34ab`.
- Form runtime: `98f6a099d2961fdf17e1266ee4edf3644bae19d10a86f1cec0932386064ea172`.
- Date runtime: `e30b4cc8385ee5d864eb5b19990b0981ba9ebcb3cf76c0e144a8a084757399e6`.
- Chinese font: `a57b0316cc0544f682b8fb9855e14ade79ae77340ef6a01ba9210e25b4c5a5b7`.
- Manifest: `/tmp/xingyuan-ai2-r17-manifest-001-20261027.json`,
  SHA256 `69536fb0a1de52af5133c8dffa86b3e3835d9be613b5c21d6f22f667e6187b18`.
- Read-only audit: `/tmp/xingyuan-ai2-r17-audit-001-20261027.rb`,
  SHA256 `0c81645d5a13e6b3563747bc711e5725ff29c11ee35cc5acc49f2cd422d21de8`.

The manifest binds all39 PNG hashes/dimensions,32 duplicate groups,22 logs,
JSONs, QA, five runtime paths, font and audit source. The audit passed once;
it did not mutate evidence or rerun product tests.

## Visual Inspection

All32 distinct final raw frames were displayed and inspected. The remaining
seven images are byte-identical matches in the table below, not seven additional
viewings. Initial and aligned states are explicitly distinguished in JSON.
Ordinary dates remain a readable calendar. Narrow name feedback is complete
at13->52 and disappears after correction. Candidate-aligned frames show full
year/month/day; action-aligned frames intentionally scroll earlier content out
of view. The single-line input itself horizontally scrolls at4x; the separate
complete candidate display does not claim the entire raw input is visible.
The keyboard action frame shows the injected inset, not a photographed keyboard.
Management/detail images only establish retrieval identity and do not accept
their entire large-text/offscreen layouts. Today bubbles are unchanged.

| Personally viewed representative | Byte-identical additional filenames |
| --- | --- |
| `keyboard-today-initial.png` | `narrow-today-initial.png` |
| `keyboard-today-entry-aligned.png` | `narrow-today-entry-aligned.png` |
| `keyboard-form-initial.png` | `narrow-form-initial.png` |
| `narrow-date-initial.png` | `keyboard-date-initial.png` |
| `narrow-initial-candidate.png` | `keyboard-initial-candidate.png` |
| `keyboard-keyboard-input.png` | None |
| `keyboard-corrected-candidate.png` | None |
| `keyboard-date-confirm.png` | None |
| `narrow-date-selected.png` | `keyboard-date-selected.png` |
| `narrow-name-error-initial.png` | None |
| `narrow-name-error-aligned.png` | None |
| `narrow-name-corrected.png` | None |
| `narrow-maximum-candidate.png` | None |
| `narrow-date-after-cancel.png` | None |
| `narrow-invalid-2026-02-30-error.png` | None |
| `narrow-invalid-2026-10-26-error.png` | `narrow-invalid-10000-01-01-error.png` |
| `narrow-corrected-candidate.png` | None |
| `narrow-date-confirm.png` | None |
| `narrow-final-save-aligned.png` | None |
| `narrow-found-management.png` | None |
| `narrow-found-detail-initial.png` | None |
| `narrow-overdue-clamped-candidate.png` | None |
| `ordinary-today-initial.png` | None |
| `ordinary-form-initial.png` | None |
| `ordinary-name-error-initial.png` | None |
| `ordinary-name-corrected.png` | None |
| `ordinary-date-initial.png` | None |
| `ordinary-calendar-invalid-error.png` | None |
| `ordinary-date-selected.png` | None |
| `ordinary-final-save-aligned.png` | None |
| `ordinary-found-management.png` | None |
| `ordinary-found-detail-initial.png` | None |

Useful review sequence: ordinary/narrow name-error-initial -> name-corrected;
ordinary-date-initial; narrow-date-initial -> initial-candidate ->
invalid-2026-02-30-error -> corrected-candidate -> date-confirm;
narrow-date-after-cancel, final-save-aligned and overdue-clamped-candidate;
keyboard-keyboard-input -> corrected-candidate -> date-confirm.
No crop, resized replacement or old screenshot is substituted for final evidence.

## Retained Failures

- red-001: the original three failures reproduce truncated name text, stale
  name error after correction and split/clipped two-digit calendar day.
- fixed-001: functional assertions reached, but QA reset its platform override
  too late; 0/3 invariant failures. Reset moved into finally; fixed-002 is3/3.
- journey-001:1/3; ordinary Cancel finder was ambiguous; year10000 correctly
  produced a range error instead of the QA's expected format error.
- journey-002:2/3; BackButton finder matched parent and date surface.
- journey-003: boundary passed, narrow failed because QA required the center of
  a noninteractive candidate Wrap to be hit-testable. Text visibility and
  actual button hit checks were retained; journey-004 narrow/keyboard2/2.
- default-001:5/7; Ahem exposed wrapping inside year+suffix. Product now preserves
  numeral tokens and permits the suffix alone to wrap.
- default-002:2/7; the new semantics wrapper required the descendant RichText
  locator instead of casting the outer renderer to RenderParagraph.
  default-003 passed7/7; final rerun also verifies Confirm button/tap semantics.
- legacy-before-001:0/3 from calendar-only finders after the legitimate new input
  path. Only locators changed; legacy-fixed-001 is6/6 with previous assertions.
- analyze-001: missing braces info; analyze-002: deprecated hasFlag info.
  Both exit1; final uses flagsCollection and is clean.
- format001/002/003/004 recorded1/1/5/1 changed files; final zero.
- Read-only lookups of nonexistent `test/goal_ui_test.dart` and `assets/`
  failed; these were not product executions or failures.

Executed journey001/002/003 source snapshots are retained as
`/tmp/xingyuan-ai2-r17-journey-00N-source-20261027.dart`.
Other intermediate logs remain in their commit/edit chronology; they are not
retroactively bound to the final source and no nonexistent snapshots are claimed.
Original CO43's1 passed/1 failed full run and separate dirty-dialog scrolling
result remain intact. This scoped R17 evidence does not turn that old run green.

All log files use directory `/tmp`; the following checksums are in the manifest:

| Log | SHA256 |
| --- | --- |
| `xingyuan-ai2-r17-analyze-001-20261027.log` | `5e50f5acd241e6ad9e6a99d197164a25a8e1feb9faa1739937a16e7fea2231e0` |
| `xingyuan-ai2-r17-analyze-002-20261027.log` | `9be8995dd65e4260c5b0b37077d6269a32f29fc1dff170974f6a9860974b4247` |
| `xingyuan-ai2-r17-analyze-final-20261027.log` | `34f5894d7e10e53d8ef4d38c5bb32748387a83c3f21ea4bc135bc40f24ce39da` |
| `xingyuan-ai2-r17-default-001-20261027.log` | `854fb330abd929d65f7d3b30b02d94e96958abdb38b7878d002feba83b407bf1` |
| `xingyuan-ai2-r17-default-002-20261027.log` | `eac61ace212108ecd367d188b096067ac51e8adf93671ac5cfd8d4426ad2753b` |
| `xingyuan-ai2-r17-default-003-20261027.log` | `ff39906d8b77ed668f18db46132f5e95ba187435c1abf762f160a8fbf726af79` |
| `xingyuan-ai2-r17-default-final-20261027.log` | `10e0f37c6b2ec8fcc16681954a231777ffe96ec9cf1dfdc117877aea439e9e2b` |
| `xingyuan-ai2-r17-final-001-20261027.log` | `56ef796b849d54644659ca43f3a57f280c0db8c5f1d84786641dc12e7e7d989c` |
| `xingyuan-ai2-r17-fixed-001-20261027.log` | `d7881dbb2a3bd4ca70eeedba949b1cb237026cb785a970b44e5c1fcc9e72e840` |
| `xingyuan-ai2-r17-fixed-002-20261027.log` | `81bed00f0753e232539dfad905774ac5151fda8e5b1d6d1caece731b8bdb6794` |
| `xingyuan-ai2-r17-format-001-20261027.log` | `ec25a9cc3f8cfed9b4e713ea6028b69bccabcfddef3fe05d6db7205cb3c67408` |
| `xingyuan-ai2-r17-format-002-20261027.log` | `9ea27a951c869eb09fdfba2f09fd30e1ef270881d526493b3eda2153a6277b4c` |
| `xingyuan-ai2-r17-format-003-20261027.log` | `1fc00aa0495914e0ee648ac6ca0a3593bffaefe52ddbaf990ef3519fd9c27f23` |
| `xingyuan-ai2-r17-format-004-20261027.log` | `91d795e4ddd0f49f072c53ec8fdffd493eff6726e148e6df490eaeb054d776bf` |
| `xingyuan-ai2-r17-format-final-20261027.log` | `3ec8f351db495c07ae881d9d9d584931370c9c21083ad1e64dae0e687c329801` |
| `xingyuan-ai2-r17-journey-001-20261027.log` | `884a552f22649f7afa423741aec7ae1c33249a10a8a3a8236bd50e21a07bd791` |
| `xingyuan-ai2-r17-journey-002-20261027.log` | `8733bf57506dd41cb786e3ef89305db366e45fb51def557f5a09ced121d089ca` |
| `xingyuan-ai2-r17-journey-003-20261027.log` | `a157a3f1f27f7ecc2edeb7c0ff520385f695b281de11dbfe4f89f7a689e26ecb` |
| `xingyuan-ai2-r17-journey-004-20261027.log` | `0a9616e1e1cd5019190b0b54d189f318b82cc3ed0c83866a5069e68b8c45e85d` |
| `xingyuan-ai2-r17-legacy-before-001-20261027.log` | `e13fe5a9fc6237ab034a777339275d6dca601a9e4e31890dad6f48fdd26bcaf4` |
| `xingyuan-ai2-r17-legacy-fixed-001-20261027.log` | `43240e7d3a2e1d016a204fb987e5b35e5882791f5f27a62c141549cc659a40b5` |
| `xingyuan-ai2-r17-red-001-20261027.log` | `d73c52ce15486532143d2775936ed36a8de8e106f904f2d1b70295dd7ac8b55f` |

## Remaining Gates

AI1 A1-129 independently verified exact9496b79: seven Chinese/seven default/six
legacy tests, analysis and format passed within the report's stated scope.
Report: `/path/to/Desktop/git/idea-ai1/docs/goal-form-recovery-independent-validation.md`,
SHA256 `9dd56cbb7e5656e721767da3e9bf850fdc3a61373c38d55f50ab9279125dea3b`.
It was read and hash-checked, not edited, copied or rerun by AI2. Its 91 states,
39 PNGs and geometry checks are independent evidence, not new producer runs.
This also corrects A2-85's reminder revision1 wording to0 and narrows the
provider assertion scope above; A2-85 and original failure logs remain intact.

Claude now coordinates under C17; new-frame visual review remains separate.
No full App/old R/platform matrix, native/UIKit/actual OS maximum/IME/VoiceOver/
Inspector, physical photos, model, device, B, formal app or deployment work ran.
No new upload, service cost or network/platform authorization. CO31 remains
exhausted; CO27 requires a positive availability change and a new bounded decision.
B interruption/install permission remains separate, with prior recovery gaps
preserved. Owner experience and whole-J13 acceptance remain open.
Old terminal billing-before-start CI is neither repolled nor retried; the final
candidate gets only its own new exact-head CI observation, with no bypass.
