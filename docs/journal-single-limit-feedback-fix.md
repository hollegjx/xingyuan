# R13 Single Length Feedback After Rejection

October 27, 2026, Asia/Shanghai. CO-17; J01/J02/J13 editor scenario:
over-limit input, explicit rejected save, readable reason, correction, explicit
save. Implementation candidate only; independent/visual/native/owner acceptance
of this new delta remains open.

## Source And Minimal Change

- Baseline product: `9fe0984d6b91d7d7b5df29ada71bd6ea5a59fab7`.
- First-red test: `e8d05d3f1fb7176782e2aa29b182ea98570af20b`; runtime identical
  to9fe. Original test SHA256:
  `5dcb16271019da7ca8d899c3395bfb2a31ef38a447f79d2e49c11ab3cea44ad1`.
- Product/initial green tests: `00d108d0957b53341e06092af97ab1014aadfc73`.
- Final stronger test: `12914b4a7556513822bcbf85bb5cc06b65a99121`; runtime
  unchanged from00d108d. Only eight test lines add same-frame count checking.
- Final candidate/docs SHA, verified remote and new exact-SHA CI: outbox A2-80.

Only JournalEditorPage runtime rendering changes (15 additions/13 deletions,
mostly indentation). The external error text is omitted only when it exactly
matches the current inline/separate length reason. The outer error region
still exists for a dirty draft, retaining its retry action even if the text is
deduplicated. All other error strings render as before. No error-state mutation,
exception swallowing, controller/store/schema/theme/AI/backend/dependency or
platform change. Existing scaling,1000/5000 limits, counter, semantics, live
regions and AI placement remain. Real save validation still rejects the input.

The three existing R12 post-rejection checks no longer require the duplicate
`journal-error` key. They now require exactly one full length message and
absence of the duplicate, retaining every table/text/selection/save assertion.
Six new R13 cases reuse the existing mount, seed, scroll, pixel and capture
helpers: four diary/quick-note journeys across390x844/1x/light and320x568/4x/dark;
a SQLite saved-revision failure; and failed draft persistence during an
over-limit quick note, followed by explicit draft retry and corrected save.

## Verification And First Failure

All runs use in-memory synthetic services/data and the existing local Flutter
SDK. Commands are wrapped with bash pipefail and tee to retain real exits.
Log prefix: `/tmp/xingyuan-ai2-r13-<label>-20261027.log`.

| Label | Source / Result |
| --- | --- |
| before-001 | e8d05d3 test,9fe product:0 passed/4 failed,3s,exit1 |
| after-001 | bytes committed as00d108d: Chinese14/14,5s,exit0 |
| default-001 | same00d108d bytes: default14/14,4s,exit0 |
| guards-001 | same product, existing3/3,1s,exit0 |
| analyze-001 / format-001 | clean3.1s;294 files/0 changes,exit0 |
| final-001 | exact00d108d: six R13 cases6/6,3s,exit0 |
| final-002 | exact12914b4: strengthened R13 Chinese6/6,3s,exit0 |
| default-002 | exact12914b4: strengthened R13 default6/6,3s,exit0 |
| analyze-final / format-final | exact12914b4: clean2.7s;294 files/0 changes |

There are six new unique cases and eight related existing cases, plus three
separate existing guards, not the sum of all repeated runs or a whole-App pass.
The first four failures are the actual duplicate-message assertion, after
successful full-feedback/pixel and data-preservation checks; no QA-first failure
preceded them. All four observed two messages after rejection. Both ordinary
before screenshots visibly contain both copies. Large-type before frames
separately preserve each full copy; a frame need not show both copies fully.

The fourteen final-001 PNGs were individually viewed. The quick-note4x rejected
frame clipped the counter top despite its separate full-counter check passing.
This capture limitation is retained, not erased or called a product regression.
12914b4 adds the existing combined-feedback helper before export: when combined
height fits, both counter and error must be fully visible together; unconditional
individual checks remain. No product scroll/caret or type-size change was made.
The final-002 fourteen PNGs were dimension/hash-checked; thirteen are byte-identical
to the already-viewed final-001 counterparts, and the one changed counter frame
was individually viewed. They contain ten distinct image hashes.

