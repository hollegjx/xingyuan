# R5 Protected-Draft Recovery: Independent Reproduction

Date: 2026-10-26, Asia/Shanghai. CO-5 bounded J12/J13 review, not release approval.

## Finding

Confirmed recovery gap, not data damage: a corrected pending chat diary proposal
cannot reach the selected day's editor while retaining that correction when an
unsaved diary draft must first be handled. The protective refusal is correct.
The pending page provides date selection, editing, append/replace, original-text
disclosure, save and cancel, but no diary-editor entry. Its existing
`chat-diary-view` entry is rendered only for an applied proposal. Back/cancel
asks whether to discard the route-local correction; declining stays here.

Important counterexample: a changed saved revision **without an unresolved
draft** already has a working recovery. Reconfirm the same date, choose append
or replace again, and explicitly confirm save. The exact correction/selection
survives, the original refreshes, and only one model-service request was made.
Do not characterize all revision conflicts as unrecoverable or remove guards.

## Exact Scope

- Reviewed product baseline: `724f234f35e76e8516e320d0aaf960e666d8dafc`.
- Independent starting point: `b87e5ff9153d257d9c64ce9db83b50b7fbf18a06`.
  `git diff --exit-code` for lib/packages/server/ios/pubspec/.github is empty.
- Test/capture source: `524996d1de6363111a750c06d6084eb3f6728caa`.
- Test: `test/chat_diary_recovery_journey_test.dart`.
- Branch: `codex/journal-protected-draft-repro`; prior navigation branch retained.
- No product, coordinator review, schema, service, dependency or runner changes.

Actual App UI, existing UiHarness/TestClock, in-memory SQLite, fake service and
test credentials only. The fixture clock is October 9, 2026; the other protected
diary uses its previous day. These are fixture dates, not the run's current date.
Each blocker has an existing saved diary/photo, a distinct unsaved text draft
and an additional draft-only photo metadata row. Photos are synthetic metadata,
not image-file/thumbnail or photo-picker verification.

## Results

One run: **1 passed, 4 failed, 00:05, pipefail exit 1**. All four failures occur
at the final missing recovery-entry expectation, after the protection checks.

| Scenario | Viewport/theme | Result |
| --- | --- | --- |
| Draft already exists before opening proposal | 390x844/1x light | Missing editor entry |
| Draft already exists before opening proposal | 320x568/4x dark | Missing editor entry |
| Saved revision plus draft changed after preview | 390x844/1x dark | Missing editor entry |
| Saved revision plus draft changed after preview | 320x568/4x light | Missing editor entry |
| Only saved revision changed after preview | 390x844/1x light | Same-day refresh and save passed |

Before each final failure, assertions independently establish:

- Two repeated confirmed saves refuse safely, with no receipt. Concurrent
  changes first produce the version-conflict warning; same-day refresh then
  exposes the still-unresolved draft warning.
- Refresh, another explicit append choice and save still cannot apply over an
  unresolved draft. Original disclosure is read-only, not an editor route.
- Back displays discard confirmation; continuing preserves the preview.
  Cancelling the proposal and declining discard also preserves it.
- All columns/rows of diary_entries, diary_photos, assistant_diary_proposals,
  assistant_messages and assistant_sessions equal the pre-attempt snapshot.
  Saved photo count is one, draft photo count two; text, slots and metadata
  remain intact. The original proposal is not replaced by the correction.
- Exact local Chinese correction, newline and TextSelection(2,6) are retained.
  Each journey has one fake request, no summaries and no automatic diary write.
- No Flutter exception precedes the intentional missing-entry assertion.

The final locator uses the existing `chat-diary-view` entry. A fix may provide a
differently named, accessible recovery control; adapt that locator if necessary
without dropping the behavior requirement. Source review of ChatDiaryPage's
pending/applied branches and `_leave`/`_cancel`, plus the exercised alternatives,
supports the finding; a missing test key alone is not the reasoning.

The passing counterexample additionally checks final-confirm cancellation makes
no write, successful append uses the refreshed original and corrected text,
the previous day's diary and every photo/message/session row are unchanged,
and the original proposal text is retained with its applied receipt.

## Reproduction And Images

From the independent workspace, use the existing Flutter SDK:

```sh
flutter test test/chat_diary_recovery_journey_test.dart \
  '--dart-define=DIARY_CAPTURE_FONT=/System/Library/Fonts/STHeiti Light.ttc' \
  --dart-define=DIARY_CAPTURE_DIR=/tmp/<fresh-r5-directory> \
  --reporter expanded
```

Log: `/tmp/xingyuan-ai1-r5-protected-001-20261026.log`.
Images: `/tmp/xingyuan-ai1-r5-protected-001-20261026/`.
Audit: `/tmp/xingyuan-ai1-r5-protected-001-audit-20261026.json` binds the exact
source/test hash, all PNG names/dimensions/SHA-256, and `suitePassed:false`.

All 14 uniquely named files were individually viewed and audited: blocked,
action and leave-dialog frames for each of the four failures, plus blocked and
recovered frames for the passing counterexample. Two standard-size blocked/
action pairs naturally have identical pixels; these are 14 files, 12 distinct
pixel hashes, not 14 visually different states. No filename overwrite occurred.
Narrow 4x warning/body text needs scrolling; its capture guard checks the first
visible text line, while action labels have full line-box/pixel verification.
This does not claim the entire warning fits in one viewport.

Rendering uses explicit STHeiti test aliases and an iOS layout variant, not a
native iOS run, OS screenshot, real keyboard, system maximum or Chinese IME.
No new native run/protection cycle/restoration, model call or old matrix was run.

Initial analysis found one unused test import; it was removed before the exact
test-source commit. Final single-file analysis passed in 1.5 seconds. The first
analysis failure is retained in the task transcript; no product issue is inferred.

## CI And Handoff

Prior navigation QA40235520634 at exact b87 independently completed/success:
API updatedAt Beijing05:51:42, job05:51:41, all recorded steps successful.
No unread counts inferred; this terminal run will not be polled again. AI2 owns
724 push/PR checks; none were duplicated here.

This new branch is deliberately failing regression evidence, not a releasable
candidate. Tests and this report are delivered together, not a docs-only CI.
AI2 may implement the conditional R5 scope now, preserving the existing
same-date recovery and every protection. Initial-load retry remains excluded.
Future exact-source QA must cover editor round trip, retained correction/current
original/new explicit mode, no automatic write, identity/concurrency/duplicate
guards and guarded undo. Real IME, owner acceptance and old J gates remain open.
No phone/B/backend/formal-app, private content, credential or fee operation.
