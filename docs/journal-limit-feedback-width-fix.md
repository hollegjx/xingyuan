# R12 Width-Based Length Feedback

October 27, 2026, Asia/Shanghai. Follow-up to A1-118 within CO-16's existing
J01/J02/J13 editor-correction scope. This is a local implementation candidate,
not independent/native/owner acceptance. The original R12 report and failures
remain in [journal-limit-feedback-fix.md](journal-limit-feedback-fix.md).

## Source And Repair

- Baseline candidate: `c9592b232f526912b2cf14fd820731ee5a14bd7d`.
- AI-1's final failing test: `c90072121d9b02972056859d98a5f28317db8a1a`, SHA256
  `3d9bd9980e1979d11d5839df107a77d046463eb085f05447353de7b69013ade8`.
- Unchanged red-test import: `1868d8ca7db476c6a3b37aa646271d20db0b0cd4`.
  Only the test was imported, not AI-1's branch/report or any other workspace.
- Product and final tests: `3a503385555b58e2fe25e91d76c83b0c5e6b7056`.
- Final candidate/document SHA, remote and new exact-SHA CI: AI2 outbox A2-79.

AI-1's report at `3a5caba8f1138c367332ac4f0ca9f58d729b82f9`, path
`docs/journal-limit-feedback-independent-validation.md`, was read and verified
against SHA256 `77d31721fb318a79e40737080615f78997248d65dc7a8cafc99e31a2f127b62b`.
Its final1.5x run failed on actual ellipsis after all preservation assertions.
Earlier two QA-first failures (old TextField snapshot; live-region expectation
on the framework inline path) remain in that report. No old red/CI was replayed
merely for receipt. The1.5x omission was an uncovered existing boundary, not a
newly introduced regression or evidence of data loss.

The only runtime change is JournalEditorPage. A local LayoutBuilder supplies
the writing sheet's actual inner width; TextPainter measures the complete
error and counter with current styles, scaler, direction and locale. Their
combined width includes InputDecorator's verified16px counter gap. Only when
they cannot fit is the full error placed below the counter, using the existing
live region. AI placement retains its original independent breakpoint; the
390px/1x control retains inline feedback. No shrinking, ellipsis, shortened
copy, changed limits, controller/store/shared-theme/backend/platform/dependency
work. The large raw editor diff is mostly indentation inside the new callback;
the full and whitespace-insensitive diffs were reviewed.

The red test's data/visual assertions are retained. Its final expectations
require the separate live region at both1.5x and1.6x while independently checking
the unchanged AI position. Source metadata now identifies the actual source.
The affected quick-note boundary additionally runs at1.5x; no broad matrix.

## Verification

All data and services are synthetic/in-memory. Log prefix:
`/tmp/xingyuan-ai2-r12-boundary-<label>-20261027.log`. Commands use the local
Flutter SDK and bash pipefail with tee; results are not tee-only exit codes.

| Label | Source / Result |
| --- | --- |
| after-001 | working source, Chinese8/8,4s,exit0 |
| analyze-001 | working source,exit1: unnecessary non-null assertion,3.0s |
| default-001 | exact bytes later committed as3a50338, default8/8,3s,exit0 |
| final | exact3a50338, Chinese8/8,3s,exit0 |
| guards | exact3a50338, existing3/3,1s,exit0 |
| analyze-final | exact3a50338, clean2.6s,exit0 |
| format | exact3a50338,294 lib/test files,0 changes,exit0 |

These are eight unique focused tests plus three existing guards, not summed
repeated runs or a whole-App pass. The initial warning was fixed by removing
the redundant `!` from the already-promoted error; its log remains intact.
No product or test source changed after final verification.

```sh
flutter test test/journal_limit_feedback_breakpoint_test.dart test/journal_limit_feedback_layout_test.dart --no-pub --reporter expanded '--dart-define=DIARY_CAPTURE_FONT=/System/Library/Fonts/STHeiti Light.ttc' --dart-define=DIARY_CAPTURE_DIR=/tmp/xingyuan-ai2-r12-boundary-final-20261027 --dart-define=LIMIT_CAPTURE_STAGE=boundary-final --dart-define=LIMIT_CAPTURE_SOURCE=3a503385555b58e2fe25e91d76c83b0c5e6b7056 --dart-define=R12_PRODUCT_SOURCE=3a503385555b58e2fe25e91d76c83b0c5e6b7056 --dart-define=R12_QA_SOURCE=3a503385555b58e2fe25e91d76c83b0c5e6b7056
flutter test test/journal_limit_feedback_breakpoint_test.dart test/journal_limit_feedback_layout_test.dart --no-pub --reporter expanded
flutter test test/journal_ui_test.dart --name 'quick note bottom sheet focuses|identity change hides journal editor|failed draft blocks exit' --no-pub --reporter expanded
flutter analyze --no-pub
dart format --output=none --set-exit-if-changed lib test
git diff --check c9592b232f526912b2cf14fd820731ee5a14bd7d
```

At320x568/dark/1.5x, the old error was131.30455x26 with nonempty glyphs but
`didExceedMaxLines=true`; now it is252x26, full and unellipsized at the same21px.
At1.6x it is252x28 at22.4px. Both full counters and errors fit simultaneously;
AI remains outside scrolling content at1.5x and inside at1.6x. Both4x themes
remain252x140/two lines at56px;390x844/1x remains100.307983x18/one line at14px.
The imported boundary checks preserve5001 graphemes, selection[4998,5000],
original saved revision/operation, complete draft, all rows/columns of four
journal tables on rejected save, and zero AI/picker calls. The existing layout
journeys also verify one explicit corrected save. Quick-note799/800/1001/1000
checks now cover4x and1.5x. Unrelated empty-content feedback remains visible.

