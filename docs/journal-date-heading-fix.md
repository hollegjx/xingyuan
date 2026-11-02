# R10 Date Heading

October 26, 2026, Asia/Shanghai. CO-11, existing J12/J13. Development candidate,
not native, owner or release acceptance.

## Immutable Scope

- Baseline: `abe3a186761fbce9f7dd6a31493cf108cfb8cf6a`.
- Failing regression: `3819fcc13b313e48dabb3ad5565f84885703d459`.
- Final product/tests: `945fcb533b0d9abef0f78c508e0d6d09dc701409`.
- Candidate branch: `codex/journal-date-heading`. Exact final documentation
  commit, verified remote and new CI are recorded in the normal AI2 outbox.

Runtime delta is one line in ChatDiaryPage: visible "日期", semantic label
"日记日期". The existing Row/Expanded, calendar, ListTile, date rendering,
picker, preview/save/store/identity/backend and dependencies are untouched.
No text scaling cap, maxLines, ellipsis, new component or implicit day selection.
Only the coordinator-authorized63-line R9 Local Decision And R10 review section
is integrated with delivery. No historical backlog or independent QA merge.

## Verification

| Execution | Source | Result |
| --- | --- | --- |
| Narrow Chinese geometry before | 3819fcc, baseline product | 0 passed/1 expected geometry failure,1s,exit1 |
| First post-fix six cases | working source before945fcb5 | 0 passed/6 test-lifetime failures,3s,exit1 |
| Final Chinese font/captures | 945fcb5 | 6/6,3s,exit0 |
| Default test font, same six | 945fcb5 | 6/6,3s,exit0 |

Separate runs, not one12-case or full-App suite. Commands use direct process
exit codes with stdout/stderr redirected to distinct logs, not a tee pipeline.

```sh
flutter test test/chat_diary_date_heading_test.dart --plain-name 'R10 date heading stays on one line 320-4x-dark' --no-pub --reporter expanded '--dart-define=DIARY_CAPTURE_FONT=/System/Library/Fonts/STHeiti Light.ttc' --dart-define=DIARY_CAPTURE_DIR=/tmp/xingyuan-ai2-r10-before-20261026
flutter test test/chat_diary_date_heading_test.dart --no-pub --reporter expanded '--dart-define=DIARY_CAPTURE_FONT=/System/Library/Fonts/STHeiti Light.ttc' --dart-define=DIARY_CAPTURE_DIR=/tmp/xingyuan-ai2-r10-final-20261026
flutter test test/chat_diary_date_heading_test.dart --no-pub --reporter expanded
flutter analyze --no-pub
dart format --output=none --set-exit-if-changed lib test
git diff --check abe3a186761fbce9f7dd6a31493cf108cfb8cf6a
```

Final analysis clean3.0s;292 lib/test files format with zero changes. No shared
fixture changed. The actual date title at320/4x had width256,height184 and two
glyph-box tops19.70549/111.70549. It now has height92 and one top19.70549 in both
themes, retaining4x scaling; ordinary390/1x title height23. The before assertion
checks geometry before checking label text, so it is not a string-only failure.

Four geometry cases also check full numeric date, calendar, one coherent full
accessible name and exactly one tap action, >=44px target and hit testing.
Known-date cancel retains the original date, exact corrected TextEditingValue
and selection. Explicit historical selection reads its existing original and
requires a new merge choice; append preview and final-confirmation cancellation
retain edits without saving. Unknown date has no suggested action or enabled
save, remains unknown on cancel, and changes only after explicit selection.
The unknown flow uses320/4x and the existing Flutter date-picker widget.

Read-only boundaries compare all rows/columns in eight synthetic tables using
the existing readState helper; diary/quick-note photos, entries, proposal,
session/message and identity remain equal. Model/summary calls stay empty and
health calls do not increase. Fixture setup writes have their own baseline;
no real data, credentials, service, model or device is accessed.

## Images And Limits

Before: `/tmp/xingyuan-ai2-r10-before-20261026/r10-320-4x-dark-date.png`.
Final: `/tmp/xingyuan-ai2-r10-final-20261026/`, five PNGs/five distinct hashes:
390/1x and320/4x date in both themes, plus320/4x-dark unknown. All five and the
before were viewed. The adjacent manifest binds945fcb5, seven source/test/helper
hashes and all five dimensions/hashes. Visible title/date are complete without
collision; the long body still scrolls. Captures use real Chinese font aliases
only inside the test process, not production assets or typography changes.

These are widget images/semantics and injected text values, not native iOS,
OS Chinese IME, actual VoiceOver or owner experience. R10 independent review,
remaining editor-title/long4x-error limits, R3 quality and whole J13 remain open.
R9 is accepted only in CO-11's bounded local/widget scope; final-read failure
does not atomically roll back all preview fields. Its existing source/QA CI
pre-start failures were not queried or retried.

## Preserved Failures

The before image and expected split failure remain. after001 reached its
assertions but all six failed end-of-test verification because addTearDown
released SemanticsHandle too late. The final helper uses try/finally around
each semantic inspection. Initial analysis also found one missing-braces lint;
both corrections are test-only and no assertion was weakened. An initial
automation TOML read with the default Python lacked tomllib and changed nothing;
the installed Python3.12 parser then succeeded. The same heartbeat was updated
to10minutes with its other fields compared unchanged; no duplicate was created.

Logs: `/tmp/xingyuan-ai2-r10-{before,after-001,final,default,analyze,analyze-final}-20261026.log`.
No R9 async/store, old native/restoration, model, phone/B, production/backend,
PR1 or terminal-CI replay. Source CI for the new exact candidate is separate;
local results are not a Linux or release pass.