```sh
flutter test test/journal_limit_feedback_layout_test.dart --name 'R13 single length feedback' --no-pub --reporter expanded '--dart-define=DIARY_CAPTURE_FONT=/System/Library/Fonts/STHeiti Light.ttc' --dart-define=DIARY_CAPTURE_DIR=/tmp/xingyuan-ai2-r13-before-001-20261027 --dart-define=LIMIT_CAPTURE_STAGE=before-001 --dart-define=LIMIT_CAPTURE_SOURCE=9fe0984d6b91d7d7b5df29ada71bd6ea5a59fab7
flutter test test/journal_limit_feedback_layout_test.dart test/journal_limit_feedback_breakpoint_test.dart --no-pub --reporter expanded '--dart-define=DIARY_CAPTURE_FONT=/System/Library/Fonts/STHeiti Light.ttc' --dart-define=DIARY_CAPTURE_DIR=/tmp/xingyuan-ai2-r13-after-001-20261027 --dart-define=LIMIT_CAPTURE_STAGE=after-001 --dart-define=LIMIT_CAPTURE_SOURCE=working-after-e8d05d3
flutter test test/journal_limit_feedback_layout_test.dart test/journal_limit_feedback_breakpoint_test.dart --no-pub --reporter expanded
flutter test test/journal_ui_test.dart --name 'quick note bottom sheet focuses|identity change hides journal editor|failed draft blocks exit' --no-pub --reporter expanded
flutter test test/journal_limit_feedback_layout_test.dart --name R13 --no-pub --reporter expanded '--dart-define=DIARY_CAPTURE_FONT=/System/Library/Fonts/STHeiti Light.ttc' --dart-define=DIARY_CAPTURE_DIR=/tmp/xingyuan-ai2-r13-final-002-20261027 --dart-define=LIMIT_CAPTURE_STAGE=final-002 --dart-define=LIMIT_CAPTURE_SOURCE=12914b4a7556513822bcbf85bb5cc06b65a99121
flutter test test/journal_limit_feedback_layout_test.dart --name R13 --no-pub --reporter expanded --dart-define=LIMIT_CAPTURE_SOURCE=12914b4a7556513822bcbf85bb5cc06b65a99121
flutter analyze --no-pub
dart format --output=none --set-exit-if-changed lib test
git diff --check 9fe0984d6b91d7d7b5df29ada71bd6ea5a59fab7
```

Final-001 used the same six-case capture command with00d108d and final-001
directory/stage. The initial fourteen-case run's R12 source-override fields were
not supplied, so its breakpoint JSON source fields are empty; it is a working
run on bytes subsequently committed as00d108d, not an immutable-source JSON.
Final-002's four R13 JSONs explicitly bind12914b4; they record copy counts and
data assertions, not geometry. Same-kind JSONs are identical because viewport
metadata is in the test/filenames, not those JSONs. All historical logs remain.

## Preserved Behavior And Evidence

Each length journey checks1001/5001 graphemes and exact selection, full error
glyphs/pixels and count, semantics plus existing live-region behavior. Rejected
save preserves every row/column of all four journal tables, original saved text,
revision, operation receipt and complete autosaved draft. Correction changes
only the draft; one final explicit save increments revision exactly once and
clears it. AI/photo calls are zero; assistant/pairing/chat remain uninstantiated.

Synthetic SQLite triggers prove a real saved-revision write failure still shows
the full persistence error, and retrying save after removal works explicitly.
A separate draft-write failure preserves the newest over-limit text/selection,
leaves all tables unchanged, displays both distinct reasons, keeps the draft
retry action enabled/reachable, and does not claim a saved draft. Successful
draft retry persists only the draft; a subsequent length-rejected save still
changes no rows. Only correction plus explicit save updates saved content.
Empty-content feedback, identity invalidation and failed-draft exit are covered
by the related existing cases. No blanket claim about every possible error.

