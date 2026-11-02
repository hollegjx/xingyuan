# R5 Protected-Draft Recovery Candidate

2026-10-26, Asia/Shanghai. J12/J13, CO-6; not release or owner acceptance.

## Scope And Source

- Product baseline: `724f234f35e76e8516e320d0aaf960e666d8dafc`.
- Independent red journey: `524996d1de6363111a750c06d6084eb3f6728caa`;
  report: `484db9ba35e969772f1db159c9beeee5de9905db`.
- Those two commits were inspected and cherry-picked with provenance as
  `a226fa8` and `64df5ae`, without their unrelated QA ancestry.
- Fixed source: `81e592fc86b186bb8f6d873cfc9f160c5793fa40`.
  Only ChatDiaryPage and ChatDiaryStore change product behavior.
- Delivery uses a separate `codex/journal-draft-recovery` candidate. PR #1's
  navigation base/head remain unchanged; no journal backlog push or merge.

AI1 reproduced four missing-editor journeys after correctly refused saves:
an existing draft and a concurrent saved revision plus draft, each at normal
and narrow/4x size. Its fifth case passed: changed saved text without a dirty
draft already recovers through same-day selection. The red run was not repeated.
See the [independent report](journal-protected-draft-recovery-validation.md).

## Behavior

The blocked preview offers a contextual draft action only when a typed draft
or revision refusal is followed by a read confirming an unresolved draft.
Pure saved-version conflicts retain their existing same-day refresh route.
The draft guard now has a local exception subtype; its message, transaction,
ordering and refusal conditions are unchanged. No translated-string matching.

The action keeps the corrected preview route/controller alive and opens only
the selected day's existing editor. It rereads the proposal before navigation
and after return. If the draft was already handled elsewhere, it only refreshes;
if the proposal is handled, pending actions do not reappear. An unchanged dirty
draft can be visited and left without changing the five protected tables.
The editor's existing autosave, explicit completion and cleanup rules remain;
this is not a new discard-draft command or a rewrite of editor persistence.

After explicit editor completion, the preview retains exact corrected text and
selection, shows the current original and requires a new append/replace choice
when the saved original/revision changed. Final save still needs confirmation.
Further drafts/concurrent changes refuse; duplicate and late callbacks do not
save twice. Model proposal text, photos, identity and guarded undo stay protected.
No schema, server, model, shared composer, platform or preview persistence change.

## Verification

- First local extension: 5/5 journeys, 00:06. Boundaries plus store: 60/60,
  00:08. These are intermediate results, not additional independent evidence.
- Chinese-font rendering revealed a new four-character action split at 4x.
  A line-box regression failed first: 2 passed/2 failed, 00:05. Wrapping the
  icon separately preserves a single full-size label line; failures retained.
- Final focused ten-file regression: 135/135, 00:18. Includes normal diary,
  edited preview, draft, identity, cancellation, confirmation, concurrency,
  idempotency, photo and undo protection. The later capture-only scroll change
  did not modify product behavior or remove assertions.
- Final explicit-font journey/capture suite: 13/13, 00:09. Covers editor return
  with no writes, explicit draft completion then one proposal save, fresh mode,
  final-confirm cancellation, historical date, before/during handled proposals,
  resolved-before-tap draft, identity change and a new draft during confirmation.
- Whole-App analysis clean (3.2s); final capture test analysis clean (1.5s).
  Standard lib/test/integration_test/tool format check: 360 files, zero changes.
  Initial one test lint was corrected; that failed check remains recorded.
- No full App, core/server/eval/DST/generation, native or model rerun. Those
  sources, dependencies and iOS files are unchanged from the baseline.

The imported test's saveDiary helper came from an unmerged QA ancestor. Its
same small body is retained locally instead of importing that QA backlog.
Editor tests use the existing in-memory photo-files substitute; photo rows
are synthetic metadata, and missing-file placeholders are not photo rendering QA.

## Commands And Evidence

```sh
flutter test test/chat_diary_recovery_journey_test.dart test/chat_diary_store_test.dart test/chat_diary_acceptance_regression_test.dart test/assistant_diary_ui_test.dart test/journal_diary_experience_test.dart test/journal_diary_edit_test.dart test/journal_diary_discard_layout_test.dart test/assistant_identity_ui_test.dart test/journal_editor_controller_test.dart test/journal_interaction_regression_test.dart --reporter expanded
flutter test test/chat_diary_recovery_journey_test.dart \
  '--dart-define=DIARY_CAPTURE_FONT=/System/Library/Fonts/STHeiti Light.ttc' \
  --dart-define=DIARY_CAPTURE_DIR=/tmp/<fresh-r5-directory> --reporter expanded
flutter analyze --no-pub
dart format --output=none --set-exit-if-changed lib test integration_test tool
```

Logs use `/tmp/xingyuan-ai2-r5-*-20261026.log`: journey-first,
boundaries-first, label-before, focused, captures-final, analyze,
analyze-final, capture-analyze and format. Earlier captures-001/002 remain.
Final images: `/tmp/xingyuan-ai2-r5-captures-final-20261026/`.
Audit: `/tmp/xingyuan-ai2-r5-capture-audit-20261026.json` binds source/test hash,
names, sizes and SHA-256. There are 30 unique filenames and 28 unique hashes;
two normal blocked/action pairs share a viewport, not 30 distinct visual states.
Ten final frames were visually checked across recovery/editor/current-text
states and both sizes/themes. All frames have text-region pixel/geometry checks.
Long 4x warning/editor/original captures check their first visible text line;
the recovery action checks its full label on one line. These are headless
widget renders, not native iOS, OS keyboard or real Chinese IME evidence.

The unchanged editor at 320px/4x still has a large toolbar and limited visible
body area; the raw frames retain that tradeoff for coordinator review. This
delivery does not claim a broader editor redesign or full visual acceptance.
AI1 independent R5 verification, native/IME/VoiceOver and owner/J13 gates remain.

AI1 reported its red branch CI could not start due to GitHub billing/spending
restrictions (empty job steps), not four Linux test failures. No payment, limit
change, workflow workaround or manual rerun was performed. New exact delivery
CI is recorded separately in the AI2 handoff; old terminal runs are not queried.
No phone/B, production, credential, real-data or deployment operation occurred.
