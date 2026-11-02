# Agent A1 Backend

Date:2026-10-27 (Asia/Shanghai). Scope:Goal-agent A1, owner's direct request,
Claude C19/D1-D6 and C20/D7. Implementation commits:
`0bdda343f19d27a1da652b83357514f27b1c4a64` and reservation-deadline fix
`71208e47ff11bc333f795cf0811613bf89a6be5e` on `codex/agent`.
Goal decisions were reviewed/committed separately as175ec77 and76b8a13.
Final documentation candidate and exact CI disposition are in handoff A2-88.

**Backend candidate only, pending AI1 independent verification.** No App
executor, private-data tool invocation, status banner, preview or save workflow
was added. All new requests use synthetic data and fake loopback relays. Real
model calls:0. A0 remains29/30, closed; neither its ledger nor configuration
was reopened or modified. No device/B/production/deployment action occurred.

## Interface

`POST /v1/agent/turn` reuses the existing device authentication, origin checks,
per-device active-request protection and bounded body reader. The optional
`agent_ledger_database` configuration selects a separate absolute SQLite path
with an existing parent; absent configuration yields503 `agent_unavailable`.
Tests never read a real configuration. Legacy forced-function paths are intact.

Initial request (all fields required):

```json
{
  "protocol": "xingyuan.agent.v1",
  "request_id": "synthetic-unique-request",
  "run_id": null,
  "turn": 1,
  "now": {
    "date": "2026-10-27",
    "time": "19:00",
    "weekday": 2,
    "time_zone": "Asia/Shanghai"
  },
  "messages": [{"role": "user", "content": "Arrange a synthetic reading slot"}]
}
```

The server issues `run_id`; subsequent turns retain the same request_id and
clock, increment turn, and append exactly one assistant/tool pair to the entire
previous transcript. The returned `tool_call` is echoed in
`{"role":"assistant","content":null,"tool_calls":[...]}`; the matching
`{"role":"tool","tool_call_id":"...","content":"JSON result"}` follows it.
The server scopes IDs as `call_<run_id>_<round>` and forwards these IDs to the
relay. It canonicalizes nested JSON keys without reordering arrays, then binds
the exact issued transcript prefix by digest. Missing/orphan/foreign/reused
IDs, reordered or changed history, wrong device/clock and replayed rounds are
rejected before dispatch. There is no persistent transcript or response cache.

Success responses include protocol/request_id/run_id/turn plus one typed kind:
`text` or `question` with text; `tool_call` with one call; or `stopped` with code.
Budget metadata reports calls, charged_tokens, remaining_ms and violation.
Guard errors retain HTTP status and a stable code (some shared transport guards
use the existing `error` field). Malformed input is400; request size413; run
state409; quota429; disabled ledger503. No error fabricates an empty success.

The five tools are server-owned, strict objects with all fields required and
additionalProperties false. Model, system instruction, tool list, auto choice,
parallel=false, store=false and output1500 cannot be supplied by the client.
Nullable window/daily_cap fields are present, not omitted. User-visible text
limits use graphemes, not scalar counts; structural schema and local semantic
checks are separate. Typed text/question uses the model content JSON envelope
`{"kind":"text|question","text":"..."}`. **This new prompt convention has
only fake-relay evidence; A0 did not prove its live compatibility.** Untyped
prose, malformed/multiple calls, refusal, length and unexpected finishes stop.

## Tool Results And Bounds

Ordinary results are exactly `{status,data}`. Status is ok, not_authorized,
failed, truncated, partial, or invalid (validation tools only). Denial/failure
requires null data. A status is not inferred from an empty array.

| Tool | Data and bounds |
| --- | --- |
| get_planning_preferences | `{preferences:[{text}]}`, at most10, text200 graphemes |
| query_schedule | `{items:[{title,date,start_minute,minutes}]}`, at most60; missing time/duration is null and cannot be ok |
| find_free_slots | `{slots:[{date,start_minute,minutes}],unknown_dates:[date]}`, at most20 slots/15 unknown days; unknown days cannot be ok |
| validate_plan / submit_plan_draft | `{issues:[{index,code}]}`, at most20; codes conflict/daily_cap/date_range/duplicate/invalid_field/unknown_schedule |

