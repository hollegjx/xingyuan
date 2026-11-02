# Agent A2 App Implementation And Local Evidence

Date: 2026-10-28, Asia/Shanghai. Assignment: Claude C21, after C22.
Base: `809a5e0c836b9e674210b4006b91cb95df58c9d5`, branch `codex/agent`.
Implementation: `4e053d47e984b35d6931769caeb5c1e6c9288271` (40 code/test/schema
paths). The final documentation/delivery SHA is recorded in A2-90.
This is the App implementation candidate, not A2 independent/native acceptance,
A3 closure, A4 model-quality evaluation, deployment or owner acceptance.

## Implemented Scope

- The shared core now owns the strict request, tool-call and result contract;
  the server imports it without changing its model/tool definitions or quotas.
  The App validates request/run/turn/call identity and budget progression.
- Five local tools check the captured identity, consent and category grant
  before reads and before duplicate-cache access. Results are validated before
  transport. Equivalent second calls use cached original status/data; the third
  stops. Cache lifetime is one run. No journal, quick-note or photo reader is used.
- Schedule projections include only title/date/start/duration, expanding current
  effective habit rules for every requested day. Archived/foreign goals are
  excluded. An overdue single appears once today with unknown start, not as a
  repeating task. The existing model can represent this scope; no new recurrence
  type or historical editing behavior was introduced.
- Free slots are sorted, deterministic, half-open and within one day/window.
  Missing timing remains unknown; known duration still counts toward the daily
  cap. Validated caps persist for that run even after a failed read, and a later
  call cannot relax an earlier cap. Limits are60 schedule rows,20 slots,10 memories
  and14 draft items. Validation reads the full local schedule, not the60-row
  projection. One highest-priority issue per item bounds issues at14 (below20).
  Hard errors take priority over partial warnings. More than14 items is rejected
  by the strict protocol, never silently saved as a shortened plan.
- The runner supports six model calls, a monotonic60-second deadline, cancellation,
  identity/consent/settings invalidation, UTF-8 body<64000 and token preflight.
  The server still reserves its larger exact body including system/tools; the
  client's estimate is an extra guard, not proof of a true token upper bound.
  Bad usage/budget progression, protocol failures and typed server stops cannot
  produce a confirmable draft. There is no automatic retry or unmetered summary.
- Every submitted draft is validated locally against fresh data. Invalid submits
  return their issues to the fake model while budget remains; six invalid submits
  end with a concrete item/problem list and no proposal. Only valid or partial-only
  drafts enter the existing proposal flow, without creating goals.
- Run statuses drive fixed D5 banners, independent of model wording. The process
  disclosure stores/displays only tool name, status and elapsed time, no arguments
  or result content. Conversation history and its existing explicit payload
  inspection remain local content storage, not metadata-only diagnostic logs.
- The functional preview marks affected partial items and requires an initially
  unchecked acknowledgement. Its necessary save guard re-reads/revalidates inside
  the existing transaction and preserves explicit confirmation/idempotency/undo.
  New conflicts, expired dates, lost consent/grant/identity and changed partial
  validation block creation. This supporting work is not full A3 acceptance.
- App inactive/background transitions cancel a pending Agent and do not resume it;
  background sends are refused. This is an App lifecycle guard, not a promise that
  changing an in-App tab cancels the run. Disposing the view also cancels Agent.
- Schema13 adds default-on `agent_enabled` and nullable metadata on messages and
  proposals, preserving old fields. Explicitly switching off uses `/v1/turn`;
  failures do not silently fall back and spend another call. Long conversations
  needing a new summary stop explicitly instead of calling legacy summarization.

## Local Verification

SDK: `/path/to/development/flutter/bin/`. All tests use synthetic data and fake
services or localhost relays, under this per-process network restriction:

```sh
sandbox-exec -p '(version 1)(allow default)(deny network*)(allow network* (local ip "localhost:*") (remote ip "localhost:*"))' <SDK command>
```

Logs below share `/tmp/xingyuan-ai2-agent-a2-` and `-20261028.log`.
No credential/configuration reads, live requests, A0 ledger operations, phone,
simulator, B, production, deployment or network-setting changes were performed.

