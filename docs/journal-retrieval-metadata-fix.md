# R14 Saved-Record Metadata Repair

October 27, 2026, Asia/Shanghai. CO-20, existing J01/J02/J05 retrieval journeys.
This is a candidate, not independent, native, owner or whole-J13 acceptance.

## Source And Authorized Handoff

- Baseline: `aa468028bd57b88a52ad93b8a19342d5562192c5`.
- AI1 CO36 test SHA256: `ad6d24e7e0080f775014d312a6c4339e6a8f43c60f980b4a1d48bd0fc2c010ec`.
  Read and imported byte-for-byte before product edits as
  `af27dd8901f17b5f78db46b68c7c772bc7cfdbf4`. There was no AI1 QA commit.
- AI1 report, read/hash-verified only, not imported:
  `/path/to/Desktop/git/idea-ai1/docs/journal-retrieval-independent-validation.md`,
  SHA256 `ff247c0132b015ad6a3ec30c2ed2f96f3235acebb8a0012b6890270207603b60`.
- First product: `9374a096fc69f23aba18e17d9c3984d8729012ef`.
- First adapted tests: `b505b4e7c00a3f09346ed5d0cba65266a514fe73`.
- Final tests: `a09676685bf8b0491d64f23c6178d3635cca19aa`.
- Final product: `85171448517b1a38c4e58527dc880408db73fcfd`.
  Its test bytes equal a096766; the later delivery commit adds only owned documents.
  Exact final candidate, normal-push equality and new CI disposition are recorded
  in the main-workspace outbox A2-82 on `codex/journal-limit-feedback`.

AI1's original first runs remain ordinary1/1,3s,exit0 and narrow0/2,4s,exit1.
The narrow cases reached data/privacy checks before their geometry failures;
they were not whole-case passes. The two raw log hashes were read-verified:
`57bbec541774e5b304994171d2bfbf68fd6210ba20c73d232247b7402267d332`
and `f4111299485999dbd17cca4a585751b8639c15da02f2b0c474376b405f742d53`.
The original baseline was not rerun, and original screenshots/logs were untouched.

## Runtime Boundary

Only `journal_list_page.dart` and `journal_day_sections.dart` change at runtime.
Complete day, weekday and HH:mm fields are measured using their actual resolved
style, locale, direction and TextScaler. The original40/44px lead and left/right
layout remain when they fit. Otherwise whole fields wrap above the full-width
summary. Metadata never uses ellipsis, shrinking, FittedBox or a scaler cap.
If even the chevron would take required field width, it gets a separate row.
List/day dividers use16px when metadata reflows; ordinary66/70px alignment remains.

Original colors, text sizes, summary ellipsis, draft badge, photo count, whole-row
tap, grouping, reverse ordering and timezone/date formatting remain. No editor,
controller, store/schema, shared theme, backend/prompt, dependency, workflow or
platform change. C2 bubbles and1000/5000 visible-character rules are untouched.
This covers tested widths/scalers; it does not claim arbitrarily large fields
can fit every conceivable viewport.

## Tests And Retained Failures

The imported test retains all three actual-App journeys and every original
data/privacy/full-token assertion. Changes add source bindings and a fresh
capture prefix, Today/Review metadata frames, and nonoverlap/full-summary-width
checks. No skip, swallowed error or removed red guard. CO36 test names remain
for provenance; JSON now records the actual R14 product/test IDs, not a stale
baseline-as-candidate label.

Two new breakpoint cases use actual paragraph styles and measured one-line
width, testing both sides with a nonuniform TextScaler whose scale(14) stays1.
Chinese time threshold1.3576483494 and diary threshold1.6666666667 are tested
at plus/minus0.01. Default Ahem thresholds differ (0.6769230769 and1.0).
Each token has nonempty single-line glyph boxes inside its paragraph, no
ellipsis/summary overlap, original font scaling, matching divider inset,
reachable draft/whole-row hit target and nonblank text-region capture pixels.

| Run | Exact product/test | Result | Exit |
| --- | --- | --- | --- |
| run-001 Chinese, both files | 9374a09 / b505b4e | 3 passed,2 failed;6s | 1 |
| run-002 Chinese, breakpoint only | 9374a09 / a096766 | 2/2;under1s | 0 |
| default-001, both files | 9374a09 / a096766 | 4 passed,1 failed;4s | 1 |
| regression-001 | 9374a09 / a096766 | 3/3;3s | 0 |
| run-003 Chinese, both files | 8517144 / a096766 | 5/5;5s | 0 |
| default-002, both files | 8517144 / a096766 | 5/5;5s | 0 |
| regression-002 | 8517144 / a096766 | 3/3;3s | 0 |
| analyze-001 | 8517144 | no issues;3.9s | 0 |
| format-001 | 8517144 | four files,zero changes;0.04s | 0 |