Read ranges are inclusive today..today+14, with no midnight crossing. Candidate
items have title<=60 graphemes, start0..1439 and duration5..480 minutes;14 items
maximum, note<=400. Free-slot daily_cap is5..1440 or null. Structurally valid
candidate dates outside the window and midnight-crossing candidates deliberately
reach App business validation for D1 repair; malformed types/unknown fields do
not. Backend checks do not substitute for conflict or final-draft validation.

On a second identical tool+canonical-arguments call, the App must return
`{status:"duplicate",original_status,result}` with the first exact cached
result. Both original status and digest are checked. A third proposed identical
call stops before another tool execution or continuation. This backend check
does **not** implement App cache lookup or the required pre-cache identity/grant
check. After submit only an invalid result may continue for repair; ok/partial
submit is terminal. The App still must validate every displayed/saved draft.

## Quota And Privacy

- Before dispatch, a SQLite immediate transaction charges
  `ceil(actual serialized model request UTF8 bytes / 2) + 1500` against both run
  and daily totals. This includes system/tools/history, not incoming whitespace
  or only the user's text. No await occurs before durable reservation.
- Each run permits at most6 attempts,60 monotonic seconds and24000 accounting
  tokens. Each device/server-UTC day permits40 starts and400000 charged tokens.
  Continuations debit the actual reservation day's bucket across midnight.
  Reservation/SQLite work is deducted from the transport's remaining time;
  if it consumes the deadline, no transport call occurs and the reserved debit
  remains conservatively charged. Two clock-injected regressions cover this.
- Coherent reported usage refunds the reservation difference. Missing,
  inconsistent, excessive or output-over1500 usage stops, retains at least the
  reservation and charges any higher known total. A violation can record debt
  above a cap rather than hide usage. **This is not a proven actual-token bound.**
- Concurrent reservations share SQLite transactions; initial request hashes
  prevent replay-as-new even after restart. Pending crash reservations remain
  charged. A new process cannot resume old runs and returns restart_required.
  Live-run affinity is to one service instance; this is not cross-worker resume.
- Runs expire logically after10 minutes and are cleaned lazily on reservation.
  Daily counters and initial-request dedup hashes retain current and previous2
  UTC days. Cleanup is not a promise of immediate disk erasure or protection
  against an administrator rolling back/deleting the ledger or system clock.
- Persisted fields are hashes of device/request IDs, server-issued run IDs,
  time/count/debit/status metadata. No bodies, tool args/results or credentials
  are persisted. Logs exclude request/device IDs and contain bounded tool/kind/
  stop code, elapsed, round, input bytes, usage and budget violation only.
- Client request, serialized model request and response each must be strictly
  below64000 UTF8 bytes. Tests distinguish63999 transport acceptance from an
  outgoing reservation; whitespace padding does not prove a near64k dispatch.
- The transport has one attempt, bounded response and deadline, no redirect or
  retry, and closes its private HTTP client. No A0 runner/validator is reused.

## Local Verification

SDK prefix:`$HOME/development/flutter/bin/`. Each piped command used bash
pipefail and its actual exit was collected. Logs are in `/tmp/`, prefix
`xingyuan-ai2-agent-a1-`, suffix `-20261027.log`. Final server source/test state
is71208e4. Other suites ran on0bdda34, with their runtime/test/dependency trees
unchanged by71208e4; later documentation does not change runtime trees.