Before directory: `/tmp/xingyuan-ai2-r13-before-001-20261027` (12 PNGs,4 JSONs).
Final directory: `/tmp/xingyuan-ai2-r13-final-002-20261027` (14 PNGs,4 JSONs).
390 files and both failure frames are390x844;320 files are320x568. DPR1,
injected scaling, synthetic Chinese and existing STHeiti aliases only.
The four individually viewed baseline frames are each kind's390 rejected-0 and
320 rejected-1. The old CO15 screenshots were not substituted for this fresh
baseline. No images or logs are bundled into the App or Git.

## R12 Acceptance And Precision Erratum

A1-119 independently verified9fe with8/8 Chinese,8/8 default and3/3 guards in
separate runs. Its expressly named local report was read and hash-verified:
`/path/to/Desktop/git/idea-ai1/docs/journal-limit-width-independent-validation.md`,
SHA256 `e222261dbef08ac46474fefdac66f1f9d4b3ed1d3c5a59fc2b2ec4b8b2ed709b`.
CO-17 accepts R12 full feedback, corresponding data protection and shown pages
only at the local/widget layer. AI-1's uncommitted report/CO31 material was not
edited, imported or committed here.

Old R12 descriptions calling21/22.4/56/14 actual font sizes were imprecise:
these are `textScaler.scale(14)` probes. The theme's bodySmall is13; the probes
are not resolved-font measurements. This is a documentation erratum, not a
typography change or reason to rerun old font tests. Original reports, logs,
images and all historical failures retain their bytes.

Two read-only source lookups initially used nonexistent application/controller
and domain/rules paths, then used the actual presentation/controller and store.
The initial staged-document whitespace check found one trailing blank line,
removed before commit. These lookup/format diagnostics are not test failures.

New R13 independent/visual/native/actual OS maximum/IME/UIKit/VoiceOver and
owner/whole-J13 gates remain open. Prior deliberate-gutter-scroll and synthetic
keyboard limits remain. No model/CO31 replay, private config/credentials/data,
CUA/Simulator/device/B/formal app, recovery, production/deployment, fees or
network setting changes. Old terminal CI stays closed; only this new candidate
has a new CI follow-up. No PR1/other-workspace/backlog/force push or coordinator
chat reply. The coordinator's review and sync files remain un-staged.

## SHA256 Manifest