## Evidence Manifest

Final directory: `/tmp/xingyuan-ai2-r12-boundary-final-20261027`. Ten PNGs were
individually viewed and dimension-checked; five JSONs bind geometry to3a50338.
Synthetic widget/DPR1/injected scaling only, with the existing STHeiti test
aliases, capture and pixel helpers. Images are not bundled product assets.
Several error frames differ from the prior candidate; no blanket pixel/hash
identity claim is made. Corrected controls retain their existing image hashes.

| PNG | Dimensions | SHA256 |
| --- | --- | --- |
| r12-boundary-1.5.png | 320x568 | af772664054995d0683a0cf9989be31a57ac451a60d09c14724f6d34cef291cc |
| r12-boundary-1.6.png | 320x568 | f179f96415d449072dee1a854245d033fd2fdcddb6422bb2a76df5e8c2fb0ea8 |
| limit-boundary-final-320-4x-dark-error.png | 320x568 | 8c22703f2e54da481e97d597b82c2026ced2b9f87a72a7e7040da3f3ba5e50d5 |
| limit-boundary-final-320-4x-dark-corrected.png | 320x568 | dd9ef95e62212ba3e74edf25c0ce74ee4e1e56b2fa24d6ee08d3ce82aedea9ef |
| limit-boundary-final-320-4x-light-error.png | 320x568 | 68788bd5cd55c102df2e267ceaaf8227b66c317b1b579fab284c6dc0c43e9518 |
| limit-boundary-final-320-4x-light-corrected.png | 320x568 | aaef150112a935e5b2903b547b2ab0cf273db2f0a2d00fc031149dfbb40e58a9 |
| limit-boundary-final-390-1x-light-error.png | 390x844 | 56d67af4cda5cbb098ed92f121aeba10e982fde5e76c6da0e1e908bfde701da7 |
| limit-boundary-final-390-1x-light-corrected.png | 390x844 | 68f69b9180e20c87c7fbe69c2d944a069425070ca59c94e76d7cd85ffedae0e1 |
| limit-boundary-final-quick-note-1.5-error.png | 320x568 | c3f52988d44bec21b7b6e12be5472c4a49db325d0ccb1e400ba68338c7a4feef |
| limit-boundary-final-quick-note-4.0-error.png | 320x568 | e07e56c077d3103b003e31c6ae513ef290398825cc25f5b324e2e58fc4f43691 |

AI-1's before frames were also viewed, not regenerated:
`/tmp/xingyuan-ai1-r12-boundary-003-20261027/r12-boundary-1.5.png`, SHA256
`86b72d7f677e2fa211314b3d46750a3ea236784631f957de513584ce24e21aa3`, and
`/tmp/xingyuan-ai1-r12-boundary-001-20261027/r12-boundary-1.6.png`, SHA256
`892babf989209eec81e8c20e7efc5ea919cbb9a589b4553d9f1bcdd06e8bb079`.

SHA256 sources, geometry and logs (same final directory and log prefix):

```text
09c67fa6372afc8053fae90c9a993be3adad18f1767738310f29b86c04671ca1  lib/features/journal/presentation/journal_editor_page.dart
4b0a2bc93e4f9e80abc033f387154400a28597d03dd49c1a33385955e4add380  test/journal_limit_feedback_breakpoint_test.dart
336f9182a70b72d372ad5662b89b30362079a6d56daecf6e761b727bafa6f808  test/journal_limit_feedback_layout_test.dart
03327b7daae3d2d742858ffa692e3985e30df0fd2f255433122a38b25177750d  r12-boundary-1.5.json
9729c2f064522614327e235ff3dc48a219a2f16fe00bfcc060d1bf2282c91b46  r12-boundary-1.6.json
d6887508f16f755bf3e07a6e545485b56928a72c91b5ecaf1a80c63005e34a99  limit-boundary-final-320-4x-dark.json
d6887508f16f755bf3e07a6e545485b56928a72c91b5ecaf1a80c63005e34a99  limit-boundary-final-320-4x-light.json
26ef019c04e0939fae30f8b43ff29093baca279e0128ed5bb2ab786b35dc279e  limit-boundary-final-390-1x-light.json
1b2eb9940dd63135abc43292a82fc067e5b5fe8ba72ea674df70c11fef662bbf  after-001.log
e495189e86a3a9aaab7d5f7658e04520ca8db74bf5adf165ff5f0aeb98a4e6bb  analyze-001.log
a11712d161d4c6f295c7d0dd83929ad25d65d45d6b2d4d7f8e5b3b0fb594f122  default-001.log
b3e9742c1239d0ab7f6adddd483701f170a137fa49b16b945afc4e6060d46ce8  final.log
09b9928ccb2cb4b91ea1bfbcf9f90a1d1ed10c58ba7b076903b1a67a45546757  guards.log
26cda2dbc82009ea81ff930bd996d393e03119087ed4f992b3c4ae397f4dfd4d  analyze-final.log
60157bfbb279633035058046f3697c39b7d22871c9a84eb435496aafde6cad68  format.log
```

## Remaining Gates

The prior200px synthetic-keyboard check still uses explicit gutter scrolling
and dismisses that keyboard before saving; it is not automatic caret/selection
repair or real IME/UIKit evidence. Ordinary post-rejection duplicate feedback
and all earlier failures remain recorded, not silently fixed or waived.
Independent review of this new delta, coordinator visual review, actual OS
maximum text size, VoiceOver, native input and owner/whole-J13 acceptance remain
open. Existing Mac-interaction and billing limits are not retested. No old CI,
CO31 model runs, CUA/Simulator/phone/B/formal app, private materials/credentials,
production, recovery or new costs; no changes to coordinator review or sync files.
