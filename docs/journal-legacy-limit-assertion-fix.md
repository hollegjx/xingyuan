# R13 Legacy Length Assertion Repair

October 27, 2026, Asia/Shanghai. CO-18, J01/J02/J13. This is a test-only
compatibility repair, not a product rollback or whole-J13 acceptance.

## Exact Scope

- Baseline/runtime: `149b80dea63a2c78df202f64c3ef5dd56f502e99`.
- Test commit: `73ed6b994d9277f5aeb9dc201de83d0168bb5417`.
- Only code path: `test/journal_interaction_regression_test.dart`, 10 additions,
  five deletions. Other changes in the delivery are owned documentation.
- Runtime, assets, dependencies, integration tests, backend, platform and workflow
  paths remain byte-identical to the baseline. No controller/store/theme change.
- Final delivery SHA and its new CI outcome are recorded in handoff A2-81;
  no earlier terminal CI was queried or rerun.

A1-120 independently passed the original affected14 cases in each font and
three guards on149b80d. CO-18 accepts that bounded result and shown candidate
visuals, but not every related regression. The newly discovered legacy failure
below remains part of the record and is not erased by those earlier passes.

## First Failure

The coordinator ran this once on clean baseline lib/test, before this repair:

```sh
/path/to/development/flutter/bin/flutter test test/journal_interaction_regression_test.dart --name 'validates boundaries and five saves stay local' --no-pub --reporter expanded
```

Result: zero passed, two failed, runner00:02, exit1. Both quickNote and diary
threw `Bad state: No element` at line55 while looking up the removed duplicate
`journal-error` Text. Later correction, five-save, revision and privacy checks
were not executed in that failing run. No data regression was established.

Source: coordinator tool chunk2a8d34, excerpt/transcription at
`/tmp/xingyuan-coordinator-r13-legacy-boundary-first-20261027.md`. This is not
a claim that the coordinator captured a separate raw shell log. AI2 read and
hashed it without rerunning the failure. During this task another writer changed
only the closing wording from `No files` to `No source/test files`; the original
failure text stayed intact. Both observed hashes are retained below. AI2 did
not write this source excerpt or the coordinator review.

## Repair And Checks

The length lookup now requires exactly one full1000/5000 message and no external
duplicate. Original emoji/Chinese/newline input and full over-limit draft checks
remain, with explicit grapheme-count assertions. Corrected text must reach both
the editor and draft while saved entries remain empty. Five taps must still
produce exactly one entry at revision1. Assistant/pairing/chat providers remain
uninstantiated. No skip, expected failure, swallowed exception or deleted test.

Searching `journal-error` across test/integration_test found this stale length
lookup, the same file's invalid-photo error check, R12/R13 absence assertions,
and R13 actual-storage/draft/empty-content checks. Only the stale length lookup
was migrated. Photo cancellation, denial, invalid bytes and three-photo cap
checks remain unchanged and are included in both four-case runs.

The existing `loadDiaryCaptureFont` helper is reused in setUpAll. Without a font
define it does nothing; with the existing STHeiti path it registers test-process
aliases. No product font, viewport, platform variant, screenshot or native
behavior changes. These are still local widget checks, not real IME or VoiceOver.

| Run | Result | Runner time | Exit evidence |
| --- | --- | --- | --- |
| default-001 | four cases passed | 00:03 | runner output; pipeline exit0 was tee only |
| chinese-001 | same four passed | 00:03 | pipefail exit0 |
| default-final | fixed73ed6b9, same four passed | 00:03 | pipefail exit0 |
| analyze-001 | no issues | 2.8s | pipefail exit0 |
| format-001 | one file, zero changes | 0.01s | pipefail exit0 |

All test runs used the final committed test bytes. The initial default command
omitted pipefail; its raw output is retained rather than retroactively claiming
a captured Flutter exit status. A final exact-commit default run supplies that
exit check. There were no test failures in this repair's post-change runs.
These remain four unique cases, not12, and do not replace the earlier14+3 or
any whole-App/native/owner acceptance.

Commands ran from `/path/to/Desktop/git/idea`, with the existing local SDK.
For the first default run only, the same test pipeline ran in bash without
`-o pipefail`, writing `default-001` instead of `default-final`.

```sh
/bin/bash -o pipefail -c '/path/to/development/flutter/bin/flutter test test/journal_interaction_regression_test.dart --no-pub --reporter expanded 2>&1 | tee /tmp/xingyuan-ai2-co18-default-final-20261027.log'
/bin/bash -o pipefail -c '/path/to/development/flutter/bin/flutter test test/journal_interaction_regression_test.dart --no-pub --reporter expanded "--dart-define=DIARY_CAPTURE_FONT=/System/Library/Fonts/STHeiti Light.ttc" 2>&1 | tee /tmp/xingyuan-ai2-co18-chinese-001-20261027.log'
/bin/bash -o pipefail -c '/path/to/development/flutter/bin/flutter analyze --no-pub 2>&1 | tee /tmp/xingyuan-ai2-co18-analyze-001-20261027.log'
/bin/bash -o pipefail -c '/path/to/development/flutter/bin/dart format --output=none --set-exit-if-changed test/journal_interaction_regression_test.dart 2>&1 | tee /tmp/xingyuan-ai2-co18-format-001-20261027.log'
git diff --exit-code 149b80dea63a2c78df202f64c3ef5dd56f502e99 -- lib assets packages server ios .github tool pubspec.yaml pubspec.lock integration_test
rg -n journal-error test integration_test
```

## Manifest And Boundaries

SHA256 values; log names use `/tmp/xingyuan-ai2-co18-` plus `-20261027.log`.
Identical runner-output hashes do not merge the separate executions or prove
distinct typography; no new visual claim or screenshot is made here.

```text
d1b2bba6a217c5b85586d019f804b542f385763b3031364174c81844317e1b3b  baseline test
084da1afb58329a16ddf6c73eabe3c28398efdc2f20ef9eeb19725f89c1acc61  final test73ed6b9
f1827deffafeaaabbe1550184e419658548b33915f7bf4a68e8225e7e7010faa  first-read coordinator excerpt
d35413562687d3be47d90e2bc5c25577fffdca379fa87af3835b999f7939e18b  clarified coordinator excerpt
f2839e61f034a0710f0d63619b33699aada5980b844e05d6143b62ea12563900  default-001
f2839e61f034a0710f0d63619b33699aada5980b844e05d6143b62ea12563900  chinese-001
f2839e61f034a0710f0d63619b33699aada5980b844e05d6143b62ea12563900  default-final
cdd69ddbb28226696be9c9947683c1b51c6e9d07c5212fa2f85214fd6902e279  analyze-001
1685974b88bd671112e17334bdc2abb8ef350e01ae026547459ec7a8307375ec  format-001
a57b0316cc0544f682b8fb9855e14ade79ae77340ef6a01ba9210e25b4c5a5b7  existing STHeiti Light.ttc
```

Independent review of this new delta remains pending. Native/real OS maximum,
IME/UIKit/VoiceOver/Inspector, owner and whole-J13 gates remain open. No new
model/CO31 run, private material/configuration/credential access, CUA/Simulator/
device/B/formal-app/deployment/restoration or paid service action occurred.
The coordinator review and sync files remain unstaged; AI1 reports are not
imported. Only this meaningful test/doc delta advances the existing candidate,
not journal backlog, PR1 or another agent's work.
