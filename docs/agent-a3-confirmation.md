# Agent A3 Confirmation And C24 Visual Candidate

Date: 2026-10-28, Asia/Shanghai. Assignments: Claude C23/C24 and AI1 A1-138.
Base: `35fb55d39a0c252988f2dc9f1906adb3f6793d26`, branch `codex/agent`.
Implementation: `571933c13d697411395db318d0c040cbdbc3962f` (12 code/test paths).
The separate final documentation/delivery commit is recorded in A2-91.
This is local implementation evidence, not independent acceptance, Claude visual
approval, native interaction, owner approval, deployment or A4 evaluation.

## Behavior

- Confirmation expands only the draft's minimum/maximum date range, clamped to
  the current local day through day+14, then uses the existing production
  validator. The repository still loads local goals before projecting that
  range; this is not a new SQL range-query optimization. Consent is checked
  before and after that read, inside the existing confirmation transaction.
- A local SHA256 confirmation token binds the preview, validation and relevant
  incomplete schedule projections. A new unknown record on the same day cannot
  reuse an acknowledgement merely because the affected item index stayed the
  same. Unknown records on an unrelated day do not invalidate the reviewed item.
  The token is held locally, never logged, sent to a model or added to a schema.
- A stale editor cannot confirm content that differs from the persisted draft.
  New conflicts, daily-cap violations, changed partial projections or expired
  dates reject the whole transaction. The preview shows `安排有变化`, specific
  item issues, `重新规划` and `返回修改`; it does not create an alternative plan.
- Returning to edit clears the partial acknowledgement and scrolls to the items.
  Replanning returns to the composer with a suggested request only when it was
  empty. Unsent input is preserved. Neither action sends a model request.
- Successful confirmation retains the existing atomic goal/outbox/receipt
  transaction. Six concurrent confirmations return the same IDs. An exact repeat
  after midnight or consent withdrawal returns that receipt without new writes;
  different content and undone proposals remain rejected. A midnight or consent
  change during writes rolls back the batch. Existing undo behavior is unchanged.
- A1-138: final reply/draft persistence now participates in the same bounded run
  deadline and cancellation race as tools/model requests. A successful commit
  consumes the pending turn, so it is not incorrectly rechecked as pending.
  Cancellation is checked after the final asynchronous identity guard, allowing
  an in-flight transaction to roll back after timeout. Late results create no
  assistant reply or confirmable proposal; the outer runner retains failure UI.

## C24 Patch

Only the named `.ai-bus/patches/C24-agent-ui.patch` was read/applied, using
`git apply -3`. SHA256:
`223de15c10dd121ea7ae1fc4b46def612688f3e1628a25bf1b994e5191a90cd8`.
Its three paths are all under `lib/`; no unknown scripts or other patch paths ran.

The trace is a metadata-only card with count/time, tool icons and colored status;
running traces default open, completed proposals closed. The awaiting-confirmation
label is a primary-color capsule. Partial item issues use amber/triangle, hard
issues red/octagon. Existing interaction and item keys are preserved.

Regression-driven adaptations preserve the design: a local Material ancestor for
InkWell; wrapping header and stacked duration at large text sizes; direct content
and RotatedBox for reduced motion, bypassing AnimatedSize/AnimatedRotation rather
than assigning zero duration. Normal animations and expansion reset on scope
changes have separate coverage. These are not new typography or palette choices.

## Verification

SDK `/path/to/development/flutter/bin/`, cwd repository root. All validation
commands below run with fake services and synthetic data under this sandbox:

```sh
sandbox-exec -p '(version 1)(allow default)(deny network*)(allow network* (local ip "localhost:*") (remote ip "localhost:*"))' <SDK command>
```

Logs share `/tmp/xingyuan-ai2-agent-a3-` and `-20261028.log`.

| Command | Result / log suffix |
| --- | --- |
| `flutter test --no-pub --reporter expanded` | 1681/1681, exit0,4m06s; `app-final` |
| `flutter test --no-pub test/agent*_test.dart test/drift/agent_migration_test.dart --reporter expanded` | 132/132, exit0,35s; `focused-final` |
| `flutter test --no-pub test/agent_confirmation_ui_test.dart test/agent_run_details_test.dart test/agent_ui_test.dart --reporter expanded --dart-define=DIARY_CAPTURE_FONT=/System/Library/Fonts/STHeiti\ Light.ttc --dart-define=DIARY_CAPTURE_DIR=/tmp/xingyuan-ai2-agent-a3-final-chinese-20261028` | 39/39, exit0,14s; `ui-final-chinese` |
| `flutter analyze --no-pub` | No issues, exit0,10s; `analyze-clean` |
| `dart format --output=none --set-exit-if-changed lib test integration_test tool server/lib server/test server/tool server/bin packages/xingyuan_core/lib packages/xingyuan_core/test packages/xingyuan_core/bin` | 492 files/0 changes, exit0,10.76s; `format-clean` |

The only cleanup during the full run was removal of an unused `dart:async` import
from the new storage test. Its behavior did not change; the final132-test focused
run, clean analysis and format all ran after that cleanup. Documentation-only
changes after implementation do not change the validated runtime/test trees.

| Evidence | SHA256 |
| --- | --- |
| `app-final` | `2de0001af0f6882ffa9512d1c856b9490284a3c1aef00d6b54fdbe51bc3edf1d` |
| `focused-final` | `77b851d0f7ffdbb34948848632e439bd75b841e6b7fcefe294700f318b667374` |
| `ui-final-chinese` | `0a3461843813661c869deb70873b2a78dd5b1f5656a6484ed2ed0a126ac3e07a` |
| `analyze-clean` | `523c0e9f2124ae8c53310918fd751d680d307ea71b712c600552f98b4dbf519f` |
| `format-clean` | `d81e8f07630f4240a0b69c64ee2db3ca822e1780ab747e41712eba9644bc5388` |
| `deadline-red-fixed-fixture` | `dbfa22543c8d1d8e27d24150e94afceb33a18d090b29cbf51d17b367b976b2e2` |
| `/tmp/xingyuan-ai2-agent-a3-screenshots-20261028.sha256` (all36 PNG hashes) | `eb86c9fd08282c69faba6f273a65475f5bb70e11e33519e54523e4048c2fac0b` |