| Directory / command | Result | Log middle name |
| --- | --- | --- |
| server: `dart test test/agent_protocol_test.dart test/agent_ledger_test.dart test/agent_service_test.dart test/agent_process_test.dart --concurrency=1 --reporter expanded` | 62/62, exit0 | targeted-deadline-final |
| server: `dart test --concurrency=1 --reporter expanded` | 385/385, exit0; includes isolated backup CLI build and offline A0 tests, no live | server-full-final |
| packages/xingyuan_core: `dart test --reporter expanded` | 128/128, exit0 | core-full |
| tool/assistant_eval: `dart test --reporter expanded` | 58/58, exit0; offline | eval-full |
| root: `flutter test --reporter expanded` | 1521 passed,8 failed, exit1 | app-full |
| root: `flutter test test/journal_ui_test.dart test/journal_writing_space_test.dart --concurrency=1 --reporter expanded` | 28 passed, same8 failed, exit1 | app-failure-isolated |
| root: `TZ=America/Los_Angeles flutter test test/moment_label_test.dart --reporter expanded` | 13/13, exit0 | dst |
| root: `flutter analyze`; three Dart packages: `dart analyze --fatal-infos` | All clean | app-analyze, server-analyze-final, core-analyze, eval-analyze |
| root: `dart format --output=none --set-exit-if-changed lib test integration_test tool` | 384 files,0 changes | app-format |
| server: same format on lib/test/tool/bin; core and eval: lib/test/bin | 63/23/21 files,0 changes | server-format-final, core-format, eval-format |
| root: `dart run build_runner build`; `dart run drift_dev make-migrations --no-test`; `dart run drift_dev schema generate drift_schemas/app_database test/drift/generated` | All exit0; generated code/schema/lock diff empty | generation, migrations, schema |
| server: `dart build cli --target=bin/server.dart --output=build/server` | Packaged binary built, exit0 | server-build-final |
| server: `dart run tool/pairing_process_probe.dart "$PWD/build/server/bundle/bin/server"` | Reviewed local-only synthetic probe passed; restart/privacy/auth, model_calls0 | packaged-process-final |

The existing backup export shell syntax check (`sh -n
deploy/export-companion-backup.sh`) also passed without executing/exporting it.
The initial build/process logs (without `-final`) remain bound to0bdda34; the
final ones above use71208e4. This is a macOS package check, not Linux CI or deploy.
Explicit-path diff checks and an added-content secret-pattern scan passed;
the unrelated diary review and synchronization files were not staged or changed.

New tests include exact budget/deadline/size boundaries, simultaneous charging,
UTC rollover, restart rejection in a real isolated child process, history
tampering, malformed results, denial/partial preservation, second/third repeat,
invalid-submit repair, auth revocation, redirects, upstream/timeouts and log/
SQLite privacy sentinels. None is a live semantic or native UI result.

App failures: four3.5x diary/keyboard cases cannot hit journal-ai-request;
four4x writing-space cases time out in waitForPhotoAction/pumpAndSettle. The
same failures reproduced serially. The entire lib/test/packages/tool/ios/assets/
integration_test and App dependency trees are unchanged from f9d3d8c. No test
assertion or unrelated App code was relaxed. These need separate Claude/AI1
triage; they are not silently waived or evidence of a green whole repository.

Before the final deadline fix, targeted-final60/60 and server-full383/383 passed;
these intermediate results are retained, not substituted for the final tests.
Retained first failures: route-red (404 expected503), submit-red (D1 candidate
incorrectly stopped), grapheme-red (scalar vs visible-character limit). Each
failed before its corresponding fix. first-tests had38 passed/1 test-fixture
TypeError when assigning null to an inferred non-null map; the fixture was
corrected. analyze-initial/style and analyze-second/unused-import logs remain.
reservation-deadline-red had0 passed/2 failed: expected55000ms but received60000,
and expected zero dispatch but received one. The fix measures again after the
transaction and stops before transport if time is exhausted. Two rejected
documentation patch attempts made no changes and were corrected before commit.
No failure log was overwritten with a successful rerun.

## Remaining Acceptance

AI1's current spec is4af7f037ce92b03a9a224c7edee7abb64a3a938a, document SHA256
63fea682f97e7ad0833b76198ba0a869875bb7f67330f7747ada71fa46ddc998; it was read only.
Twenty scenarios and full AG acceptance remain not_run. A2 must supply local
tools, grant-sensitive duplicate caching, cancellation/identity protection,
forced final validation and D5 banners. A3 supplies requery/revalidation and
explicit transactional confirmation. A4 needs separately authorized live
quality/semantic evaluation, including the new text/question envelope.

No screenshots were produced: A1 has no new UI. No iOS build, simulator/phone,
VoiceOver, owner trial or release approval is implied. D7 permits local evidence
while billing blocks CI startup, but neither CI nor whole-App tests are marked
passed. Exact new CI evidence belongs to A2-88; old terminal CI is not queried.
