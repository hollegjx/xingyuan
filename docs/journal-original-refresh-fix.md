# R9 Direct Original Refresh

October 26, 2026, Asia/Shanghai. CO-10, existing J12/J13, not a release.

## Source And Behavior

- Baseline: `959f72b7fbd2b1af61f2e2293fbb9a1d59908f92`.
- Focused failing-before test: `8ddb98f` (full SHA in the handoff).
- Final product/tests: `572b1aa245c495643e6b1ba5a649de58f97b6a21`.
- Candidate branch: `codex/journal-original-refresh`; exact delivery and new
  source-push CI outcome are recorded in the normal AI2 outbox/status.

Only ChatDiaryPage product code changes (94 additions/9 deletions). A typed
saved-version conflict without an unresolved draft exposes a contextual
"refresh original" command. Known stale saves, including retained callbacks,
cannot open another final confirmation. Editing, explicit date selection,
declining cancellation and declining leave remain available while awaiting
refresh. During the read, the existing busy guard excludes overlapping actions
and the command reports that it is refreshing.

Refresh rereads the same local proposal/day with the original identity lease.
Exact corrected TextEditingValue and selected date survive; neither the model
proposal nor durable drafts change. A failed first or second read retains the
old preview/date and offers retry with one error banner. Current original and
combined result use the existing disclosure/preview. Changed nonempty original
requires append/replace selection again and the normal final confirmation.

A new unsaved draft exposes the existing R5 editor route, never automatically
discarding or saving it. Handled proposals remove pending actions; the queued
case rereads authoritative status if handling races between proposal and
preview reads. Missing proposals retain the correction with a local error and
disabled save; retry cannot write or revive them. Late disposal and identity
away/back remain inert. No translated-error matching, store/undo/identity-
boundary/provider/schema/backend/shared-confirmation change is included.

The existing same-day calendar recovery still works. Its one saved-version
test updates only the expected contextual warning/capture label; all original
functional assertions and unrelated draft warnings remain. Route-local edits
are still not durable across process termination. R8's separately accepted
local async evidence is not replayed or expanded by this work.

## Executed Checks

All final checks below ran at immutable572b1aa; each completed with exit0.
Shell redirection preserved each process exit, with no success-masking pipe.
These are separate batches, not one combined58-test or whole-App suite.

| Batch | Result | Runner time |
| --- | --- | --- |
| New direct refresh and guards | 21/21 | 00:07 |
| Existing affected R5 recovery and receipt behavior | 17/17 | 00:08 |
| Selected chat editing/date/confirmation/identity | 12/12 | 00:04 |
| Selected store conflict/idempotency/rollback guards | 8/8 | 00:00 |
| Full App analysis | Clean | 3.3s |
| lib/test formatting | 291 files / zero changes | 2.37s |

```sh
flutter test test/chat_diary_refresh_original_test.dart test/chat_diary_refresh_guard_test.dart --no-pub --reporter expanded '--dart-define=DIARY_CAPTURE_FONT=/System/Library/Fonts/STHeiti Light.ttc' --dart-define=DIARY_CAPTURE_DIR=/tmp/xingyuan-ai2-r9-final-20261026
flutter test test/chat_diary_recovery_journey_test.dart test/chat_diary_acceptance_regression_test.dart --no-pub --reporter expanded
flutter test test/assistant_diary_ui_test.dart test/journal_diary_edit_test.dart --name 'chat-diary|^chat |^identity change|^cancelled confirmation|^ambiguous date' --no-pub --reporter expanded
flutter test test/chat_diary_store_test.dart --name 'edited proposal does not bypass|changed target after preview|identity generation change|rapid repeated confirmations|receipt failure rolls back' --no-pub --reporter expanded
flutter analyze --no-pub
dart format --output=none --set-exit-if-changed lib test
git diff --check
```

The new tests cover normal390x844/1x and320x568/4x in both themes, full four-
character labels, >=44px action height, button/tap semantics, two successive
read failures, busy duplicate callbacks, unchanged selection/date, first and
second SELECT failure, historical date, concurrent draft/save, handled/deleted
proposals before and during a queued read, disposal, identity switch away/back,
cancelled confirmation, explicit append/replacement, guarded undo and retained
callbacks. Synthetic snapshots compare all rows/columns of eight tables:
diaries/photos, quick notes/photos, proposals, messages, sessions and identity.
Refresh makes no implicit writes or added model/summary/health requests.
Explicit fixture mutations, final save, draft handling and undo have their own
expected baselines; the entire suite is not described as zero-write.

## Images And Failure History

Final images: `/tmp/xingyuan-ai2-r9-final-20261026/`, 24 PNG files with20 distinct
pixel-file hashes; all are390x844 or320x568. `manifest.json` binds exact572b1aa,
source/test SHA-256, dimensions and each PNG hash. Eight final frames were
viewed: normal-light/narrow-dark refresh, normal/narrow-light read error,
narrow-dark retry/busy, normal-dark original and normal-light combined result.
Large-text errors remain scrollable, not fully visible in one screenshot.
The action remains fully readable without shrinking the system text; at4x
the refresh icon can occupy its own line. These are actual widget renders
with explicit Chinese/font/icon aliases, not native iOS/IME/VoiceOver evidence.

Logs are `/tmp/xingyuan-ai2-r9-{name}-20261026.log`:

- `before`: focused original four cases fail at the missing direct command,
  00:03/exit1. Four prior-state images are in the matching `before` directory.
  No established R5 before matrix was replayed.
- `direct-001`: four failures at final receipt after direct recovery checks
  passed. `diagnostic-001`: one selected failure identifies the generic save
  error. Reused R7 read-only fixture had a short proposal ID, violating the
  existing36-character operation-ID constraint on actual save.
- `direct-002`: test compilation failed because imported matcher `completion`
  shadowed an inherited property; explicit `this.completion` fixed the fixture.
- `direct-003` and `guards-001`: respectively4 and15 setup failures; changing
  the fixture ID left the already loaded conversation button cached. The new
  tests now open the real page with its corrected synthetic UUID directly.
  No product/store constraint or old fixture was weakened.
- `combined-001`:15 pass/4 fail,00:06/exit1. Two date-layout expectations
  assumed a particular wrap; now they assert the full semantic date. Two real
  queued-handling failures retained disabled pending controls. The local
  authoritative reread above fixes these without string matching or writes.
- `combined-002`:19/19,00:06/exit0 before two additional date/read guards and
  the single concise refresh-error banner. `final`:21/21 at572b1aa.
- `analyze-001`: three unused new-test imports/names; removed before final
  clean analysis. One initial source lookup used the wrong feature directory
  and was corrected with file discovery. All failures remain recorded.

Final related logs use `related-recovery`, `related-ui`, `related-store` and
`analyze-final`. No interrupted runner, timeout, weakened assertion, hidden red
test or consumed unexpected exception is reported as success.

Only CO-10's appended69-line review section is authorized for integration with
this delivery. No old R6/R7/R8 success matrices, terminal CI, model/native/
restoration cycle, phone/B/formal App, real data/credentials, network/payment,
backend deployment, PR1 or historical backlog is touched. Independent AI1 QA,
coordinator visual review, native/Chinese IME/VoiceOver, R3 quality, owner trial
and whole-J13 acceptance remain separate gates.
