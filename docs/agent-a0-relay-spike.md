# A0 Relay Capability Experiment

Date: October 27, 2026 (Asia/Shanghai). Assignment: Claude C17, followed by C18.
Owner directly authorized the existing local model-configuration method and
synthetic data only, at most 30 total model attempts. **Finished at 29/30; do not
replay either run, delete its ledger or spend the last call to fill evidence gaps.**

## Conclusion

The existing relay/model supports the required basic Chat Completions transport:
five strict function definitions together, `tool_choice: auto`,
`parallel_tool_calls: false`, direct text without tools, and two-, three- and
four-call conversations carrying actual synthetic tool results by `tool_call_id`.
All 18 observed model tool calls conformed to the experiment's local schema.
A deliberately conflicting candidate was rejected, revised, validated and
submitted as a synthetic draft. This supports proceeding to A1 design review,
not claiming a working App Agent or AG01-AG10 acceptance.

Important limitations:

- The relay accepted an orphan `role: tool` message with HTTP 200. Local
  call-ID/history validation is mandatory; relay acceptance is not protocol proof.
- Invalid strict-schema configuration was rejected with HTTP 400. This is one
  negative configuration probe, not proof that all invalid schemas are rejected.
- A malformed-argument seed was repaired. A malformed-result seed instead led
  directly to text, without the requested requery; recovery is not established.
- Non-ok results reached the model, but only lexical metadata was retained.
  Negated availability statements also match the marker. AG04 semantic honesty
  is **unverified**, not a pass or a detected lie. Do not replay to obtain text.
- Request bodies were 3752..5439 UTF-8 bytes. This does not test a real relay or
  Caddy boundary near 64000 bytes, or establish large-history reliability.

## Scope And Source

The experiment directly contacts only the existing HTTPS relay endpoint
`model-relay.example.com:443/v1/chat/completions`, with `gpt-6-luna`, reasoning `none`,
`max_completion_tokens: 1500`, `store: false` and no redirects. The private
configuration is read inside the process using the existing loader; credentials,
raw model text, requests and responses are not printed or committed. The
endpoint/model are checked before the loader accesses the key. No personal
schedule, memory, journal, photos, device, production server or installation is
used. The `store` request flag is not evidence about the relay's retention policy.

| Source | Commit / digest |
| --- | --- |
| R17 baseline | `9496b79c2adc4cafde6c3072d37e2e0af91913c5` |
| First run, calls 1..25 | `b3dbf9a10bec95aa809337050e13ad614631970f` |
| Four-call follow-up, calls 26..29 | `1e603da74b9bcc7dfab877f17192a59aa35fb0ad` |
| First runner SHA256 | `236972b85b6da7bd23833f919d5162ad95611723bd120391a1ca7ba04d603e7b` |
| Final runner SHA256 | `b523576fb2d26f3a1627b4947593ff378a96f08aa57b201a3fb5ccc3d1c2dddf` |
| Final test SHA256 | `44f9928bffb19193d66ce5f8f81081898bb2f84caa7ccdf3d53f2615a4b833f5` |

Files: `server/tool/agent_a0_relay_spike.dart` and
`server/test/agent_a0_relay_spike_test.dart`. No product runtime changes.
Fixtures are fixed synthetic data, not the future scheduling algorithm: one
known 19:00..20:00 appointment, a returned 20:00/30-minute slot and simple local
validation. The fixture validator is deliberately limited and must not be
reused as an A1/A2 production validator.

Each HTTP attempt is reserved and flushed in a locked durable ledger before
dispatch. Failures/crashes consume attempts. There are no retries. A sample has
a 60-second deadline, each HTTP attempt at most 25 seconds, and the experiment
has a separate aggregate 100000-token debit limit. Missing usage retains the
reservation of request bytes + 1500, not zero. This is an experimental accounting
guard, not a demonstrated tokenizer upper bound or the later per-session T.
The follow-up has a separate one-time claim and shares the same ledger; it did
not restart the budget or modify the first report.

C18 / Goal chapter 8 arrived after these live runs. Preserve this source and its
evidence: the A0 fixture stops on the second equivalent call, caps draft items at
8 and uses the earlier, more conservative missing-usage debit. Those are **not**
verification of C18's third-call stop, 14-item draft or bytes/2 accounting.

## Observed Scenarios

