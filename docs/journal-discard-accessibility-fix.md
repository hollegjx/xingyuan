# A1-80 Diary Discard Confirmation

October 26, 2026. Product baseline `3526be8`; R3 test-only parent `c3a2747`
does not change the reproduced UI. This is a separate J13 correction, not a
new global dialog design or proof that the entire diary experience is accepted.

## Reproduction And Scope

Reviewed AI1's committed `72c04c35708bb75811c64cd526f54171de600e0a`
regression and the named synthetic failed captures. Reused its four cases,
inlining only the unavailable snapshot helper. On the main workspace, all
four initially failed for the same isolated action character at 320x568,
3.5x, iOS target platform and explicit STHeiti/Cupertino font aliases.
The original full-label, line, viewport, pixel, hit, 44px and no-write
assertions remain. These are host widget fonts, not an iOS-native reproduction.

Only `confirmDiscardDiaryEdits` changes in production. Normal-size previews
keep the adaptive confirmation. Large text uses the existing diary save
confirmation's full-width, scrollable bottom-sheet pattern. Title, full
disclosure and both choices share one scroll surface rather than independently
constrained title/action panes. The existing wording, keys and text scaling are
kept. Continue editing is the primary non-destructive choice; discard remains
explicit and visibly destructive. No content is truncated or font scaled down.
The entire long disclosure still requires scrolling at extreme text sizes.

Continue or route dismissal returns false and retains the corrected proposal.
Explicit discard follows the existing caller behavior; it neither saves nor
changes prior diary text/photos. Draft, authorization, model, protocol, receipt,
undo and persistence code are unchanged. No new model call or upload is added.

## Verification

The adapted regression is named `test/journal_diary_discard_layout_test.dart`
to coexist with AI1's original accessibility test without an add/add conflict.
It adds 4x diary-route coverage to the original 3.5x path, captures the full
title at the initial scroll position, checks exact effective action scaling,
and verifies both actions remain hit-testable together at the scroll end.
It then exercises continue, route dismissal, and explicit discard, checking
original diary/photo table values and the single synthetic request count.
Only chat's explicit proposal cancellation changes its expected proposal state.

```sh
flutter test test/journal_diary_discard_layout_test.dart test/journal_diary_edit_test.dart test/journal_diary_readability_test.dart --dart-define='DIARY_CAPTURE_FONT=/System/Library/Fonts/STHeiti Light.ttc' --dart-define=DIARY_CAPTURE_DIR=/tmp/fresh-discard-captures --reporter expanded
flutter test --reporter expanded
flutter analyze --no-pub
dart format --output=none --set-exit-if-changed lib test integration_test tool packages server
```

Logs are `/tmp/xingyuan-ai2-a1-80-*-20261026.log`:

- `before`: **0 pass / 4 fail**, before the product fix.
- `after`: **4/4**, the original four regressions after the fix.
- `focused`: **37 pass / 2 fail**, when added 4x chat cases tried to open
  the upstream conversation composer; see the separate limitation below.
- `focused-final`: **39/39**, including eight discard cases, after isolating
  the added 4x scenario to the diary route. Original 3.5x entry path unchanged.
- `app`: **1367/1367**, 01:58, exit 0. This includes the R3 request regressions.
  The run precedes only the collision-avoiding test-file rename and equivalent
  missing-braces lint fix; the renamed regression is separately rerun afterward.
- `named-final`: renamed regression **8/8**, 00:05. `analyze-final` is clean;
  `format-final` checks 432 files with zero changes; `git diff --check` passes.

Final explicit-font images: `/tmp/xingyuan-ai2-a1-80-final-v2-20261026/`, 24 PNGs:
two paths x two themes x two scales x reading/continue/discard. Every image
has expected dimensions and visible text-region pixel/geometry assertions.
Eight final frames were visually inspected across both paths/themes/scales,
plus four earlier successful 3.5x action frames. No native screenshots are
claimed; independent native confirmation and coordinator visual review remain.
Earlier failures/captures and the inherited missing-braces lint are retained.

## Separate Open Finding

The added 4x chat scenario initially failed *before entering the diary preview*:
`openDiarySuggestion` could not hit `assistant-send`, with 47px/46px vertical
overflows at `assistant_conversation_view.dart:546` and `:392`, in both themes.
This is not A1-80's confirmation failure and was not fixed by this patch.
It is preserved in `focused`, reported in A2-62 for separate triage, not erased
or passed off as a fixture mismatch. To reproduce that upstream gap, set the
320x568 iOS synthetic viewport and 4x scale before calling the shared
`openDiarySuggestion(preconsented: true)` helper with the same explicit fonts.

For the new 4x confirmation-only cases, the chat preview is opened at 3.5x,
then set to 4x before editing/dismissing; the full label/scale/geometry/state
assertions still run at 4x. This does not certify entry from a 4x chat composer.
No blanket large-text or overall accessibility acceptance is claimed.

AI1's R2 IME run was interrupted by the locked desktop; its incomplete result
and completed simulator restoration remain unchanged. No repeat unlock request,
device operation, restore, seven-call replay, credential read, deployment,
B interruption or formal-app operation occurred in this work package.
