# Agent A4 Offline Preparation

2026-10-28, Claude C25. This is preparation, not A4 live-model acceptance.
Base candidate: `558b48f64bf6e3c636474870771548d745d5dafe` on `codex/agent`.
Implementation: `a47faf201a8ea7e14425b801c37e5982d4d92ab1` (34 reviewed paths).
The documentation delivery SHA and its new CI are recorded in A2-92.

## Scope And Provenance

- Reviewed/copied eight framework files from AI1
  `2744e2db76daae3296e78c7ec1ffddcfb38833d7`; no merge of its independent report,
  old branch history or unrelated QA. Framework code/tests/fixture provenance
  is retained in `tool/assistant_eval/AGENT_EVAL.md`.
- Real `AssistantConversationRunner` selects Agent mode. Real local tool source,
  executor, final validator, proposal store and confirmation transaction operate
  on a fresh in-memory SQLite database for each scenario. Read-only observation
  callbacks receive cloned results; production leaves them unset.
- The actual HTTP App service calls a bound `127.0.0.1` Agent backend using a
  generated synthetic device credential. The actual backend/model client calls
  a wire-format fake relay on loopback. No alternate implementation of the loop
  or prewritten scoring trajectory supplies the observed result.
- Synthetic fixtures include original goals/schedules, another identity's goal
  and check-in, diary/note drafts and photo metadata. Protected rows are hashed
  before/after. Outbound JSON and backend logs are scanned for canaries; process
  logs and rendered UI are deliberately not asserted as observed.
- `agent-v1` lives in `server/lib/src/prompts/agent_v1.dart`; the Agent body uses
  that constant. General questions need no private queries, missing data is not
  availability, only locally validated drafts are allowed, and arrangements
  cannot be invented. The original legacy assistant/diary prompts are unchanged.

## Budget And Live Interlocks

Only `--scripted` runs are authorized here. `--live` requires an explicit
authorization marker and config path. The CLI checks the marker before output
creation or worker launch; the worker checks again before claiming quota and
loading configuration. Marker fields are id, scope, owner_authorized, max_calls,
expires_at, endpoint and product_digest. Scope is `xingyuan-agent-a4-synthetic`,
endpoint is the existing authorized relay, quota is 1..300 and expiry must be UTC
and in the future. Marker permissions are owner-only. This is a local interlock,
not cryptographic proof or a substitute for the owner's direct conversation.
No real owner authorization marker was created or consumed by this work.
Temporary synthetic markers exercise startup rejection with a missing synthetic
configuration, before any credential or model access.

For future live use, the authorization id selects a fixed SQLite ledger under
`$HOME/Library/Application Support/XingyuanAgentEval/authorizations/`, outside
build artifacts and independent of checkout/output directory. An exclusive
claim file survives crashes and missing SQLite files; a second claim fails.
Each model attempt is reserved in a FULL-synchronous transaction before the
transport, failures/pending attempts count, and settlements never refund calls.
No automatic scenario/HTTP retry or resume exists. Expiry is checked before
every attempt. Each base scenario is attempted at most once in the current
driver; the 300 ceiling is not permission to repeat or select the best run.
Manual ledger/claim deletion or inventing another marker id is forbidden;
this local guard does not defend against a person deliberately rewriting files.

The existing model-config loader now optionally checks an exact destination
before credential selection, using the same parsed config snapshot. Legacy
callers have no new requirement. C25 tests only read newly generated synthetic
configs and never call a real endpoint or Keychain. A0's 29/30 ledger and old
processes are untouched, and its remaining call cannot be used here.

## Evidence Meaning

The final scripted CLI run executes 18 base scenarios with 34 loopback relay attempts.
The report deliberately has 18 incomplete, 2 not_run, 0 passed and 0 failed:
logical expectations pass, but rendered presentation and process-log privacy
coverage are missing. Exit 3 means incomplete, not product failure or success.
Every semantic rubric remains needs_human; the manual reviewed count is zero.

- S10 remains not_run: the frozen fixture has 60 one-minute schedule rows;
  actual SQLite allows 5..480 minutes. We do not rewrite the fixture or bypass
  database constraints to fabricate a passing truncation experiment.
- S20 remains not_run: the oversized Chinese/emoji/injection fault adapter is
  not implemented. Normal bounded tool results are not substituted for it.
- S15/S16 cancellation and identity change are triggered while the fake relay
  is pending; its late result is released after the App has stopped, then all
  backend work is drained. This is not an OS/device or real-relay race test.
  Actual App failure kind and the measured identity lease, not injected intent,
  determine the terminal reason. Raw failure kind stays in adapter diagnostics.
  These pending-fault injections are disabled/not_run in future live mode until
  separately implemented; they are not silently treated as normal live cases.
- S18 injects a new conflict before confirmation and observes rejected save.
  S19 explicitly cancels, then confirms twice and observes only two new goals.
  Confirmation actions are harness commands, not owner/device interaction.
  Formal rows are captured before confirmation and after apply; digests derive
  from actual persisted title/date/time/minutes, and row owner/type/reminder
  validity is checked. Premature writes and correct-count/wrong-content writes
  have failing negative controls. These are checkpoints, not continuous SQL tracing.