| Case | Calls | Observed outcome |
| --- | ---: | --- |
| general | 1 | Direct text; no tool call |
| preferences | 2 | preferences -> text |
| schedule | 2 | query -> text |
| slots_draft | 3 | slots -> validate(ok) -> draft(ok) |
| conflict_repair | 3 | validate(failed) -> revised validate(ok) -> draft(ok) |
| denied | 2 | query(not_authorized) -> text; semantic verdict unavailable |
| failed | 2 | query(failed) -> text; semantic verdict unavailable |
| truncated | 2 | query(truncated) -> text; semantic verdict unavailable |
| partial | 2 | Model chose query(partial), not slots; then text |
| schema_pressure | 1 | Correct typed slots arguments without injected user_id; deliberately one-call sample ends at its limit |
| argument_repair | 2 | Seeded malformed JSON -> corrected query -> text |
| result_repair | 1 | Seeded malformed result -> text, no requery |
| invalid_strict_schema | 1 | Removing additionalProperties:false -> HTTP 400 |
| orphan_tool_result | 1 | No matching assistant call -> HTTP 200 accepted |
| four_round | 4 | query -> slots -> validate(ok) -> draft(ok) |

The four-round prompt explicitly requests that sequence. It proves transport
continuity with real returned results, not autonomous discovery of the optimal
chain. All five tools are offered in ordinary samples; none is forced with
`tool_choice`. These 15 protocol scenarios include negative probes and are not
AG09's completed quality matrix or AI1's 20 planned evaluation scenarios.

## Per-Attempt Measurements

Milliseconds include the request and bounded response read. Tokens below are
reported prompt + completion = total, except the explicitly missing usage row.
There were 28 HTTP 200 responses and one HTTP 400 (attempt 24).

| Attempt | Case | Request bytes | Latency ms | Tokens / missing-usage debit |
| ---: | --- | ---: | ---: | --- |
| 1 | general | 3814 | 3560 | 1039 + 106 = 1145 |
| 2 | preferences | 3811 | 2784 | 1038 + 16 = 1054 |
| 3 | preferences | 4176 | 3587 | 1098 + 35 = 1133 |
| 4 | schedule | 3811 | 3684 | 1044 + 32 = 1076 |
| 5 | schedule | 4224 | 4489 | 1121 + 35 = 1156 |
| 6 | slots_draft | 3961 | 3790 | 1078 + 58 = 1136 |
| 7 | slots_draft | 4428 | 3026 | 1177 + 43 = 1220 |
| 8 | slots_draft | 4875 | 3121 | 1258 + 56 = 1314 |
| 9 | conflict_repair | 3963 | 2715 | 1078 + 43 = 1121 |
| 10 | conflict_repair | 4436 | 3786 | 1167 + 43 = 1210 |
| 11 | conflict_repair | 4883 | 2818 | 1248 + 57 = 1305 |
| 12 | denied | 3819 | 6568 | 1051 + 32 = 1083 |
| 13 | denied | 4270 | 2785 | 1128 + 39 = 1167 |
| 14 | failed | 3819 | 3318 | 1051 + 32 = 1083 |
| 15 | failed | 4262 | 2674 | 1126 + 29 = 1155 |
| 16 | truncated | 3819 | 3233 | 1051 + 32 = 1083 |
| 17 | truncated | 4265 | 3499 | 1127 + 33 = 1160 |
| 18 | partial | 3886 | 4491 | 1066 + 32 = 1098 |
| 19 | partial | 4330 | 3598 | 1141 + 48 = 1189 |
| 20 | schema_pressure | 3901 | 5276 | 1070 + 46 = 1116 |
| 21 | argument_repair | 4170 | 2915 | 1092 + 66 = 1158 |
| 22 | argument_repair | 4583 | 2187 | 1169 + 30 = 1199 |
| 23 | result_repair | 4169 | 6948 | 1105 + 36 = 1141 |
| 24 | invalid_strict_schema | 3752 | 2023 | missing; debit 5252 |
| 25 | orphan_tool_result | 3901 | 4752 | 1035 + 23 = 1058 |
| 26 | four_round | 4112 | 4610 | 1105 + 32 = 1137 |
| 27 | four_round | 4525 | 4089 | 1182 + 58 = 1240 |
| 28 | four_round | 4992 | 3068 | 1281 + 43 = 1324 |
| 29 | four_round | 5439 | 3890 | 1362 + 62 = 1424 |

Reported usage totals 32685 = 31488 prompt + 1197 completion; the ledger totals
37937 after the missing-usage debit of 5252. HTTP 400 is not claimed to cost zero.
Latency: min 2023, median 3560, mean 3699.448, nearest-rank p95 6568, max 6948 ms.
Four-call sample: 15657 ms, 5125 reported tokens; bodies grow
4112 -> 4525 -> 4992 -> 5439 bytes. No extrapolation to large real schedules.

## Recommended Protocol

Use Chat Completions for A1, retaining the existing model and endpoint. The
backend provides the five definitions; the client cannot substitute tools,
model, destination, identity, limits or developer/system instructions. Strict
object schemas should reject extra fields, require all declared properties and
use explicit nullable values for optional inputs. Independently validate actual
arguments and tool-result unions locally; the relay is not the trust boundary.

