# R6 Focused Caret Reflow Correction

2026-10-26, Asia/Shanghai. A1-92 under CO-7; J03/J13, not release acceptance.

## Source And Finding

- Baseline: `ff4c7e99ad68584004a61cf68ca8a1ad7dd36af1`.
- AI1 red sources: `c5ecb44c58ce779c69b2cb4d5b21e6e5d18cdd9c`, then
  `2717eedab58643077bdc7acd4919807c9a3a00a3`; report head
  `f75724280dd7fe0ee4078462896979ad9a0c965a` was read, not integrated.
- Only the two inspected test commits were cherry-picked with provenance:
  `45f9704af78d1a74f314312d713cc2c9f1c39191` and
  `60362446d0b22a5d9e175a2191f7a4fad55b9393`. The test remains byte-identical.
- Fixed product/final test source: `f7a49c18bb8b8ea3a918677b523b5227a2e25d92`.
- Separate `codex/journal-caret-reflow` candidate contains these three commits
  plus delivery docs, only eight paths beyond ff4c7e9. Exact head/CI in A2-71.
  No PR1 change, force push, branch deletion or journal backlog push.

AI1 observed the focused caret leaving the viewport when text scale changes
1.5 to1.7 at320x568 with top20/bottom0 safe area and200px injected keyboard.
The AI action moves above the field without an editing event to reveal its caret.
Quick-note caret y343..388 was outside viewport93.815..316; diary y329..380
was outside77.015..316. AI1's20-pass/2-fail and targeted0-pass/2-fail runs are
retained, not replayed. They establish **temporary visibility loss**, not data,
focus, composition or input-connection loss. Another composing character already
restored visibility before this correction.

## Local Change

Only25 product lines in the existing editor: track AI placement, and on a changed
placement while focused, coalesce one post-frame callback. After layout, use the
existing EditableTextState's public bringIntoView with the current selection
extent. Mounted/focus/leaving/preview/valid-selection guards prevent obsolete work.
No text/selection/composition assignment, refocus, synthetic editing event or
persistence write. Unfocused reading is left alone. The breakpoint,160px tool
rule, AI action semantics, system text scaling and all data/model behavior stay.

## Verification

```sh
flutter test test/journal_writing_breakpoint_delta_test.dart \
  test/journal_writing_caret_guard_test.dart test/journal_writing_space_test.dart \
  test/journal_toolbar_insets_test.dart test/journal_negative_keyboard_test.dart \
  test/journal_keyboard_transition_test.dart --reporter expanded
flutter test test/chat_diary_recovery_journey_test.dart \
  --name 'R5 recovery entry' --reporter expanded
flutter test test/journal_writing_breakpoint_delta_test.dart \
  test/journal_writing_caret_guard_test.dart \
  '--dart-define=DIARY_CAPTURE_FONT=/System/Library/Fonts/STHeiti Light.ttc' \
  --dart-define=DIARY_CAPTURE_DIR=/tmp/xingyuan-ai2-r6-caret-final-20261026 \
  --reporter expanded
flutter analyze
dart format --output=none --set-exit-if-changed lib test
```

- Original four QA directions after correction:4/4,3s,exit0 (`caret-001`).
- Relevant layout/keyboard/unfocused checks:49/49,16s,exit0 (`caret-focused`).
- Only four relevant recovery-entry journeys:4/4,7s,exit0 (`caret-recovery`).
- Final immutable-source breakpoint/unfocused checks:6/6,3s,exit0 (`caret-final`).
- App analysis clean5.7s; lib/test283 files format unchanged; diff checks clean.
  Logs use `/tmp/xingyuan-ai2-r6-<name>-20261026.log`.

At the formerly failing transition the final quick-note caret is271..316 and
diary caret265..316, both inside the same respective viewports. Exact text,
selection/composing, controller/focus/input client, four full tables, saved rows
and zero AI requests remain asserted. Continuation/return and both starting
directions pass. Two new checks preserve an unfocused reading offset through
both transitions without changing text or four tables. The49 includes the
existing18 static space/permission/photo/save checks; counts are not additive.

## Evidence And Limits

Final `/tmp/xingyuan-ai2-r6-caret-final-20261026/`:18 unique PNG names/16 hashes;
four final transition frames and two independent red frames viewed across both
editors. Audit `/tmp/xingyuan-ai2-r6-caret-audit-20261026.json` binds immutable
product/test bytes, unchanged inherited red test, all dimensions/hashes/logs and
eight final transition geometries. It also records AI1's10 red diagnostic images
and source2717eed without claiming they were executed by AI2. Separate directories
preserve the preliminary fix run and all old failures.

These are raw widget boundary captures, not an OCR/text-pixel test or native run.
Scale, safe area, composition and keyboard inset are injected; genuine Chinese
IME, OS keyboard, VoiceOver/Inspector, coordinator/owner and overallJ13 acceptance
remain open. AI1 owns the independent new delta; no old native/restoration cycle,
live-model call, full-App/store/server/core matrix or terminal CI was repeated.
Known billing-before-job failures remain closed, including AI1's40245301543
accepted from A1-92. New normal candidate CI is recorded separately, never rerun
or bypassed. No phone/B/formal-app/credential/deployment/payment operation.
