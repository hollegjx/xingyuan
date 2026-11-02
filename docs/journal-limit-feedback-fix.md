# R12 Inline Length Feedback

October 27, 2026, Asia/Shanghai. CO-16, existing J01/J02/J13 editor correction
scenario. This is an implementation candidate, not independent/native/owner or
release acceptance. No claim that the whole J13 experience is complete.

## Source And Scope

- Baseline product: `f2e62beeee98f9e54b25956770f5fb8eaaf5a64b`.
- Failing-first test: `4c8478bb25bac1d70b6fd8c86628a430928ba24d`, direct child
  of baseline, product unchanged. Original test SHA256:
  `54ccb82e328d6bdc6bf83aa6d9b01e81cb2d5af1516f310add48d566e53e41aa`.
- Product and initial corrected test: `c96d197775bfa052956c99d2c608becb7f124a0f`.
- Stronger simultaneous-count evidence: `43f3c3ea5968177303aef9810220cfaaa7d43c0a`.
- Final test/source: `c19adab2eed988472037167a576559d6591a2c90`.
- Candidate: `codex/journal-limit-feedback`. The final documentation SHA,
  verified remote ref and new exact-SHA CI outcome are in the AI2 outbox.

Only JournalEditorPage runtime presentation changes (26 additions/5 deletions).
The existing narrow/scaled breakpoint moves the full length error below the
counter inside the existing writing area, using the original error color and
bodySmall text with a live region. Ordinary InputDecoration remains unchanged.
No text scaling cap, truncation, maxLines, ellipsis, shortened wording or new
card/action. Near-limit counter and1000/5000 grapheme limits are unchanged.
Controller, store, confirmation, identity, AI, shared theme and dependencies are
untouched. Coordinator review edits remain un-staged; no QA or backlog merge.

## Verification

All executions use synthetic in-memory services/data. Logs are distinct files
under `/tmp/xingyuan-ai2-co16-<label>-20261027.log`; tee uses bash pipefail, so
exit codes below are Flutter's real result, not tee success.

| Label | Source | Result |
| --- | --- | --- |
| before | original red test, f2e product | 0/1,1s,exit1: width0 |
| after-001 | working source | 3 pass/2 fail,3s: corrected capture offscreen |
| after-002 | working source | 0/2,2s: caret below viewport |
| after-003 | working source | 0/2,2s: save center not hit-testable |
| action-004 | diagnostic working source | 0/1,2s: same hit-test failure |
| action-005 | gutter-scroll working source | 1/1,1s,exit0 |
| after-006 | bytes committed as c96d197 | 5/5,3s,exit0 |
| final / default | c96d197 | 5/5 each,3s/2s,exit0 |
| count | bytes committed as43f3c3e, Chinese | 5/5,3s,exit0 |
| final-002 | 43f3c3e, Chinese | 5/5,2s,exit0 |
| default-002 | 43f3c3e, default font | 2 pass/3 fail,2s: combined viewport |
| default-003 | exact test bytes committed as c19adab | 5/5,3s,exit0 |
| final-003 | c19adab, Chinese + seven captures | 5/5,3s,exit0 |
| guards | c96d197 product, existing unchanged tests | 3/3,1s,exit0 |

These are repeated runs of five unique new tests, not a summed matrix or full
App pass. Final analysis (`analyze-final-003`) clean2.6s; final formatting
(`format-final-003`)293 files, zero changes. No generation/platform work needed.

```sh
flutter test test/journal_limit_feedback_layout_test.dart --name 'R12 diary full limit feedback 320-4x-dark' --no-pub --reporter expanded '--dart-define=DIARY_CAPTURE_FONT=/System/Library/Fonts/STHeiti Light.ttc' --dart-define=DIARY_CAPTURE_DIR=/tmp/xingyuan-ai2-co16-before-20261027 --dart-define=LIMIT_CAPTURE_STAGE=before --dart-define=LIMIT_CAPTURE_SOURCE=f2e62beeee98f9e54b25956770f5fb8eaaf5a64b
flutter test test/journal_limit_feedback_layout_test.dart --no-pub --reporter expanded '--dart-define=DIARY_CAPTURE_FONT=/System/Library/Fonts/STHeiti Light.ttc' --dart-define=DIARY_CAPTURE_DIR=/tmp/xingyuan-ai2-co16-final-003-20261027 --dart-define=LIMIT_CAPTURE_STAGE=final-003 --dart-define=LIMIT_CAPTURE_SOURCE=c19adab2eed988472037167a576559d6591a2c90
flutter test test/journal_limit_feedback_layout_test.dart --no-pub --reporter expanded
flutter test test/journal_ui_test.dart --name 'quick note bottom sheet focuses|identity change hides journal editor|failed draft blocks exit' --no-pub --reporter expanded
flutter analyze --no-pub
dart format --output=none --set-exit-if-changed lib test
git diff --check f2e62beeee98f9e54b25956770f5fb8eaaf5a64b
```