- Model bytes are the serialized outbound body, usage is actual fake response
  usage, and tools/results/validation come from actual callbacks. Persistent
  previews have a separate `preview` event, never a rendered `draft`/banner.
  Unknown query necessity remains unknown, not a keyword-based quality score.
- Metadata hashes source, prompt/version, schemas, model mode and parameters;
  fixture digests remain exactly the frozen inputs. The paired comparison is
  conservative: product hashes include prompt source, so even a prompt-only
  source change currently disables automatic paired deltas. Versioned files and
  complete reports can be reviewed side by side; prompt-only causal comparison
  needs a reviewed fingerprint policy before claiming automated attribution.
  Live wire_calls is null/unobserved, never a fabricated zero; model_attempts
  is separately counted by the pre-transport reservations.
- Local raw traces contain only synthetic text for later review. JSON/Markdown
  reports whitelist metadata/numeric findings and do not export prompt content,
  tool result text, receipt/device credentials or raw backend logs.

## Verification

All commands use `/path/to/development/flutter/bin/`. Local execution is
wrapped in `sandbox-exec -p '(version 1)(allow default)(deny network*)(allow network* (local ip "localhost:*") (remote ip "localhost:*"))'`.
No new network/SDK/service was installed. Offline pub resolution adds only root
dev path dependencies and marks the already locked sqlite3 dependency direct.

Log names below use `/tmp/xingyuan-ai2-` plus the listed stem and
`-20261028.log`. Commands are run in the stated directory with the sandbox
prefix above; Flutter uses `--no-pub`. Subsets overlap the App total and must
not be added as independent cases.

| Directory / Command | Result / Log Stem |
| --- | --- |
| Root: `flutter test --no-pub --reporter expanded` | 1690/1690, exit0, 3m44s, `a4-app-exclusive`; other gates stopped for this run |
| Root: `flutter test --no-pub test/agent*_test.dart test/drift/agent_migration_test.dart --reporter expanded` | 141/141, exit0, `a4-agent-final` |
| Root: `flutter test --no-pub test/agent_evidence_regression_test.dart test/agent_headless_driver_test.dart --reporter expanded` | 8/8, exit0, `a4-evidence-final`; includes real 18-case driver |
| Root: `flutter test --no-pub test/agent_subscription_lifecycle_test.dart --reporter expanded` | 2/2, exit0, `a4-lifecycle-isolated`; no source changes after failed full run |
| `server`: `dart test --concurrency=1 --reporter expanded` | 387/387, exit0, `a4-server-final` |
| `packages/xingyuan_core`: `dart test --reporter expanded` | 128/128, exit0, `a4-core-final` |
| `tool/assistant_eval`: `dart test --reporter expanded` | 125/125, exit0, `a4-eval-final`; includes crash/concurrent claimant and actual CLI denial |
| Root: `TZ=America/Los_Angeles flutter test --no-pub test/moment_label_test.dart --reporter expanded` | 13/13, exit0, `a4-dst-final` |
| Root: `flutter analyze --no-pub`; each of server/core/eval: `dart analyze --fatal-infos` | Four clean exit0 results: `a4-analyze-final`, `a4-server-analyze`, `a4-core-analyze`, `a4-eval-analyze` |
| Root: `dart format --output=none --set-exit-if-changed lib test integration_test tool server packages` | 516 files, zero changes, exit0, `a4-format-final` |
| `server`: `dart build cli --target bin/server.dart --output /tmp/xingyuan-ai2-a4-server-cli-20261028` | exit0, `a4-server-build`; compiled only, not deployed |
| `tool/assistant_eval`: `dart run bin/agent_run.dart --scripted --output /tmp/xingyuan-ai2-a4-cli-final-20261028` | exit3/incomplete as designed, `a4-cli-final`; 18 executed, 34 fake attempts, no automatic failure |
| Root: `dart run build_runner build` | exit0, `a4-build-runner`; 37s, generated tracked content unchanged |
| Root: `dart run drift_dev make-migrations --no-test` | exit0, `a4-migrations`; healthy CPU-heavy run allowed to finish, not interrupted |
| Root: `dart run drift_dev schema generate drift_schemas/app_database test/drift/generated` | exit0, `a4-schema` |
| Root: `shasum -a 256 -c /tmp/xingyuan-ai2-a4-generated-before-20261028.sha256` | 32/32 unchanged, exit0, `a4-generated-check`; baseline taken after intentional offline path-dependency lock edits |

Runtime/test/index content remained identical after these generators; no
post-test code change or unreviewed generated delta was committed. Early
evidence is retained separately:

- `/tmp/xingyuan-ai2-a4-scoring-red-20261028.log`: new missing-presentation case
  failed with unknown preview event; the explicit headless contract fixed it.
- `/tmp/xingyuan-ai2-a4-driver-first-20261028.log`: new adapter missing type
  import, compile failure; second log has the real 18-scenario adapter test pass.