The App supplies a bounded transcript with exactly corresponding assistant
`tool_calls` and JSON-encoded `role: tool` results. Reject orphan, missing,
duplicate, reused, wrong-run or uncompleted call IDs before sending; validate
the model response before any repository operation. Tool text is untrusted data,
not instructions. Authentication identifies the device on the backend; local
identity and active grants remain App-owned, never model arguments.

Return a typed text response or a single tool-call response plus bounded usage
metadata. Do not infer a save command or a draft from prose. Mixed text+tool
replies follow C18: process only the validated tool call, not the accompanying
text as an approved draft. Reject multiple calls, including read+submit batches,
before executing any of them. Preserve refusal/length/malformed/error outcomes
as explicit stops rather than manufacturing empty successful results.

The following is **Claude's C18 direction**, not newly implemented behavior:

| Topic | Required A1-A3 behavior / evidence gap |
| --- | --- |
| Date/time | Local YYYY-MM-DD in inclusive [D,D+14], 15 date values; device zone; half-open [start,start+minutes), end <=1440, no cross-midnight. Recheck current date at confirmation; ambiguous/nonexistent local times need deterministic tests. |
| Calls/time | At most six actual model attempts per user request, including failures; one monotonic 60-second deadline, no background continuation. Cancel, identity change or grant withdrawal invalidates pending results. |
| Tokens | T=24000 input+output across the user request; max output1500 per call. C18 missing-usage formula is ceil(request UTF-8 bytes / 2)+1500, never zero. See unresolved hard-bound risk below. |
| Repetition | Canonical tool name+arguments, recursively sorted object keys, arrays unchanged. Second occurrence returns cached result with duplicate status; third stops. New call IDs must not bypass counting. Validate identity/grants before cache access. |
| Result caps | preferences10; schedule60; slots20; validation issues20; draft14. Over-cap returns truncated, never silently promotes incomplete data to ok. Count caps do not replace serialized UTF-8 limits. |
| Draft | App validates actual final items even when model skipped validate. Hard errors return issues for repair while budget remains; exhausted budget shows failure/issues and no confirmation. Partial-only warnings may be shown, per item, with explicit acknowledgment checkbox before confirmation. |
| Save | Latest-data requery/revalidation and existing proposal transaction/idempotency; a new conflict requires new confirmation, not silently changed items. No automatic reminders or formal writes from any tool. |

To retain C18's duplicate status without losing partial/truncated/not_authorized,
recommend a strict duplicate envelope containing the cached result with its
original business status. Do not overwrite that status with a success-shaped
empty result. The second occurrence must not reread private repositories; the
third must neither dispatch another tool nor continue the model loop.

On submit, terminate model generation only after final validation allows a
normal or acknowledged-partial preview. A hard-invalid submit instead returns
its issues for the C18 repair path while budget remains. This reconciles
"submit ends the loop" with chapter 8's explicit repair requirement; Claude
should confirm this interpretation before A2 implements the state machine.

### Budget Risk Requiring A1 Resolution

The observed 28 usages are internally consistent (prompt+completion=total).
That does **not** prove bytes/2+1500 is an upper bound for arbitrary Unicode,
tokenizers or relay framing. The A0 runner's bytes+1500 is also not a formally
proved model-token bound. C18's estimate can be an accounting policy, but cannot
alone establish a hard 24000 actual-token guarantee.

Recommendation for Claude: reserve before dispatch; on absent/inconsistent
usage retain at least the configured estimate and stop the current request,
rather than refunding to zero or continuing with unknown consumption. A1 must
prove a valid input/output reservation bound for this model or fail closed when
it cannot bound the next request. Usage exceeding its reservation must be a
visible budget violation, not silently counted as a successful bounded run.
This is a proposed safety clarification, not an unapproved product change.

Backend enforcement also needs replay-safe accounting bound to authenticated
device+run (attempts/deadline/debit only, no transcript). A wholly stateless
endpoint trusting client counters or replayable receipts cannot enforce a
shared six-call budget. Recommend a minimal durable quota ledger while keeping
conversation bodies stateless; confirm compatibility with Goal chapter 3 in A1.
No new model calls are needed to resolve these deterministic design/test issues.

## Offline Verification And Retained Failures

Final executed source 1e603da: 15/15 offline tests; targeted analysis clean;
two-file format check zero changes. No CLI flags gives expected exit64 before
configuration/network access. These are experiment tests, not production Agent
or whole-server tests. Commands from `server/` using the existing Dart SDK:

```sh
dart test test/agent_a0_relay_spike_test.dart --reporter expanded
dart analyze tool/agent_a0_relay_spike.dart test/agent_a0_relay_spike_test.dart
dart format --output=none --set-exit-if-changed tool/agent_a0_relay_spike.dart test/agent_a0_relay_spike_test.dart
dart run tool/agent_a0_relay_spike.dart
```