Before: width0,height70,no glyph boxes,exceeded lines at14px scaled to56.
After: both320x568/4x themes width252,height140,two boxes,no exceeded lines,
same56px scale. The390x844/1x control stays100.307983x18,one box,14px scale.
Every full error/count is checked for nonzero width, nonempty boxes, no
truncation and all glyph bounds inside the viewport after scrolling. Chinese
final frames also show both complete together; default-font glyphs can require
more height than the entire viewport, so combined visibility is asserted only
when measured combined bounds fit. Full individual visibility is unconditional.

The three diary journeys preserve5001 graphemes, selection[4998,5000], autosaved
draft, original saved content/revision/operation receipt and all rows/columns
of diary_entries,diary_photos,quick_notes,quick_note_photos on rejected save.
Correction retains selection[1,3] and original saved content until one explicit
save produces revision1->2 and clears the draft. Empty-content failure remains
fully readable. Quick-note799/800/1001/1000 checks counter threshold, full error,
untruncated draft and no implicit save. AI/photo/request services stay unused.

## Preserved Limits And Failures

after-001 centered the tall minLines12 field, placing corrected text offscreen;
the harness now aligns its top for the corrected capture. after-002's caret
bottom358 exceeded viewport bottom294; this is not established as a new R12
regression and no automatic-caret repair is claimed. The final200px injected
keyboard check explicitly scrolls if needed, keeps exact correction/selection,
then checks caret visibility and the enabled, hit-testable save action.

after-003/action-004 dragged through selected text. The diagnostic screenshot
and hit-test path show a selection-handle overlay intercepting save center,
although the button remains enabled. Moving the gesture to the4px scroll
gutter passes without changing selection, focus code or product layout. This
does not claim that all native selection-overlay behavior has been repaired.
The final actual save is explicit after dismissing the synthetic keyboard.

The first final quick-note error frame clipped the count top. The additional
same-frame assertion/capture in43f3c3e exposed default-font height assumptions;
default-002 failures are retained. c19adab uses measured combined height rather
than hiding/shrinking content; the final Chinese count and error are both full.
Intermediate uncommitted diagnostic source hashes were not saved, so these
runs are not represented as immutable sources. Original red and final sources
are immutable. Missing lookup paths during inspection were not test failures.

No real IME, UIKit, actual OS maximum text size, VoiceOver, simulator/device,
owner trial or whole-J13 acceptance. Ordinary duplicate post-rejection feedback
is unchanged. Native automatic caret/selection behavior remains unverified.
No CO31 model replay, private configuration/data, B/formal app, production,
PR1, old CI/recovery or fees. Existing native and billing limits remain open.

## Evidence Manifest

Before directory: `/tmp/xingyuan-ai2-co16-before-20261027`.
Final directory: `/tmp/xingyuan-ai2-co16-final-003-20261027`.
All eight before/final PNGs were viewed; dimensions were checked by capture and
sips. Seven final PNGs have seven distinct hashes. Synthetic widget images only.
DPR1;320 safe20/0,390 safe47/34; exported frames have inset0. STHeiti aliases are
test-process only, not bundled product assets or typography changes.