Every listed command used bash pipefail and tee. These are five unique new cases,
not ten unique cases or all-App coverage. The related three cases are the
existing quick-note draft/idempotent-save, diary Today/Review/history, and
photo-count/open/remove/delete-cancel journeys.

The first two failures were new QA capture framing: RepaintBoundary inside the
Scaffold wrapped only an87px/141px list row, not the expected568px viewport.
a096766 moves the boundary outside the Scaffold; it does not alter product,
field or data expectations. All three App journeys already passed in run-001.

The next failure was a genuine current-font width edge: default Ahem4x HH:mm
is260px, fitting the262px content but not the243px header after the chevron.
Four time-field width assertions failed after the three-route data/privacy
journey. 8517144 gives the chevron its own row when needed. The unchanged test
then passes. Chinese output stays byte-identical to run-001. default-001 had
no capture/source flags, so its logged candidate is empty, not an invented SHA;
the table identifies its actual checkout. No old failure is overwritten.

A pre-run single-file analysis was clean. An initial read-only wc path lookup
targeted a nonexistent widgets/journal_preview_tile.dart (exit1); actual tile
is in journal_list_page.dart. This was discovery, not a product/test failure.

## Reproduction And Evidence

All commands ran from `/path/to/Desktop/git/idea`, using
`/path/to/development/flutter/bin/flutter` (or its sibling dart).
The following is the exact final capture command:

```sh
/bin/bash -o pipefail -c '/path/to/development/flutter/bin/flutter test test/journal_retrieval_independent_test.dart test/journal_metadata_breakpoint_test.dart --no-pub --reporter expanded "--dart-define=DIARY_CAPTURE_FONT=/System/Library/Fonts/STHeiti Light.ttc" --dart-define=DIARY_CAPTURE_DIR=/tmp/xingyuan-ai2-r14-run-003-20261027 --dart-define=R14_PRODUCT_SOURCE=85171448517b1a38c4e58527dc880408db73fcfd --dart-define=R14_TEST_SOURCE=a09676685bf8b0491d64f23c6178d3635cca19aa 2>&1 | tee /tmp/xingyuan-ai2-r14-run-003-20261027.log'
```

run-001 uses the same two files with product9374a09/testb505b4e and run-001
output paths. run-002 selects only journal_metadata_breakpoint_test.dart with
product9374a09/testa096766 and run-002 paths. default-001 uses both files without
dart-defines; default-002 removes font/directory flags from the final command
but keeps both source IDs. Both default logs use their names from the table.
Use a new output directory/log when reproducing; do not overwrite these files.

```sh
/bin/bash -o pipefail -c '/path/to/development/flutter/bin/flutter test test/journal_ui_test.dart --name "quick note bottom sheet focuses|diary appears in today|photos add, open and remove" --no-pub --reporter expanded 2>&1 | tee /tmp/xingyuan-ai2-r14-regression-002-20261027.log'
/bin/bash -o pipefail -c '/path/to/development/flutter/bin/flutter analyze --no-pub 2>&1 | tee /tmp/xingyuan-ai2-r14-analyze-001-20261027.log'
/bin/bash -o pipefail -c '/path/to/development/flutter/bin/dart format --output=none --set-exit-if-changed lib/features/journal/presentation/journal_list_page.dart lib/features/journal/presentation/journal_day_sections.dart test/journal_retrieval_independent_test.dart test/journal_metadata_breakpoint_test.dart 2>&1 | tee /tmp/xingyuan-ai2-r14-format-001-20261027.log'
```

Final directory: `/tmp/xingyuan-ai2-r14-run-003-20261027`.
There are28PNG files with22 distinct hashes and five JSONs. All22 App images
are byte-identical to corresponding run-001 images. Each distinct App frame
was viewed (16 at run-001, six ordinary frames at final); all six final
breakpoint images were also viewed. Hash equality links the already-viewed
App frames to the final product. Ordinary1x remains left/right;2x/4x fields
are complete above summaries. No metadata/summary overlap was observed.
At4x, lead-first list frames clip part of the draft badge; a separate scroll
and full-glyph check verifies its reachability, not a claim it fits in one frame.
Some Today/Review frames intentionally start partway down the page.