The last command deliberately exits64. **Do not add --live or replay the
recorded experiments.** Independent verification should use offline tests and
read-only evidence inspection. The two completed live invocations used
`--live --config` with the existing private local path; only the second added
`--case four_round`. No configuration bytes were copied into this report.

Initial 13 tests passed. A new equivalent-arguments regression then failed:
reordered JSON keys bypassed repeat detection. Preserve the first failing log,
whose initial pipeline lacked pipefail (outer exit0), and the repeated red with
actual exit1. Recursive key canonicalization fixed it; final14 tests passed,
then the four-round follow-up raised final coverage to15. Subsequent piped test,
analysis and live invocations used bash pipefail and their exits were collected.
Read-only Ruby filter_map incompatibility and nonexistent assistant/report-path
lookups were corrected without touching product code; they are not test failures.

## Evidence

Private ignored root: `/path/to/Desktop/git/idea/build/agent-a0-20261027`.
Reports contain metadata only, with runtime/source hashes, each request hash,
bytes, timing, usage and tool/status sequence. No screenshots: A0 has no UI.

| File | SHA256 |
| --- | --- |
| report.json | `e71bfdd8c27c24777abb660f675932d50f9ef4facc2aa338cd99dc2df92e27ad` |
| report-four-round.json | `f22073f5a68f70c3abc2e6742d7112e9bc8437da9beec1df88983a6ce29964a2` |
| ledger.jsonl | `0bfd5db98b6a4b93d2907f51def0ea1438de140f986dacb316e5fca15e225656` |

Logs are in `/tmp/`, with prefix `xingyuan-ai2-a0-` and suffix `-20261027.log`:

| Middle name | SHA256 |
| --- | --- |
| live-001 | `6435513dfe11fa0de4f097164801afa0891089bf2dbdca34eb1631744e7f3bdc` |
| live-four-round | `3c273f660aeeafde2a66aae455620082c3abbcc8095f8bdca6578810166534e0` |
| offline-followup | `d7741fe1c7dab354ab687655e080f383de6499068cfcda6c78b5cc8c9190ae1a` |
| analyze-followup | `6c1099cc8d7c20bd75ed72aef38d79ff92ececc2479f1bdf0972f19ac8d6eb4b` |
| format-followup | `86cbe6234237454cd872d2340a34541d75abeb076ec9f849ac6f88fbd2f5cdeb` |
| repeat-red-final | `9af71d10d9f6b5167303bbe410dc90b620c0d3c2c58c44e047cc4cd29824e373` |

Read-only final audit matched attempts1..29 with29 reservations/completions,
each case/body/debit, both complete reports, the unchanged first-report digest,
runtime/source bindings, usage sums and all aggregate measurements above.
No evidence or ledger was rewritten. Source CI40493143508/head b3dbf9a ended
before any job steps due to account billing/spending limits; terminal annotation
was inspected once. No retry, payment change or Linux-pass claim. Final delivery
SHA and its own CI status are recorded in the AI-2 handoff, not backfilled here.

AI1 A1-130's evaluation specification was read at
`c37f5a415b787d3609d48712c5ea6740f74f5762` (document SHA256
`a9424956ce603fa3fe428049affc1186df60d84dc4013274286a7e460cbc03ce`).
It predates C18 and needs alignment on second/third repeats and partial policy;
it was not edited or committed on AI1's behalf. A1-A4 production implementation,
deterministic acceptance suite, Chinese semantic evaluation, before/after
metrics, App interaction, accessibility and owner approval all remain open.

## C19/C20 Follow-Up (October 27, 2026)

This is an appended disposition, not a revision to any A0 observation above.
Claude accepted the transport evidence and resolved the design questions in
Goal chapter9 D1-D6: invalid submits can return for repair; bytes/2+1500 is a
precharge estimate, not a proven token bound; usage anomalies charge and stop;
a metadata-only durable quota ledger is allowed; duplicates retain the original
business status; deterministic App banners and A4 semantic scoring are separate.
D7 records local acceptance while GitHub billing prevents CI startup.

The owner then directly authorized A1 backend work with fake relays only.
[A1 implementation/evidence](agent-a1-backend.md) covers that separate product
candidate, including history rejection and precharge protections. It does not
retroactively change the experiment's second-repeat stop, draft8, usage formula,
or orphan-tool acceptance. No A0 evidence was replayed/reset, no configuration
was read again and no live call was added;29/30 remains final.

The current AI1 specification is A1-134, commit
`4af7f037ce92b03a9a224c7edee7abb64a3a938a`, SHA256
`63fea682f97e7ad0833b76198ba0a869875bb7f67330f7747ada71fa46ddc998`.
It now aligns with D1-D7 and supersedes the earlier alignment concern, but the
20 scenarios remain not_run. It was read, not modified or committed on AI1's
behalf. A1 backend tests do not satisfy A2-A4, all AG gates, native or owner review.
