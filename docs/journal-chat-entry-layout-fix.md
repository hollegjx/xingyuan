# R4 Chat-To-Diary Entry Layout

October 26, 2026. CO-3 / J12-J13, based on
`eac0b0a503a7cd162806d4a8a0ece4274147344c`. Exact delivery SHA and CI are recorded
in AI2 handoff A2-64; this is not owner, native or full J13 acceptance.

## Reproduction And Scope

The isolated regression sets 320x568 and 4x before entering planning. In both
themes the old titled state overflows 47px and the conversation 46px. Measured
available height is 492px, fixed header 292px and composer 246px: 538px cannot
fit. Before log: `/tmp/xingyuan-ai2-r4-before-font-20261026.log`, 0 pass/2 fail.
Actual Chinese-glyph frames: `/tmp/xingyuan-ai2-r4-before-font-20261026/`.
An earlier run without Cupertino font aliases rendered missing glyphs; it is
retained as `r4-before`, not accepted Chinese visual evidence.

Only `assistant_conversation_view.dart` changes product behavior:

- The header scrolls with history; the existing composer remains pinned and
  bounded. Returning to older messages also gives access to header navigation.
- Header text and tool group use actual-width overflow layout, not smaller text,
  hidden tools or guessed viewport/font thresholds. Long session titles still
  have the existing one-line ellipsis; the details route remains available.
- Loading, failure and consent headings scroll with their bodies. Tests include
  actual drag gestures through the nested content, not just ensureVisible.
- Waiting status and cancellation use separate rows with full-width actions.
  The expanded regression first caught a 70px horizontal overflow in both themes
  (`r4-expanded`: 12 pass/2 fail); that failure is retained.

The shared composer, storage, providers, protocol, model, privacy defaults and
confirmation/undo behavior are unchanged. The deliberate tradeoff is that the
heading is no longer pinned at normal sizes either; the input stays pinned.

## Checks

- Final focused render suite: 14/14, 00:06, exit 0, `r4-visual-final`.
- Related assistant/diary/shared-caller checks: 113/113, 00:23, exit 0,
  `r4-focused-final`, before the additional equivalent lint/drag/label checks.
- Final App: 1381/1381, 01:51, exit 0, `r4-app-final`, including the final
  drag/label assertions. Analysis clean (`r4-analyze-final`); 433 formatted
  files unchanged (`r4-format-full`). No core/server/eval/DST/schema rerun.

Logs use `/tmp/xingyuan-ai2-<name>-20261026.log`. The initial focused command
mistyped `journal_diary_editing_test.dart`: 87 pass/1 missing-file load failure,
retained as `r4-focused`; corrected to the existing `journal_diary_edit_test`.
The initial analysis caught a deprecated diagnostic description and two brace
lints, fixed without changing product logic. `r4-first` also retains a capture
that inspected a partially scrolled preview line; the final test scrolls the
actual suggestion into view before checking the same pixel/geometry rules.

The final matrix covers narrow/standard screens and both themes at 1x/4x,
keyboard insets 0/100/200, Chinese composition/emoji/newline preservation,
session/settings/tab navigation, one exact sent request, diary preview without
automatic save, disabled repeated send and cancel with a late discarded reply.
Cancel labels retain 4x scaling, one line, a 44px-or-larger target and visible
text pixels. Consent remains optional; loading and read errors remain scrollable.

Final 26 PNGs: `/tmp/xingyuan-ai2-r4-final-20261026/`. Every frame checks exact
heading/input/proposal/cancel text and its visible region pixels. Eight frames
were viewed across themes, sizes and entry/input/preview/cancel states. Large
content still needs scrolling; placeholder and multiline input follow the
existing TextField clipping/scrolling behavior. Insets do not draw an OS keyboard.

## Remaining Gates

AI1 independently checks the exact delta and CI; the coordinator reviews visual
tradeoffs. Real Chinese IME, VoiceOver, native/font behavior and owner experience
remain separate. No B/phone operation, deployment, model request, credential,
private data or simulator restoration was performed. This is not a reproduction
or closure of the historic native 34px/inset problem. The approved 49-line
coordinator review follow-up is included without changing its pending status.