The three actual routes retain Today/history isolation, My diary and note
draft return/reopen, explicit save, and Review calendar selection/reopening.
Before save, complete draft and saved content/version/receipt remain separate.
Each explicit save changes exactly one target row, revision1->2, preserving
id/owner/day/zone/createdAt/deletedAt. Other rows and every column across all
four journal tables remain unchanged; no duplicate or write to today.
Review reopening can establish an equal draft, so is not described as zero-write.
AI and picker calls stay0; assistant/pairing/chat providers remain uninstantiated.
A separate structured read of final JSONs verified all six save transitions,
source IDs/hashes, fixture linkage, privacy flags and PNG dimensions/hashes.

Fixture SHA256 (Ruby JSON.generate on parsed fixture, stored key order):

```text
73702a18ed34983ffd5fe8eabf52350efd0fcf57d0c7177144f818c64f7a018b  320-2x-light
9814b86d0984f8b0853072e873f07dd2527d4a2602fcaa7bde076d72283d25c1  320-4x-dark
8b68d597501176c44b08364f5d57112363b1872f0befed0b3e38feecf4ed7978  390-1x-light
```

Final PNG/JSON SHA256 manifest, relative to the directory above:

```text
25996a451c2c770bf997b7cedd76e950f69e114b5e2ceaba1d60fd4ef7cc878c  320-2x-light-diary-draft-list.png
9c006d91445e456b0f62e1f8c072a2f2fcfffbfd062ae8bf532ec1e3c643c42f  320-2x-light-note-reopened.png
b5e3d278af551f69cfda36cf865b4babe7e29255bfc9e6e8a77dd8519330bd57  320-2x-light-quickNote-draft-list.png
047965f5d422e6281ae7534850695cd4a7fd617e5cdbea02a53722f65e3d9699  320-2x-light-review-diary.png
d5b984dd13aab4916317e98a7bcef686c51ac974cb554689381afffbc6f61a8e  320-2x-light-review-quickNote.png
8d7d485873cdaf0e461bce7b819912f831a9e6745b80c7aa75b5924bf969b8d7  320-2x-light-today-diary.png
aaa9488a57e3ed796fe1b9b7a65453ce2d660890a16d9088576a3744b33fc394  320-2x-light-today-quickNote.png
a7edfe486a04740328782966f3d2537c90eb93032887fc699be64f54c665baec  320-2x-light.json
5c6e2363829e295bf894b7c71e9bc764a2015c04a18f9e8a388b7204bbf20ac1  320-4x-dark-diary-draft-list.png
b929480d2300408178c866c9c4ea5c398ddf44d68d6ac5c9cd66dc9df9482930  320-4x-dark-note-reopened.png
2f26bdabe36e1e5ded846cf26b6b99fdc52e9f48ea139f2c45c548c59307c9e2  320-4x-dark-quickNote-draft-list.png
6ab4ee202156954afbad4b425ad356f9dc77d2e97f67aa1d3dc08ef0e3457e54  320-4x-dark-review-diary.png
741c6535250d955b1491a07d5e557b0e94c8deca60a016be20c46c864fffe847  320-4x-dark-review-quickNote.png
1463bcd76d192108d4b9307bd168f163887570df859324539654300dd101185a  320-4x-dark-today-diary.png
4d0013c01f24c1730a6d2edacf7bca026b8b2462d2c67716718344e685a3e636  320-4x-dark-today-quickNote.png
d2e6cf6b0557b88c1c05d2bccdd21960b7a2a53b052ff1536f5d6e0c2d63339e  320-4x-dark.json
72d20cdcafb3b9b8062d667933d00df85848fbb4a1aaf5be2a6414b62576192a  390-1x-light-diary-draft-list.png
302b2aae0b9d34d7afaf668782902909902f0c2049e486e448ca1d67fb7efcad  390-1x-light-quickNote-draft-list.png
f59ccb5dd794e842469b8c446fb14c2717265ac305e67c957e0d89b92e927c28  390-1x-light-review-diary.png
f59ccb5dd794e842469b8c446fb14c2717265ac305e67c957e0d89b92e927c28  390-1x-light-review-history.png
f59ccb5dd794e842469b8c446fb14c2717265ac305e67c957e0d89b92e927c28  390-1x-light-review-quickNote.png
59e3aacb7f81fd4f9c3020c6bc4a4cd52ada792e3392a14552c4a0000b3edaf2  390-1x-light-today-diary.png
59e3aacb7f81fd4f9c3020c6bc4a4cd52ada792e3392a14552c4a0000b3edaf2  390-1x-light-today-quickNote.png
59e3aacb7f81fd4f9c3020c6bc4a4cd52ada792e3392a14552c4a0000b3edaf2  390-1x-light-today.png
e05e2394130c0d95c7b34f9f61cbd390ed82f38b9a252f242f612cf91fbd7d3d  390-1x-light.json
091776856e00b4cf91f18afb4669bf2e86b3b3be3e8d9a1988e19aa02464f7f9  diary-above-26.png
091776856e00b4cf91f18afb4669bf2e86b3b3be3e8d9a1988e19aa02464f7f9  diary-above-周一.png
641b5096f614af157c1ab63d4d648ad8eeb9b21de105727fb40b78b51665e1c8  diary-below-26.png
641b5096f614af157c1ab63d4d648ad8eeb9b21de105727fb40b78b51665e1c8  diary-below-周一.png
7f05a4870ac51c1470cf6019922fab7fbe088edc0c67ecd313724ebc8516eb75  diary-breakpoint.json
233bed1494da530fcacaa714c602698260811ea2a5dd90ee00ea4ca32fb2e613  quickNote-above-18:40.png
1b26fa3f0035286a7c287e4536c7c171b6ed4af31b2268c42355103f74778227  quickNote-below-18:40.png
98766bb8e93dce8373025709e0521eb6ea880c0d56b7ff303dbe9bba7f835ef8  quickNote-breakpoint.json
```