| File (final prefix `limit-final-003-`) | Dimensions | SHA256 |
| --- | --- | --- |
| before/limit-before-320-4x-dark-inline.png | 320x568 | d9a4d71462dfd7e2e4d2f35bdde316c4c24baa569fda96a5c3df736a4c3726ea |
| 320-4x-dark-error.png | 320x568 | 20662c4d80b6cbfe8ba36908fc7e3fe66825c0200eaca91b7a8eda017e9a073d |
| 320-4x-dark-corrected.png | 320x568 | dd9ef95e62212ba3e74edf25c0ce74ee4e1e56b2fa24d6ee08d3ce82aedea9ef |
| 320-4x-light-error.png | 320x568 | 5590f79f2c52ff72fda08171b900996351265d05f572e2d9cd36d7c7bd8a749c |
| 320-4x-light-corrected.png | 320x568 | aaef150112a935e5b2903b547b2ab0cf273db2f0a2d00fc031149dfbb40e58a9 |
| 390-1x-light-error.png | 390x844 | 9a57bca44b48f59e0c32dc68f5fb4bc31d1162b4a25aa73f56fb1867308d8ca0 |
| 390-1x-light-corrected.png | 390x844 | 68f69b9180e20c87c7fbe69c2d944a069425070ca59c94e76d7cd85ffedae0e1 |
| quick-note-error.png | 320x568 | 611e82c195da47204cce43bf2a4d6bb2814953d23d42a770e305359e7673fe39 |

SHA256 source/helper/font manifest at c19adab:

```text
11e087070e6c1cc31513ada30c69e4c79091a646a7d249ad2766cb06f3fdc4ad  lib/features/journal/presentation/journal_editor_page.dart
d16b9158d99a62af7e01410889a08a3df7d965e0d3b0281fc71efe18df9316e9  test/journal_limit_feedback_layout_test.dart
e7403a388c1065b358bcb0a485c43799f0c4947cc420e88231ce21b8ab976005  test/journal_writing_space_test.dart
5d5fc066e710910cb245a2e775af56e0fa967ba5ad87db7842494f2125efb95c  test/journal_writing_breakpoint_delta_test.dart
bccdbe7b3c8cac2693cdb80cd097eed0e15513e23aae13458f05bdd015967fe9  test/journal_diary_capture_test.dart
5808fced4c357eaa23cff558e393be3d891172eab18bbf5d2d8835ed50fbcd03  test/support/diary_capture_pixels.dart
a57b0316cc0544f682b8fb9855e14ade79ae77340ef6a01ba9210e25b4c5a5b7  /System/Library/Fonts/STHeiti Light.ttc
```

SHA256 geometry/log manifest (same /tmp prefix and date suffix as above):

```text
b8fa1dda7fb8b3c51b2b5ea9f2473fad802bfe977d062dec974f6b4ed254f158  before/limit-before-320-4x-dark.json
b08a42fb6862b2f30d8506fcb6a81d2ff5531941caf3b7e67afac8afcfb91be8  final-003/limit-final-003-320-4x-dark.json
b08a42fb6862b2f30d8506fcb6a81d2ff5531941caf3b7e67afac8afcfb91be8  final-003/limit-final-003-320-4x-light.json
bae9445193d5e1470fdbc7236aaea0bb06ae9daff96b96422254018d0b69576b  final-003/limit-final-003-390-1x-light.json
8a16ffe241759a3dd1695ec61d3e1f95a403134fc1daa715841d149bc32669ef  before.log
1159466972eb958cff4b3814df2e8496caebb41fc1519f1bb1c94cca5c4468b4  after-001.log
2edb9a6b898212aeb17e9b087da7138cd386fb74087d5de9c3955493d04c2f75  after-002.log
466ffa166643d1d5fd6ddbfee6c21380f5eb8ca86f09c0539b86c77831ffe823  after-003.log
ff96aa27cadb0a6a7b3f32227ba8f3da18e53c91704335321105641c46a192d4  action-004.log
8afb678960409c9aa1c243eebc920b8dc054b296ba15f8137c14ab1d758ed930  action-005.log
6a821f7575b7db8d5bc59ca24ae55dd6d6bcdb2e173aa4242e28c985c8664150  default-002.log
26a9a2b8bb13bae70ed8c6cec4a5c1327c491545eb097abd748343d73d76bb54  default-003.log
3454cc15d8fb518873a7c0127996f817b74f7f1cca671b951d644455f571f974  final-003.log
09b9928ccb2cb4b91ea1bfbcf9f90a1d1ed10c58ba7b076903b1a67a45546757  guards.log
26cda2dbc82009ea81ff930bd996d393e03119087ed4f992b3c4ae397f4dfd4d  analyze-final-003.log
ac55188ba2bc3630623b65f5b354b84ac1f4497de5b2067e868d2a48481cca63  format-final-003.log
```