```text
8c22703f2e54da481e97d597b82c2026ced2b9f87a72a7e7040da3f3ba5e50d5  /tmp/xingyuan-ai2-r13-before-001-20261027/r13-before-001-diary-320-4x-dark-before-save.png
749f6cd82d7dff84b4a4391b78585d6f05c29dec29186c45ee016db28a3facc8  /tmp/xingyuan-ai2-r13-before-001-20261027/r13-before-001-diary-320-4x-dark-rejected-0.png
7cb297ea4ac38338747faae699b1a3dcf817b18a6fb2c56c613f4143550d82da  /tmp/xingyuan-ai2-r13-before-001-20261027/r13-before-001-diary-320-4x-dark-rejected-1.png
b8e02e363818601816748c4a17341fb365afe4b44e1c5ca5155944370a0539be  /tmp/xingyuan-ai2-r13-before-001-20261027/r13-before-001-diary-320-4x-dark.json
54f1c2b5eec775946919db871ce9d4ae5d275b5eb878692f4fd8779ed07de662  /tmp/xingyuan-ai2-r13-before-001-20261027/r13-before-001-diary-390-1x-light-before-save.png
3ed8762f6903be4a919ddd3c699e4d2b2b1247e0e1ea90dc8b82f2bcc4eb2b35  /tmp/xingyuan-ai2-r13-before-001-20261027/r13-before-001-diary-390-1x-light-rejected-0.png
3ed8762f6903be4a919ddd3c699e4d2b2b1247e0e1ea90dc8b82f2bcc4eb2b35  /tmp/xingyuan-ai2-r13-before-001-20261027/r13-before-001-diary-390-1x-light-rejected-1.png
b8e02e363818601816748c4a17341fb365afe4b44e1c5ca5155944370a0539be  /tmp/xingyuan-ai2-r13-before-001-20261027/r13-before-001-diary-390-1x-light.json
9126f38adb89529eb214236410dccd58369a28b61b27c38772e354f165217c2b  /tmp/xingyuan-ai2-r13-before-001-20261027/r13-before-001-quickNote-320-4x-dark-before-save.png
8fd7b5b7fcab5237191630681bd41b15b2444e1c02760afec0347709e1a804c6  /tmp/xingyuan-ai2-r13-before-001-20261027/r13-before-001-quickNote-320-4x-dark-rejected-0.png
d669a86714d4462638a70660c6925888cf48113ac8bf199250d992a02a7107b4  /tmp/xingyuan-ai2-r13-before-001-20261027/r13-before-001-quickNote-320-4x-dark-rejected-1.png
cb593cf34b20aede167940e1929c6aceb0bef680c4e644d21bf5c567b45d0638  /tmp/xingyuan-ai2-r13-before-001-20261027/r13-before-001-quickNote-320-4x-dark.json
0aa7a1f34c8684feb2a89b0765fa52344a689ced4212278c0f6cf8edb40bc689  /tmp/xingyuan-ai2-r13-before-001-20261027/r13-before-001-quickNote-390-1x-light-before-save.png
96542a5846eebbabe75a632d1d7a005831f7e4d05ad7d7e01af38cfd9dc003fe  /tmp/xingyuan-ai2-r13-before-001-20261027/r13-before-001-quickNote-390-1x-light-rejected-0.png
96542a5846eebbabe75a632d1d7a005831f7e4d05ad7d7e01af38cfd9dc003fe  /tmp/xingyuan-ai2-r13-before-001-20261027/r13-before-001-quickNote-390-1x-light-rejected-1.png
cb593cf34b20aede167940e1929c6aceb0bef680c4e644d21bf5c567b45d0638  /tmp/xingyuan-ai2-r13-before-001-20261027/r13-before-001-quickNote-390-1x-light.json
8c22703f2e54da481e97d597b82c2026ced2b9f87a72a7e7040da3f3ba5e50d5  /tmp/xingyuan-ai2-r13-final-002-20261027/r13-final-002-diary-320-4x-dark-before-save.png
dd9ef95e62212ba3e74edf25c0ce74ee4e1e56b2fa24d6ee08d3ce82aedea9ef  /tmp/xingyuan-ai2-r13-final-002-20261027/r13-final-002-diary-320-4x-dark-corrected.png
8c22703f2e54da481e97d597b82c2026ced2b9f87a72a7e7040da3f3ba5e50d5  /tmp/xingyuan-ai2-r13-final-002-20261027/r13-final-002-diary-320-4x-dark-rejected-0.png
7d7781ae1c21fb6ea8401ce9c7e7d0a20d62651230191e90bbff19524ea22dcd  /tmp/xingyuan-ai2-r13-final-002-20261027/r13-final-002-diary-320-4x-dark.json
54f1c2b5eec775946919db871ce9d4ae5d275b5eb878692f4fd8779ed07de662  /tmp/xingyuan-ai2-r13-final-002-20261027/r13-final-002-diary-390-1x-light-before-save.png
68f69b9180e20c87c7fbe69c2d944a069425070ca59c94e76d7cd85ffedae0e1  /tmp/xingyuan-ai2-r13-final-002-20261027/r13-final-002-diary-390-1x-light-corrected.png
54f1c2b5eec775946919db871ce9d4ae5d275b5eb878692f4fd8779ed07de662  /tmp/xingyuan-ai2-r13-final-002-20261027/r13-final-002-diary-390-1x-light-rejected-0.png
7d7781ae1c21fb6ea8401ce9c7e7d0a20d62651230191e90bbff19524ea22dcd  /tmp/xingyuan-ai2-r13-final-002-20261027/r13-final-002-diary-390-1x-light.json
960db3592dd250462a22b3d6d26362d38368ce129ee51cb102f0371e19622e8e  /tmp/xingyuan-ai2-r13-final-002-20261027/r13-final-002-draft-failure.png
9126f38adb89529eb214236410dccd58369a28b61b27c38772e354f165217c2b  /tmp/xingyuan-ai2-r13-final-002-20261027/r13-final-002-quickNote-320-4x-dark-before-save.png
2549b9312c22115f2056abc6211977878ffc1c269c2b64ba2668e469e78f631a  /tmp/xingyuan-ai2-r13-final-002-20261027/r13-final-002-quickNote-320-4x-dark-corrected.png
9126f38adb89529eb214236410dccd58369a28b61b27c38772e354f165217c2b  /tmp/xingyuan-ai2-r13-final-002-20261027/r13-final-002-quickNote-320-4x-dark-rejected-0.png
9a9448c4a8d6a7596a621a5e3746d10d1332f747aabe7bd49a4b385cc1639423  /tmp/xingyuan-ai2-r13-final-002-20261027/r13-final-002-quickNote-320-4x-dark.json
0aa7a1f34c8684feb2a89b0765fa52344a689ced4212278c0f6cf8edb40bc689  /tmp/xingyuan-ai2-r13-final-002-20261027/r13-final-002-quickNote-390-1x-light-before-save.png
99952265595d400f33f9d594a2de219076be9bb35e4f47766ed7c3653bb6caf0  /tmp/xingyuan-ai2-r13-final-002-20261027/r13-final-002-quickNote-390-1x-light-corrected.png
0aa7a1f34c8684feb2a89b0765fa52344a689ced4212278c0f6cf8edb40bc689  /tmp/xingyuan-ai2-r13-final-002-20261027/r13-final-002-quickNote-390-1x-light-rejected-0.png
9a9448c4a8d6a7596a621a5e3746d10d1332f747aabe7bd49a4b385cc1639423  /tmp/xingyuan-ai2-r13-final-002-20261027/r13-final-002-quickNote-390-1x-light.json
b188a605a971909566a0d640b46e78432adcb124de38eb6d9e4a47dcb606a982  /tmp/xingyuan-ai2-r13-final-002-20261027/r13-final-002-storage-failure.png
1675939b2c514bdd14aa4b65d90cf0e6785a2ab565ef735f1efd5fe7d2cc4e6f  /tmp/xingyuan-ai2-r13-after-001-20261027.log
703176ec8b585300255945925e58427d7a78d060dc3e668bfad473cc11f1b63d  /tmp/xingyuan-ai2-r13-analyze-001-20261027.log
623aedf33c0e038ca693a82e12da52ecd73926f1de6531164a65acd55b4c5cd9  /tmp/xingyuan-ai2-r13-analyze-final-20261027.log
39a7fac2eb9f49b85265df3d5df4d9f0e255d3d159ad6134898608975cb6c658  /tmp/xingyuan-ai2-r13-before-001-20261027.log
07b2c0a953c30eca13429d06b44f8a6f120412302d0f2ab59afb471543ef53b6  /tmp/xingyuan-ai2-r13-default-001-20261027.log
e737b012013a3cc053661bffe1fbeaa797fdfdede8cb4372a286ca6a5400d3f4  /tmp/xingyuan-ai2-r13-default-002-20261027.log
4d91c1c20299d745d6abc5a3fd1876866f6c305a50086698e1106568a24b8343  /tmp/xingyuan-ai2-r13-final-001-20261027.log
53b1ea0dd70aec77c59dce51358b0ae50e6886373ba5405c722495e22aad8db3  /tmp/xingyuan-ai2-r13-final-002-20261027.log
26981e6fe6892129ca714ff7b76bbfc84e41ca00f1e7d50f1293b612c098bfc9  /tmp/xingyuan-ai2-r13-format-001-20261027.log
26981e6fe6892129ca714ff7b76bbfc84e41ca00f1e7d50f1293b612c098bfc9  /tmp/xingyuan-ai2-r13-format-final-20261027.log
09b9928ccb2cb4b91ea1bfbcf9f90a1d1ed10c58ba7b076903b1a67a45546757  /tmp/xingyuan-ai2-r13-guards-001-20261027.log
21ba14090d5f5251b3b736b6f7caee8b6421322feeaf2b702a5de72013cd484f  lib/features/journal/presentation/journal_editor_page.dart
9523a242a9b722c61a694aca1842fcef816ba16f3dce93262d74453c0c74d560  test/journal_limit_feedback_layout_test.dart
```