- `/tmp/xingyuan-ai2-a4-budget-first-20261028.log`: initial nine checks passed;
  later crash/concurrent-process and CLI denial coverage is additional.
- `/tmp/xingyuan-ai2-a4-analyze-first-20261028.log`: two missing braces, four
  unnecessary assertions and two implementation imports, subsequently corrected.
- `/tmp/xingyuan-ai2-a4-cli-first-20261028.log`: actual CLI -> Flutter headless
  -> backend -> fake relay -> report, exit3; initial outputs in
  `/tmp/xingyuan-ai2-a4-cli-20261028/` are retained, not overwritten.
- Multi-file apply_patch context mismatches were rejected atomically and
  corrected, including one later documentation-only mismatch.
- Read-only review identified disposable quota state, fabricated write digests,
  intended-vs-observed cancellation and live wire-count ambiguity. Three initial
  failures and six expanded regressions are retained in `a4-evidence-red` and
  `a4-evidence-red2` logs; fixed2 passes all seven combined checks. The first
  fix exposed S16's HTTP-cancel/identity-discard race as an actual report failure;
  `a4-evidence-fixed1` and `a4-cli-debug` are retained. Attribution now requires
  an observed changed lease and actual cancellation/discard, never arbitrary
  network/timeout relabeling. A follow-up discarded-with-unchanged-lease negative
  control failed in `a4-discard-red`; the default classification now remains
  protocol unless an identity change is measured. Final evidence regression and
  real-driver checks pass 8/8. No assertion was weakened to turn the report green.
- `a4-app-delivery` completed 1689 passed/1 failed, exit1, while other local
  gates were active. The existing subscription lifecycle test failed at its
  cleanup `agentRequests.single` with no request. Unchanged Agent141 and isolated
  lifecycle2/2 passed. Root cause is not proven; neither resource contention nor
  a product defect is asserted. The full run with other gates stopped is recorded
  separately above and passed 1690/1690. This does not erase the earlier failure
  or prove its cause. No test assertion, timeout or cleanup was changed.

## Retained Artifacts

The final CLI output is `/tmp/xingyuan-ai2-a4-cli-final-20261028/`:

| Artifact | SHA256 |
| --- | --- |
| report.json | `d18e628088a096289c66a6b744c2c517b87863e4facf770a0bc98c8f796a6056` |
| report.md | `89abb83c7176609fb3693fa79d6fb2cf10ecfccc5572582282b130f6d186f095` |
| adapter-evidence.json | `b40cd35bae940ff87fad9d5572724196e3bab2805e625b24610cbc770d595dfc` |
| synthetic-traces.json | `6d33f69b93bb2b8484299b8389fdf66388a0d2de16ec4733fd8743490ac6a805` |
| evaluation.sqlite | `6110020806af1392a134ede48380b89172af205006efead1d9f4b35499b309ec` |

The 41-entry local evidence hash manifest, including retained failure logs,
final gate logs, generation baseline and these five final artifacts, is
`/tmp/xingyuan-ai2-a4-evidence-20261028.sha256`, SHA256
`90be7ede725d65afaeaa0c62193fb83c8a90dd55cb8938896a32a229ff8b02db`.

Report metadata product digest is
`0686de9a8d7c253fdad3d1c5eaf029dfda03e5d4868f3e8c77bd4fad30d1533a`,
test/adapter digest
`a0e6f3e9fdee5222eb609d23046208a7a651c4332ffe58df3434bbd52175ccf6`.
The copied fixture remains byte-identical to AI1's original, SHA256
`0ac34cc7747348e804bd1d420ba2c87a70253a626b886256c19db4af1d15581f`;
its scorer CLI, fixture parser and original 861-line test remain byte-identical.
Trace/scoring/report extensions and their new negative controls are separate.
The 34 staged source/test/lock paths matched the verified working files;
4303 added lines had zero checked credential-pattern matches. The unrelated
diary review file retained SHA256
`6796c20d8a697b870f0ea7f48621c72db1ff6ba3e643058a7ffa7b9baba510cb`;
sync metadata and the previous recovery stash were not modified.
C25 implementation/review/local gates occupied approximately 03:16-04:14
Beijing on October 28, followed by documentation/handoff. This is wall time,
not an estimate of human effort or a delivery promise for remaining A4 gates.

## Remaining Gates

No screenshots are produced by this headless path. C24/Claude visual review,
current A4 independent QA, native/IME/VoiceOver/OS text sizes, actual model semantics,
AG acceptance, owner trial, deployment and B installation remain separate.
AI1 A1-140 independently accepted the older 558b48f A3 offline boundary;
that evidence was read and hash-checked, not rerun or inherited by this increment.
AI1 A1-141's native permission request remains in its own thread; no duplicate
request, device action or permission expansion is made here.
Existing terminal billing-blocked CI is not repolled. D7 uses honest local
tests; only the new exact delivery SHA gets a new CI record, no payment or
workflow changes. No owner action is required to reproduce these offline tests.