Full logs, including all first failures:

```text
b62807c89e64e148507cd19c280939fdae8621f6fcff6e36c291b8fc47ce86dd  /tmp/xingyuan-ai2-r14-analyze-001-20261027.log
ff56ca2ead57adceb23d36e20b50caa8e6bbba97e34dab2e78d108961bd41a19  /tmp/xingyuan-ai2-r14-default-001-20261027.log
c92cf0ac4a569997ff99aecd9191ec2305755b9a6e422398cc277184b5558828  /tmp/xingyuan-ai2-r14-default-002-20261027.log
7477651517b81e82690cdc75609bc9e914fef11973ce522f1e8f33c5ed04d09b  /tmp/xingyuan-ai2-r14-format-001-20261027.log
ee896a87dc5818a17a7719f3832a82ecc2f57903551abd77d112b11fac955a2b  /tmp/xingyuan-ai2-r14-regression-001-20261027.log
ee896a87dc5818a17a7719f3832a82ecc2f57903551abd77d112b11fac955a2b  /tmp/xingyuan-ai2-r14-regression-002-20261027.log
b4a9482c16f99825d09b3a5bd35530a1ca298ff0f5680f439adcbdc9ba639a6c  /tmp/xingyuan-ai2-r14-run-001-20261027.log
8fb964c6e598ec56bcc5a0a8368e2a8aaa5732457ab40a1a1f7fcff887bed14d  /tmp/xingyuan-ai2-r14-run-002-20261027.log
f49c0f03481468d8ae39473ec6125f2a4e7d8202bed8893dfb7f02f6f35ce7be  /tmp/xingyuan-ai2-r14-run-003-20261027.log
```

Final source SHA256:

```text
98a1b2ab0915a3afd9766ac809f8864b80b80c92a3cc4fd374d2a34eb2aae496  test/journal_retrieval_independent_test.dart
7482c22fac4e08b570eea0d975840a8d282486459704f6e764b22c8d95c82558  test/journal_metadata_breakpoint_test.dart
62a84e4c082b033290f30eaf2905cd9af489557478fc79b3248986e7823f92be  lib/features/journal/presentation/journal_list_page.dart
1313ca8101aa4f78109361809423c2ace177bd544d9c1861fb98041b0ffad93d  lib/features/journal/presentation/journal_day_sections.dart
```

## Limits And Delivery

All evidence is local widget/DPR1, injected scaling and synthetic SQLite data.
Chinese rendering uses the existing test-only font alias; no production font
is installed or bundled. Keyboard inset is0; ensureVisible/explicit scrolling
is used. Native IME, actual OS maximum, UIKit, VoiceOver/Inspector and owner
experience remain unverified. No native/CUA/Simulator/device/availability probe,
model call, private config/credential/data, B or production action occurred.

CO18/CO35 is now accepted only in the coordinator's CO-19 bounded scope.
R14 independent exact-delta validation and coordinator new-image review remain
pending. No whole-J13 claim. Only this candidate's new CI may be followed;
all prior terminal CI, including40440648435, remains unqueried/unrerun.
No billing, workflow, PR1, historical journal backlog, other branch/workspace
or synchronization/review file changes are included in the delivery.