| Cwd / command | Result / log |
| --- | --- |
| Root: `flutter test --no-pub --reporter expanded` | Final1639/1639, exit0,3m07s; `app-verified`. Earlier1638/1638 in `app-full`; failed QA-import attempt in `app-complete` retained |
| Root: `flutter test --no-pub test/agent_planning_test.dart test/agent_tool_executor_test.dart test/agent_conversation_runner_test.dart test/agent_subscription_lifecycle_test.dart test/agent_transport_test.dart test/agent_ui_test.dart test/drift/agent_migration_test.dart --reporter expanded` | Final90/90, exit0,21s; `focused-verified`. Earlier89/89 in `focused-final`; failed QA import attempt in `focused-complete` retained |
| Root: `flutter test --no-pub test/agent_ui_test.dart --reporter expanded --dart-define=DIARY_CAPTURE_FONT=/System/Library/Fonts/STHeiti\ Light.ttc --dart-define=DIARY_CAPTURE_DIR=/tmp/xingyuan-ai2-agent-a2-final-chinese-20261028` | 11/11 exit0,28s; `ui-final-chinese` |
| Server: `dart test --concurrency=1 --reporter expanded` | 385/385 exit0,1m36s; `server-full`, includes existing A1 production route/ledger/process tests |
| Core: `dart test --reporter expanded` | 128/128 exit0; `core-full` |
| Offline eval: `dart test --reporter expanded` | 58/58 exit0,1m22s; `eval-full`, configured serial CLI tests |
| Root: `TZ=America/Los_Angeles flutter test --no-pub test/moment_label_test.dart --reporter expanded` | 13/13 exit0; `dst` |
| Root: `flutter analyze --no-pub`; each of server/core/eval: `dart analyze --fatal-infos` | All exit0, no issues; final App `analyze-verified` (10.6s), `server-analyze`, `core-analyze`, `eval-analyze` |
| Root: `dart format --output=none --set-exit-if-changed lib test integration_test tool server/lib server/test server/tool server/bin packages/xingyuan_core/lib packages/xingyuan_core/test packages/xingyuan_core/bin` | 488 files/0 changes, exit0; final `format-verified` (11.14s) |

The focused/UI/DST counts are subsets, not additional unique App tests. The full
App discovery includes all135 base test files and seven new Agent test files.
The populated v12 migration tests include file reopen, exact old rows plus explicit
new defaults, owner-isolated settings, failure after each new column, rollback and
retry. Earlier v5/v6/v10/v11 preservation comparisons remain strict, with only the
three specified v13 defaults added to their expectations.

Generation consistency: `dart run build_runner build`,
`dart run drift_dev make-migrations --no-test`, and
`dart run drift_dev schema generate drift_schemas/app_database test/drift/generated`.
All three exited0. The33 generated-source/schema/helper/lock hashes before and
after are identical. `make-migrations` was CPU-active for several minutes;
it was allowed to finish, not interrupted. Generated outputs and locks were
compared to this candidate, not HEAD,
because the candidate legitimately adds schema13. Hash inventories are
`/tmp/xingyuan-ai2-agent-a2-generated-before-20261028.txt` and the matching
`generated-after` file, both SHA256
`857e2c5e6b34466fc127a3ac9b777fa23268c6b1b4cecd437d9441d40bf42ac6`.

| Log suffix | SHA256 |
| --- | --- |
| `app-verified` | `44ccfc5263c20c936734095c0b26487d98d69639f8f4aa6346bfbde3ddcb81e1` |
| `app-complete` (QA compile failure) | `40ab4f9c1af94b1442991bfd9b9027866f8cba7d009d4093d4c827f4ab202e1b` |
| `focused-verified` | `c78a3cb1285d378cb3afc612060ee1f01bdcdd091b05a9c3eb6805618a02b015` |
| `ui-final-chinese` | `bb0f4823f7e3850e01ee32db2fceafcbf1c4b86367345bc24b812cdec2c86066` |
| `server-full` | `4194b40e49bfbfd1d254f1628b6ddb6012b7157211000beade53a5d73da49d29` |
| `core-full` | `bc41e403c5173db40cc5f28316f1e643b30598a60a2ecf47758a01840d5a4467` |
| `eval-full` | `a3e5fbe1fe0e358e4772e1836bdb51af6d6f62ce20a771d5e3c67fdd9878e8f9` |
| `analyze-verified` | `2f5521c7962ad11ba44fd934a0ce45c10f89a82c766b4f11ee47278607903d46` |
| `format-verified` | `522b4d94ca52181e420e9e887d1a3fd00cd7255b077fa225c02f9fe3d33e00ec` |
| `build-runner` | `d6bbd6c401abcd5cdf7e8e442155b05fa27d3bccc36a1f49a54ac4663120f86f` |
| `make-migrations` | `dd35d399349c10aa3a96d7b290940c947560d0a57270cc0c46cfa73c85128ef6` |
| `schema-generate` | `092bdb53ce9f162f2d25f8b904f1d0383937f7cb986c477f559350dfd34533d9` |