Focused/UI counts are subsets of App full discovery, not additional unique tests.
The nine storage cases cover concurrent/later-day receipts, stale editors,
unrelated-day partials, valid future-day midnight confirmation, second-write SQL
fault/rollback/retry, mid-write midnight/consent changes, failed requery and
grant-before-read. Nineteen UI cases cover four changes across light/dark and
1x/3.5x, plus revoke/cancel/double-tap. Nine trace cases cover both modes/themes/
sizes and normal/reduced-motion behavior. Four deadline cases use a shortened
one-second run with 1100ms barriers at commit entry or final identity validation,
plus immediate/cancel controls; they are not real60-second or native observations.

`git diff --exit-code 35fb55d -- server packages tool ios assets .github
drift_schemas lib/data/local/app_database.dart lib/data/local/app_database.g.dart
pubspec.yaml pubspec.lock test/drift/generated` is empty. Backend/core/offline eval,
DST and generation were not rerun: their earlier385/128/58/13 and33 unchanged
generated-file hashes belong to the [A2 evidence](agent-a2-app.md), not this run.

## Retained Failures

- `first-red`:39 passed/13 failed, exit1. A newly added unknown schedule with the
  same issue index was wrongly confirmed; four recovery-UI checks and eight trace
  expectations failed. Confirmation binding and explicit recovery were added.
- `c24-patch-red`:0 passed/8 failed, exit1. The raw patch lacked a Material
  ancestor and overflowed horizontally by14px at320px/3.5x.
- `fixed`:51 passed/12 failed, exit1. Eight reduced-motion tests exposed
  RenderAnimatedSize mutation during its own layout; four old tests expected one
  combined tool/time Text. The reduced-motion path bypasses animation; tests now
  locate the preserved row key and tool label instead of the old text grouping.
- `boundaries-red`:27 passed/1 failed, exit1. Stale edited proposal content created
  a goal. Persisted-content comparison now rejects it before writes.
- `focused`:76 passed/2 load failures, exit1. A new capture wrapper had a misplaced
  MediaQuery parenthesis; correcting that QA syntax yielded84/84, exit0 in
  `focused-fixed`. The second load failure was compiler cascade, not another bug.
- `deadline-red`:QA compilation failure, exit1, missing Drift extension import.
  After fixing only the import, `deadline-red-fixed-fixture` reproduced both
  deadline bugs:2 passed/2 failed, exit1; each late path left one draft.
- `boundaries-fixed`:88 passed/1 failed, exit1. Deadline protections passed; the
  new normal-animation test disposed its SemanticsHandle in teardown after the
  framework's end-of-test check. Moving disposal before return fixed QA cleanup,
  without changing product behavior or weakening assertions.
- `analyze-final`:one unnecessary-import info, exit1. Removing that QA import
  yields the clean analysis above; first format was already492 files/0 changes.

All logs remain in place. No longer timeouts, silent retries or relaxed consent,
data, save, text-scaling or cancellation assertions were used.

## Screenshots And Limits

36 PNGs in `/tmp/xingyuan-ai2-agent-a3-final-chinese-20261028/`:16 change notices,
four awaiting capsules, eight trace states, four existing confirmation states and
four D5 banners. The Chinese-font test also checks nonblank text-region pixels.
Eight images were personally inspected:

- `a3-conflict-light-1.0.png`
- `a3-partial-dark-3.5.png`
- `a3-midnight-dark-1.0.png`
- `a3-daily_cap-light-1.0.png`
- `c24-light-1.0-running.png`
- `c24-dark-3.5-running.png`
- `c24-waiting-light-1.0.png`
- `c24-waiting-dark-3.5.png`

These are320x568 widget captures. Large-text captures deliberately scroll to the
notice/capsule; items and actions are reached separately by scrolling, not all
visible in one screenshot. Isolated trace fixtures have no Scaffold/ambient
Material and include the test DEBUG ribbon/black unused background; these are
not full-screen product screenshots. The other28 images were generated and
pixel-checked but not individually visually reviewed. Full visual judgment
belongs to Claude. No simulator/phone/OS maximum-font/IME/VoiceOver evidence is
claimed, and no phone/B/production operation was performed.

## Independent Work And Remaining Gates

A1-137's offline scoring skeleton is received by source report only:
`2744e2db76daae3296e78c7ec1ffddcfb38833d7`, report SHA256
`1f1c60307e9e90a154737aab60d0d3e16c71363b8e705cacdab5909d1d2c3446`.
Its114 tests were not rerun or merged here. Handwritten tracks are not product
execution or a20-case model benchmark. A1-138's independent deadline red prompted
the two local reproductions above; independent verification of the fix remains.

A2/A3 independent acceptance, Claude visuals, native and owner gates remain open.
AG01/AG04 semantic honesty/AG09/A4 are not completed by scripted tests or D5
banners. A0 is fixed at29/30; no configuration/credential reads, model requests,
ledger resets, replay or extra budget. No changes to privacy, C2 bubbles,
journal1000/5000 visible-character limits, draft/undo or deployment permissions.
CI follows D7: record the new exact delivery once; old terminal runs are not
queried/rerun. Billing-not-started is neither a pass nor a product blocker.
