# J13 R3 Offline Coverage

October 26, 2026. CO-2 baseline:
`3526be80e237b7edad04f205af35418c19cff412`.
Scope: J09/J13 request retention, privacy and executable evaluation fixtures.
No product, prompt, schema, dependency, platform or deployment change.

## Evidence Boundary

Every response in `tool/assistant_eval/test/fixtures/journal_r3_responses.json`
is handwritten synthetic text, not a model output or generated before/after
comparison. There were zero live model requests and no credential/config reads.
The seven earlier calls were not replayed. No simulator, phone, B, backend,
formal app, real diary or photo file was used. This test-only slice has no new
screenshots and does not close native, visual, semantic or owner acceptance.

Reviewed the committed AI1 `journal_experience.dart` runner and R3 proposal in
`docs/journal-diary-coordinator-delta-qa.md` at
`49ad0c84b8fb61a74f6fb5b4f3cdfb2cabfca2c2`; did not copy its live-config runner
or read uncommitted work/private reports. Its three editor and four single-turn
chat inputs do not cover these multi-material/current-history cases.
Existing `DIARY02-mixed` already covers a completed reading item, unchecked
running and one intention note. Its ten-case live matrix and CLI are unchanged.

## Bounded Cases

| Case | Additional input coverage | Human semantic criteria |
| --- | --- | --- |
| R3-MULTI | Two goals plus three independent, chronologically saved notes: a difficult paragraph, two breads bought after work, undecided evening walk | Keep one chapter completed, difficulty/frustration, two breads and undecided intention. Unchecked running is neither proof of exercise nor proof it never happened. No invented companions, meal, duration, causal connection or upbeat resolution. |
| R3-CORRECTION | Five current-session messages: original claim, acknowledgement, explicit correction, acknowledgement, diary request | Follow the correction: alone, library, one chapter. Keys may be at home and remain missing. Old companion/place/count can only be mentioned as explicitly corrected, not current facts. Date stays null for local selection. |
| R3-NEGATIVE | Sufficient undated material: bag/coat search, missing keys, possible office location, frustration and no solution | Preserve uncertainty, negative voice and unresolved ending. Do not invent discovery, certainty, reassurance-as-fact or a moral. Return a draft without substituting a mandatory date interview; local date selection is still required before saving. |

Inputs live in `journal_r3_cases.dart`, reusing `JournalAiCase` and the existing
chat `sample` builder. The shared `checkJournalAi` now accepts `TurnResponse`,
requires a diary proposal and rejects unrelated plan/memory operations. Date
deferral is opt-in for the two undated fixtures, not a ban on explicitly dated
chat diaries. No production semantic filter is introduced.

## Executable Layers

`test/journal_r3_request_test.dart` uses real stores/builders and in-memory SQLite:

- Editor projection retains all three saved notes in creation-time order and
  both goal statuses/check-in text. Distinct timestamps avoid random-ID ordering.
  An unsaved edit cannot replace the saved source or be mutated by building.
- Real begin/build/recordRequest/commitResponse retains every current-session
  role and message in order, including original and corrected details. The final
  request has diary capability; it does not create a diary proposal or save.
- Seeded historical notes/diaries, today's private diary, unsaved note/photo,
  another owner's saved note/goal, other-session user/reply and saved check-in
  photo metadata are excluded. Chat also excludes an unrelated saved note today.
- Memory, schedule and stats are explicitly opted out in chat; seeded memory
  and future goal remain local. These may be sent under existing opt-in settings,
  so this is not a claim that all chat context is always disabled.

`tool/assistant_eval/test/journal_r3_test.dart` passes all 19 handwritten outputs
through the real `AssistantModelClient` and an ephemeral loopback fake HTTP server.
Each gets one attempt; the full structured user payload survives serialization,
strict tool schema/capability is unchanged, `store` and parallel calls are false.
These adapter checks and App projection checks are separate deterministic layers,
not a single real-network App-to-model run.

The corpus contains six acceptable examples (two different phrasings per case),
twelve known bad examples and one deliberate lexical blind spot. Invalid prose
is protocol-valid and returned by the adapter; the offline checker catches its
specified status errors, stale corrected detail, unsupported event, forced
optimism, guessed date or missing draft. A separate checker test covers unrelated
plan/memory and the opt-in date constraint. Passing the transport is not passing
semantic review, and a guard failure is not a production rejection mechanism.

## Limits And Future Review

Exact-phrase guards cannot prove truth, material coverage, naturalness, coherence
or emotional fidelity. The blind-spot fixture invents a friend/meal using a
different phrasing and omits other material: it deliberately passes lexical
checks, but the fixture's human disposition is reject. Conversely, quoted or
negated bad phrases can trigger false positives. Do not expand a blacklist and
call that a language-quality fix. No exact prose is the only acceptable answer.
Current conversation tests cover five unsummarized turns, not summary compression,
very long history, every privacy setting, live model variability or all wording.

Proposed future matrix, NOT run or authorized as part of this package:
three cases above, two fresh responses per case (six requests total), on one
frozen approved candidate/model/prompt configuration. Review input and full reply
plus draft side by side; retain every failure without selective retries. Record
source SHA, prompt/adapter digest, model settings and attempt count. Do not replay
the old seven inputs as a substitute for this gap. For each response, a human
records supported facts, lost details, completed/unchecked/intended status,
latest-correction priority, uncertainty/voice, invented additions, readable
organization and date handling, with specific input/output excerpts and reasons.
Two samples only reveal observed gaps; they cannot estimate general reliability.
Only a concrete reproduced defect justifies a scoped prompt/request change and
necessary increment, subject to the existing permission and review boundaries.

## Verification

From the repository root:

```sh
flutter test test/journal_r3_request_test.dart test/journal_ai_controller_test.dart test/assistant_diary_handoff_test.dart --reporter expanded
flutter analyze --no-pub
dart format --output=none --set-exit-if-changed lib test integration_test tool
```

From `tool/assistant_eval/`:

```sh
dart test --reporter expanded
dart analyze
```

Final App focused **43/43**, including three new request projections; full eval
**58/58**, including 21 new R3 tests. App/eval analysis is clean and root format
checks 356 files without changes. Logs:
`/tmp/xingyuan-ai2-r3-{app-final,eval-final,app-analyze-final,eval-analyze,format}-20261026.log`.
No full App/core/server suite, generation, native or live rerun was needed for
this test/eval-only delta. Existing controller/privacy tests remain included.

Retained setup failures: first fake-envelope assertion omitted the existing tool
description (1 pass/19 failures); after correcting the assertion, the old checker
rejected the new chat request type (9 pass/11 failures), then was extended. App
first compilation lacked a goal import; the next run had 40 passes/3 fixture
failures because journal stores require an identity lease. Seeding the inactive
owner's retained row directly in the synthetic DB fixed the fixture without
changing product identity checks. These are harness/coverage development results,
not newly discovered product bugs or model before/after evidence.
The original `app-analyze` log also retains the relative-lib-import lint; the
single shared-fixture import explicitly documents its test-only lint exemption
to avoid copying cases or introducing an App dependency on the evaluation tool.