## Coverage And Evidence Limits

AI1 reference: `4af7f037:docs/agent-eval-spec.md` (D1-D7).
These are component/scripted checks mapped to its cases, not an executed20-case
model benchmark with quality metrics or full independent acceptance.

| Reference | Evidence in candidate |
| --- | --- |
| S03/S04/S17 | Real local schedule -> slots -> invalid submit -> repaired draft; exact tool transcript/call IDs, final fresh validation, no formal write |
| S05/S06/S07 | Deterministic cap/overlap/missing-time tests; per-item partial and explicit checkbox through actual widget route |
| S08/S09/S10 | Grant-before-read/cache, failed/truncated results and preserved duplicate status; all four fixed banner widgets |
| S11 | Direct-question response with nonempty private schedule/memory canaries, no implicit queries or private payload |
| S12 | D through D+14, midnight/adjacency/range validation; plus14 confirm and expired-preview rejection |
| S13/S14 | Canonical duplicate caching/third stop, six-call/no seventh, budget/body preflight, invalid usage progression and typed restart/quota stops |
| S15/S16 | Pending fake cancellation, identity/consent/grant/mode changes, late-result rejection, shared live subscriptions, injected background transitions |
| S18/S19 | Fresh conflicting/unknown schedule, revoked grants/identity, confirmation retry idempotency; UI cancel/reopen/acknowledge/explicit creation |
| S20 | Exact localhost63999-byte transport and64000/64001 rejection before credential read/network; large combining-grapheme context stopped without truncating input |

63999 transport success does not bypass the runner/server token budget. The
App timeout test uses a shortened150ms deadline, not exact59999/60000/60001ms
wall-clock measurements. The backend's existing fake-clock boundary tests run
in server-full. The failed-banner widget inserts valid failure metadata to test
rendering; query-failure execution is separately checked in executor tests, not
claimed as one end-to-end injected database-failure UI journey.

AG02/03/04-banner/05/06/07/08/10 have the above local evidence only. No independent
A2 review, native lifecycle/OS keyboard/VoiceOver/system maximum font, Claude visual
approval or owner trial is implied. No model semantic AG01/AG04 or AG09 quality
benchmark ran. A0 remains29/30 closed, including its earlier orphan-result and
usage-estimate limitations. A3 fault-matrix and A4 remain separate assignments.

## Retained Failures

All earlier logs are retained, including interrupted diagnostics. Interrupted
process exit0 is not a successful test. No assertion weakening or longer test
timeouts was used to obtain the final results.

- `tools-first`:27 passed/3 failed; two queries returned failed instead of
  partial/truncated, and the cap assertion found no issue. The final executor
  sorts its own copy of repository rows; status assertions are retained. The
  cap retention defect was isolated in `cap-red` (0/1), then fixed without
  relaxing the cap. Authorization-call count assertions match both pre/post checks.
- `transport-migration-first`:94 passed/5 failed. Old expected schema12/row shapes
  were updated to current13 plus explicit defaults, retaining every old value.
- UI diagnostics exposed waiting for shared Drift subscription teardown; the new
  `shared-listeners-red` regressed both normal and cancelled completion (0/2).
  Disabling invalidation synchronously and detaching subscriptions lets the run
  finish while the database remains open; commit still rechecks identity/consent.
- `lifecycle-fixed`:26 passed/8 UI failures. Missing Material for ExpansionTile
  and the long preview label were fixed locally. Full normal UiHarness teardown
  is used; diagnostic prints/custom teardown workarounds were removed.
- `cap-failure-red`:0/1 demonstrated loss of a valid cap after a failed query.
  Caps are now retained before that fallible read.
- `budget-red`:1 passed/4 failed. First-call budget failure now has a specific
  error without fabricating sent payload; zero/unchanged charged tokens are
  rejected, and real backend stop codes map to appropriate messages.
- `save-boundaries`:33 passed/1 failed because the new test omitted production's
  identity lease. Correcting only that fixture and tightening the expected error
  yielded34/34 in `save-boundaries-fixed`; not a new identity product defect.
- `foreground-issues-red`/`foreground-red` include a new QA await-void compile
  error and invalid lifecycle transition. After fixture correction,
  `foreground-corrected-red` independently reproduced missing cancellation (0/1).
  Lifecycle handling and sixth-invalid-submit issue details were fixed;
  `foreground-fixed` passed53/53. Actual injected lifecycle order is retained.
- `analyze-first` had17 formatting-style infos; `analyze-final` had one remaining
  brace info. Scoped style corrections led to the clean analysis above.
- The final direct-question test initially omitted the `MemoryDraft` import:
  `focused-complete` failed compilation (including a compiler-cascade load error),
  and `app-complete` ended1603 passed/1 load failure, exit1. Adding only the missing
  test import produced the final90/90 focused and1639/1639 full results, each
  from its separate command with actual exit0. No product changes were needed.

## Screenshot Inventory

Eight final PNGs in `/tmp/xingyuan-ai2-agent-a2-final-chinese-20261028/` were all
personally inspected. They use synthetic data,320x568 widget capture, STHeiti,
and a test clock of2026-10-09 (runner tests use2026-10-28). No OS chrome is shown.
Confirmation captures are intentionally scrolled to acknowledgement/confirm;
3.5x does not show the items simultaneously, which require scrolling. Both
themes preserve readable controls; final visual acceptance belongs to Claude.

Stable keys include `assistant-agent-enabled`, `agent-stage`,
`agent-data-<scope>-<status>`, `agent-trace-<scope>`,
`agent-item-issue-<item-id>`, `agent-partial-acknowledgement`,
`agent-invalid-draft`, `agent-awaiting-confirmation`, and the existing
`assistant-apply-plan`/`open-proposal-<id>` actions.

| Filename | SHA256 |
| --- | --- |
| `agent-banner-failed.png` | `0ba89b1a91f9615bcfaf955c45bcc31a66dd7277888f0c620a2d208029f7e9cb` |
| `agent-banner-not_authorized.png` | `aaaa66b1d9cea9c2f90ba96a16c4763953e330cf826e7192b6636af4ba61fac3` |
| `agent-banner-partial.png` | `8a4ff8bed7357fafa52c82a5c7acaedba1cca05e1e01ee94730603a2e1dbad59` |
| `agent-banner-truncated.png` | `142c3487314a462b8bdd29f6fccb189b5177ce9cf6536651cd15534ca98c3355` |
| `agent-dark-1.0x-confirm.png` | `f2f605a9491e7b5bf7d25819416e0ca194486366c028e2c5d9c1702809ea8717` |
| `agent-dark-3.5x-confirm.png` | `f68090c769f50b76a4bc887107eedef140e209220f9c7b33a4bbadcb2039757b` |
| `agent-light-1.0x-confirm.png` | `8c37cce49d525d7b42371c4efd491f95c80fe25892df09ac2d2ad3449dfa2865` |
| `agent-light-3.5x-confirm.png` | `f57b9fe22a52ba61310d333401cd75dcae6626b270caa415c1bcc6f98beb3daa` |

## Earlier Independent Evidence

A1-136 independently verified C22 exact809a5e0: original8/8 and App1549/1549,
analysis clean and formatting388/0 (includes its three retained QA files).
Report: `idea-ai1/docs/journal-c22-independent-validation.md`, SHA256
`1cee5a3064856a36ea94d94b1d41c8643ff9daea75296b3ddf9a174b7aeae0d1`.
Read-only receipt, not this author's rerun or independent Agent acceptance.
That report was not edited/staged. C22 CI40549476654 was already confirmed
billing-not-started and was not queried again. New delivery CI is recorded once
in A2-90 under D7; no workflow/fee changes or old reruns.
